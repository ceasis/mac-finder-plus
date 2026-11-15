# Workbench PayPal checkout setup

The sandbox runs on its own `workers.dev` host with test accounts, test money,
and a dummy file. Keep it separate from the live Workbench page and paid installer.
Do not paste secret values into chat, source files, screenshots, or shell command arguments.

The [sandbox checkout](https://qnsub-workbench-paypal-sandbox.qnsub.workers.dev/workbench/checkout)
and its dummy ZIP are already provisioned. Continue at step 4 to configure secrets.

## 1. Set up the sandbox seller and buyer

1. In the [PayPal Developer Dashboard](https://developer.paypal.com/dashboard/), open
   **Apps & Credentials → Sandbox**. Create or select a REST app owned by the
   sandbox **Business** account. Use its Client ID and Secret for the Worker.
2. Get that same Business account's PayPal Merchant ID, not its email address or
   Client ID. If necessary, sign in at [PayPal Sandbox](https://www.sandbox.paypal.com/)
   with the sandbox Business login and open **Account Settings → Business information**.
3. In **Testing Tools → Sandbox Accounts**, use a separate **Personal** account
   for the buyer. Keep its generated login for the PayPal Sandbox sign-in only;
   do not enter the buyer's login into Cloudflare.

See [PayPal's sandbox account guide](https://developer.paypal.com/sandbox-testing/accounts)
and [REST app setup guide](https://developer.paypal.com/api/get-started/).

## 2. Stage a dummy ZIP in a private test bucket

1. In Cloudflare **R2 Object Storage**, create `qnsub-workbench-checkout-test`.
   Keep the `r2.dev` public URL disabled and do not attach a custom domain.
2. Run this from the repository root to create a ZIP with only a test text file:

   ```sh
   mkdir -p build/qnsub-checkout-test
   printf '%s\n' 'PayPal sandbox test only. This is not the Workbench installer.' > build/qnsub-checkout-test/README.txt
   zip -j build/qnsub-checkout-test/Workbench-Checkout-Test.zip build/qnsub-checkout-test/README.txt
   ```

3. Upload that ZIP in the R2 dashboard at the object key
   `fixtures/Workbench-Checkout-Test.zip`. Do not upload a real installer to this bucket.

## 3. Deploy only the sandbox Worker

Use your QnSub Cloudflare account and ensure its `workers.dev` subdomain is set up.
Render the Workbench page into `build/qnsub-workbench-public/workbench.html` first
(see [release README](README.md)). That directory is public; keep ZIPs out of it.
From the repository root, the sandbox-only command is:

```sh
npx wrangler deploy --config release/qnsub/wrangler.paypal-sandbox.jsonc
```

The Worker is named `qnsub-workbench-paypal-sandbox`, uses `PAYPAL_MODE=sandbox`,
and defines no `qnsub.com` routes. The checkout returns 503 until configured.

## 4. Enter secrets in Cloudflare

In **Workers & Pages → qnsub-workbench-paypal-sandbox → Settings → Variables and
Secrets**, select **Add**, set the type to **Secret**, then enter the name and value.
Add all four and select **Deploy** in the dashboard:

| Secret name | Value |
| --- | --- |
| `PAYPAL_CLIENT_ID` | Sandbox REST app Client ID |
| `PAYPAL_CLIENT_SECRET` | Secret from the same sandbox REST app |
| `PAYPAL_MERCHANT_ID` | PayPal Merchant ID of the sandbox Business account that owns the REST app |
| `CHECKOUT_SIGNING_KEY` | Independently generated random value, at least 32 bytes of entropy (e.g. 64 hex characters from a password manager) |

Use a different signing key for live. Replacing a signing key invalidates the
browser cookies that it signed. See [Cloudflare Worker secrets](https://developers.cloudflare.com/workers/configuration/secrets/).

## 5. Test in a browser

1. Open the deployed Worker's HTTPS `workers.dev` URL and go directly to
   `/workbench/checkout`. The sandbox does not replace the Gumroad button on its
   product page.
2. Select **Continue to PayPal · US$4.99**. Verify the redirect is to
   `www.sandbox.paypal.com`, then approve as the sandbox Personal buyer.
3. Return to the same browser, select **Confirm payment**, then download. Open the
   ZIP and confirm it contains only the test text file. Confirm the Sandbox seller
   received one completed US$4.99 test payment.
4. Retry the same confirmation link and confirm there is no second charge. Open
   the return link in a different browser profile and confirm it cannot download.
   In a new checkout, cancel on PayPal and confirm no payment is captured and no
   download is offered. The public Workbench page should remain unchanged.

## Later: stage the real installer privately

After sandbox tests pass and a release is approved, use the [release README](README.md)
to build the latest universal Developer ID–signed and notarized QnSub ZIP. Extract
the **finished** ZIP and verify its app with `codesign --verify --strict --deep`,
`xcrun stapler validate`, and `spctl --assess --type execute` before uploading.
Upload only the verified release to private bucket `qnsub-workbench-downloads` as
`releases/Workbench-macOS.zip`. Keep public R2 access and custom domains disabled.

Live checkout uses the separate production Worker `qnsub-workbench-page` and
`wrangler.paypal.jsonc`, with the same four Secret names but the live REST app,
the matching live merchant, and a fresh signing key. Review the live support,
privacy, receipt, and refund flows before switching the public purchase button.
Do not deploy the live configuration as part of sandbox setup.
