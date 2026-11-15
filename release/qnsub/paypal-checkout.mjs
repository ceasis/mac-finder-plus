const ROOT = '/workbench/checkout';
const SKU = 'workbench-macos';
const PRICE = '4.99';
const CURRENCY = 'USD';
const ORDER_ID = /^[A-Z0-9]{10,36}$/;
const COOKIE_AGE = 14 * 24 * 60 * 60;
const encoder = new TextEncoder();

export function checkoutConfigured(env) {
  return ['sandbox', 'live'].includes(env.PAYPAL_MODE)
    && Boolean(env.PAYPAL_CLIENT_ID && env.PAYPAL_CLIENT_SECRET && env.PAYPAL_MERCHANT_ID
      && env.CHECKOUT_SIGNING_KEY?.length >= 32 && env.WORKBENCH_RELEASE_KEY && env.WORKBENCH_RELEASES);
}

function headers(extra = {}) {
  return { 'Cache-Control': 'private, no-store', 'Referrer-Policy': 'same-origin',
    'X-Content-Type-Options': 'nosniff', ...extra };
}

function page(title, body, status = 200) {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${title} · QnSub</title>
<style>body{background:#f4f6fb;color:#192237;font:16px/1.55 system-ui,sans-serif;margin:0;padding:clamp(1rem,7vw,5rem)}main{max-width:36rem;margin:auto;background:white;border:1px solid #dce3ef;border-radius:1rem;padding:clamp(1.25rem,5vw,3rem)}h1{line-height:1.15}button{background:#153d91;color:white;border:0;border-radius:.5rem;padding:.8rem 1.15rem;font:inherit;font-weight:650;cursor:pointer}a{color:#154590}small{color:#465570}</style>
<main><small>QNSUB · WORKBENCH FOR MAC</small><h1>${title}</h1>${body}<p><a href="/workbench">Back to Workbench</a> · <a href="/workbench/support">Support</a></p></main></html>`, {
    status,
    headers: headers({ 'Content-Type': 'text/html; charset=utf-8',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https://www.paypal.com https://www.sandbox.paypal.com; frame-ancestors 'none'; base-uri 'none'" }),
  });
}

function form(path, label, id) {
  return `<form method="post" action="${ROOT}/${path}">${id ? `<input type="hidden" name="order" value="${id}">` : ''}<button type="submit">${label}</button></form>`;
}

function originFor(request, env) {
  return env.PAYPAL_MODE === 'live' ? 'https://qnsub.com' : new URL(request.url).origin;
}

function validPost(request, origin) {
  return request.method === 'POST' && request.headers.get('Origin') === origin;
}

function cookieName(id) { return `__Secure-qnsub-workbench-${id}`; }

async function signature(id, expiration, env) {
  const key = await crypto.subtle.importKey('raw', encoder.encode(env.CHECKOUT_SIGNING_KEY),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
  return { key, data: encoder.encode(`v1:${env.PAYPAL_MODE}:${env.PAYPAL_MERCHANT_ID}:${id}:${expiration}`) };
}

async function issueCookie(id, env) {
  const expiration = Math.floor(Date.now() / 1000) + COOKIE_AGE;
  const { key, data } = await signature(id, expiration, env);
  const bytes = new Uint8Array(await crypto.subtle.sign('HMAC', key, data));
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
  return `${cookieName(id)}=${expiration}.${hex}; Path=${ROOT}; Max-Age=${COOKIE_AGE}; Secure; HttpOnly; SameSite=Lax`;
}

async function ownsOrder(request, id, env) {
  if (typeof id !== 'string' || !ORDER_ID.test(id)) return false;
  const prefix = `${cookieName(id)}=`;
  const cookie = request.headers.get('Cookie')?.split(';').map(value => value.trim()).find(value => value.startsWith(prefix));
  const match = cookie?.slice(prefix.length).match(/^(\d{10})\.([a-f0-9]{64})$/);
  if (!match || Number(match[1]) <= Date.now() / 1000) return false;
  const { key, data } = await signature(id, Number(match[1]), env);
  const bytes = Uint8Array.from(match[2].match(/../g), part => parseInt(part, 16));
  return crypto.subtle.verify('HMAC', key, bytes, data);
}

function paypalBase(env) {
  return env.PAYPAL_MODE === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com';
}

async function accessToken(env) {
  const response = await fetch(`${paypalBase(env)}/v1/oauth2/token`, {
    method: 'POST',
    headers: { Authorization: `Basic ${btoa(`${env.PAYPAL_CLIENT_ID}:${env.PAYPAL_CLIENT_SECRET}`)}`,
      'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
    redirect: 'error',
  });
  if (!response.ok) throw new Error('PayPal authentication failed');
  const { access_token: token } = await response.json();
  if (!token) throw new Error('PayPal returned no access token');
  return token;
}

async function paypal(env, token, path, body, requestID) {
  return fetch(`${paypalBase(env)}${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json',
      ...(body === undefined ? {} : { 'Content-Type': 'application/json', Prefer: 'return=representation' }),
      ...(requestID ? { 'PayPal-Request-Id': requestID } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: 'error',
  });
}

function correctAmount(amount) {
  return amount?.currency_code === CURRENCY && amount?.value === PRICE;
}

function workbenchUnit(order, id, env) {
  if (order.id !== id || order.intent !== 'CAPTURE' || order.purchase_units?.length !== 1) return null;
  const [unit] = order.purchase_units;
  return unit.reference_id === SKU && unit.custom_id === SKU && unit.payee?.merchant_id === env.PAYPAL_MERCHANT_ID
    && correctAmount(unit.amount) ? unit : null;
}

function completedCapture(order, id, env) {
  if (order.status !== 'COMPLETED') return null;
  const captures = workbenchUnit(order, id, env)?.payments?.captures;
  if (captures?.length !== 1) return null;
  const [capture] = captures;
  return capture.status === 'COMPLETED' && correctAmount(capture.amount) && ORDER_ID.test(capture.id ?? '')
    ? capture.id : null;
}

async function orderDetails(env, token, id) {
  const response = await paypal(env, token, `/v2/checkout/orders/${id}`);
  if (!response.ok) throw new Error('PayPal order lookup failed');
  return response.json();
}

async function captureRequestID(id) {
  // Keep this deterministic across retries and under PayPal's 38-character limit.
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(`${SKU}:${id}`)));
  return Array.from(digest.slice(0, 16), byte => byte.toString(16).padStart(2, '0')).join('');
}

