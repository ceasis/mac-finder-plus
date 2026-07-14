import SwiftUI

struct FileActivityOverlay: View {
    @Environment(AppState.self) private var appState
    @AppStorage(ActivityPopupSettings.autoHideDelayKey)
    private var autoHideDelay = ActivityPopupSettings.defaultAutoHideDelay
    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isVisible && !appState.fileActivities.isEmpty {
                FileActivityPanel {
                    hidePanel()
                }
                .padding(12)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: isVisible)
        .onAppear {
            updatePresentation()
        }
        .onChange(of: presentationKey) { _, _ in
            updatePresentation()
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }

    private var presentationKey: String {
        appState.fileActivities.prefix(4)
            .map { activity in
                "\(activity.id.uuidString):\(statusKey(activity.status)):\(activity.finishedAt?.timeIntervalSince1970 ?? 0)"
            }
            .joined(separator: "|")
    }

    private func updatePresentation() {
        guard !appState.fileActivities.isEmpty else {
            hidePanel()
            return
        }
        isVisible = true
        scheduleAutoHideIfReady()
    }

    private func scheduleAutoHideIfReady() {
        hideTask?.cancel()
        guard autoHideDelay > ActivityPopupSettings.neverAutoHideDelay else { return }
        guard appState.fileActivities.prefix(4).allSatisfy({ $0.status.isTerminal }) else { return }

        let delay = UInt64(max(autoHideDelay, 0.1) * 1_000_000_000)
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }

    private func hidePanel() {
        hideTask?.cancel()
        isVisible = false
    }

    private func statusKey(_ status: FileActivityStatus) -> String {
        switch status {
        case .queued: "queued"
        case .running: "running"
        case .paused: "paused"
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
}

struct FileActivityPanel: View {
    @Environment(AppState.self) private var appState
    var onDismiss: () -> Void = {}

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Activity", systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
                Spacer()
                if showsConflictPolicyPicker {
                    Picker("Conflicts", selection: $appState.fileOperationConflictPolicy) {
                        ForEach(FileConflictPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 108)
                    .help("Conflict handling for copy, move, and sync operations")
                }
                PanelIconButton(systemName: "xmark", help: "Hide Activity") {
                    onDismiss()
                }
            }

            ForEach(appState.fileActivities.prefix(4)) { activity in
                activityRow(activity)
                if activity.id != appState.fileActivities.prefix(4).last?.id {
                    Divider()
                }
            }
        }
        .padding(10)
        .frame(width: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .shadow(radius: 10, y: 4)
    }

    private var showsConflictPolicyPicker: Bool {
        appState.fileActivities.prefix(4).contains { activity in
            activity.supportsConflictPolicy && !activity.status.isTerminal
        }
    }

    private func activityRow(_ activity: FileActivity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(activity.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if !activity.status.isTerminal {
                    Button {
                        appState.togglePauseActivity(activity.id)
                    } label: {
                        Image(systemName: activity.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.plain)
                    .help(activity.isPaused ? "Resume" : "Pause")
                    Button {
                        appState.cancelActivity(activity.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                } else {
                    if appState.canUndoActivity(activity.id) {
                        Button {
                            appState.undoActivity(activity.id)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.plain)
                        .help("Undo")
                    }
                    if appState.canRevealActivity(activity.id) {
                        Button {
                            appState.revealActivity(activity.id)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    }
                }
            }

            if activity.bytesTotal > 0 {
                ProgressView(value: activity.progress)
                    .controlSize(.small)
            } else if !activity.status.isTerminal {
                ProgressView()
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text(statusText(activity))
                if let progressDetail = activity.progressDetail {
                    Text("·")
                    Text(progressDetail)
                } else if activity.bytesTotal > 0 {
                    Text("·")
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: activity.bytesCompleted, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: activity.bytesTotal, countStyle: .file))"
                    )
                }
                if let speed = activity.speedText, activity.isRunning {
                    Text("· \(speed)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func statusText(_ activity: FileActivity) -> String {
        switch activity.status {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .paused:
            return "Paused"
        case .completed:
            return "Done"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }
}
