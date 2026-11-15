# Workbench interaction regressions

These macOS XCUITests exercise mouse and keyboard interactions through the real
icon grid, inline rename field, sidebar favorite row/drop modifier, and video
preview. They assert filesystem and editor effects, not merely button presence.

```sh
xcodegen generate
xcodebuild -project MacFinderPlus.xcodeproj -scheme Workbench \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:WorkbenchUITests test
```

Use `DEVELOPER_DIR` if the full Xcode installation is not selected. XCTest UI
automation needs an unlocked desktop and may request the system's developer or
accessibility permission. Run outside a restricted command sandbox; media
fixture encoding also uses the system encoder service.

Each test creates a marked `workbench-ui-tests-<UUID>` directory within the UI
runner's own canonical temporary directory, so the runner can keep its default
App Sandbox entitlements. Under Xcode this is normally
`~/Library/Containers/com.qnsub.workbench.app.uitests.xctrunner/Data/tmp/`.
The DEBUG-only app launch mode accepts only that exact runner-container temp
folder, the app's canonical temp folder, or `/private/tmp`, and requires the UUID
name and matching marker. Other locations are rejected. Fixtures and a dedicated
preferences suite are removed during teardown. The mode bypasses saved tabs, bookmark restoration,
clipboard monitoring, app-data stores, menu actions, and window restoration.
The movie fixture is generated locally with video and audio tracks. No personal
media, microphone permission, or external tools are needed.

The fixture scene deliberately isolates the interaction surfaces from onboarding
and unrelated background tools. It is not a full-window layout/screenshot test.
