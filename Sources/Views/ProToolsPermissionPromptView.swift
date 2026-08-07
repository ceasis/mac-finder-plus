import AppKit
import SwiftUI

enum PermissionReviewPresentationPolicy {
    static let presentedDefaultsKey = "permissions.reviewPresented.v1"

    static var shouldPresentAutomatically: Bool {
        !UserDefaults.standard.bool(forKey: presentedDefaultsKey)
    }

    static func markPresented() {
        UserDefaults.standard.set(true, forKey: presentedDefaultsKey)
    }
}

struct PermissionsReviewView: View {
    static let windowID = "permissions-review"

    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var permissions = PermissionsManager()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(WorkbenchPermission.allCases.enumerated()), id: \.element.id) { index, permission in
                        permissionRow(permission)

                        if index < WorkbenchPermission.allCases.count - 1 {
                            Divider()
                                .padding(.leading, 58)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }

            Divider()

            footer
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 540, idealHeight: 660)
        .task {
            await permissions.refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refreshAll() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 50, height: 50)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 7) {
                Text("Review App Permissions")
                    .font(.title2.weight(.semibold))

                Text("Workbench works as a file browser with folder access. Grant the other permissions only for the features you use; you can change them later in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            Button {
                Task { await permissions.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Check permission status again")
        }
        .padding(22)
    }

    private func permissionRow(_ permission: WorkbenchPermission) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(iconColor(for: permission))
                .frame(width: 36, height: 36)
                .background(iconColor(for: permission).opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(permission.title)
                        .font(.callout.weight(.semibold))
                    statusBadge(for: permission)
                }

                Text(permission.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            permissionAction(for: permission)
                .frame(width: 205)
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func statusBadge(for permission: WorkbenchPermission) -> some View {
        switch permissions.status(for: permission) {
        case .granted:
            Label(permission == .folderAccess ? "Added" : "Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .notDetermined:
            Text("Not enabled")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func permissionAction(for permission: WorkbenchPermission) -> some View {
        let status = permissions.status(for: permission)

        if permission == .folderAccess {
            Button {
                Task {
                    await permissions.request(
                        permission,
                        folderStartingAt: appState.activePane.currentURL
                    )
                }
            } label: {
                Label(
                    status == .granted ? "Add Another Folder…" : "Choose Folder…",
                    systemImage: "folder.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
        } else {
            switch status {
            case .granted:
                Button(action: {}) {
                    Label("Access Granted", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            case .denied:
                Button {
                    permissions.openSettings(for: permission)
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
            case .notDetermined:
                Button {
                    Task { await permissions.request(permission) }
                } label: {
                    Label("Request Access", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func iconColor(for permission: WorkbenchPermission) -> Color {
        switch permissions.status(for: permission) {
        case .granted: .green
        case .denied: .orange
        case .notDetermined: .accentColor
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "macOS controls these permissions. Workbench never requests one until you choose its action above or use the related feature.",
                systemImage: "hand.raised"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Continue") {
                PermissionReviewPresentationPolicy.markPresented()
                dismissWindow(id: Self.windowID)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }
}

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
