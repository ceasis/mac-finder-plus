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

Each build writes its timestamp, source revision, and configuration into the built
app before signing. See **About Workbench** or Copy Diagnostics to identify the
exact build; generating this information does not modify the source Info.plist.

## Regression tests

Regenerate the project when adding tests, then run the unit and UI targets:

```sh
xcodegen generate
xcodebuild -project MacFinderPlus.xcodeproj -scheme Workbench -destination 'platform=macOS' -only-testing:WorkbenchTests test
xcodebuild -project MacFinderPlus.xcodeproj -scheme Workbench -destination 'platform=macOS' -only-testing:WorkbenchUITests test
```

UI tests require a logged-in macOS desktop and permission for Xcode to automate
the test app. They exercise the real grid/sidebar drop handlers, inline rename,
and video-preview controls using generated files in a marked, disposable folder
inside the test runner’s temporary directory. They do not restore user tabs or load notes, favorites, or
clipboard history. Cleanup tests use a simulated Trash and verify Undo without
moving user files to the real Trash.

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
