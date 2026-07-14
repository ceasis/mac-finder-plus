import AppKit
import SwiftUI

struct PanelIconButton: View {
    let systemName: String
    let help: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }
}

struct AdaptiveActionBar<Leading: View, Trailing: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                leading()
                Spacer(minLength: 12)
                trailing()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: spacing) {
                    leading()
                }
                HStack(spacing: spacing) {
                    trailing()
                }
            }
        }
    }
}

struct AboutWorkbenchView: View {
    @Environment(AppState.self) private var appState
    @State private var copiedDiagnostics = false

    private let info = WorkbenchBuildInfo.current

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchPanelHeader(
                title: "About Workbench",
                subtitle: info.displayVersion,
                systemImage: "square.grid.2x2"
            )

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 82, height: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(info.appName)
                            .font(.system(size: 24, weight: .semibold))
                        Text("A faster workspace for files, notes, snippets, previews, and cleanup.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: info.bundleID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                WorkbenchInfoGrid(rows: [
                    ("Version", info.version),
                    ("Build", info.build),
                    ("macOS", info.macOSVersion),
                    ("Mac", info.hardwareModel),
                ])

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            appState.copySupportDiagnostics()
                            copiedDiagnostics = true
                        } label: {
                            Label(copiedDiagnostics ? "Copied" : "Copy Diagnostics", systemImage: "doc.on.doc")
                        }

                        Button {
                            appState.exportWorkbenchDiagnostics()
                        } label: {
                            Label("Export Diagnostics", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            appState.reportProblem()
                        } label: {
                            Label("Report Problem", systemImage: "envelope")
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            appState.revealWorkbenchSupportFolder()
                        } label: {
                            Label("Support Folder", systemImage: "folder")
                        }

                        Spacer()

                        Button("Close") {
                            appState.showAboutWorkbench = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .controlSize(.large)
            }
            .padding(24)
        }
        .frame(width: 620)
    }
}

struct UpdateWorkbenchView: View {
    @Environment(AppState.self) private var appState
    @State private var copiedVersion = false

    private let info = WorkbenchBuildInfo.current

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchPanelHeader(
                title: "Version & Updates",
                subtitle: info.displayVersion,
                systemImage: "arrow.triangle.2.circlepath"
            )

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Managed by your install channel")
                            .font(.headline)
                        Text("Keep Workbench updated from the same place you installed it. App Store builds receive updates through the Mac App Store.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(info.appName) \(info.displayVersion)", forType: .string)
                        copiedVersion = true
                    } label: {
                        Label(copiedVersion ? "Copied" : "Copy Version", systemImage: "doc.on.doc")
                    }

                    Spacer()

                    Button("Close") {
                        appState.showUpdatePanel = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(24)
        }
        .frame(width: 580)
    }
}

struct ReleaseReadinessChecklistView: View {
    @Environment(AppState.self) private var appState

    private let groups = WorkbenchReleaseChecklistGroup.defaults

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchPanelHeader(
                title: "Release Readiness",
                subtitle: "Final checks before distribution",
                systemImage: "checklist"
            )

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(group.title, systemImage: group.systemImage)
                                .font(.headline)
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(group.items, id: \.self) { item in
                                    HStack(alignment: .top, spacing: 9) {
                                        Image(systemName: "circle")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.blue)
                                            .padding(.top, 4)
                                        Text(item)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
            }
            .frame(width: 720, height: 520)

            Divider()

            HStack(spacing: 10) {
                Button {
                    appState.exportWorkbenchDiagnostics()
                } label: {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.down")
                }

                Spacer()

                Button("Close") {
                    appState.showReleaseChecklist = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }
}

struct KeyboardShortcutsView: View {
    @Environment(AppState.self) private var appState

    private let groups = WorkbenchShortcutGroup.defaults

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchPanelHeader(
                title: "Keyboard Shortcuts",
                subtitle: "Common Workbench commands",
                systemImage: "keyboard"
            )

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        WorkbenchShortcutGroupView(group: group)
                    }
                }
                .padding(20)
            }
            .frame(width: 680, height: 520)

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    appState.showKeyboardShortcuts = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }
}

struct ActivityHistoryView: View {
    @Environment(AppState.self) private var appState

