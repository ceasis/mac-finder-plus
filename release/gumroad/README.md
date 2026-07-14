# Workbench Gumroad Release Kit

This folder contains the launch material for selling Workbench as a direct-download macOS app on
Gumroad.

## Files

- `GUMROAD_LISTING.md` - product title, short description, long description, FAQ, tags, and pricing.
- `RELEASE_CHECKLIST.md` - build, signing, notarization, QA, and Gumroad upload checklist.
- `INSTALL.txt` - customer-facing install instructions to include beside the app in the zip.
- `PRIVACY_POLICY.md` - simple privacy policy draft for the product page.
- `SUPPORT.md` - support and update policy draft.
- `VERSION_NOTES.md` - release notes for the first Gumroad upload or update email.

## Build

Use the packaging script from the repository root:

```sh
./script/package_gumroad_release.sh
```

For a local internal test package without Developer ID signing:

```sh
./script/package_gumroad_release.sh --allow-adhoc
```

Do not upload an ad-hoc package to Gumroad. Public customers should receive a Developer ID signed
and notarized zip.
