import assert from 'node:assert/strict';
import test from 'node:test';
import { checkoutConfigured, handleCheckout } from './paypal-checkout.mjs';
import worker from './workbench-route.mjs';

const origin = 'https://qnsub.com';
const root = '/workbench/checkout';
const orderId = '5O190127TN364715T';
const captureId = '8MC585209K746392H';
const amount = { currency_code: 'USD', value: '4.99' };
const releaseKey = 'releases/Workbench-macOS.zip';

function fixture(t, mode = 'live') {
  const sandbox = mode === 'sandbox';
  const apiHost = sandbox ? 'https://api-m.sandbox.paypal.com' : 'https://api-m.paypal.com';
  const approvalHost = sandbox ? 'https://www.sandbox.paypal.com' : 'https://www.paypal.com';
  const state = { available: true, orderStatus: 'APPROVED', captureStatus: 'COMPLETED',
    amount, merchant: 'TESTMERCHANT', ref: 'workbench-macos', captureCalls: 0, downloads: 0 };
  const env = { PAYPAL_MODE: mode, PAYPAL_CLIENT_ID: 'test-id', PAYPAL_CLIENT_SECRET: 'test-secret',
    PAYPAL_MERCHANT_ID: 'TESTMERCHANT', CHECKOUT_SIGNING_KEY: 'a-test-secret-only-never-used-live',
    WORKBENCH_RELEASE_KEY: releaseKey, WORKBENCH_RELEASES: {
      head: async key => key === releaseKey && state.available ? { size: 5 } : null,
      get: async key => {
        if (key !== releaseKey || !state.available) return null;
        state.downloads++;
        return { body: 'abcde', size: 5 };
      },
    } };
  t.mock.method(globalThis, 'fetch', async (address, init) => {
    const url = new URL(address);
    assert.equal(url.origin, apiHost);
    if (url.pathname === '/v1/oauth2/token') return Response.json({ access_token: 'test-access-token' });
    if (url.pathname === '/v2/checkout/orders') {
      const body = JSON.parse(init.body);
      assert.equal(body.purchase_units[0].custom_id, 'workbench-macos');
      assert.deepEqual(body.purchase_units[0].amount, amount);
      assert.equal(body.purchase_units[0].payee.merchant_id, 'TESTMERCHANT');
      assert.equal(body.payment_source.paypal.experience_context.shipping_preference, 'NO_SHIPPING');
      return Response.json({ id: orderId, links: [{ rel: 'payer-action', href: `${approvalHost}/checkoutnow?token=${orderId}` }] });
    }
    if (url.pathname === `/v2/checkout/orders/${orderId}/capture`) {
      assert.match(init.headers['PayPal-Request-Id'], /^[a-f0-9]{32}$/);
      state.captureCalls++;
      state.orderStatus = 'COMPLETED';
      return Response.json({ id: orderId, status: 'COMPLETED' });
    }
    if (url.pathname === `/v2/checkout/orders/${orderId}`) {
      return Response.json({ id: orderId, intent: 'CAPTURE', status: state.orderStatus, purchase_units: [{
        reference_id: state.ref, custom_id: 'workbench-macos', payee: { merchant_id: state.merchant }, amount: state.amount,
        payments: { captures: [{ id: captureId, status: state.captureStatus, amount }] },
      }] });
    }
    if (url.pathname === `/v2/payments/captures/${captureId}`) {
      return Response.json({ id: captureId, status: state.captureStatus, amount });
    }
    assert.fail(`Unexpected mock request: ${url.pathname}`);
  });
  const get = (path, cookie) => handleCheckout(new Request(`${origin}${root}${path}`, {
    headers: cookie ? { Cookie: cookie } : undefined,
  }), env);
  const post = (path, cookie, values = { order: orderId }, from = origin) => {
    const headers = { Origin: from, 'Content-Type': 'application/x-www-form-urlencoded' };
    if (cookie) headers.Cookie = cookie;
    return handleCheckout(new Request(`${origin}${root}${path}`, {
      method: 'POST', headers, body: new URLSearchParams(values),
    }), env);
  };
  async function start() {
    const reply = await post('/start', null, { price: '0.01', currency: 'EUR' });
    assert.equal(reply.status, 303);
    assert.equal(new URL(reply.headers.get('Location')).origin, approvalHost);
    assert.match(reply.headers.get('set-cookie'), /Secure; HttpOnly; SameSite=Lax/);
    return reply.headers.get('set-cookie').split(';')[0];
  }
  return { env, state, get, post, start };
}

