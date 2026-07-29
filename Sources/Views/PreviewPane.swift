import AVKit
import QuickLookUI
import SwiftUI

private struct PendingLongVideoTransform {
    let operation: MediaTransformOperation
    let itemIDs: Set<FileItem.ID>
    let longVideoCount: Int
    let longestDuration: Double

    var message: String {
        let videoLabel = longVideoCount == 1 ? "video is" : "videos are"
        return "\(longVideoCount) selected \(videoLabel) longer than 15 minutes (up to \(VideoTrimmer.timeText(longestDuration))). Transforming video re-encodes it and may take a while. A transformed copy will be saved; the original stays unchanged."
    }
}

/// Inline media preview for the active pane's selection: images (downsampled,
/// off-main decode) and video/audio with autoplay and a loop toggle.
struct PreviewPane: View {
    @Environment(AppState.self) private var appState
    @AppStorage("loopVideos") private var loopVideos = true
    @AppStorage("previewLayoutMode") private var previewLayoutMode = PreviewLayoutMode.rows.rawValue
    @AppStorage("previewMediaSizeScale") private var previewMediaSizeScale = 1.0
    @AppStorage("previewControlsSizeScale") private var previewControlsSizeScale = 1.0
    @State private var transformActivityID: UUID?
    @State private var pendingLongVideoTransform: PendingLongVideoTransform?
    @State private var isCheckingVideoDuration = false
    @State private var showsVideoControls = true

    private var selectedItems: [FileItem] { appState.activePane.selectedItems }
    private var mediaItems: [FileItem] { selectedItems.filter(\.isPreviewable) }
    private var previewItems: [FileItem] { mediaItems }
    private var primaryItem: FileItem? { previewItems.first ?? selectedItems.first }
    private var imagePreviewIDs: Set<FileItem.ID> {
        Set(previewItems.filter(\.isImage).map(\.id))
    }
    private var hasPlayablePreview: Bool {
        previewItems.contains { $0.isPlayableMedia }
    }
    private var hasSingleVideoPreview: Bool {
        selectedItems.count == 1 && selectedItems.first?.isVideoMedia == true
    }
    private var transformablePreviewItems: [FileItem] {
        selectedItems.filter { $0.isImage || $0.isVideoMedia }
    }
    private var activeTransformActivity: FileActivity? {
        guard let transformActivityID,
              let activity = appState.fileActivities.first(where: { $0.id == transformActivityID }),
              !activity.status.isTerminal else {
            return nil
        }
        return activity
    }
    private var isTransforming: Bool {
        isCheckingVideoDuration || activeTransformActivity != nil
    }
    private var layoutMode: PreviewLayoutMode {
        PreviewLayoutMode(rawValue: previewLayoutMode) ?? .rows
    }
    private var title: String {
        guard selectedItems.count > 1 else { return primaryItem?.name ?? "Preview" }
        guard !previewItems.isEmpty else { return "\(selectedItems.count) selected" }
        return "\(previewItems.count) previews"
    }
    private var controlsScale: CGFloat {
        CGFloat(min(max(previewControlsSizeScale, 0.8), 2.0)) * 1.1
    }
    private var previewControlSize: ControlSize {
        if previewControlsSizeScale < 0.9 { return .mini }
        if previewControlsSizeScale < 1.15 { return .small }
        if previewControlsSizeScale < 1.55 { return .regular }
        return .large
    }
    private var previewControlFont: Font {
        .system(size: 13 * controlsScale)
    }
    private var previewControlCaptionFont: Font {
        .system(size: 11 * controlsScale)
    }
    private var previewControlSpacing: CGFloat {
        max(5, 5 * controlsScale)
    }
    private var previewButtonSide: CGFloat {
        16 * controlsScale
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let activity = activeTransformActivity {
                transformProgress(activity)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 240, idealWidth: 340, maxHeight: .infinity)
        .onKeyPress("0") { rateSelection(0); return .handled }
        .onKeyPress("1") { rateSelection(1); return .handled }
        .onKeyPress("2") { rateSelection(2); return .handled }
        .onKeyPress("3") { rateSelection(3); return .handled }
        .onKeyPress("4") { rateSelection(4); return .handled }
        .onKeyPress("5") { rateSelection(5); return .handled }
        .alert("Long Video Export", isPresented: Binding(
            get: { pendingLongVideoTransform != nil },
            set: { isPresented in
                if !isPresented {
                    pendingLongVideoTransform = nil
                }
            }
        )) {
            Button("Transform Copy") {
                guard let request = pendingLongVideoTransform else { return }
                pendingLongVideoTransform = nil
                startMediaTransform(request.operation, itemIDs: request.itemIDs)
            }
            Button("Cancel", role: .cancel) {
                pendingLongVideoTransform = nil
            }
        } message: {
            Text(pendingLongVideoTransform?.message ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let primaryItem, !primaryItem.isDirectory {
                Menu {
                    Button("Clear Rating") { appState.rateSelection(0) }
                    Divider()
                    ForEach(1...5, id: \.self) { rating in
                        Button("\(rating) Star\(rating == 1 ? "" : "s")") {
                            appState.rateSelection(rating)
                        }
                    }
                } label: {
                    RatingStarsView(rating: primaryItem.rating, size: 9)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Rate selection with 1-5, or 0 to clear")
            }
            Spacer(minLength: 8)
            headerControls
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var headerControls: some View {
        HStack(spacing: previewControlSpacing) {
            if !imagePreviewIDs.isEmpty {
                Button {
                    appState.beginAnnotateImage(imagePreviewIDs)
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: previewButtonSide, height: previewButtonSide)
                }
                .help("Annotate Image (⌥⌘A)")
            }
            if !transformablePreviewItems.isEmpty {
                mediaTransformButton(.rotateCounterclockwise, image: Image(systemName: "rotate.left"))
                mediaTransformButton(.rotateClockwise, image: Image(systemName: "rotate.right"))
                mediaTransformButton(.flipHorizontal, image: Image(systemName: "flip.horizontal"))
                mediaTransformButton(.flipVertical, image: Image(systemName: "flip.vertical"))
            }
            if hasPlayablePreview {
                Toggle(isOn: $loopVideos) {
                    Image(systemName: loopVideos ? "repeat.circle.fill" : "repeat")
                        .foregroundStyle(loopVideos ? Color.accentColor : Color.secondary)
                        .frame(width: previewButtonSide, height: previewButtonSide)
                        .contentShape(Rectangle())
                }
                .toggleStyle(.button)
                .accessibilityLabel("Loop playback")
                .accessibilityValue(loopVideos ? "On" : "Off")
                .help(loopVideos
                    ? "Loop playback is on"
                    : "Loop playback is off")
            }
            if hasSingleVideoPreview {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsVideoControls.toggle()
                    }
                } label: {
                    Image(systemName: showsVideoControls ? "eye.slash" : "eye")
                        .frame(width: previewButtonSide, height: previewButtonSide)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(
                    showsVideoControls
                        ? "Hide video editing controls"
                        : "Show video editing controls"
                )
                .help(
                    showsVideoControls
                        ? "Hide trim and export controls and enlarge the player"
                        : "Show trim and export controls"
                )
            }
            if !previewItems.isEmpty {
                HStack(spacing: previewControlSpacing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.secondary)
                    Slider(value: $previewMediaSizeScale, in: 0.6...3.6)
                        .frame(width: 82 * controlsScale)
                }
                .help("Resize media previews")
            }
            if !previewItems.isEmpty {
                Button {
                    appState.beginPreviewSlideshow()
                } label: {
                    Image(systemName: "play.rectangle")
                        .frame(width: previewButtonSide, height: previewButtonSide)
                }
                .help("Play preview slideshow")
            }
            if previewItems.count > 1 {
                Picker("Layout", selection: $previewLayoutMode) {
                    ForEach(PreviewLayoutMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode.rawValue)
                            .help(mode.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 58 * controlsScale)
                .help("Preview layout")
            }
            Button {
                appState.dismissToolPanel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: previewButtonSide, height: previewButtonSide)
            }
            .help("Close preview (⌥⌘P)")
        }
        .font(previewControlFont)
        .controlSize(previewControlSize)
    }

    private func mediaTransformButton(
        _ operation: MediaTransformOperation,
        image: Image
    ) -> some View {
        Button {
            requestMediaTransform(operation)
        } label: {
            image
                .frame(width: previewButtonSide, height: previewButtonSide)
        }
        .disabled(isTransforming)
        .help(operation.title)
    }

    private func requestMediaTransform(_ operation: MediaTransformOperation) {
        let items = transformablePreviewItems
        guard !items.isEmpty else { return }
        let itemIDs = Set(items.map(\.id))
        let videos = items.filter(\.isVideoMedia)
        guard !videos.isEmpty else {
            startMediaTransform(operation, itemIDs: itemIDs)
            return
        }

        isCheckingVideoDuration = true
        Task { @MainActor in
            defer { isCheckingVideoDuration = false }
            var longDurations: [Double] = []
            for video in videos {
                guard !Task.isCancelled else { return }
                if let duration = await VideoTransformer.duration(for: video.url),
                   duration > VideoTransformer.longVideoWarningDuration {
                    longDurations.append(duration)
                }
            }
            guard !Task.isCancelled else { return }
            if let longestDuration = longDurations.max() {
                pendingLongVideoTransform = PendingLongVideoTransform(
                    operation: operation,
                    itemIDs: itemIDs,
                    longVideoCount: longDurations.count,
                    longestDuration: longestDuration
                )
            } else {
                startMediaTransform(operation, itemIDs: itemIDs)
            }
        }
    }

    private func startMediaTransform(
        _ operation: MediaTransformOperation,
        itemIDs: Set<FileItem.ID>
    ) {
        let items = selectedItems.filter { itemIDs.contains($0.id) }
        transformActivityID = appState.transformPreviewMedia(items, operation: operation)
    }

    private func transformProgress(_ activity: FileActivity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(activity.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(activity.progressDetail ?? "Processing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    appState.cancelActivity(activity.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Cancel transformation")
            }
            ProgressView(value: activity.progress)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func rateSelection(_ rating: Int) {
        appState.rateSelection(rating)
    }

    @ViewBuilder
    private var content: some View {
        if selectedItems.count == 1, let item = selectedItems.first {
            singlePreview(for: item)
        } else if !previewItems.isEmpty {
            multiPreviewContent
        } else if let item = selectedItems.first {
            GenericItemPreview(item: item)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.right",
                description: Text("Select a file to preview it here.")
            )
        }
    }

    @ViewBuilder
    private func singlePreview(for item: FileItem) -> some View {
        if item.isDirectory {
            FolderPreview(item: item)
        } else if item.isZipArchive {
            ZipArchivePreview(item: item)
        } else if item.isImage || item.isPlayableMedia {
            SingleMediaPreview(
                item: item,
                sizeScale: previewMediaSizeScale,
                showsVideoControls: showsVideoControls
            )
        } else if item.isText {
            TextFilePreview(item: item)
        } else if item.isRichDocument {
            // Quick Look renders PDFs, RTF, and Office docs natively.
            QuickLookPreview(url: item.url)
        } else {
            GenericItemPreview(item: item)
        }
    }

    @ViewBuilder
    private var multiPreviewContent: some View {
        ScrollView {
            switch layoutMode {
            case .rows:
                LazyVStack(spacing: 10) {
                    ForEach(previewItems) { item in
                        MediaPreviewTile(
                            item: item,
                            style: .row,
                            mutePlayer: true,
                            sizeScale: previewMediaSizeScale
                        )
                    }
                }
                .padding(10)
            case .gallery:
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(
                                minimum: PreviewTileStyle.galleryTileWidth * CGFloat(previewMediaSizeScale),
                                maximum: PreviewTileStyle.galleryTileWidth * CGFloat(previewMediaSizeScale)
                            ),
                            spacing: 5,
                            alignment: .topLeading
                        )
                    ],
                    alignment: .leading,
                    spacing: 5
                ) {
                    ForEach(previewItems) { item in
                        MediaPreviewTile(
                            item: item,
                            style: .gallery,
                            mutePlayer: true,
                            sizeScale: previewMediaSizeScale
                        )
                    }
                }
                .padding(5)
            }
        }
    }
}

