// Run with WORKBENCH_MINIFLARE pointing to the Miniflare package used by Wrangler.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(process.env.WORKBENCH_MINIFLARE || 'miniflare');
const html = fs.readFileSync('build/qnsub-workbench-public/workbench.html', 'utf8');
const worker = {
  compatibilityDate: '2026-10-21',
  modules: ['workbench-route.mjs', 'paypal-checkout.mjs'].map(name => {
    const filename = path.resolve('release/qnsub', name);
    return { type: 'ESModule', path: filename, contents: fs.readFileSync(filename, 'utf8') };
  }),
  bindings: { PAYPAL_MODE: 'live', PAYPAL_CLIENT_ID: 'mock', PAYPAL_CLIENT_SECRET: 'mock',
    PAYPAL_MERCHANT_ID: 'mock', CHECKOUT_SIGNING_KEY: 'mock-unused-test-signing-key-long',
    WORKBENCH_RELEASE_KEY: 'mock.zip' },
  r2Buckets: ['WORKBENCH_RELEASES'],
  serviceBindings: { PAGE_ASSETS: req => {
    assert.equal(req.headers.get('if-none-match'), null);
    return new Response(html, { headers: { 'Content-Type': 'text/html', ETag: 'test-etag' } });
  } },
};
const mf = new Miniflare(convertV4MiniflareOptions ? convertV4MiniflareOptions(worker) : worker);
try {
  await (await mf.getR2Bucket('WORKBENCH_RELEASES')).put('mock.zip', 'fixture');
  const page = await mf.dispatchFetch('https://qnsub.com/workbench', { headers: { 'If-None-Match': 'test-etag' } });
  assert.equal(page.status, 200);
  assert.equal(page.headers.get('etag'), null);
  const out = await page.text();
  assert.equal((out.match(/Buy Workbench — US\$4\.99/g) || []).length, 3);
  assert(!out.includes('See Gumroad for current pricing'));
  assert(out.includes('First Gumroad release'));
  const checkout = await mf.dispatchFetch('https://qnsub.com/workbench/checkout');
  assert.equal(checkout.status, 200);
  assert((await checkout.text()).includes('Continue to PayPal · US$4.99'));
  console.log('Cloudflare Worker runtime smoke test passed.');
} finally {
  await mf.dispose();
}