test('fixed price checkout confirms a capture once and delivers a private ZIP', async t => {
  const { state, start, post, get } = fixture(t);
  const cookie = await start();
  assert.equal((await get(`/return?token=${orderId}`, cookie)).status, 200);
  assert.equal((await post('/download', cookie)).status, 403);
  const confirmation = await post('/confirm', cookie);
  assert.equal(confirmation.status, 200);
  assert.match(await confirmation.text(), /Payment confirmed/);
  assert.equal((await post('/confirm', cookie)).status, 200);
  assert.equal(state.captureCalls, 1);
  const zip = await post('/download', cookie);
  assert.equal(zip.status, 200);
  assert.equal(zip.headers.get('Content-Type'), 'application/zip');
  assert.match(zip.headers.get('Cache-Control'), /no-store/);
  assert.equal(await zip.text(), 'abcde');
});

test('rejects unowned and tampered orders and cross-origin capture requests', async t => {
  const { state, start, post, get } = fixture(t);
  const cookie = await start();
  assert.equal((await get(`/return?token=${orderId}`)).status, 403);
  assert.equal((await post('/confirm', `${cookie}x`)).status, 403);
  assert.equal((await post('/confirm', cookie, { order: orderId }, 'https://elsewhere.test')).status, 403);
  assert.equal(state.captureCalls, 0);
  assert.equal(state.downloads, 0);
});

test('never captures other purchases or unlocks pending or refunded payments', async t => {
  const { state, start, post } = fixture(t);
  const cookie = await start();
  for (const change of [{ amount: { currency_code: 'EUR', value: '4.99' } },
    { amount: { currency_code: 'USD', value: '4.98' } }, { merchant: 'WRONGPAYEE' }, { ref: 'another-product' }]) {
    const previous = { ...state };
    Object.assign(state, change);
    assert.equal((await post('/confirm', cookie)).status, 403);
    Object.assign(state, previous);
  }
  assert.equal(state.captureCalls, 0);
  state.captureStatus = 'PENDING';
  assert.equal((await post('/confirm', cookie)).status, 409);
  assert.equal((await post('/download', cookie)).status, 403);
  state.captureStatus = 'REFUNDED';
  assert.equal((await post('/download', cookie)).status, 403);
  assert.equal(state.downloads, 0);
});

test('missing installer prevents order creation and capture', async t => {
  const { state, start, post } = fixture(t);
  state.available = false;
  assert.equal((await post('/start')).status, 503);
  state.available = true;
  const cookie = await start();
  state.available = false;
  assert.equal((await post('/confirm', cookie)).status, 503);
  assert.equal(state.captureCalls, 0);
});

test('unconfigured Worker retains existing product page and refuses checkout', async () => {
  const env = { PAGE_ASSETS: { fetch: request => new Response(new URL(request.url).pathname) } };
  assert.equal(checkoutConfigured(env), false);
  const page = await worker.fetch(new Request(`${origin}/workbench`), env);
  assert.equal(await page.text(), '/workbench.html');
  const checkout = await worker.fetch(new Request(`${origin}${root}`), env);
  assert.equal(checkout.status, 503);
});

test('sandbox uses only test PayPal hosts and labels its dummy download', async t => {
  const { start, post, get } = fixture(t, 'sandbox');
  const page = await get('');
  assert.match(await page.text(), /Test money only/);
  const cookie = await start();
  const confirm = await post('/confirm', cookie);
  assert.match(await confirm.text(), /Download test ZIP/);
  const download = await post('/download', cookie);
  assert.match(download.headers.get('Content-Disposition'), /Workbench-Checkout-Test\.zip/);
});

test('Worker serves only the named gallery assets and only read methods', async () => {
  const env = { PAGE_ASSETS: { fetch: request => new Response(new URL(request.url).pathname) } };
  for (const name of ['image-preview', 'csv-preview', 'markdown-editor']) {
    const path = `/workbench/gallery/${name}.jpg`;
    assert.equal(await (await worker.fetch(new Request(`${origin}${path}`), env)).text(), path);
    assert.equal((await worker.fetch(new Request(`${origin}${path}`, { method: 'POST' }), env)).status, 405);
  }
  const unlisted = await worker.fetch(new Request(`${origin}/workbench/gallery/Workbench-macOS.zip`), env);
  assert.equal(unlisted.status, 404);
});

test('Worker serves the new icon on current and legacy URLs', async () => {
  const env = { PAGE_ASSETS: { fetch: request => new Response(new URL(request.url).pathname) } };
  const jpg = '/images/workbench-app-icon.jpg';
  const webp = '/images/icons/workbench.webp';
  for (const [path, asset] of [[webp, webp], [jpg, jpg], ['/s3-images/workbench-app-icon.jpg', jpg]]) {
    assert.equal(await (await worker.fetch(new Request(`${origin}${path}`), env)).text(), asset);
    assert.equal((await worker.fetch(new Request(`${origin}${path}`, { method: 'HEAD' }), env)).status, 200);
    assert.equal((await worker.fetch(new Request(`${origin}${path}`, { method: 'POST' }), env)).status, 405);
  }
  assert.equal((await worker.fetch(new Request(`${origin}/images/icons/another-app.webp`), env)).status, 404);
});
