# Panes — a dual-pane file manager for macOS

**Working title:** "Panes" (verify App Store name availability before submission — and note that
Apple will almost certainly reject a product name containing the word "Finder", so the repo name
`mac-finder-plus` should stay internal only).

**One-liner:** A fast, keyboard-driven, dual-pane file manager that makes moving, comparing, and
organizing files dramatically faster than Finder.

---

## 1. Vision & positioning

Finder is optimized for casual browsing. Power users — developers, photographers, media managers,
anyone who moves files between folders all day — fight it constantly: no dual pane, weak keyboard
support, no folder sizes, hidden files buried behind shortcuts.

Panes is the "commander-style" file manager rebuilt as a modern, native Mac app: SwiftUI,
first-class dark mode, and full Finder feature parity where it matters, plus the power features
Finder refuses to add.

**Competitors:** Path Finder ($36, aging), ForkLift ($19.95), Commander One (freemium),
Marta (free, unmaintained). The market is proven but every incumbent is either dated, heavy, or
abandoned. The wedge: *native-feeling, fast, modern UI, sold at an impulse price.*

**Target users:** developers, IT admins, creative professionals, "prosumer" Mac users.

**Primary persona (v1):** people who work with large image/video libraries — photographers,
editors, social-media producers. For them Finder's gaps hurt most: no inline video preview with
looping, no quick resize, weak type-scoped search. Panes treats *media triage* as a first-class
workflow: preview → filter by type → resize/move — without opening another app.

## 2. Business model

- **Paid upfront on the Mac App Store: $14.99** (launch sale $9.99). No subscription for v1 —
  paid-upfront converts better in this category and avoids receipt-validation complexity.
- v2 may add a "Pro" IAP tier (cloud drives, FTP/SFTP) if the free-feature baseline grows.
- Also plan a notarized direct-download build later (Paddle/Gumroad) — same codebase, sandbox kept.

## 3. The App Store constraint (critical)

Mac App Store apps **must be sandboxed**. A sandboxed file manager cannot freely read the disk;
it gets access only to folders the user grants via an open panel, persisted with
**security-scoped bookmarks**. This shapes the whole UX:

- First-run onboarding asks the user to grant their Home folder (one click, standard panel).
- Every granted folder is stored as an app-scoped bookmark and restored at launch.
- Navigating anywhere not yet granted shows an inline "Grant Access" state instead of an error.
- Entitlements: `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`.

This is exactly how ForkLift and Commander One ship on MAS, so it's a proven path — but it must be
designed in from day one, not bolted on.

## 4. V1 scope

### Must have (in this codebase now)
| Feature | Notes |
|---|---|
| Dual-pane browser | Toggleable single/dual; active pane highlighted |
| Sidebar | Standard places + user favorites (bookmarked folders), Add Folder… |
| List view | Sortable columns: Name, Size, Kind, Date Modified; folders-first option |
| Navigation | Back/forward history, breadcrumb path bar, Enclosing Folder, Go to Folder (⇧⌘G) |
| File operations | New folder, rename, duplicate, move to trash, copy/move to other pane (F5/F6) |
| Quick Look | Spacebar / ⌘Y on selection |
| Filter-as-you-type | Per-pane live name filter |
| Hidden files toggle | ⇧⌘. |
| Folder size on demand | "Calculate Size" context menu, async |
| Open with default app | Double-click / ⌘↓ |
| Sandbox + grant-access flow | Security-scoped bookmarks, inline grant UI |
| Preview pane (⌥⌘P) | Inline image viewer + video/audio player with **loop toggle**; autoplays selection |
| Image resize | Resize selected images by longest side or percent; JPEG/PNG/original output; writes copies, never overwrites |
| Find with type presets | ⌘F per-pane search: name match, **Include Subfolders**, presets (Images, Videos, Audio, Documents, Archives, Folders) |
| Type-scoped browsing | The same presets filter the current folder view (e.g. show only images while browsing) |
| Photo → video slideshow | Select photos → right-click → H.264 MP4 slideshow; per-photo duration, landscape/portrait/square/4K sizes, fit or fill, progress + cancel |
| Rotate & flip images | In-place rotate left/right and flip horizontal/vertical (context menu, preview-pane buttons, ⌥⌘L/⌥⌘R) |
| Pin folders to sidebar | Drag folders from a pane (or from Finder) onto the sidebar to pin as favorites; drops double as sandbox grants |
| View modes | List and icon-grid views per pane (⌘1/⌘2); grid shows real Quick Look thumbnails (cached) |

