# Staged Workbench page for QnSub

`workbench.html` is a staged replacement for
`/Users/choloasis/eclipse-workspace/qnsub/src/main/resources/templates/workbench.html`.
It keeps the existing Gumroad purchase flow and support and privacy routes. It
adds installation instructions and separates the documented public launch from
dated development milestones. It intentionally does not add a separate public
download link or describe unpublished changes as part of a public release.

The QnSub template used as the base had this SHA-256 checksum:

```
70f9603f00e83e922821b093d31aba77323ccc80b945519cc4b58d94058df5ab
```

Confirm the destination still matches before replacing it. If the checksum
differs, merge only the intended changes so ongoing QnSub edits are preserved.
Preview the page in QnSub before deployment. The normal production deploy
publishes the whole site. To release just this page, render `/workbench` into
`build/qnsub-workbench-public/workbench.html` and deploy this directory's
`wrangler.jsonc` using the QnSub Cloudflare account. The page-specific Worker
serves the product page, screenshot gallery, and Workbench icon URLs; it does not
intercept support, privacy, or other apps' assets. Cloudflare exact routes don't
match query strings; those still go to the main site. When the main Worker has
deployed the updated template and visual assets, remove the page and asset
overrides to bring them back under the main site deploy workflow. Keep the
legacy `/s3-images/workbench-app-icon.jpg` override if the main site is still
serving an older icon at that URL.

## Screenshot gallery

`gallery/` holds the finished screenshots rendered from Workbench's file grid
and preview views using the demo workspace in `gallery-fixtures/`. Copy the
JPEGs to `build/qnsub-workbench-public/workbench/gallery/` for the page-specific
Worker and to `src/main/resources/static/workbench/gallery/` in the QnSub
project for the full-site deploy. To add or refresh only the gallery in a rendered
page or QnSub template, run:

```sh
node release/qnsub/merge-workbench-gallery.mjs INPUT release/qnsub/workbench.html OUTPUT
```

Review the output before replacing the existing page. The gallery does not change
the purchase flow or add a public installer URL.

## App icon

`branding/workbench.webp` is the macOS Workspace app icon with transparency for
the Workbench listing and QnSub homepage tile. The matching
`branding/workbench-app-icon.jpg` is the social preview image. Copy these to
`images/icons/workbench.webp` and `images/workbench-app-icon.jpg`, respectively,
under both `build/qnsub-workbench-public/` and QnSub's
`src/main/resources/static/`. Update Workbench's social metadata and blog to use
the static JPEG rather than the legacy S3 URL.

## PayPal checkout — US$4.99

The site charges a fixed one-time US$4.99 via PayPal Orders v2. It only delivers
the private ZIP after PayPal confirms the exact order, merchant, amount, and
completed capture. It does not store payer contact or card details. The signed
browser cookie expires after 14 days; checkout does not offer a permanent
customer account or email delivery.

Before enabling the production button:

1. In the [PayPal Developer Dashboard](https://developer.paypal.com/dashboard/),
   use the intended QnSub business merchant's REST app. Test create, approve,
   capture, and download with sandbox credentials first. For staging use a
   separate Worker name, HTTPS test host, private bucket, and `PAYPAL_MODE=sandbox`;
   do not attach production routes. Set the same sandbox merchant ID that owns
   the sandbox REST app.
2. Prepare the universal Developer ID–signed ZIP with the existing packaging
   script (`--prepare-qnsub` only signs and packages; it does not submit to Apple).
   Once authorized, use `--qnsub` with `DEVELOPER_ID_APPLICATION` and
   `NOTARY_KEYCHAIN_PROFILE`. Verify the app extracted from the **finished ZIP**
   with `codesign --verify --strict --deep`, `xcrun stapler validate`, and
   `spctl --assess --type execute`. Never use a Debug or an unstapled package.
3. Create `qnsub-workbench-downloads` as a **private R2 bucket**. Leave public
   access and custom domains disabled. Upload the verified ZIP as
   `releases/Workbench-macOS.zip`; never place it in the public assets directory.
4. Configure `PAYPAL_CLIENT_ID`, `PAYPAL_CLIENT_SECRET`, `PAYPAL_MERCHANT_ID`,
   and a fresh high-entropy `CHECKOUT_SIGNING_KEY` using the Cloudflare Worker
   secret UI or `wrangler secret put NAME --name qnsub-workbench-page`. Do not
   enter credentials into chat, the repository, command arguments, or page HTML.
   Keep sandbox and live secrets separate. Changing the signing key invalidates
   existing browser purchase links.
5. Update public support and privacy copy for QnSub purchases, retaining legacy
   Gumroad support. For download recovery, direct paying customers to
   support@qnsub.com with their PayPal transaction ID and verify the purchase in
   the merchant account before sending a replacement. Document the same-browser
   cookie and its 14-day expiry on the privacy page. Check receipt, refund, and
   digital goods tax handling before accepting live orders. Deploy `wrangler.paypal.jsonc` only
   once the sandbox purchase succeeds end-to-end. The product page keeps the
   Gumroad link unless live checkout is configured and the R2 object exists.

Run the offline checkout regression tests with:

```sh
node --test release/qnsub/paypal-checkout.test.mjs
```

The local Worker smoke test additionally checks the rendered page and checkout
using mock configuration and a fake R2 object. Use the Miniflare installation
from Wrangler (`WORKBENCH_MINIFLARE` may be set to its package directory):

```sh
node release/qnsub/checkout-smoke.mjs
```
