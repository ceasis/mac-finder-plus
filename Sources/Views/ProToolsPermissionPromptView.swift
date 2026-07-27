import SwiftUI

struct ProToolsPermissionPromptView: View {
    @Environment(AppState.self) private var appState

    let prompt: ProToolsPermissionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Enable Pro Tools", systemImage: "wand.and.stars")
                    .font(.title3.bold())

                Text("Voice Recorder, Screenshot, and Screen Recording require access to Screen Recording and the Microphone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(prompt.required) { requirement in
                    permissionRow(requirement)
                }
            }

            Divider()

            HStack {
                Button("Cancel") {
                    appState.dismissProToolsPermissionPrompt()
                }

                Spacer()

                Button("Check Again") {
                    appState.retryProToolsPermissions()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func permissionRow(_ requirement: CapturePermissionRequirement) -> some View {
        let isMissing = prompt.missing.contains(requirement)

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: requirement.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isMissing ? .orange : .green)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.title)
                    .font(.callout.weight(.semibold))
                Text(requirement.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isMissing {
                Button("Open Settings") {
                    appState.openCapturePermissionSettings(requirement)
                }
            } else {
                Label("OK", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(isMissing ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isMissing ? Color.orange.opacity(0.28) : Color.green.opacity(0.22),
                    lineWidth: 1
                )
        )
    }
}