### Should have (v1.x before launch, not in this scaffold)
Tabs per pane · drag & drop between panes and to/from Finder · batch rename · copy path ·
column view mode · archive/unarchive · app icon + onboarding polish · localization (EN first).

### Won't have in v1
Cloud drives (Dropbox/Drive/S3), FTP/SFTP, dual-pane sync/diff, terminal integration, plugins,
iCloud settings sync. All are v2 candidates.

### Keyboard map (v1)
⌘[ / ⌘] back/forward · ⌘↑ enclosing folder · ⌘↓ open · Space/⌘Y Quick Look · ⇧⌘N new folder ·
⌘⌫ trash · F5 copy to other pane · F6 move to other pane · ⇧⌘D toggle dual pane · ⇧⌘. hidden files
· ⇧⌘G go to folder · ⌘R refresh · ⇧⌘H home · ⌘F find in pane · ⌥⌘P preview pane ·
⌘1 list view · ⌘2 icon view.

## 5. Technical architecture

- **Stack:** Swift + SwiftUI (AppKit interop where needed: `NSOpenPanel`, `NSWorkspace`), macOS 14+.
  Swift 5 language mode for v1 velocity; migrate to Swift 6 strict concurrency before v2.
- **Pattern:** MVVM with `@Observable` models.
  - `AppState` — panes, active pane, global settings, error surface.
  - `PaneModel` — current URL, history, listing, sort order, selection, filter (one per pane).
  - `FileItem` — value type row model (name, size, kind, dates, flags).
  - `BookmarkStore` — persists/resolves security-scoped bookmarks (UserDefaults).
  - `FileOperations` — copy/move/trash/duplicate/new-folder, async, collision-safe naming.
- **Listing:** `FileManager.contentsOfDirectory` with pre-fetched resource keys, off main thread;
  display-side filtering/sorting so toggles don't re-hit the disk.
- **Project generation:** XcodeGen (`project.yml`) — the `.xcodeproj` is disposable, sources are
  the truth. CI-friendly.
- **Testing (v1.x):** unit tests for `FileOperations` collision naming and `BookmarkStore`;
  UI smoke test for the grant flow.

## 6. App Store submission checklist

1. Apple Developer Program membership; App ID + MAS provisioning.
2. Final name/trademark check; app icon (all sizes), screenshots (light+dark), privacy policy URL.
3. App privacy "nutrition label": no data collected (keep it that way in v1 — no analytics SDK).
4. Category: Utilities. Price tier: $14.99.
5. Hardened runtime + sandbox entitlements as above; test the *signed, sandboxed* build heavily —
   sandbox bugs never appear in dev builds.
6. Review-risk notes: don't use "Finder" in name/subtitle/keywords; describe Quick Look and trash
   behavior in review notes; demo video of grant flow helps.

## 7. Risks

- **Sandbox friction** — users expect to see the whole disk instantly. Mitigate with one-click
  Home grant in onboarding. (Biggest churn risk.)
- **Finder is free** — must be visibly faster/better in the first 60 seconds of use.
- **Crowded shelf** — differentiate on native feel + speed; incumbents are Qt-ish or dated.
- **SwiftUI Table limitations** (inline rename, drag & drop edge cases) — fall back to
  `NSTableView` wrapper if needed in v1.x; the MVVM split keeps that swap contained.

## 8. Milestones

- **M0 (this scaffold):** buildable v1 core per "Must have" table.
- **M1 (~2–3 wks):** drag & drop, tabs, batch rename, app icon, onboarding, unit tests.
- **M2 (~2 wks):** signed MAS build, TestFlight beta, 20+ external testers, crash-free week.
- **M3:** submission + launch (Product Hunt, r/macapps, lifetime-deal launch pricing).
