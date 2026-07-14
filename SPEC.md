# Workbench — a dual-pane file manager for macOS

Apple will almost certainly reject a product name containing the word "Finder", so the repo name
`mac-finder-plus` should stay internal only).

**One-liner:** A fast, keyboard-driven, dual-pane file manager that makes moving, comparing, and
organizing files dramatically faster than Finder.

---

## 1. Vision & positioning

Finder is optimized for casual browsing. Power users — developers, photographers, media managers,
anyone who moves files between folders all day — fight it constantly: no dual pane, weak keyboard
support, no folder sizes, hidden files buried behind shortcuts.

Workbench is the "commander-style" file manager rebuilt as a modern, native Mac app: SwiftUI,
first-class dark mode, and full Finder feature parity where it matters, plus the power features
Finder refuses to add.

**Competitors:** Path Finder ($36, aging), ForkLift ($19.95), Commander One (freemium),
Marta (free, unmaintained). The market is proven but every incumbent is either dated, heavy, or
abandoned. The wedge: *native-feeling, fast, modern UI, sold at an impulse price.*

**Target users:** developers, IT admins, creative professionals, "prosumer" Mac users.

**Primary persona (v1):** people who work with large image/video libraries — photographers,
editors, social-media producers. For them Finder's gaps hurt most: no inline video preview with
looping, no quick resize, weak type-scoped search. Workbench treats *media triage* as a first-class
workflow: preview → filter by type → resize/move — without opening another app.

## 2. Business model

- **Paid upfront on Gumroad: $29.99** (launch sale $19.99). No subscription for v1 —
  paid-upfront converts better in this category and keeps distribution simple.
- One purchase covers household use on up to 5 Macs for personal/family use.
- Optional Gumroad supporter tier: $49.99 for customers who want to back development.
- v2 may add a "Pro" tier (cloud drives, FTP/SFTP) if the free-feature baseline grows.
- The first public build is a notarized direct-download app with bundle id
  `com.qnsub.workbench.app`.

## 3. Direct-download permissions model

Workbench ships outside the Mac App Store, so the production build is **not sandboxed**. This keeps
core file-management behavior predictable and allows screenshot/screen-recording tools to call the
system utilities they need. macOS privacy prompts still apply:

- First-run onboarding explains file browsing, screen recording, and microphone permissions.
- The sidebar can still persist favorite folders and user-chosen locations across launches.
- Entitlements: hardened runtime plus `com.apple.security.device.audio-input`.
- Public builds must be signed with Developer ID and notarized so Gatekeeper accepts them cleanly.

The Mac App Store can be revisited later as a separate sandboxed edition if it becomes worth the
extra permission and review constraints.

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

## 6. Gumroad release checklist

1. Apple Developer Program membership and a **Developer ID Application** certificate.
2. Notary credentials configured with `notarytool` keychain profile or app-specific password.
3. Final app icon, screenshots, demo GIF/video, privacy policy, support email, and version notes.
4. Category: Productivity or Utilities. Launch price: $19.99, standard price: $29.99.
5. Build a Release zip with `script/package_gumroad_release.sh`, then verify signing,
   notarization, install, launch, permissions, and core file operations on a clean Mac account.
6. Avoid using "Finder" in public product naming, subtitle, or keywords.

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
