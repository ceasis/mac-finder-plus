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
                Toggle("Loop", isOn: $loopVideos)
                    .toggleStyle(.checkbox)
                    .font(previewControlCaptionFont)
                    .help("Restart playback automatically when the video ends")
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
        if item.isZipArchive {
            ZipArchivePreview(item: item)
        } else if item.isImage || item.isPlayableMedia {
            SingleMediaPreview(item: item, sizeScale: previewMediaSizeScale)
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

    @State private var player: AVPlayer?

    var body: some View {
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
                            sizeScale: sizeScale,
                            onPlayerChange: { player = $0 }
                        )
                            .frame(height: previewHeight(for: geometry.size.height))
                    }
                    if item.isVideoMedia {
                        VideoTrimControls(item: item, player: player)
                    }
                    MediaMetadataInspector(item: item)
                }
                .padding(10)
            }
        }
    }

    private func previewHeight(for availableHeight: CGFloat) -> CGFloat {
        max(min(max(availableHeight * 0.58, 220), 460) * CGFloat(sizeScale), 140)
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
                PlayerPreviewView(player: player, showsControls: style.showsPlaybackControls)
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

private struct AudioPreviewCard: View {
    let item: FileItem

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var endObserver: NSObjectProtocol?
    @State private var timeObserver: Any?

    private var progressBinding: Binding<Double> {
        Binding {
            currentTime
        } set: { value in
            currentTime = value
            player?.seek(to: CMTime(seconds: value, preferredTimescale: 600))
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 132, height: 132)

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

            HStack(spacing: 10) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")

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
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: "\(item.id)|\(item.modified.timeIntervalSince1970)") {
            await preparePlayer()
        }
        .onDisappear(perform: teardown)
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
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = max(CMTimeGetSeconds(time), 0)
            Task { @MainActor in
                currentTime = seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                isPlaying = false
                currentTime = 0
                player?.seek(to: .zero)
            }
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
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct VideoTrimControls: View {
    @Environment(AppState.self) private var appState
    let item: FileItem
    let player: AVPlayer?

    @State private var duration: Double = 0
    @State private var inTime: Double = 0
    @State private var outTime: Double = 0
    @State private var isLoading = false

    private var trimDuration: Double {
        max(outTime - inTime, 0)
    }

    private var isValid: Bool {
        duration > 0 && outTime - inTime >= 0.1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Trim", systemImage: "timeline.selection")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(VideoTrimmer.timeText(inTime)) – \(VideoTrimmer.timeText(outTime))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("· \(VideoTrimmer.timeText(trimDuration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button {
                        markIn()
                    } label: {
                        Label("In", systemImage: "arrow.left.to.line")
                    }
                    .disabled(player == nil)
                    .help("Set trim in point to the current playback time")

                    Button {
                        markOut()
                    } label: {
                        Label("Out", systemImage: "arrow.right.to.line")
                    }
                    .disabled(player == nil)
                    .help("Set trim out point to the current playback time")

                    Spacer()

                    Button {
                        appState.exportVideoTrim(item, inTime: inTime, outTime: outTime)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!isValid)
                    .help("Export this range without re-encoding")
                }
                .font(.caption)

                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("In")
                            .foregroundStyle(.secondary)
                        Slider(value: inBinding, in: 0...max(duration, 0.1))
                        Text(VideoTrimmer.timeText(inTime))
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Out")
                            .foregroundStyle(.secondary)
                        Slider(value: outBinding, in: 0...max(duration, 0.1))
                        Text(VideoTrimmer.timeText(outTime))
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
            }
        }
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: "\(item.id)|\(item.modified.timeIntervalSince1970)") {
            await loadDuration()
        }
    }

    private var inBinding: Binding<Double> {
        Binding {
            inTime
        } set: { value in
            inTime = min(max(value, 0), max(outTime - 0.1, 0))
        }
    }

    private var outBinding: Binding<Double> {
        Binding {
            outTime
        } set: { value in
            outTime = min(max(value, min(inTime + 0.1, duration)), duration)
        }
    }

    @MainActor
    private func loadDuration() async {
        isLoading = true
        let loadedDuration = await VideoTrimmer.duration(for: item.url) ?? 0
        guard !Task.isCancelled else { return }
        duration = loadedDuration
        inTime = 0
        outTime = loadedDuration
        isLoading = false
    }

    private func markIn() {
        guard let seconds = currentPlayerSeconds() else { return }
        inTime = min(max(seconds, 0), max(outTime - 0.1, 0))
    }

    private func markOut() {
        guard let seconds = currentPlayerSeconds() else { return }
        outTime = min(max(seconds, min(inTime + 0.1, duration)), duration)
    }

    private func currentPlayerSeconds() -> Double? {
        guard let player else { return nil }
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : nil
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

    var showsPlaybackControls: Bool {
        switch self {
        case .full: true
        case .row, .gallery: false
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

/// Monospaced, selectable preview for text and source files. Reads at most
/// `byteCap` off the main thread and decodes UTF-8 (falling back to Latin-1)
/// so it never blocks on a large log or hangs on binary content.
private struct TextFilePreview: View {
    let item: FileItem

    @State private var text: String?
    @State private var truncated = false
    @State private var errorMessage: String?

    private let byteCap = 1_000_000

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
                    if truncated {
                        Divider()
                        Text("Preview limited to the first \(ByteCountFormatter.string(fromByteCount: Int64(byteCap), countStyle: .file)).")
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
        let cap = byteCap
        let outcome: (text: String?, truncated: Bool, error: String?) =
            await Task.detached(priority: .userInitiated) {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: cap + 1) ?? Data()
                    let isTruncated = data.count > cap
                    let slice = Data(data.prefix(cap))
                    let decoded = String(data: slice, encoding: .utf8)
                        ?? String(data: slice, encoding: .isoLatin1)
                        ?? ""
                    return (decoded, isTruncated, nil)
                } catch {
                    return (nil, false, error.localizedDescription)
                }
            }.value
        guard !Task.isCancelled, item.url == url else { return }
        errorMessage = outcome.error
        text = outcome.text
        truncated = outcome.truncated
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

private struct PlayerPreviewView: NSViewRepresentable {
    let player: AVPlayer
    let showsControls: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .floating : .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        view.controlsStyle = showsControls ? .floating : .none
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
