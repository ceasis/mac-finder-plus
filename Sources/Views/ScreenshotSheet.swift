import AppKit
import SwiftUI

struct CapturePanelView: View {
    @Environment(AppState.self) private var appState

    @AppStorage("capture.kind") private var captureKindValue = CaptureKind.screenshot.rawValue
    @AppStorage("screenshot.mode") private var modeValue = ScreenshotCaptureMode.interactive.rawValue
    @AppStorage("screenshot.format") private var formatValue = ScreenshotFormat.png.rawValue
    @AppStorage("screenshot.delay") private var delay = 0
    @AppStorage("recording.duration") private var recordingDuration = 30
    @AppStorage("screenshot.includeCursor") private var includeCursor = false
    @AppStorage("screenshot.includeWindowShadow") private var includeWindowShadow = true
    @AppStorage("recording.includeMicrophone") private var includeMicrophone = false
    @AppStorage("recording.showClicks") private var showClicks = true
    @AppStorage("screenshot.saveToActiveFolder") private var saveToActiveFolder = true
    @AppStorage("screenshot.copyToClipboard") private var copyToClipboard = true
    @AppStorage("screenshot.openInPreview") private var openInPreview = false
    @AppStorage("screenshot.playSound") private var playSound = false

    @State private var windowTargets: [ScreenCaptureWindowTarget] = []
    @State private var selectedWindowNumber: Int?

    private let modeColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    private var captureKind: CaptureKind {
        CaptureKind(rawValue: captureKindValue) ?? .screenshot
    }

    private var mode: ScreenshotCaptureMode {
        ScreenshotCaptureMode(rawValue: modeValue) ?? .interactive
    }

    private var format: ScreenshotFormat {
        ScreenshotFormat(rawValue: formatValue) ?? .png
    }

    private var canCapture: Bool {
        if mode.needsAppWindowSelection && selectedWindowNumber == nil {
            return false
        }
        switch captureKind {
        case .screenshot:
            return saveToActiveFolder || copyToClipboard
        case .recording:
            return saveToActiveFolder
        }
    }