async function createOrder(env, origin) {
  if (!await env.WORKBENCH_RELEASES.head(env.WORKBENCH_RELEASE_KEY)) {
    return page('Download not available', '<p>Workbench is temporarily unavailable. No payment was taken.</p>', 503);
  }
  const token = await accessToken(env);
  const response = await paypal(env, token, '/v2/checkout/orders', {
    intent: 'CAPTURE',
    purchase_units: [{ reference_id: SKU, custom_id: SKU, description: 'Workbench for macOS',
      payee: { merchant_id: env.PAYPAL_MERCHANT_ID }, amount: { currency_code: CURRENCY, value: PRICE } }],
    payment_source: { paypal: { experience_context: { brand_name: 'QnSub', shipping_preference: 'NO_SHIPPING',
      user_action: 'CONTINUE', return_url: `${origin}${ROOT}/return`, cancel_url: `${origin}${ROOT}/cancelled` } } },
  }, crypto.randomUUID());
  if (!response.ok) throw new Error('PayPal order creation failed');
  const order = await response.json();
  const href = order.links?.find(link => link.rel === 'payer-action' || link.rel === 'approve')?.href;
  const approval = new URL(href);
  const expectedHost = env.PAYPAL_MODE === 'live' ? 'www.paypal.com' : 'www.sandbox.paypal.com';
  if (!ORDER_ID.test(order.id ?? '') || approval.origin !== `https://${expectedHost}`) throw new Error('Invalid approval response');
  return new Response(null, { status: 303, headers: headers({ Location: approval.href, 'Set-Cookie': await issueCookie(order.id, env) }) });
}

