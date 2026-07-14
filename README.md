# Workbench

A fast, keyboard-driven, dual-pane file manager for macOS, built for direct download distribution.
Product and technical spec: [SPEC.md](SPEC.md).

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The `.xcodeproj` is generated, not committed — sources and `project.yml` are the truth.

```sh
xcodegen generate
xcodebuild -project MacFinderPlus.xcodeproj -scheme Workbench -configuration Debug build
```

Or open `MacFinderPlus.xcodeproj` in Xcode and run the `Workbench` scheme.

## Gumroad release packaging

Direct-download release material lives in `release/gumroad/`.

```sh
./script/package_gumroad_release.sh
```

Public Gumroad builds should be signed with a **Developer ID Application** certificate and
notarized by Apple. For an internal test zip only, run:

```sh
./script/package_gumroad_release.sh --allow-adhoc
```

## Layout

- `project.yml` — XcodeGen project definition (target, entitlements, Info.plist keys)
- `Sources/Models/` — `AppState`, `PaneModel`, `FileItem`, `FileOperations`, `BookmarkStore`
- `Sources/Views/` — SwiftUI views (panes, sidebar, path bar, status bar)
- `Sources/Commands/` — menu bar commands and keyboard shortcuts