    private var activities: [FileActivity] {
        appState.fileActivities
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchPanelHeader(
                title: "Activity History",
                subtitle: "\(activities.count) recent operation\(activities.count == 1 ? "" : "s")",
                systemImage: "arrow.up.arrow.down"
            )

            Divider()

            Group {
                if activities.isEmpty {
                    ContentUnavailableView(
                        "No Activity Yet",
                        systemImage: "tray",
                        description: Text("Copy, move, export, or convert files and they will show here.")
                    )
                    .frame(width: 700, height: 420)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(activities) { activity in
                                ActivityHistoryRow(activity: activity)
                            }
                        }
                        .padding(14)
                    }
                    .frame(width: 720, height: 480)
                }
            }

            Divider()

            HStack {
                Button {
                    appState.clearCompletedActivities()
                } label: {
                    Label("Clear Done", systemImage: "checkmark.circle")
                }
                .disabled(!activities.contains { $0.status.isTerminal })

                Spacer()

                Button("Close") {
                    appState.showActivityHistory = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }
}

private struct WorkbenchPanelHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct WorkbenchInfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label)
                        .foregroundStyle(.secondary)
                    Text(verbatim: value)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct WorkbenchShortcutGroup: Identifiable {
    let title: String
    let systemImage: String
    let rows: [WorkbenchShortcut]

    var id: String { title }

    static let defaults: [WorkbenchShortcutGroup] = [
        WorkbenchShortcutGroup(
            title: "Browse",
            systemImage: "folder",
            rows: [
                WorkbenchShortcut(command: "Back", keys: ["Command", "["]),
                WorkbenchShortcut(command: "Forward", keys: ["Command", "]"]),
                WorkbenchShortcut(command: "Enclosing Folder", keys: ["Command", "Up"]),
                WorkbenchShortcut(command: "Open Selection", keys: ["Command", "Down"]),
                WorkbenchShortcut(command: "Go to Folder", keys: ["Shift", "Command", "G"]),
                WorkbenchShortcut(command: "Refresh", keys: ["Command", "R"]),
                WorkbenchShortcut(command: "Find", keys: ["Command", "F"]),
                WorkbenchShortcut(command: "Quick Look", keys: ["Command", "Y"]),
            ]
        ),
        WorkbenchShortcutGroup(
            title: "Views",
            systemImage: "rectangle.3.group",
            rows: [
                WorkbenchShortcut(command: "List View", keys: ["Command", "1"]),
                WorkbenchShortcut(command: "Icon View", keys: ["Command", "2"]),
                WorkbenchShortcut(command: "Column View", keys: ["Command", "3"]),
                WorkbenchShortcut(command: "Dual Pane", keys: ["Shift", "Command", "D"]),
                WorkbenchShortcut(command: "Hidden Files", keys: ["Shift", "Command", "."]),
                WorkbenchShortcut(command: "Preview Pane", keys: ["Option", "Command", "P"]),
            ]
        ),
        WorkbenchShortcutGroup(
            title: "Files",
            systemImage: "doc",
            rows: [
                WorkbenchShortcut(command: "New Folder", keys: ["Shift", "Command", "N"]),
                WorkbenchShortcut(command: "Duplicate", keys: ["Command", "D"]),
                WorkbenchShortcut(command: "Move to Trash", keys: ["Command", "Delete"]),
                WorkbenchShortcut(command: "Copy to Other Pane", keys: ["F5"]),
                WorkbenchShortcut(command: "Move to Other Pane", keys: ["F6"]),
                WorkbenchShortcut(command: "Edit Text", keys: ["Option", "Command", "E"]),
                WorkbenchShortcut(command: "Annotate Image", keys: ["Option", "Command", "A"]),
                WorkbenchShortcut(command: "Capture", keys: ["Option", "Command", "5"]),
            ]
        ),
        WorkbenchShortcutGroup(
            title: "Tools",
            systemImage: "wrench.and.screwdriver",
            rows: [
                WorkbenchShortcut(command: "Command Palette", keys: ["Command", "K"]),
                WorkbenchShortcut(command: "Notes", keys: ["Option", "Command", "N"]),
                WorkbenchShortcut(command: "Clipboard History", keys: ["Option", "Command", "V"]),
                WorkbenchShortcut(command: "Drop Stack", keys: ["Option", "Command", "D"]),
                WorkbenchShortcut(command: "Advanced Search", keys: ["Option", "Command", "F"]),
                WorkbenchShortcut(command: "Voice Recorder", keys: ["Option", "Command", "M"]),
                WorkbenchShortcut(command: "Organize", keys: ["Shift", "Command", "O"]),
                WorkbenchShortcut(command: "Clean Up", keys: ["Shift", "Command", "K"]),
                WorkbenchShortcut(command: "Shortcuts", keys: ["Command", "/"]),
            ]
        ),
    ]
}

private struct WorkbenchReleaseChecklistGroup: Identifiable {
    let title: String
    let systemImage: String
    let items: [String]

