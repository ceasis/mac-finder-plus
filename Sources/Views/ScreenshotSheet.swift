import SwiftUI

struct ScreenshotSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("screenshot.mode") private var modeValue = ScreenshotCaptureMode.interactive.rawValue
    @AppStorage("screenshot.format") private var formatValue = ScreenshotFormat.png.rawValue
    @AppStorage("screenshot.delay") private var delay = 0
    @AppStorage("screenshot.includeCursor") private var includeCursor = false
    @AppStorage("screenshot.includeWindowShadow") private var includeWindowShadow = true
    @AppStorage("screenshot.saveToActiveFolder") private var saveToActiveFolder = true
    @AppStorage("screenshot.copyToClipboard") private var copyToClipboard = true
    @AppStorage("screenshot.openInPreview") private var openInPreview = false
    @AppStorage("screenshot.playSound") private var playSound = false

    private var mode: ScreenshotCaptureMode {
        ScreenshotCaptureMode(rawValue: modeValue) ?? .interactive
    }

    private var format: ScreenshotFormat {
        ScreenshotFormat(rawValue: formatValue) ?? .png
    }

    private var canCapture: Bool {
        saveToActiveFolder || copyToClipboard
    }

    private var options: ScreenshotOptions {
        ScreenshotOptions(
            mode: mode,
            format: format,
            delay: min(max(delay, 0), 30),
            includeCursor: mode.supportsCursor && includeCursor,
            includeWindowShadow: mode.supportsShadow && includeWindowShadow,
            saveToActiveFolder: saveToActiveFolder,
            copyToClipboard: copyToClipboard,
            openInPreview: saveToActiveFolder && openInPreview,
            playSound: playSound
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Screenshot")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Picker("Mode", selection: modeBinding) {
                ForEach(ScreenshotCaptureMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Form {
                Picker("Format", selection: formatBinding) {
                    ForEach(ScreenshotFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }

                Stepper(value: $delay, in: 0...30) {
                    Text(delay == 0 ? "Delay: None" : "Delay: \(delay)s")
                }

                Toggle("Save in Active Folder", isOn: $saveToActiveFolder)

                Toggle("Copy to Clipboard", isOn: $copyToClipboard)

                Toggle("Open in Preview", isOn: $openInPreview)
                    .disabled(!saveToActiveFolder)

                Toggle("Capture Cursor", isOn: $includeCursor)
                    .disabled(!mode.supportsCursor)

                Toggle("Window Shadow", isOn: $includeWindowShadow)
                    .disabled(!mode.supportsShadow)

                Toggle("Sound", isOn: $playSound)
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Label(destinationTitle, systemImage: saveToActiveFolder ? "folder" : "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button {
                    appState.performScreenshot(options: options)
                } label: {
                    Label("Capture", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCapture)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var destinationTitle: String {
        if saveToActiveFolder {
            return appState.activePane.currentURL.lastPathComponent
        }
        return "Clipboard only"
    }

    private var modeBinding: Binding<ScreenshotCaptureMode> {
        Binding(
            get: { mode },
            set: { newMode in
                modeValue = newMode.rawValue
                if !newMode.supportsCursor {
                    includeCursor = false
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
}
