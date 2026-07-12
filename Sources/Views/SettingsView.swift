import SwiftUI

/// The Preferences window (⌘,). A tabbed surface over the settings that were
/// previously scattered across individual sheets as loose @AppStorage keys.
/// Everything here binds to the same store the feature UIs read, so changing a
/// default in Preferences and opening the matching sheet stay in sync.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PreviewSettingsView()
                .tabItem { Label("Preview", systemImage: "photo") }
            CaptureSettingsView()
                .tabItem { Label("Screenshots", systemImage: "camera.viewfinder") }
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 460)
    }
}

private struct PermissionsSettingsView: View {
    @State private var permissions = PermissionsManager()

    var body: some View {
        Form {
            Section("Capture Permissions") {
                permissionRow(
                    title: "Screen Recording",
                    detail: "Required for screenshots and screen recording.",
                    status: permissions.screenRecording,
                    enableAction: { permissions.requestScreenRecording() },
                    settingsAction: { permissions.openScreenRecordingSettings() }
                )
                permissionRow(
                    title: "Microphone",
                    detail: "Required to narrate recordings and record voice/video journals.",
                    status: permissions.microphone,
                    enableAction: { Task { await permissions.requestMicrophone() } },
                    settingsAction: { permissions.openMicrophoneSettings() }
                )
                permissionRow(
                    title: "Camera",
                    detail: "Required to record video journals in Notes.",
                    status: permissions.camera,
                    enableAction: { Task { await permissions.requestCamera() } },
                    settingsAction: { permissions.openCameraSettings() }
                )
            }
            Section {
                Text("macOS only prompts once. If a permission was denied, use “Open System Settings” to change it, then return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        status: PermissionsManager.Status,
        enableAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Enabled", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            case .denied:
                Button("Open System Settings", action: settingsAction)
            case .notDetermined:
                Button("Enable", action: enableAction)
            }
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(WorkbenchAppIconMode.defaultsKey) private var appIconMode = WorkbenchAppIconMode.animated.rawValue

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section("Appearance") {
                Picker("App icon", selection: $appIconMode) {
                    ForEach(WorkbenchAppIconMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $appState.showHidden)
                Toggle("Show folders first", isOn: $appState.foldersFirst)
                Toggle("Calculate folder sizes automatically", isOn: $appState.autoCalculateFolderSizes)
            }
            Section("Sidebar") {
                Button("Reset Sidebar Layout") {
                    SidebarLayoutPreferences.reset()
                }
                Text("Restores the default section, place, drive, and tool order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Calculating folder sizes scans every enclosed file, which can be slow on large folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PreviewSettingsView: View {
    @AppStorage("loopVideos") private var loopVideos = true
    @AppStorage("previewControlsSizeScale") private var previewControlsSizeScale = 1.0
    @AppStorage("previewSlideshow.interval") private var slideshowInterval = 3.0
    @AppStorage("previewSlideshow.fillFrame") private var slideshowFillFrame = false

    var body: some View {
        Form {
            Section("Preview Pane") {
                HStack {
                    Text("Controls size")
                    Slider(value: $previewControlsSizeScale, in: 0.8...2.0, step: 0.1)
                    Text("\(Int(previewControlsSizeScale * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Button("Reset Controls Size") {
                    previewControlsSizeScale = 1.0
                }
            }
            Section("Video") {
                Toggle("Loop videos in the preview pane", isOn: $loopVideos)
            }
            Section("Preview Slideshow") {
                Picker("Seconds per image", selection: $slideshowInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                }
                Toggle("Fill the frame (crop to fit)", isOn: $slideshowFillFrame)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CaptureSettingsView: View {
    @AppStorage("screenshot.format") private var formatValue = ScreenshotFormat.png.rawValue
    @AppStorage("screenshot.mode") private var modeValue = ScreenshotCaptureMode.interactive.rawValue
    @AppStorage("screenshot.delay") private var delay = 0
    @AppStorage("screenshot.includeCursor") private var includeCursor = false
    @AppStorage("screenshot.includeWindowShadow") private var includeWindowShadow = true
    @AppStorage("screenshot.saveToActiveFolder") private var saveToActiveFolder = true
    @AppStorage("screenshot.copyToClipboard") private var copyToClipboard = true
    @AppStorage("screenshot.openInPreview") private var openInEditor = false
    @AppStorage("screenshot.playSound") private var playSound = false
    @AppStorage("recording.duration") private var recordingDuration = 30
    @AppStorage("recording.includeMicrophone") private var includeMicrophone = false
    @AppStorage("recording.showClicks") private var showClicks = true

    var body: some View {
        Form {
            Section("Screenshots") {
                Picker("Default format", selection: $formatValue) {
                    ForEach(ScreenshotFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                Picker("Default capture", selection: $modeValue) {
                    ForEach(ScreenshotCaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Picker("Timer", selection: $delay) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Include pointer", isOn: $includeCursor)
                Toggle("Include window shadow", isOn: $includeWindowShadow)
            }
            Section("After Capture") {
                Toggle("Save to the active folder", isOn: $saveToActiveFolder)
                Toggle("Copy to the clipboard", isOn: $copyToClipboard)
                Toggle("Open in the annotation editor", isOn: $openInEditor)
                Toggle("Play a shutter sound", isOn: $playSound)
            }
            Section("Screen Recording") {
                Picker("Maximum length", selection: $recordingDuration) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                }
                Toggle("Record microphone audio", isOn: $includeMicrophone)
                Toggle("Show mouse clicks", isOn: $showClicks)
            }
        }
        .formStyle(.grouped)
    }
}
