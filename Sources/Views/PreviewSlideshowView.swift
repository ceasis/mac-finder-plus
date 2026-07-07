import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct PreviewSlideshowView: View {
    @Environment(AppState.self) private var appState
    let items: [FileItem]

    @AppStorage("previewSlideshow.effect") private var effectRawValue =
        PreviewSlideshowEffect.fade.rawValue
    @AppStorage("previewSlideshow.interval") private var imageInterval = 3.0
    @AppStorage("previewSlideshow.fillFrame") private var fillFrame = false

    @FocusState private var focused: Bool
    @State private var currentIndex = 0
    @State private var isPlaying = true
    @State private var currentImage: CGImage?
    @State private var currentPlayer: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var imageAdvanceTask: Task<Void, Never>?
    @State private var musicPlayer: AVAudioPlayer?
    @State private var musicURL: URL?
    @State private var musicAccessURL: URL?
    @State private var window: NSWindow?
    @State private var zoomIn = false

    private var currentItem: FileItem? {
        guard !items.isEmpty else { return nil }
        return items[min(max(currentIndex, 0), items.count - 1)]
    }

    private var effect: PreviewSlideshowEffect {
        PreviewSlideshowEffect(rawValue: effectRawValue) ?? .fade
    }

    private var effectBinding: Binding<PreviewSlideshowEffect> {
        Binding(
            get: { effect },
            set: { effectRawValue = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                ContentUnavailableView("No Slideshow Items", systemImage: "play.rectangle")
            } else if let currentItem {
                stage(for: currentItem)
                    .id(currentItem.id)
                    .transition(effect.transition)
                    .animation(effect.animation, value: currentIndex)
            }
            controls
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(SlideshowWindowAccessor { newWindow in
            window = newWindow
            newWindow?.collectionBehavior.insert(.fullScreenPrimary)
        })
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            prepareCurrentItem()
        }
        .onDisappear {
            teardownCurrentItem()
            clearMusic()
        }
        .onChange(of: currentIndex) { _, _ in prepareCurrentItem() }
        .onChange(of: isPlaying) { _, _ in updatePlaybackState() }
        .onChange(of: imageInterval) { _, _ in scheduleImageAdvanceIfNeeded() }
        .onKeyPress(.space) {
            isPlaying.toggle()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            previous()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            advance()
            return .handled
        }
        .onExitCommand {
            close()
        }
    }

    @ViewBuilder
    private func stage(for item: FileItem) -> some View {
        if item.isImage {
            if let currentImage {
                Image(decorative: currentImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fillFrame ? .fill : .fit)
                    .scaleEffect(effect == .zoom && zoomIn ? 1.06 : 1)
                    .animation(
                        effect == .zoom ? .linear(duration: max(imageInterval, 1)) : .default,
                        value: zoomIn
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        } else if item.isVideoMedia {
            if let currentPlayer {
                SlideshowPlayerView(player: currentPlayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        } else {
            audioStage(item)
        }
    }

    private func audioStage(_ item: FileItem) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(.white.opacity(0.86))
            Text(item.name)
                .font(.title2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 540)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.82))
                .help("Close slideshow")
            }
            .padding(18)

            Spacer()

            HStack(spacing: 12) {
                Text("\(min(currentIndex + 1, max(items.count, 1))) / \(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 54, alignment: .leading)

                Text(currentItem?.name ?? "Slideshow")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 160, maxWidth: 280, alignment: .leading)

                Button {
                    previous()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Previous slide")

                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .help(isPlaying ? "Pause" : "Play")

                Button {
                    advance()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Next slide")

                Divider()
                    .frame(height: 18)
                    .overlay(.white.opacity(0.22))

                Picker("Effect", selection: effectBinding) {
                    ForEach(PreviewSlideshowEffect.allCases) { effect in
                        Text(effect.title).tag(effect)
                    }
                }
                .labelsHidden()
                .frame(width: 118)
                .help("Choose transition effect")

                Stepper(value: $imageInterval, in: 1...30, step: 1) {
                    Text("\(Int(imageInterval.rounded()))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 28, alignment: .trailing)
                }
                .help("Seconds per image")

                Toggle("Fill", isOn: $fillFrame)
                    .toggleStyle(.button)
                    .help("Fill the screen")

                Button {
                    chooseMusic()
                } label: {
                    Image(systemName: musicURL == nil ? "music.note" : "music.note.list")
                }
                .help(musicURL == nil ? "Choose background music" : musicURL?.lastPathComponent ?? "Background music")

                if musicURL != nil {
                    Button {
                        clearMusic()
                    } label: {
                        Image(systemName: "speaker.slash")
                    }
                    .help("Stop background music")
                }

                Button {
                    toggleFullScreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Toggle fullscreen")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(18)
        }
    }

    private func prepareCurrentItem() {
        teardownCurrentItem()
        guard let item = currentItem else { return }

        if item.isPlayableMedia {
            let player = AVPlayer(url: item.url)
            currentPlayer = player
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                // Posted on the main queue, so hopping to the main actor is safe.
                MainActor.assumeIsolated { advance() }
            }
            if isPlaying {
                player.play()
            }
        } else if item.isImage {
            let itemID = item.id
            let itemURL = item.url
            imageLoadTask = Task {
                let image = await ImageProcessing.downsampled(url: itemURL, maxPixel: 4096)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard currentItem?.id == itemID else { return }
                    currentImage = image
                    restartZoomEffect()
                    scheduleImageAdvanceIfNeeded()
                }
            }
        }

        updateMusicPlayback()
    }

    private func teardownCurrentItem() {
        imageAdvanceTask?.cancel()
        imageAdvanceTask = nil
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentPlayer?.pause()
        currentPlayer = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        currentImage = nil
        zoomIn = false
    }

    private func updatePlaybackState() {
        if isPlaying {
            currentPlayer?.play()
            scheduleImageAdvanceIfNeeded()
        } else {
            currentPlayer?.pause()
            imageAdvanceTask?.cancel()
            imageAdvanceTask = nil
        }
        updateMusicPlayback()
    }

    private func scheduleImageAdvanceIfNeeded() {
        imageAdvanceTask?.cancel()
        guard isPlaying, currentItem?.isImage == true, currentImage != nil else { return }
        let nanoseconds = UInt64(max(imageInterval, 1) * 1_000_000_000)
        imageAdvanceTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                advance()
            }
        }
    }

    private func restartZoomEffect() {
        guard effect == .zoom else { return }
        zoomIn = false
        DispatchQueue.main.async {
            zoomIn = true
        }
    }

    private func previous() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex - 1 + items.count) % items.count
    }

    private func advance() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex + 1) % items.count
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadMusic(url)
    }

    private func loadMusic(_ url: URL) {
        clearMusic()
        let hasAccess = url.startAccessingSecurityScopedResource()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            musicURL = url
            musicAccessURL = hasAccess ? url : nil
            musicPlayer = player
            updateMusicPlayback()
        } catch {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
            appState.lastError = error.localizedDescription
        }
    }

    private func updateMusicPlayback() {
        guard let musicPlayer else { return }
        if isPlaying {
            musicPlayer.play()
        } else {
            musicPlayer.pause()
        }
    }

    private func clearMusic() {
        musicPlayer?.stop()
        musicPlayer = nil
        musicURL = nil
        if let musicAccessURL {
            musicAccessURL.stopAccessingSecurityScopedResource()
        }
        musicAccessURL = nil
    }

    private func toggleFullScreen() {
        (window ?? NSApplication.shared.keyWindow)?.toggleFullScreen(nil)
    }

    private func close() {
        appState.showPreviewSlideshow = false
    }
}

private enum PreviewSlideshowEffect: String, CaseIterable, Identifiable {
    case cut
    case fade
    case zoom
    case slide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cut: "Cut"
        case .fade: "Fade"
        case .zoom: "Zoom"
        case .slide: "Slide"
        }
    }

    var transition: AnyTransition {
        switch self {
        case .cut:
            .identity
        case .fade:
            .opacity
        case .zoom:
            .opacity.combined(with: .scale(scale: 0.96))
        case .slide:
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        }
    }

    var animation: Animation? {
        switch self {
        case .cut: nil
        case .fade: .easeInOut(duration: 0.45)
        case .zoom: .easeInOut(duration: 0.55)
        case .slide: .easeInOut(duration: 0.42)
        }
    }
}

private struct SlideshowPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.videoGravity = .resizeAspect
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        view.controlsStyle = .none
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private struct SlideshowWindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
    }
}
