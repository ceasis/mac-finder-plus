import SwiftUI

struct FileActivityPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Activity", systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
                Spacer()
                Picker("Conflicts", selection: $appState.fileOperationConflictPolicy) {
                    ForEach(FileConflictPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden()
                .frame(width: 108)
                .help("Conflict handling for new copy and move operations")
                Button {
                    appState.clearCompletedActivities()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .disabled(!appState.fileActivities.contains { $0.status.isTerminal })
                .help("Clear completed activities")
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
