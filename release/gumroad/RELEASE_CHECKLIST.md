# Gumroad Release Checklist

## 1. Account And Product Setup

- Create or update the Gumroad product as a digital product.
- Product name: `Workbench for macOS`.
- Price: launch at `$19.99`; standard price `$29.99`; optional supporter tier `$49.99`.
- License policy: one household purchase covers up to 5 Macs for personal/family use.
- Optional for launch: enable Gumroad license keys so each buyer has a receipt key, even if the app
  does not yet require activation.
- Add product description from `GUMROAD_LISTING.md`.
- Add support email and privacy policy URL or paste `PRIVACY_POLICY.md` onto your site.
- Upload screenshots: file browser, media preview, notes with images, snippets, disk space analyzer.
- Upload a short demo video or GIF showing browsing, preview, notes, snippets, and disk analysis.

## 2. Apple Signing Prerequisites

- Apple Developer Program account is active.
- Install a `Developer ID Application` certificate in Keychain.
- Configure notarization with one of these options:
  - `xcrun notarytool store-credentials workbench-notary`
  - Or set `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, and `NOTARY_PASSWORD`.
- Confirm the bundle id is `com.qnsub.workbench.app`.

## 3. Build And Package

From the repository root:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="workbench-notary" \
./script/package_gumroad_release.sh
```

The script writes the final zip and checksum to `build/gumroad/`.

For internal testing only:

```sh
./script/package_gumroad_release.sh --allow-adhoc
```

Do not upload an ad-hoc build publicly.

## 4. Clean Mac QA

- Download the final zip from Gumroad preview or open the exact zip from `build/gumroad/`.
- Move `Workbench.app` to `/Applications`.
- Launch by double-clicking.
- Confirm the app name, icon, bundle id, About window, update page, and support links are correct.
- Confirm there is no scary unidentified-developer warning.
- Open Settings and verify permissions, update link, safety prompts, activity popup, and preview controls.
- Browse Downloads, Documents, Desktop, and an external drive.
- Test file selection, right-click menus, drag/drop, notes image paste, snippets, and preview.
- Test right-click tools for images, videos, audio, PDFs, documents, folders, ZIPs, and mixed selections.
- Test screenshot/screen recording permission flow, including denied-permission recovery.
- Test microphone/camera permission flow, voice recording playback, and note video journal capture.
- Move one file and several files to Trash; confirm the safety prompt, Activity undo, and Reveal work.
- Export Workbench Data, import it back, and confirm Notes, Snippets, Clipboard History, and Disk Space reload.
- Confirm a pre-import safety backup is created and can be revealed.
- Export Diagnostics and confirm it contains version info, activity history, recent logs, and crash reports if present.
- Run disk analyzer and confirm previous results restore after relaunch.
- Quit and relaunch; confirm window size, sidebar width, and layout persist.

## 5. Gumroad Upload

- Upload the final notarized zip from `build/gumroad/`.
- Add the SHA-256 checksum in the product update notes.
- Add `INSTALL.txt` content to the purchase confirmation or product instructions.
- Send yourself a test purchase.
- Download from the buyer flow and install on a clean user account.

## 6. Launch Copy

Short launch post:

> I built Workbench for macOS: a file workspace for organizing downloads, previewing media,
> keeping notes and snippets, and finding what is using disk space. Launch price is $19.99.

Launch channels:

- Gumroad audience
- Personal site
- X/Twitter
- Reddit communities that allow self-promotion
- Mac app directories
- Friends/testers who gave feedback

## 7. Before Raising Price

- Fix the first wave of install and permission issues.
- Add at least one short demo video.
- Add three customer-facing screenshots that show real workflows.
- Publish a small changelog for the first update.
