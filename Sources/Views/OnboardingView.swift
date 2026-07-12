import SwiftUI

/// First-run welcome flow. Walks a new user through the one folder grant Workbench
/// needs to browse their files, plus the Screen Recording and Microphone
/// permissions the capture tools require — these fail silently if not granted,
/// so surfacing them up front avoids a "the recorder is broken" first impression.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool

    @State private var permissions = PermissionsManager()
    @State private var step = 0

    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 40)

            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: folderStep
        case 2: screenRecordingStep
        default: microphoneStep
        }
    }

    private var welcomeStep: some View {
        stepLayout(
            icon: "square.split.2x1",
            title: "Welcome to Workbench",
            message: "A fast, keyboard-driven file manager for people who work with photos and video — with a built-in screenshot editor and screen recorder. Let’s get a few things set up."
        ) {
            EmptyView()
        }
    }

    private var folderStep: some View {
        stepLayout(
            icon: "folder.badge.person.crop",
            title: "Give Workbench access to your files",
            message: "macOS asks your permission before an app can browse a folder. Grant your Home folder to get started — you can add more folders anytime from the sidebar."
        ) {
            actionRow(
                granted: permissions.hasGrantedFolderAccess,
                grantedLabel: "Folder access granted",
                buttonLabel: permissions.hasGrantedFolderAccess ? "Add Another Folder…" : "Grant Home Folder…"
            ) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                if let granted = BookmarkStore.shared.requestAccess(startingAt: home) {
                    appState.activePane.navigate(to: granted)
                }
                permissions.refresh()
            }
        }
    }

    private var screenRecordingStep: some View {
        stepLayout(
            icon: "record.circle",
            title: "Enable Screen Recording",
            message: "Workbench’s screenshot and screen-recording tools need macOS’s Screen Recording permission. This is optional — skip it if you only want to manage files."
        ) {
            actionRow(
                granted: permissions.screenRecording == .granted,
                grantedLabel: "Screen Recording enabled",
                buttonLabel: permissions.screenRecording == .denied ? "Open System Settings…" : "Enable…"
            ) {
                if permissions.screenRecording == .denied {
                    permissions.openScreenRecordingSettings()
                } else {
                    permissions.requestScreenRecording()
                }
            }
        }
    }

    private var microphoneStep: some View {
        stepLayout(
            icon: "mic",
            title: "Enable the Microphone",
            message: "Grant microphone access to narrate screen recordings and record voice notes. Optional — you can enable it later in System Settings."
        ) {
            actionRow(
                granted: permissions.microphone == .granted,
                grantedLabel: "Microphone enabled",
                buttonLabel: permissions.microphone == .denied ? "Open System Settings…" : "Enable…"
            ) {
                if permissions.microphone == .denied {
                    permissions.openMicrophoneSettings()
                } else {
                    Task { await permissions.requestMicrophone() }
                }
            }
        }
    }

    private func stepLayout(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .frame(height: 64)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }

    private func actionRow(
        granted: Bool,
        grantedLabel: String,
        buttonLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if granted {
                Label(grantedLabel, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            } else {
                Button(buttonLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    private var footer: some View {
        HStack {
            // Progress dots.
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            if step < lastStep {
                Button(step == 0 ? "Get Started" : "Continue") {
                    permissions.refresh()
                    step += 1
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func finish() {
        isPresented = false
    }
}
