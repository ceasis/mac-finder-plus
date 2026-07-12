# Workbench

A fast, keyboard-driven, dual-pane file manager for macOS, built to be sold on the Mac App Store.
Product and technical spec: [SPEC.md](SPEC.md).

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The `.xcodeproj` is generated, not committed — sources and `project.yml` are the truth.

```sh
xcodegen generate
xcodebuild -project MacFinderPlus.xcodeproj -scheme Workbench -configuration Debug build
```

Or open `MacFinderPlus.xcodeproj` in Xcode and run the `Workbench` scheme.

## Sandbox note

The app is sandboxed (a Mac App Store requirement), so on first launch it can only see its own
container. Use the sidebar's **Add Folder…** button or any pane's **Grant Access…** prompt to
grant folders; grants persist across launches via security-scoped bookmarks. This is the intended
App Store behavior, not a bug — see SPEC.md §3.

## Layout

- `project.yml` — XcodeGen project definition (target, entitlements, Info.plist keys)
- `Sources/Models/` — `AppState`, `PaneModel`, `FileItem`, `FileOperations`, `BookmarkStore`
- `Sources/Views/` — SwiftUI views (panes, sidebar, path bar, status bar)
- `Sources/Commands/` — menu bar commands and keyboard shortcuts