    var id: String { title }

    static let defaults: [WorkbenchReleaseChecklistGroup] = [
        WorkbenchReleaseChecklistGroup(
            title: "Clean Install",
            systemImage: "person.crop.circle.badge.checkmark",
            items: [
                "Install the DMG on a clean macOS user account.",
                "Launch Workbench from Applications, not the build folder.",
                "Confirm the app name, icon, bundle ID, and About window are correct.",
                "Open Settings and verify permissions, safety prompts, support tools, and preview controls.",
            ]
        ),
        WorkbenchReleaseChecklistGroup(
            title: "Privacy Permissions",
            systemImage: "lock.shield",
            items: [
                "Click Screenshot and Screen Recording tools and confirm permission prompts happen only when needed.",
                "Record a short voice note and video journal attachment.",
                "Confirm denied permissions show a clear route to System Settings.",
            ]
        ),
        WorkbenchReleaseChecklistGroup(
            title: "File Workflows",
            systemImage: "folder",
            items: [
                "Copy, move, rename, duplicate, create folder, create text file, and move to Trash.",
                "Confirm risky Trash actions ask first and Activity History offers Undo and Reveal.",
                "Right-click images, videos, audio, PDFs, documents, folders, ZIPs, and mixed selections.",
                "Drag files into Notes and Snippets, then drag them back out to a folder.",
            ]
        ),
        WorkbenchReleaseChecklistGroup(
            title: "Data Recovery",
            systemImage: "externaldrive.badge.timemachine",
            items: [
                "Export Workbench Data and confirm the ZIP includes a manifest.",
                "Import that backup and confirm Notes, Snippets, Clipboard History, and Disk Space data reload.",
                "Reveal the pre-import safety backup created during restore.",
                "Export Diagnostics and confirm it contains version info, activity history, recent logs, and crash reports when present.",
            ]
        ),
        WorkbenchReleaseChecklistGroup(
            title: "Distribution",
            systemImage: "shippingbox",
            items: [
                "Run the signed and notarized build, not an ad-hoc debug build.",
                "Open the DMG, drag Workbench to Applications, eject, then launch from Applications.",
                "Install the final customer build and repeat a smoke test.",
                "Confirm update messaging matches the distribution channel.",
            ]
        ),
    ]
}

private struct WorkbenchShortcut: Identifiable {
    let command: String
    let keys: [String]

    var id: String { "\(command)-\(keys.joined(separator: "-"))" }
}

private struct WorkbenchShortcutGroupView: View {
    let group: WorkbenchShortcutGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(group.title, systemImage: group.systemImage)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(group.rows) { row in
                    HStack {
                        Text(row.command)
                            .foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(row.keys, id: \.self) { key in
                                ShortcutKeyCap(label: key)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    if row.id != group.rows.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

private struct ShortcutKeyCap: View {
    let label: String

    var body: some View {
        Text(keyGlyph(label))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
    }

    private func keyGlyph(_ value: String) -> String {
        switch value {
        case "Command": return "cmd"
        case "Option": return "opt"
        case "Shift": return "shift"
        case "Delete": return "delete"
        case "Up": return "up"
        case "Down": return "down"
        default: return value
        }
    }
}

private struct ActivityHistoryRow: View {
    @Environment(AppState.self) private var appState
    let activity: FileActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 28, height: 28)
                    .background(statusTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(activity.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusTint)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(statusTint.opacity(0.10), in: Capsule())
                    }

                    Text(activity.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Text(timestamp)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !activity.status.isTerminal {
                if activity.bytesTotal > 0 {
                    ProgressView(value: activity.progress)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                if appState.canUndoActivity(activity.id) {
                    Button {
                        appState.undoActivity(activity.id)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                }

                if appState.canRevealActivity(activity.id) {
                    Button {
                        appState.revealActivity(activity.id)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }

                if let errorMessage {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(errorMessage, forType: .string)
                    } label: {
                        Label("Copy Error", systemImage: "doc.on.doc")
                    }
                }

                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var timestamp: String {
        (activity.finishedAt ?? activity.startedAt).formatted(date: .abbreviated, time: .shortened)
    }

    private var statusText: String {
        switch activity.status {
        case .queued: return "Queued"
        case .running: return "Running"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    private var statusSymbol: String {
        switch activity.status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch activity.status {
        case .queued: return .secondary
        case .running: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .cancelled: return .secondary
        case .failed: return .red
        }
    }

    private var errorMessage: String? {
        if case let .failed(message) = activity.status {
            return message
        }
        return nil
    }
}
