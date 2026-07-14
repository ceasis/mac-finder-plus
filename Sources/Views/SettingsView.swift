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
        .frame(width: 560, height: 620)
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
    @AppStorage(WorkbenchAppIconMode.defaultsKey) private var appIconMode = WorkbenchAppIconMode.forge.rawValue
    @AppStorage(ActivityPopupSettings.autoHideDelayKey)
    private var activityAutoHideDelay = ActivityPopupSettings.defaultAutoHideDelay
    @AppStorage(DeletionSafetySettings.confirmMoveToTrashKey) private var confirmMoveToTrash = true

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section("Appearance") {
                AppIconPicker(selection: $appIconMode)
            }
            Section("Activity") {
                Picker("Hide popup after", selection: $activityAutoHideDelay) {
                    Text("Never").tag(ActivityPopupSettings.neverAutoHideDelay)
                    Text("1 second").tag(1.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Button("Reset Activity Popup") {
                    activityAutoHideDelay = ActivityPopupSettings.defaultAutoHideDelay
                }
            }
            Section("Safety") {
                Toggle("Confirm before moving files to Trash", isOn: $confirmMoveToTrash)
                Text("Activity History keeps undo and reveal controls for file operations when macOS still allows them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $appState.showHidden)
                Toggle("Show folders first", isOn: $appState.foldersFirst)
                Toggle("Calculate folder sizes automatically", isOn: $appState.autoCalculateFolderSizes)
            }
            Section("Support & Data") {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Export Data") {
                            appState.exportWorkbenchDataBackup()
                        }
                        Button("Import Data") {
                            appState.importWorkbenchDataBackup()
                        }
                        Button("Export Diagnostics") {
                            appState.exportWorkbenchDiagnostics()
                        }
                    }
                    VStack(alignment: .leading) {
                        Button("Export Data") {
                            appState.exportWorkbenchDataBackup()
                        }
                        Button("Import Data") {
                            appState.importWorkbenchDataBackup()
                        }
                        Button("Export Diagnostics") {
                            appState.exportWorkbenchDiagnostics()
                        }
                    }
                }
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

private struct AppIconPicker: View {
    @Binding var selection: String

    private let columns = [
        GridItem(.flexible(minimum: 92), spacing: 8),
        GridItem(.flexible(minimum: 92), spacing: 8),
        GridItem(.flexible(minimum: 92), spacing: 8),
        GridItem(.flexible(minimum: 92), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(WorkbenchAppIconMode.allCases) { mode in
                iconButton(for: mode)
            }
        }
        .padding(.vertical, 4)
        .onAppear(perform: normalizeSelection)
        .onChange(of: selection) { _, _ in
            WorkbenchDockIconAnimator.shared.applyPreferredMode()
        }
    }

    private func iconButton(for mode: WorkbenchAppIconMode) -> some View {
        let isSelected = selectedMode == mode

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selection = mode.rawValue
            }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: WorkbenchDockIconAnimator.image(for: mode))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.16), radius: 6, y: 3)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .background(Circle().fill(.white))
                            .offset(x: 4, y: -4)
                    }
                }

                VStack(spacing: 1) {
                    Text(mode.title)
                        .font(.caption.weight(.semibold))
                    Text(mode.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.64) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(mode.title))
        .accessibilityValue(Text(isSelected ? "Selected" : mode.detail))
    }

    private var selectedMode: WorkbenchAppIconMode {
        WorkbenchAppIconMode.mode(for: selection)
    }

    private func normalizeSelection() {
        let normalized = WorkbenchAppIconMode.mode(for: selection).rawValue
        if selection != normalized {
            selection = normalized
        }
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