private struct SingleMediaPreview: View {
    let item: FileItem
    let sizeScale: Double
    let showsVideoControls: Bool

    var body: some View {
        if item.isVideoMedia {
            SingleVideoPreview(
                item: item,
                sizeScale: sizeScale,
                showsControls: showsVideoControls
            )
        } else {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 10) {
                        if item.isAudioMedia {
                            AudioPreviewCard(item: item)
                        } else {
                            MediaPreviewTile(
                                item: item,
                                style: .full,
                                mutePlayer: false,
                                sizeScale: sizeScale
                            )
                            .frame(height: previewHeight(for: geometry.size.height))
                        }
                        MediaMetadataInspector(item: item)
                    }
                    .padding(10)
                }
            }
        }
    }

    private func previewHeight(for availableHeight: CGFloat) -> CGFloat {
        max(min(max(availableHeight * 0.58, 220), 460) * CGFloat(sizeScale), 140)
    }
}

private struct SingleVideoPreview: View {
    let item: FileItem
    let sizeScale: Double
    let showsControls: Bool

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    private var previewKey: String {
        "\(item.id)|\(item.modified.timeIntervalSince1970)"
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                videoSurface
                    .frame(
                        height: videoPreviewHeight(
                            for: geometry.size.height,
                            showsControls: showsControls
                        )
                    )
                    .clipped()
                    .allowsHitTesting(false)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VideoPlaybackControls(player: player)
                    .zIndex(1)

                if showsControls {
                    VideoTimelineTrimView(item: item, player: player)
                        .zIndex(1)

                    ScrollView {
                        MediaMetadataInspector(item: item)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: previewKey) {
            preparePlayer()
        }
        .onDisappear(perform: teardown)
    }

    @ViewBuilder
    private var videoSurface: some View {
        if let player {
            PlayerPreviewView(player: player)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewHeight(for availableHeight: CGFloat) -> CGFloat {
        max(min(max(availableHeight * 0.58, 220), 460) * CGFloat(sizeScale), 140)
    }

    private func videoPreviewHeight(
        for availableHeight: CGFloat,
        showsControls: Bool
    ) -> CGFloat {
        guard showsControls else {
            let reservedForPlaybackControls: CGFloat = 82
            return max(availableHeight - reservedForPlaybackControls, 140)
        }
        let reservedForControls: CGFloat = 300
        let visibleBudget = max(availableHeight - reservedForControls, 100)
        return min(previewHeight(for: availableHeight), visibleBudget)
    }

    @MainActor
    private func preparePlayer() {
        teardown()
        let newPlayer = AVPlayer(url: item.url)
        player = newPlayer
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { _ in
            let loop = UserDefaults.standard.object(forKey: "loopVideos") as? Bool ?? true
            if loop {
                newPlayer.seek(to: .zero)
                newPlayer.play()
            }
        }
        newPlayer.play()
    }

    @MainActor
    private func teardown() {
        player?.pause()
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}

private struct MediaPreviewTile: View {
    let item: FileItem
    let style: PreviewTileStyle
    let mutePlayer: Bool
    let sizeScale: Double
    var onPlayerChange: ((AVPlayer?) -> Void)? = nil

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var previewImage: CGImage?

    private var previewKey: String {
        "\(item.id)|\(item.modified.timeIntervalSince1970)"
    }

    var body: some View {
        VStack(spacing: style.spacing) {
            if style.showsFooter {
                previewBody
                    .frame(maxWidth: .infinity)
                    .frame(height: style.previewHeight * CGFloat(sizeScale))
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                footer
            } else {
                previewBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if item.isImage, let previewImage {
                    Text("\(previewImage.width) × \(previewImage.height)  ·  \(item.sizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
        }
        .padding(style.padding)
        .background(
            style.showsFooter ? Color(nsColor: .textBackgroundColor) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: previewKey) { await loadPreview() }
        .onChange(of: mutePlayer) { _, muted in player?.isMuted = muted }
        .onDisappear { teardown() }
    }

    @ViewBuilder
    private var previewBody: some View {
        if item.isPlayableMedia {
            if let player {
                PlayerPreviewView(player: player)
            } else {
                ProgressView()
            }
        } else if let previewImage {
            Image(decorative: previewImage, scale: 1)
                .resizable()
                .scaledToFit()
                .padding(style.imagePadding)
        } else {
            ProgressView()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(item.sizeText)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @MainActor
    private func loadPreview() async {
        teardown()
        if item.isPlayableMedia {
            let newPlayer = AVPlayer(url: item.url)
            newPlayer.isMuted = mutePlayer
            player = newPlayer
            onPlayerChange?(newPlayer)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: newPlayer.currentItem,
                queue: .main
            ) { _ in
                let loop = UserDefaults.standard.object(forKey: "loopVideos") as? Bool ?? true
                if loop {
                    newPlayer.seek(to: .zero)
                    newPlayer.play()
                }
            }
            newPlayer.play()
        } else if item.isImage {
            let url = item.url
            let decoded = await ImageProcessing.downsampled(
                url: url, maxPixel: style.downsamplePixelSize
            )
            if !Task.isCancelled && item.url == url {
                previewImage = decoded
            }
        }
    }

    @MainActor
    private func teardown() {
        player?.pause()
        player = nil
        onPlayerChange?(nil)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        previewImage = nil
    }
}

private struct VideoPlaybackControls: View {
    let player: AVPlayer?

    @State private var observedPlayer: AVPlayer?
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var resumesAfterScrubbing = false
    @State private var timeObserver: Any?

    private var playerID: ObjectIdentifier? {
        player.map(ObjectIdentifier.init)
    }

    private var progressBinding: Binding<Double> {
        Binding {
            currentTime
        } set: { value in
            let clampedValue = min(max(value, 0), duration)
            currentTime = clampedValue
            seekPrecisely(to: clampedValue)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(player == nil)
            .help(isPlaying ? "Pause" : "Play")

            VStack(spacing: 4) {
                Slider(
                    value: progressBinding,
                    in: 0...max(duration, 0.1),
                    onEditingChanged: handleScrubbing
                )
                    .disabled(player == nil || duration <= 0)
                HStack {
                    Text(VideoTrimmer.preciseTimeText(currentTime))
                    Spacer()
                    Text(VideoTrimmer.preciseTimeText(duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: playerID) {
            await observePlayer()
        }
        .onDisappear(perform: stopObserving)
    }

    @MainActor
    private func observePlayer() async {
        stopObserving()
        guard let activePlayer = player else { return }

        observedPlayer = activePlayer
        currentTime = max(CMTimeGetSeconds(activePlayer.currentTime()), 0)
        isPlaying = activePlayer.timeControlStatus != .paused
        timeObserver = activePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = max(CMTimeGetSeconds(time), 0)
            Task { @MainActor in
                if !isScrubbing {
                    currentTime = seconds.isFinite ? seconds : 0
                }
                isPlaying = activePlayer.timeControlStatus != .paused
            }
        }

        if let loadedDuration = try? await activePlayer.currentItem?.asset.load(.duration) {
            guard !Task.isCancelled, player === activePlayer else { return }
            let seconds = CMTimeGetSeconds(loadedDuration)
            duration = seconds.isFinite ? seconds : 0
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    private func handleScrubbing(_ editing: Bool) {
        guard let player else { return }

        if editing {
            resumesAfterScrubbing = player.timeControlStatus != .paused
            isScrubbing = true
            player.pause()
            isPlaying = false
        } else {
            seekPrecisely(to: currentTime)
            isScrubbing = false
            if resumesAfterScrubbing {
                player.play()
                isPlaying = true
            }
            resumesAfterScrubbing = false
        }
    }

    private func seekPrecisely(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 60_000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func stopObserving() {
        if let timeObserver {
            observedPlayer?.removeTimeObserver(timeObserver)
        }
        observedPlayer = nil
        timeObserver = nil
        duration = 0
        currentTime = 0
        isPlaying = false
        isScrubbing = false
        resumesAfterScrubbing = false
    }
}

private struct VideoFilmstripThumbnail: Identifiable {
    let id: Int
    let time: Double
    var image: CGImage?
}

private enum VideoScreenshotIntervalUnit: String, CaseIterable, Identifiable {
    case milliseconds
    case seconds
    case minutes

    var id: Self { self }

    var title: String {
        switch self {
        case .milliseconds: "Ms"
        case .seconds: "Secs"
        case .minutes: "Mins"
        }
    }

    var multiplier: Double {
        switch self {
        case .milliseconds: 0.001
        case .seconds: 1
        case .minutes: 60
        }
    }
}

private struct VideoScreenshotIntervalPreset: Identifiable {
    let value: Int
    let unit: VideoScreenshotIntervalUnit

    var id: String { "\(value)-\(unit.rawValue)" }
    var title: String { "\(value) \(unit.title)" }
}

private struct VideoTimelineTrimView: View {
    @Environment(AppState.self) private var appState
    let item: FileItem
    let player: AVPlayer?

    @State private var thumbnails: [VideoFilmstripThumbnail] = []
    @State private var duration: Double = 0
    @State private var inTime: Double = 0
    @State private var outTime: Double = 0
    @State private var isLoadingDuration = true
    @State private var activeHandle: TrimHandle?
    @State private var removeAudio = false
    @State private var showsIntervalCapture = false
    @State private var screenshotIntervalText = "100"
    @State private var screenshotIntervalUnit: VideoScreenshotIntervalUnit = .milliseconds
    @State private var hasAudioTrack = false

    private let thumbnailHeight: CGFloat = 66
    private let thumbnailSpacing: CGFloat = 2
    private let handleWidth: CGFloat = 14
    private let screenshotIntervalPresets = [
        VideoScreenshotIntervalPreset(value: 100, unit: .milliseconds),
        VideoScreenshotIntervalPreset(value: 250, unit: .milliseconds),
        VideoScreenshotIntervalPreset(value: 500, unit: .milliseconds),
        VideoScreenshotIntervalPreset(value: 1, unit: .seconds),
        VideoScreenshotIntervalPreset(value: 5, unit: .seconds),
        VideoScreenshotIntervalPreset(value: 10, unit: .seconds),
        VideoScreenshotIntervalPreset(value: 30, unit: .seconds),
        VideoScreenshotIntervalPreset(value: 1, unit: .minutes),
    ]

    private enum TrimHandle: Equatable {
        case leading
        case trailing
    }

    private var loadKey: String {
        "\(item.id)|\(item.modified.timeIntervalSince1970)"
    }

    private var trimDuration: Double {
        max(outTime - inTime, 0)
    }

    private var isValid: Bool {
        duration > 0 && trimDuration >= 0.1
    }

    private var screenshotIntervalValue: Double {
        Double(screenshotIntervalText) ?? 0
    }

    private var screenshotIntervalSeconds: Double {
        screenshotIntervalValue * screenshotIntervalUnit.multiplier
    }

    private var screenshotCount: Int {
        VideoIntervalFrameCapture.frameCount(
            duration: duration,
            interval: screenshotIntervalSeconds
        )
    }

    private var canCaptureAtInterval: Bool {
        screenshotIntervalSeconds >= VideoIntervalFrameCapture.minimumInterval
            && screenshotCount > 0
            && screenshotCount <= VideoIntervalFrameCapture.maximumFrameCount
    }

    var body: some View {
        VStack(spacing: 7) {
            trimToolbar

            GeometryReader { geometry in
                let thumbnailCount = preferredThumbnailCount(for: geometry.size.width)

                timeline(width: geometry.size.width, thumbnailCount: thumbnailCount)
                    .task(id: "\(loadKey)|\(thumbnailCount)") {
                        await loadThumbnails(count: thumbnailCount)
                    }
                    .overlay {
                        if isLoadingDuration {
                            ProgressView()
                                .controlSize(.small)
                                .padding(7)
                                .background(.regularMaterial, in: Circle())
                        }
                    }
            }
            .frame(height: thumbnailHeight)

            HStack {
                Text("In \(VideoTrimmer.preciseTimeText(inTime))")
                Spacer()
                Text("Selected \(VideoTrimmer.preciseTimeText(trimDuration))")
                Spacer()
                Text("Out \(VideoTrimmer.preciseTimeText(outTime))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: loadKey) {
            await loadDuration()
        }
    }

    private var trimToolbar: some View {
        HStack(spacing: 7) {
            Label("Trim", systemImage: "timeline.selection")
                .font(.caption.weight(.semibold))

            Spacer()

            NativePreviewToolbarButton(
                systemImage: "arrow.left.to.line",
                accessibilityLabel: "Set In Point",
                help: "Set trim start to the current playback position",
                isEnabled: player != nil && duration > 0
            ) {
                markIn()
            }
            .frame(width: 42, height: 22)

            NativePreviewToolbarButton(
                systemImage: "arrow.right.to.line",
                accessibilityLabel: "Set Out Point",
                help: "Set trim end to the current playback position",
                isEnabled: player != nil && duration > 0
            ) {
                markOut()
            }
            .frame(width: 42, height: 22)

            NativePreviewToolbarButton(
                systemImage: "camera",
                accessibilityLabel: "Capture Frame",
                help: "Save the current video frame as a PNG beside the video",
                isEnabled: player != nil
            ) {
                captureCurrentFrame()
            }
            .frame(width: 44, height: 22)

            NativePreviewToolbarButton(
                systemImage: "camera.on.rectangle",
                accessibilityLabel: "Capture Screenshots at an Interval",
                help: "Capture screenshots from the full video at a chosen interval",
                isEnabled: duration > 0
            ) {
                showsIntervalCapture.toggle()
            }
            .frame(width: 45, height: 22)
            .popover(isPresented: $showsIntervalCapture, arrowEdge: .bottom) {
                intervalCapturePopover
            }

            NativePreviewToolbarButton(
                title: "Remove Audio",
                systemImage: removeAudio ? "speaker.slash.fill" : "speaker.slash",
                accessibilityLabel: "Remove Audio",
                help: "Keep the audio track and set its volume to zero",
                isEnabled: hasAudioTrack,
                isToggle: true,
                isOn: removeAudio
            ) { newValue in
                removeAudio = newValue
            }

            NativePreviewToolbarButton(
                title: "Export Audio",
                systemImage: "waveform",
                accessibilityLabel: "Export Audio",
                help: hasAudioTrack
                    ? "Export the selected range as an audio-only M4A file"
                    : "This video has no audio track",
                isEnabled: isValid && hasAudioTrack
            ) {
                appState.exportVideoAudio(item, inTime: inTime, outTime: outTime)
            }

            NativePreviewToolbarButton(
                title: "Export",
                systemImage: "square.and.arrow.down",
                accessibilityLabel: "Export Video",
                help: removeAudio
                    ? "Export the selected range with a silent audio track"
                    : "Export the selected range without re-encoding",
                isEnabled: isValid
            ) {
                appState.exportVideoTrim(
                    item,
                    inTime: inTime,
                    outTime: outTime,
                    muteAudio: removeAudio
                )
            }
        }
        .font(.caption)
        .onChange(of: removeAudio) { _, shouldMute in
            player?.volume = shouldMute ? 0 : 1
        }
    }

    private var intervalCapturePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Interval Screenshots", systemImage: "camera.on.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    showsIntervalCapture = false
                } label: {
                    Image(systemName: "xmark")
                        .accessibilityLabel("Close")
                }
                .buttonStyle(.plain)
            }

            Text(
                "Capture the full video into a new folder beside the source. "
                    + "The folder will include a copy of the original video."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Interval", text: $screenshotIntervalText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(width: 72)
                .accessibilityLabel("Screenshot interval")
                .onChange(of: screenshotIntervalText) { _, newValue in
                    let sanitized = String(
                        newValue.filter { "0123456789".contains($0) }.prefix(3)
                    )
                    if sanitized != newValue {
                        screenshotIntervalText = sanitized
                    }
                }

                Picker("Unit", selection: $screenshotIntervalUnit) {
                    ForEach(VideoScreenshotIntervalUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Presets")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 66), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(screenshotIntervalPresets) { preset in
                        Button(preset.title) {
                            screenshotIntervalText = String(preset.value)
                            screenshotIntervalUnit = preset.unit
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            intervalCaptureSummary

            Divider()

            HStack {
                Text("PNG screenshots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    captureFramesAtInterval()
                } label: {
                    Label("Create Folder", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCaptureAtInterval)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private var intervalCaptureSummary: some View {
        if screenshotIntervalSeconds < VideoIntervalFrameCapture.minimumInterval {
            Label(
                "Use an interval of at least 100 milliseconds.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        } else if screenshotCount > VideoIntervalFrameCapture.maximumFrameCount {
            Label(
                "This would create \(screenshotCount.formatted()) screenshots. "
                    + "The limit is \(VideoIntervalFrameCapture.maximumFrameCount.formatted()).",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        } else {
            Label(
                "\(screenshotCount.formatted()) "
                    + "\(screenshotCount == 1 ? "screenshot" : "screenshots")",
                systemImage: "photo.stack"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func captureFramesAtInterval() {
        guard canCaptureAtInterval else { return }
        showsIntervalCapture = false
        appState.captureVideoFrames(item, every: screenshotIntervalSeconds)
    }

    private func timeline(width: CGFloat, thumbnailCount: Int) -> some View {
        let safeWidth = max(width, 1)
        let leadingX = position(for: inTime, width: safeWidth)
        let trailingX = position(for: outTime, width: safeWidth)

        return ZStack {
            filmstrip(width: safeWidth, thumbnailCount: thumbnailCount)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            Color.black.opacity(0.5)
                .frame(width: leadingX, height: thumbnailHeight)
                .position(x: leadingX / 2, y: thumbnailHeight / 2)
                .allowsHitTesting(false)

            Color.black.opacity(0.5)
                .frame(width: max(safeWidth - trailingX, 0), height: thumbnailHeight)
                .position(
                    x: trailingX + max(safeWidth - trailingX, 0) / 2,
                    y: thumbnailHeight / 2
                )
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(
                    width: max(trailingX - leadingX, 1),
                    height: thumbnailHeight - 2
                )
                .position(
                    x: leadingX + max(trailingX - leadingX, 1) / 2,
                    y: thumbnailHeight / 2
                )
                .allowsHitTesting(false)

            trimHandle(.leading, at: leadingX, timelineWidth: safeWidth)
            trimHandle(.trailing, at: trailingX, timelineWidth: safeWidth)
        }
        .frame(width: safeWidth, height: thumbnailHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: loadKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video trimming timeline")
    }

    private func filmstrip(width: CGFloat, thumbnailCount: Int) -> some View {
        let availableWidth = max(
            width - (CGFloat(thumbnailCount - 1) * thumbnailSpacing),
            1
        )
        let thumbnailWidth = availableWidth / CGFloat(thumbnailCount)

        return HStack(spacing: thumbnailSpacing) {
            ForEach(0..<thumbnailCount, id: \.self) { index in
                thumbnailCell(at: index)
                    .frame(width: thumbnailWidth, height: thumbnailHeight)
            }
        }
    }

    private func trimHandle(
        _ handle: TrimHandle,
        at position: CGFloat,
        timelineWidth: CGFloat
    ) -> some View {
        let handlePosition = min(
            max(position, handleWidth / 2),
            max(timelineWidth - handleWidth / 2, handleWidth / 2)
        )
        let time = handle == .leading ? inTime : outTime
        let title = handle == .leading ? "Trim Start" : "Trim End"

        return ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor)
                .frame(width: handleWidth, height: thumbnailHeight)
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: 22)
        }
        .frame(width: 24, height: thumbnailHeight)
        .contentShape(Rectangle())
        .scaleEffect(activeHandle == handle ? 1.04 : 1)
        .position(x: handlePosition, y: thumbnailHeight / 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(loadKey))
                .onChanged { value in
                    activeHandle = handle
                    update(handle, locationX: value.location.x, timelineWidth: timelineWidth)
                }
                .onEnded { _ in
                    activeHandle = nil
                }
        )
        .accessibilityLabel(title)
        .accessibilityValue(VideoTrimmer.preciseTimeText(time))
        .help("Drag to adjust \(title.lowercased())")
    }

    @ViewBuilder
    private func thumbnailCell(at index: Int) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))

            if thumbnails.indices.contains(index), let image = thumbnails[index].image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
    }

    private func preferredThumbnailCount(for width: CGFloat) -> Int {
        min(max(Int(width / 84), 4), 12)
    }

    private func position(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return time <= 0 ? 0 : width }
        return width * CGFloat(min(max(time / duration, 0), 1))
    }

    private func update(
        _ handle: TrimHandle,
        locationX: CGFloat,
        timelineWidth: CGFloat
    ) {
        guard duration > 0, timelineWidth > 0 else { return }
        player?.pause()
        let requestedTime = VideoFilmstrip.time(
            at: Double(locationX),
            width: Double(timelineWidth),
            duration: duration
        )

        let selectedTime: Double
        switch handle {
        case .leading:
            inTime = VideoFilmstrip.clampedInTime(
                requestedTime,
                outTime: outTime,
                duration: duration
            )
            selectedTime = inTime
        case .trailing:
            outTime = VideoFilmstrip.clampedOutTime(
                requestedTime,
                inTime: inTime,
                duration: duration
            )
            selectedTime = outTime
        }
        seekPlayer(to: selectedTime)
    }

    private func markIn() {
        guard let seconds = currentPlayerSeconds() else { return }
        inTime = VideoFilmstrip.clampedInTime(
            seconds,
            outTime: outTime,
            duration: duration
        )
    }

    private func markOut() {
        guard let seconds = currentPlayerSeconds() else { return }
        outTime = VideoFilmstrip.clampedOutTime(
            seconds,
            inTime: inTime,
            duration: duration
        )
    }

    private func captureCurrentFrame() {
        guard let seconds = currentPlayerSeconds() else { return }
        appState.captureVideoFrame(item, at: seconds)
    }

    private func currentPlayerSeconds() -> Double? {
        guard let player else { return nil }
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : nil
    }

    private func seekPlayer(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 60_000)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @MainActor
    private func loadDuration() async {
        isLoadingDuration = true
        async let durationResult = VideoTrimmer.duration(for: item.url)
        async let hasAudioResult = AudioRangeExporter.hasAudioTrack(in: item.url)
        let (loadedDuration, loadedHasAudioTrack) = await (
            durationResult ?? 0,
            hasAudioResult
        )
        guard !Task.isCancelled else { return }
        duration = loadedDuration
        hasAudioTrack = loadedHasAudioTrack
        inTime = 0
        outTime = loadedDuration
        removeAudio = false
        player?.volume = 1
        isLoadingDuration = false
    }

    @MainActor
    private func loadThumbnails(count: Int) async {
        let asset = AVURLAsset(url: item.url)
        guard let loadedDuration = try? await asset.load(.duration) else {
            thumbnails = []
            return
        }

        let duration = CMTimeGetSeconds(loadedDuration)
        let sampleTimes = VideoFilmstrip.sampleTimes(duration: duration, count: count)
        guard !sampleTimes.isEmpty else {
            thumbnails = []
            return
        }

        thumbnails = sampleTimes.enumerated().map {
            VideoFilmstripThumbnail(id: $0.offset, time: $0.element, image: nil)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let toleranceSeconds = max(min(duration / Double(count * 4), 0.25), 1.0 / 60.0)
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        for (index, seconds) in sampleTimes.enumerated() {
            guard !Task.isCancelled else {
                generator.cancelAllCGImageGeneration()
                return
            }

            let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let result = try? await generator.image(at: requestedTime) else {
                continue
            }
            guard !Task.isCancelled, thumbnails.indices.contains(index) else {
                generator.cancelAllCGImageGeneration()
                return
            }
            thumbnails[index].image = result.image
        }
    }
}

private struct AudioPreviewCard: View {
    @Environment(AppState.self) private var appState
    let item: FileItem

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var endObserver: NSObjectProtocol?
    @State private var timeObserver: Any?
    @State private var waveformSamples: [Float] = []
    @State private var isLoadingWaveform = false
    @State private var waveformError: String?
    @State private var inTime: Double = 0
    @State private var outTime: Double = 0
    @State private var activeHandle: TrimHandle?

    private let waveformHeight: CGFloat = 76
    private let handleWidth: CGFloat = 14

    private enum TrimHandle: Equatable {
        case leading
        case trailing
    }

    private var loadKey: String {
        "\(item.id)|\(item.modified.timeIntervalSince1970)"
    }

    private var waveformCoordinateSpace: String {
        "audio-waveform-\(item.id)"
    }

    private var trimDuration: Double {
        max(outTime - inTime, 0)
    }

    private var hasValidTrim: Bool {
        duration > 0 && trimDuration >= 0.1
    }

    private var progressBinding: Binding<Double> {
        Binding {
            currentTime
        } set: { value in
            let clampedValue = min(max(value, 0), duration)
            currentTime = clampedValue
            seekPlayer(to: clampedValue)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 108, height: 108)

            VStack(spacing: 5) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                Text("\(item.kind) · \(item.sizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            playbackControls
            trimEditor
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: loadKey) {
            await preparePlayer()
            await loadWaveform()
        }
        .onDisappear(perform: teardown)
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .buttonStyle(.plain)
            .disabled(player == nil || duration <= 0)
            .help(isPlaying ? "Pause" : "Play selected range")

            VStack(spacing: 6) {
                Slider(value: progressBinding, in: 0...max(duration, 0.1))
                    .disabled(duration <= 0)
                HStack {
                    Text(timeText(currentTime))
                    Spacer()
                    Text(timeText(duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var trimEditor: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Label("Trim", systemImage: "timeline.selection")
                    .font(.caption.weight(.semibold))

                Spacer()

                Button {
                    markIn()
                } label: {
                    Image(systemName: "arrow.left.to.line")
                        .accessibilityLabel("Set In Point")
                }
                .disabled(player == nil || duration <= 0)
                .help("Set trim start to the current playback position")

                Button {
                    markOut()
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .accessibilityLabel("Set Out Point")
                }
                .disabled(player == nil || duration <= 0)
                .help("Set trim end to the current playback position")

                Button {
                    appState.exportAudioTrim(item, inTime: inTime, outTime: outTime)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(!hasValidTrim)
                .help("Save the selected range as a new M4A file beside the original")
            }
            .font(.caption)

            GeometryReader { geometry in
                waveformTimeline(width: geometry.size.width)
                    .overlay {
                        if isLoadingWaveform {
                            ProgressView()
                                .controlSize(.small)
                                .padding(7)
                                .background(.regularMaterial, in: Circle())
                        } else if waveformSamples.isEmpty {
                            Image(systemName: waveformError == nil ? "waveform" : "waveform.slash")
                                .foregroundStyle(.tertiary)
                                .help(waveformError ?? "No waveform data")
                        }
                    }
            }
            .frame(height: waveformHeight)

            HStack {
                Text("In \(VideoTrimmer.preciseTimeText(inTime))")
                Spacer()
                Text("Selected \(VideoTrimmer.preciseTimeText(trimDuration))")
                Spacer()
                Text("Out \(VideoTrimmer.preciseTimeText(outTime))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func waveformTimeline(width: CGFloat) -> some View {
        let safeWidth = max(width, 1)
        let leadingX = position(for: inTime, width: safeWidth)
        let trailingX = position(for: outTime, width: safeWidth)
        let playheadX = position(for: currentTime, width: safeWidth)

        return ZStack {
            waveformCanvas

            Color.black.opacity(0.38)
                .frame(width: leadingX, height: waveformHeight)
                .position(x: leadingX / 2, y: waveformHeight / 2)
                .allowsHitTesting(false)

            Color.black.opacity(0.38)
                .frame(width: max(safeWidth - trailingX, 0), height: waveformHeight)
                .position(
                    x: trailingX + max(safeWidth - trailingX, 0) / 2,
                    y: waveformHeight / 2
                )
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(
                    width: max(trailingX - leadingX, 1),
                    height: waveformHeight - 2
                )
                .position(
                    x: leadingX + max(trailingX - leadingX, 1) / 2,
                    y: waveformHeight / 2
                )
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.primary.opacity(0.75))
                .frame(width: 1, height: waveformHeight - 8)
                .position(x: playheadX, y: waveformHeight / 2)
                .allowsHitTesting(false)

            trimHandle(.leading, at: leadingX, timelineWidth: safeWidth)
            trimHandle(.trailing, at: trailingX, timelineWidth: safeWidth)
        }
        .frame(width: safeWidth, height: waveformHeight)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: waveformCoordinateSpace)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio waveform trimming timeline")
    }

    private var waveformCanvas: some View {
        Canvas { context, size in
            guard !waveformSamples.isEmpty else { return }
            let slotWidth = size.width / CGFloat(waveformSamples.count)
            let barWidth = max(min(slotWidth * 0.62, 3), 1)
            let availableHeight = max(size.height - 12, 1)

            for (index, sample) in waveformSamples.enumerated() {
                let normalized = CGFloat(min(max(sample, 0), 1))
                let barHeight = max(normalized * availableHeight, 2)
                let rect = CGRect(
                    x: (CGFloat(index) + 0.5) * slotWidth - barWidth / 2,
                    y: (size.height - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(Color.accentColor.opacity(0.82))
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func trimHandle(
        _ handle: TrimHandle,
        at position: CGFloat,
        timelineWidth: CGFloat
    ) -> some View {
        let handlePosition = min(
            max(position, handleWidth / 2),
            max(timelineWidth - handleWidth / 2, handleWidth / 2)
        )
        let time = handle == .leading ? inTime : outTime
        let title = handle == .leading ? "Trim Start" : "Trim End"

        return ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor)
                .frame(width: handleWidth, height: waveformHeight)
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: 24)
        }
        .frame(width: 24, height: waveformHeight)
        .contentShape(Rectangle())
        .scaleEffect(activeHandle == handle ? 1.04 : 1)
        .position(x: handlePosition, y: waveformHeight / 2)
        .gesture(
            DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(waveformCoordinateSpace)
            )
            .onChanged { value in
                activeHandle = handle
                update(handle, locationX: value.location.x, timelineWidth: timelineWidth)
            }
            .onEnded { _ in
                activeHandle = nil
            }
        )
        .accessibilityLabel(title)
        .accessibilityValue(VideoTrimmer.preciseTimeText(time))
        .help("Drag to adjust \(title.lowercased())")
    }

    private func position(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return time <= 0 ? 0 : width }
        return width * CGFloat(min(max(time / duration, 0), 1))
    }

    private func update(
        _ handle: TrimHandle,
        locationX: CGFloat,
        timelineWidth: CGFloat
    ) {
        guard duration > 0, timelineWidth > 0 else { return }
        pausePlayback()
        let requestedTime = VideoFilmstrip.time(
            at: Double(locationX),
            width: Double(timelineWidth),
            duration: duration
        )

        let selectedTime: Double
        switch handle {
        case .leading:
            inTime = VideoFilmstrip.clampedInTime(
                requestedTime,
                outTime: outTime,
                duration: duration
            )
            selectedTime = inTime
        case .trailing:
            outTime = VideoFilmstrip.clampedOutTime(
                requestedTime,
                inTime: inTime,
                duration: duration
            )
            selectedTime = outTime
        }
        currentTime = selectedTime
        seekPlayer(to: selectedTime)
    }

    private func markIn() {
        inTime = VideoFilmstrip.clampedInTime(
            currentTime,
            outTime: outTime,
            duration: duration
        )
    }

    private func markOut() {
        outTime = VideoFilmstrip.clampedOutTime(
            currentTime,
            inTime: inTime,
            duration: duration
        )
    }

    @MainActor
    private func preparePlayer() async {
        teardown()
        let newPlayer = AVPlayer(url: item.url)
        player = newPlayer
        if let loadedDuration = try? await newPlayer.currentItem?.asset.load(.duration) {
            let seconds = CMTimeGetSeconds(loadedDuration)
            duration = seconds.isFinite ? seconds : 0
        }
        inTime = 0
        outTime = duration
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = max(CMTimeGetSeconds(time), 0)
            Task { @MainActor in
                if isPlaying, outTime > inTime, seconds >= outTime {
                    newPlayer.pause()
                    isPlaying = false
                    currentTime = outTime
                } else {
                    currentTime = min(seconds, duration)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                isPlaying = false
                currentTime = outTime
            }
        }
    }

    @MainActor
    private func loadWaveform() async {
        isLoadingWaveform = true
        waveformError = nil
        waveformSamples = []
        do {
            let samples = try await AudioWaveform.samples(for: item.url, count: 280)
            guard !Task.isCancelled else { return }
            waveformSamples = samples
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            waveformError = error.localizedDescription
        }
        isLoadingWaveform = false
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            pausePlayback()
        } else {
            if currentTime < inTime || currentTime >= outTime - 0.01 {
                currentTime = inTime
                seekPlayer(to: inTime)
            }
            player.play()
            isPlaying = true
        }
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
    }

    private func seekPlayer(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 60_000)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func teardown() {
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player = nil
        timeObserver = nil
        endObserver = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        inTime = 0
        outTime = 0
        activeHandle = nil
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private enum PreviewLayoutMode: String, CaseIterable, Identifiable {
    case rows
    case gallery

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .rows: "rectangle.split.1x2"
        case .gallery: "square.grid.2x2"
        }
    }

    var title: String {
        switch self {
        case .rows: "One per row"
        case .gallery: "Gallery"
        }
    }
}

private enum PreviewTileStyle {
    case full
    case row
    case gallery

    static let galleryTileWidth: CGFloat = 112

    var showsFooter: Bool {
        switch self {
        case .full: false
        case .row, .gallery: true
        }
    }

    var spacing: CGFloat {
        switch self {
        case .full: 0
        case .row: 6
        case .gallery: 3
        }
    }

    var padding: CGFloat {
        switch self {
        case .full: 0
        case .row: 8
        case .gallery: 0
        }
    }

    var previewHeight: CGFloat {
        switch self {
        case .full: 0
        case .row: 180
        case .gallery: 72
        }
    }

    var imagePadding: CGFloat {
        switch self {
        case .full: 8
        case .row: 6
        case .gallery: 0
        }
    }

    var downsamplePixelSize: Int {
        switch self {
        case .full: 2048
        case .row: 1024
        case .gallery: 720
        }
    }
}

private struct ZipArchivePreview: View {
    @Environment(AppState.self) private var appState
    let item: FileItem

    @State private var listing: ZipArchiveListing?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isExtracting = false
    @State private var searchText = ""
    @State private var selectedEntryID: ZipArchiveEntry.ID?

    private var previewKey: String {
        "\(item.id)|\(item.modified.timeIntervalSince1970)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let listing {
                let visibleEntries = filteredEntries(in: listing)
                archiveSummary(listing, visibleEntries: visibleEntries)
                Divider()
                if listing.entries.isEmpty {
                    ContentUnavailableView("Empty ZIP Archive", systemImage: "archivebox")
                } else if visibleEntries.isEmpty {
                    ContentUnavailableView.search
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleEntries) { entry in
                                ZipEntryRow(
                                    entry: entry,
                                    isSelected: selectedEntryID == entry.id
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedEntryID = entry.id
                                }
                                Divider()
                            }
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Can’t Preview ZIP",
                    systemImage: "archivebox",
                    description: Text(errorMessage)
                )
            } else if isLoading {
                ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: previewKey) { await loadListing() }
    }

    private func archiveSummary(
        _ listing: ZipArchiveListing,
        visibleEntries: [ZipArchiveEntry]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Label("\(listing.fileCount)", systemImage: "doc")
                if listing.folderCount > 0 {
                    Label("\(listing.folderCount)", systemImage: "folder")
                }
                Text(totalSizeText(for: listing))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Search ZIP", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    extractSelectedEntry(from: visibleEntries)
                } label: {
                    if isExtracting {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Label("Extract", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(selectedFile(in: visibleEntries) == nil || isExtracting)
                .help("Extract selected file")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func filteredEntries(in listing: ZipArchiveListing) -> [ZipArchiveEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return listing.entries }
        return listing.entries.filter { entry in
            entry.path.localizedCaseInsensitiveContains(query)
        }
    }

    private func selectedFile(in entries: [ZipArchiveEntry]) -> ZipArchiveEntry? {
        entries.first { $0.id == selectedEntryID && !$0.isDirectory }
    }

    private func totalSizeText(for listing: ZipArchiveListing) -> String {
        let capped = min(listing.uncompressedSize, UInt64(Int64.max))
        return ByteCountFormatter.string(fromByteCount: Int64(capped), countStyle: .file)
    }

    @MainActor
    private func loadListing() async {
        isLoading = true
        listing = nil
        errorMessage = nil
        do {
            let loaded = try await ZipArchiveListingReader.listing(for: item.url)
            if !Task.isCancelled {
                listing = loaded
                selectedEntryID = nil
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        if !Task.isCancelled {
            isLoading = false
        }
    }

    private func extractSelectedEntry(from entries: [ZipArchiveEntry]) {
        guard let entry = selectedFile(in: entries) else { return }
        isExtracting = true
        Task {
            do {
                try await FileOperations.extractZipEntry(item.url, entryPath: entry.path)
                await MainActor.run {
                    appState.panes.forEach { $0.refresh() }
                    isExtracting = false
                }
            } catch {
                await MainActor.run {
                    appState.lastError = error.localizedDescription
                    isExtracting = false
                }
            }
        }
    }
}

private struct ZipEntryRow: View {
    let entry: ZipArchiveEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let parentPath = entry.parentPath {
                    Text(parentPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if !entry.isDirectory {
                Text(entry.uncompressedSizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
    }
}

/// Folders used to fall back to `GenericItemPreview`, which showed a bare folder
/// icon and told you nothing about the contents. Shows a thumbnail grid of what's
/// inside instead; double-clicking an entry opens it.
private struct FolderPreview: View {
    let item: FileItem

    @Environment(AppState.self) private var appState
    @State private var entries: [FileItem]?

    private let tileSide: CGFloat = 84

    var body: some View {
        Group {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Empty Folder",
                        systemImage: "folder",
                        description: Text("“\(item.name)” has no items.")
                    )
                } else {
                    contents(entries)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: "\(item.id)|\(item.modified.timeIntervalSince1970)|\(appState.showHidden)") {
            entries = nil
            entries = await Self.loadEntries(in: item.url, showHidden: appState.showHidden)
        }
    }

    private func contents(_ entries: [FileItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(summary(entries))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: tileSide + 12, maximum: tileSide + 12),
                        spacing: 8,
                        alignment: .top
                    )],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(entries) { entry in
                        FolderEntryTile(entry: entry, side: tileSide)
                            .onTapGesture(count: 2) { open(entry) }
                            .help(entry.name)
                    }
                }
                .padding(8)
            }
        }
    }

    private func summary(_ entries: [FileItem]) -> String {
        let folders = entries.filter(\.isDirectory).count
        let files = entries.count - folders
        let total = "\(entries.count) item\(entries.count == 1 ? "" : "s")"
        switch (folders, files) {
        case (0, _): return total
        case (_, 0): return "\(total) · \(folders) folder\(folders == 1 ? "" : "s")"
        default:
            return "\(total) · \(folders) folder\(folders == 1 ? "" : "s"), "
                + "\(files) file\(files == 1 ? "" : "s")"
        }
    }

    private func open(_ entry: FileItem) {
        if entry.isDirectory {
            appState.activePane.navigate(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    /// Folders can hold thousands of entries, so the directory read stays off the
    /// main actor — `FileItem` is `Sendable`, so the result crosses back safely.
    private static func loadEntries(in folder: URL, showHidden: Bool) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            ) else {
                return []
            }
            var items = urls.map(FileItem.make)
            if !showHidden {
                items = items.filter { !$0.isHidden }
            }
            return items.sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }.value
    }
}

private struct FolderEntryTile: View {
    let entry: FileItem
    let side: CGFloat

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(nsImage: entry.icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * 0.55, height: side * 0.55)
                }
            }
            .frame(width: side, height: side)
            Text(entry.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: side + 12)
        .contentShape(Rectangle())
        .task(id: "\(entry.id)|\(entry.modified.timeIntervalSince1970)") {
            thumbnail = await ThumbnailLoader.thumbnail(for: entry, pixelSize: 256)
        }
    }
}

private struct GenericItemPreview: View {
    let item: FileItem

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 72, height: 72)
            Text(item.kind)
                .font(.callout)
            Text(item.sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Selectable preview for text and source files. CSV/TSV files are parsed into
/// a native table with one header and up to 10 data rows. All file loading and
/// delimited parsing stays off the main thread.
private struct TextFilePreview: View {
    let item: FileItem

    @State private var text: String?
    @State private var delimitedPreview: DelimitedFilePreviewResult?
    @State private var previewLimit: TextFilePreviewLimit?
    @State private var errorMessage: String?

    private var previewKey: String {
        "\(item.id)|\(item.modified.timeIntervalSince1970)"
    }

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(
                    "Can’t Preview",
                    systemImage: "doc.questionmark",
                    description: Text(errorMessage)
                )
            } else if let delimitedPreview {
                DelimitedFilePreviewView(preview: delimitedPreview)
            } else if let text {
                VStack(spacing: 0) {
                    ScrollView([.vertical, .horizontal]) {
                        Text(text.isEmpty ? " " : text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    if let previewLimit {
                        Divider()
                        Text(limitMessage(for: previewLimit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: previewKey) { await load() }
    }

    private func load() async {
        let url = item.url
        text = nil
        delimitedPreview = nil
        previewLimit = nil
        errorMessage = nil
        do {
            let isDelimited = item.isDelimitedSpreadsheet
            if isDelimited {
                let separator: DelimitedFileSeparator =
                    item.url.pathExtension.lowercased() == "tsv" ? .tab : .comma
                let result = try await TextFilePreviewLoader.loadDelimited(
                    from: url,
                    separator: separator
                )
                guard !Task.isCancelled, item.url == url else { return }
                delimitedPreview = result
            } else {
                let result = try await TextFilePreviewLoader.load(from: url)
                guard !Task.isCancelled, item.url == url else { return }
                text = result.text
                previewLimit = result.limit
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, item.url == url else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func limitMessage(for limit: TextFilePreviewLimit) -> String {
        switch limit {
        case let .rows(count):
            "Preview limited to the first \(count) rows."
        case let .bytes(count):
            "Preview limited to the first \(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file))."
        }
    }
}

/// Wraps QLPreviewView so Quick Look renders PDFs, RTF, and Office documents
/// inline — the same engine Finder's preview uses.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? NSURL) as URL? != url {
            nsView.previewItem = url as NSURL
        }
    }
}

final class PassthroughAVPlayerView: AVPlayerView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class PreviewToolbarNSButton: NSButton {
    var onPress: (Bool) -> Void = { _ in }
    private var reportsToggleState = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(performToolbarAction)
        bezelStyle = .rounded
        controlSize = .small
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(performToolbarAction)
    }

    func configure(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        help: String,
        isEnabled: Bool,
        isToggle: Bool,
        isOn: Bool,
        onPress: @escaping (Bool) -> Void
    ) {
        self.title = title
        image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: accessibilityLabel
        )
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        toolTip = help
        setAccessibilityLabel(accessibilityLabel)
        self.isEnabled = isEnabled
        reportsToggleState = isToggle
        setButtonType(isToggle ? .toggle : .momentaryPushIn)
        state = isToggle && isOn ? .on : .off
        self.onPress = onPress
    }

    @objc
    private func performToolbarAction() {
        onPress(reportsToggleState && state == .on)
    }
}

private struct NativePreviewToolbarButton: NSViewRepresentable {
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let help: String
    let isEnabled: Bool
    let isToggle: Bool
    let isOn: Bool
    let action: (Bool) -> Void

    init(
        title: String = "",
        systemImage: String,
        accessibilityLabel: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.isEnabled = isEnabled
        self.isToggle = false
        self.isOn = false
        self.action = { _ in action() }
    }

    init(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        help: String,
        isEnabled: Bool,
        isToggle: Bool,
        isOn: Bool,
        action: @escaping (Bool) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.isEnabled = isEnabled
        self.isToggle = isToggle
        self.isOn = isOn
        self.action = action
    }

    func makeNSView(context: Context) -> PreviewToolbarNSButton {
        PreviewToolbarNSButton(frame: .zero)
    }

    func updateNSView(_ button: PreviewToolbarNSButton, context: Context) {
        button.configure(
            title: title,
            systemImage: systemImage,
            accessibilityLabel: accessibilityLabel,
            help: help,
            isEnabled: isEnabled,
            isToggle: isToggle,
            isOn: isOn,
            onPress: action
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PreviewToolbarNSButton,
        context: Context
    ) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(
            width: proposal.width ?? intrinsic.width,
            height: proposal.height ?? intrinsic.height
        )
    }
}

private struct PlayerPreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PassthroughAVPlayerView {
        let view = PassthroughAVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: PassthroughAVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        view.controlsStyle = .none
    }

    static func dismantleNSView(_ view: PassthroughAVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
