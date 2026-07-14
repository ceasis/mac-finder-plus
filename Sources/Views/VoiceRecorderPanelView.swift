import AppKit
import AVFoundation
import SwiftUI

struct VoiceRecorderPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = VoiceRecorderStore.shared
    @State private var player: AVPlayer?
    @State private var playbackURL: URL?
    @State private var endObserver: NSObjectProtocol?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    destinationRow
                    recorderSurface
                    if let savedURL = store.lastSavedURL {
                        savedRecordingRow(savedURL)
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 460, maxHeight: .infinity)
        .background(.bar)
        .alert("Voice Recorder Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {
                store.clearError()
            }
        } message: {
            Text(store.lastError ?? "")
        }
        .onDisappear {
            teardownPlayback()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Voice Recorder", systemImage: "mic")
                .font(.headline)

            Spacer()

            PanelIconButton(
                systemName: "xmark",
                help: store.isRecording ? "Stop or cancel recording before closing" : "Hide Voice Recorder",
                isDisabled: store.isRecording
            ) {
                appState.hideVoiceRecorderTool()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var destinationRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Save to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(folderDisplayName(appState.activePane.currentURL))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(10)
        .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
        .help(appState.activePane.currentURL.path)
    }

    private var recorderSurface: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(store.isRecording ? Color.red.opacity(0.16) : Color.secondary.opacity(0.12))
                Image(systemName: store.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(store.isRecording ? .red : .secondary)
            }
            .frame(width: 132, height: 132)
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                if store.isRecording {
                    VoiceRecorderTimerView(startedAt: store.startedAt)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(store.destinationURL?.lastPathComponent ?? "Recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Ready")
                        .font(.title3.weight(.semibold))
                    Text("Record audio into the active folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            VoiceLevelMeter(level: store.inputLevel)
                .frame(height: 8)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.isRecording {
                Button {
                    stopAndSelectRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    store.cancelRecording()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    store.startRecording(in: appState.activePane.currentURL)
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func savedRecordingRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback(url)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause" : "Play")

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "play.rectangle")
            }
            .buttonStyle(.plain)
            .help("Open recording")
        }
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stopAndSelectRecording() {
        guard let url = store.stopRecording() else { return }
        teardownPlayback()
        appState.activePane.selection = [url.path]
        appState.activePane.refresh()
    }

    private func togglePlayback(_ url: URL) {
        if playbackURL != url || player == nil {
            teardownPlayback()
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            playbackURL = url
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: newPlayer.currentItem,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    guard playbackURL == url else { return }
                    isPlaying = false
                    player?.seek(to: .zero)
                }
            }
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func teardownPlayback() {
        player?.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player = nil
        playbackURL = nil
        endObserver = nil
        isPlaying = false
    }

    private func folderDisplayName(_ url: URL) -> String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )
    }
}

private struct VoiceRecorderTimerView: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(recordingText(now: context.date))
        }
    }

    private func recordingText(now: Date) -> String {
        guard let startedAt else { return "0:00" }
        let seconds = max(Int(now.timeIntervalSince(startedAt)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VoiceLevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(Color.red.opacity(0.72))
                    .frame(width: max(6, geometry.size.width * min(max(level, 0), 1)))
            }
        }
        .accessibilityLabel("Input level")
    }
}