    private var options: ScreenshotOptions {
        ScreenshotOptions(
            kind: captureKind,
            mode: mode,
            format: format,
            delay: min(max(delay, 0), 30),
            recordingDuration: min(max(recordingDuration, 0), 3_600),
            includeCursor: mode.supportsCursor(for: captureKind) && includeCursor,
            includeWindowShadow: mode.supportsShadow(for: captureKind) && includeWindowShadow,
            includeMicrophone: captureKind == .recording && includeMicrophone,
            showClicks: captureKind == .recording && showClicks,
            saveToActiveFolder: captureKind == .recording ? true : saveToActiveFolder,
            copyToClipboard: captureKind == .screenshot && copyToClipboard,
            openInPreview: saveToActiveFolder && openInPreview,
            playSound: playSound,
            selectedWindowNumber: selectedWindowNumber,
            selectedWindowTitle: selectedWindowTitle
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    captureKindPicker
                    modeGrid
                    if mode.needsAppWindowSelection {
                        windowPicker
                    }
                    captureSettings
                    outputSettings
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .onAppear {
            syncCaptureKindWithTool()
            reloadWindowTargets()
        }
        .onChange(of: appState.activeToolPanel) { _, _ in
            syncCaptureKindWithTool()
        }
        .onChange(of: captureKind) { _, newValue in
            if newValue == .recording {
                saveToActiveFolder = true
                copyToClipboard = false
            }
            if !mode.supportsCursor(for: newValue) {
                includeCursor = false
            }
        }
        .background(
            Button("", action: { appState.hideCaptureTool() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(
                captureKind == .recording ? "Screen Recording" : "Screenshot",
                systemImage: captureKind.systemImage
            )
            .font(.headline)

            Spacer()

            Button { appState.hideCaptureTool() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide capture panel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var captureKindPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Type")
            Picker("Type", selection: captureKindBinding) {
                ForEach(CaptureKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage)
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Choose screenshot or screen recording")
        }
    }

    private var modeGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Mode")
            LazyVGrid(columns: modeColumns, alignment: .leading, spacing: 8) {
                ForEach(ScreenshotCaptureMode.allCases) { candidate in
                    CaptureModeTile(
                        mode: candidate,
                        isSelected: candidate == mode
                    ) {
                        modeBinding.wrappedValue = candidate
                    }
                }
            }
        }
    }

    private var windowPicker: some View {
        CaptureSettingsGroup(title: "Window") {
            CaptureOptionRow("App Window", systemImage: "macwindow") {
                Picker("App Window", selection: $selectedWindowNumber) {
                    Text("Choose").tag(Optional<Int>.none)
                    ForEach(windowTargets) { target in
                        Text(target.title).tag(Optional(target.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Choose the app window to capture")

                Button {
                    reloadWindowTargets()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh windows")
            }
        }
    }

    private var captureSettings: some View {
        CaptureSettingsGroup(title: "Capture") {
            if captureKind == .screenshot {
                CaptureOptionRow("Format", systemImage: "doc") {
                    Picker("Format", selection: formatBinding) {
                        ForEach(ScreenshotFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Choose the screenshot file format")
                }
            } else {
                CaptureOptionRow("Format", systemImage: "film") {
                    Text("MOV")
                        .foregroundStyle(.secondary)
                        .monospaced()
                }

                CaptureOptionRow("Duration", systemImage: "timer") {
                    Stepper(value: $recordingDuration, in: 0...3_600, step: 5) {
                        Text(recordingDuration == 0 ? "Manual" : durationText(recordingDuration))
                            .frame(width: 72, alignment: .trailing)
                    }
                    .help("Set recording duration")
                }

                CaptureOptionRow("Microphone", systemImage: "mic") {
                    Toggle("", isOn: $includeMicrophone)
                        .labelsHidden()
                        .help("Include microphone audio")
                }

                CaptureOptionRow("Clicks", systemImage: "cursorarrow.click") {
                    Toggle("", isOn: $showClicks)
                        .labelsHidden()
                        .help("Show mouse clicks in the recording")
                }
            }

            CaptureOptionRow("Delay", systemImage: "clock") {
                Stepper(value: $delay, in: 0...30) {
                    Text(delay == 0 ? "None" : "\(delay)s")
                        .frame(width: 72, alignment: .trailing)
                }
                .help("Set capture delay")
            }

            if mode.supportsCursor(for: captureKind) {
                CaptureOptionRow("Cursor", systemImage: "cursorarrow") {
                    Toggle("", isOn: $includeCursor)
                        .labelsHidden()
                        .help("Include the pointer in the capture")
                }
            }

            if captureKind == .screenshot && mode.supportsShadow(for: captureKind) {
                CaptureOptionRow("Shadow", systemImage: "rectangle.dashed") {
                    Toggle("", isOn: $includeWindowShadow)
                        .labelsHidden()
                        .help("Include the window shadow")
                }
            }
        }
        .controlSize(.small)
    }

    private var outputSettings: some View {
        CaptureSettingsGroup(title: "Output") {
            CaptureOptionRow("Save", systemImage: "folder") {
                Toggle("", isOn: $saveToActiveFolder)
                    .labelsHidden()
                    .disabled(captureKind == .recording)
                    .help("Save the capture in the active folder")
            }

            if captureKind == .screenshot {
                CaptureOptionRow("Clipboard", systemImage: "doc.on.clipboard") {
                    Toggle("", isOn: $copyToClipboard)
                        .labelsHidden()
                        .help("Copy the screenshot to the clipboard")
                }
            }

            CaptureOptionRow(captureKind == .recording ? "QuickTime" : "Preview", systemImage: "play.rectangle") {
                Toggle("", isOn: $openInPreview)
                    .labelsHidden()
                    .disabled(!saveToActiveFolder)
                    .help(captureKind == .recording ? "Open the recording in QuickTime" : "Open the screenshot in Preview")
            }

            CaptureOptionRow("Sound", systemImage: "speaker.wave.2") {
                Toggle("", isOn: $playSound)
                    .labelsHidden()
                    .help("Play a sound after capture")
            }
        }
        .controlSize(.small)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(destinationTitle, systemImage: destinationSystemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button {
                appState.performScreenshot(options: options)
            } label: {
                Label(captureKind == .recording ? "Start Recording" : "Take Screenshot", systemImage: captureKind.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canCapture)
            .help(captureKind == .recording ? "Start recording" : "Take screenshot")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func syncCaptureKindWithTool() {
        switch appState.activeToolPanel {
        case .screenshot:
            captureKindValue = CaptureKind.screenshot.rawValue
        case .recording:
            captureKindValue = CaptureKind.recording.rawValue
        default:
            break
        }
    }

    private var destinationSystemImage: String {
        if captureKind == .screenshot && !saveToActiveFolder && copyToClipboard {
            return "doc.on.clipboard"
        }
        return "folder"
    }

    private var destinationTitle: String {
        let folder = appState.activePane.currentURL.lastPathComponent
        if captureKind == .recording {
            return "Saves to \(folder)"
        }
        switch (saveToActiveFolder, copyToClipboard) {
        case (true, true):
            return "Saves to \(folder) and copies to clipboard"
        case (true, false):
            return "Saves to \(folder)"
        case (false, true):
            return "Copies to clipboard only"
        case (false, false):
            return "Choose an output option"
        }
    }

    private var selectedWindowTitle: String? {
        guard let selectedWindowNumber,
              let target = windowTargets.first(where: { $0.id == selectedWindowNumber }) else {
            return nil
        }
        return target.title
    }

    private var captureKindBinding: Binding<CaptureKind> {
        Binding(
            get: { captureKind },
            set: { newKind in
                captureKindValue = newKind.rawValue
                appState.selectCaptureKindInPanel(newKind)
            }
        )
    }

    private var modeBinding: Binding<ScreenshotCaptureMode> {
        Binding(
            get: { mode },
            set: { newMode in
                modeValue = newMode.rawValue
                if !newMode.supportsCursor(for: captureKind) {
                    includeCursor = false
                }
                if !newMode.supportsShadow(for: captureKind) {
                    includeWindowShadow = false
                }
            }
        )
    }

    private var formatBinding: Binding<ScreenshotFormat> {
        Binding(
            get: { format },
            set: { formatValue = $0.rawValue }
        )
    }

    private func reloadWindowTargets() {
        windowTargets = ScreenshotCapture.availableWindowTargets()
        if let selectedWindowNumber,
           windowTargets.contains(where: { $0.id == selectedWindowNumber }) {
            return
        }
        selectedWindowNumber = windowTargets.first?.id
    }

    private func durationText(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }
}

private struct CaptureModeTile: View {
    let mode: ScreenshotCaptureMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(mode.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }
}

private struct CaptureSettingsGroup<Content: View>: View {
    var title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                content
            }
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CaptureOptionRow<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(title)
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            content
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 37)
        }
    }
}

// Keep the old name for any external references.
typealias ScreenshotSheet = CapturePanelView