export async function handleCheckout(request, env) {
  if (!checkoutConfigured(env)) return page('PayPal checkout unavailable', '<p>Please try again later. No payment was taken.</p>', 503);
  const url = new URL(request.url);
  const origin = originFor(request, env);
  if (url.origin !== origin) return new Response(null, { status: 404, headers: headers() });
  const path = url.pathname;
  try {
    if (request.method === 'GET' && path === ROOT) {
      const sandbox = env.PAYPAL_MODE === 'sandbox' ? '<p><strong>Sandbox test:</strong> Test money only. The download is a sample ZIP, not the app.</p>' : '';
      return page('Buy Workbench', sandbox + '<p>One-time purchase: <strong>US$4.99</strong>. Requires macOS 14 or later.</p><p>After PayPal confirms your purchase, download Workbench here. Keep this browser open for the return and download. One purchase covers personal or family use in one household on up to five Macs.</p>' + form('start', 'Continue to PayPal · US$4.99') + '<p><small><a href="https://www.paypal.com/us/legalhub/paypal/privacy-full">PayPal processes your payment</a>. QnSub checks payment through PayPal and uses a secure cookie to connect this browser to your purchase for up to 14 days. If you lose download access, contact <a href="mailto:support@qnsub.com">QnSub support</a> with your PayPal transaction ID. Never send payment credentials.</small></p>');
    }
    if (request.method === 'GET' && path === `${ROOT}/`) return Response.redirect(`${origin}${ROOT}`, 303);
    if (request.method === 'GET' && path === `${ROOT}/cancelled`) {
      return page('Checkout cancelled', `<p>PayPal checkout did not complete. You can <a href="${ROOT}">try again</a>.</p>`);
    }
    if (request.method === 'GET' && path === `${ROOT}/return`) {
      const id = url.searchParams.get('token');
      if (!await ownsOrder(request, id, env)) return unavailableOrder();
      return page('Complete your purchase', '<p>Confirm your US$4.99 PayPal purchase to unlock the Workbench download.</p>' + form('confirm', 'Confirm payment', id));
    }
    if (!validPost(request, origin)) return new Response(null, { status: 403, headers: headers() });
    if (path === `${ROOT}/start`) return await createOrder(env, origin);
    if (path !== `${ROOT}/confirm` && path !== `${ROOT}/download`) return new Response(null, { status: 404, headers: headers() });
    if (!request.headers.get('Content-Type')?.startsWith('application/x-www-form-urlencoded')) {
      return new Response(null, { status: 415, headers: headers() });
    }
    const body = await readForm(request);
    if (body === null) return new Response(null, { status: 413, headers: headers() });
    const id = new URLSearchParams(body).get('order');
    if (!await ownsOrder(request, id, env)) return unavailableOrder();
    const token = await accessToken(env);
    let order = await orderDetails(env, token, id);
    if (!workbenchUnit(order, id, env)) return unavailableOrder();

    if (path === `${ROOT}/confirm`) {
      if (order.status === 'APPROVED') {
        // Don't capture if there is currently no package to fulfill the purchase.
        if (!await env.WORKBENCH_RELEASES.head(env.WORKBENCH_RELEASE_KEY)) {
          return page('Download not available', '<p>Workbench is temporarily unavailable. We did not capture your payment.</p>', 503);
        }
        const capture = await paypal(env, token, `/v2/checkout/orders/${id}/capture`, {}, await captureRequestID(id));
        // A lost response or a duplicate callback can race with successful capture. Re-read authoritative state.
        if (!capture.ok && capture.status >= 500) throw new Error('PayPal capture temporarily unavailable');
        order = await orderDetails(env, token, id);
      }
      if (!completedCapture(order, id, env)) {
        return page('Payment not confirmed', '<p>PayPal has not confirmed a completed payment. If payment is pending, wait and then check again. Do not start another purchase for the same order.</p>' + form('confirm', 'Check payment again', id), 409);
      }
      const sandbox = env.PAYPAL_MODE === 'sandbox';
      const instructions = sandbox ? '<p>PayPal confirmed the test payment. Download the sample ZIP to verify delivery.</p>' : '<p>Workbench is ready to download. Open the ZIP and move Workbench.app to Applications. Save the purchase return link below to retry from the same browser for up to 14 days.</p>';
      return page('Payment confirmed', instructions + form('download', sandbox ? 'Download test ZIP' : 'Download Workbench for Mac', id)
        + `<p><small><a href="${ROOT}/return?token=${id}">Purchase return link</a></small></p>`);
    }

    const captureId = completedCapture(order, id, env);
    if (!captureId) return unavailableOrder();
    // Check current capture status, including refunds, before serving private bytes.
    const details = await paypal(env, token, `/v2/payments/captures/${captureId}`);
    if (!details.ok) throw new Error('PayPal capture lookup failed');
    const capture = await details.json();
    if (capture.id !== captureId || capture.status !== 'COMPLETED' || !correctAmount(capture.amount)) return unavailableOrder();
    const file = await env.WORKBENCH_RELEASES.get(env.WORKBENCH_RELEASE_KEY);
    if (!file) return page('Download temporarily unavailable', '<p>Your payment is confirmed. Please retry later or contact support. Do not pay again.</p>', 503);
    const filename = env.PAYPAL_MODE === 'sandbox' ? 'Workbench-Checkout-Test.zip' : 'Workbench-macOS.zip';
    return new Response(file.body, { headers: headers({ 'Content-Type': 'application/zip',
      'Content-Disposition': `attachment; filename="${filename}"`, 'Content-Length': String(file.size) }) });
  } catch {
    return page('Couldn’t check your purchase', '<p>Please try the same step again. If PayPal shows a payment, do not pay again; contact support if the problem persists.</p>', 502);
  }
}

function unavailableOrder() {
  return page('Purchase unavailable', '<p>Open the original PayPal return link in the same browser used for checkout, or contact support if you paid.</p>', 403);
}

async function readForm(request) {
  if (!request.body) return '';
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let size = 0;
  let text = '';
  while (true) {
    const { value, done } = await reader.read();
    if (done) return text + decoder.decode();
    size += value.byteLength;
    if (size > 256) {
      await reader.cancel();
      return null;
    }
    text += decoder.decode(value, { stream: true });
  }
}
