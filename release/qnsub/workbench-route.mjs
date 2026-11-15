import { checkoutConfigured, handleCheckout } from './paypal-checkout.mjs';

const visualAssets = new Map([
  ['/images/icons/workbench.webp', '/images/icons/workbench.webp'],
  ['/images/workbench-app-icon.jpg', '/images/workbench-app-icon.jpg'],
  ['/s3-images/workbench-app-icon.jpg', '/images/workbench-app-icon.jpg'],
  ...['image-preview', 'csv-preview', 'markdown-editor'].map(name => {
    const path = `/workbench/gallery/${name}.jpg`;
    return [path, path];
  }),
]);

// The main QnSub Worker still serves the home page, app directory and shared assets.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const assetPath = visualAssets.get(url.pathname);
    if (assetPath) {
      if (!['GET', 'HEAD'].includes(request.method)) {
        return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
      }
      if (assetPath === url.pathname) return env.PAGE_ASSETS.fetch(request);
      url.pathname = assetPath;
      return env.PAGE_ASSETS.fetch(new Request(url, request));
    }
    if (url.pathname === '/workbench/checkout' || url.pathname.startsWith('/workbench/checkout/')) {
      return handleCheckout(request, env);
    }
    if (url.pathname === '/workbench/') {
      url.pathname = '/workbench';
      return Response.redirect(url, 301);
    }
    if (url.pathname !== '/workbench') return new Response('Not Found', { status: 404 });
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    url.pathname = '/workbench.html';
    const assetRequest = new Request(url, request);
    if (request.method !== 'GET' || env.PAYPAL_MODE !== 'live' || !checkoutConfigured(env)) {
      return env.PAGE_ASSETS.fetch(assetRequest);
    }
    try {
      if (!await env.WORKBENCH_RELEASES.head(env.WORKBENCH_RELEASE_KEY)) return env.PAGE_ASSETS.fetch(assetRequest);
    } catch { return env.PAGE_ASSETS.fetch(assetRequest); }
    assetRequest.headers.delete('If-None-Match');
    assetRequest.headers.delete('If-Modified-Since');
    const response = await env.PAGE_ASSETS.fetch(assetRequest);
    if (!response.ok) return response;

    const transformed = new HTMLRewriter()
      .on('a[href="https://qnsub.gumroad.com/l/yyloqo"]', { element(link) {
        link.setAttribute('href', '/workbench/checkout');
        link.removeAttribute('target');
        link.removeAttribute('rel');
        link.setInnerContent('Buy Workbench — US$4.99');
      } })
      .on('.hero-eyebrow', { element(eyebrow) { eyebrow.setInnerContent('One-time purchase · US$4.99'); } })
      .on('#download .section-title p', { element(summary) {
        summary.setInnerContent('For Apple silicon and Intel Macs running macOS 14 or later. Pay once with PayPal, then download your copy from QnSub.');
      } })
      .on('#download .parkingmanager-workflow > div:first-child p', { element(copy) {
        copy.setInnerContent('Pay US$4.99 through PayPal. Return to QnSub in the same browser to confirm the payment and download Workbench.');
      } })
      .on('#download .hero-buttons', { element(buttons) {
        buttons.before('<p>One purchase covers personal or family use within one household on up to 5 Macs.</p>', { html: true });
      } })
      .on('#download .container > div:nth-child(3) > p', { element(copy) { copy.remove(); } })
      .on('.cta-section .cta-content > p', { element(copy) {
        copy.setInnerContent('Get Workbench for macOS for US$4.99 from QnSub Tech.');
      } })
      .transform(response);
    const headers = new Headers(transformed.headers);
    headers.set('Cache-Control', 'no-store');
    headers.delete('ETag');
    headers.delete('Last-Modified');
    headers.delete('Content-Length');
    return new Response(transformed.body, { status: transformed.status, headers });
  },
};
