import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct SnippetPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = SnippetStore.shared
    @State private var draftText = ""
    @State private var isFileDropTargeted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            searchAndFilters
            Divider()
            snippetsList(selection: $store.selectedSnippetID)
            Divider()
            selectedSnippetPanel
            Divider()
            textComposer
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .contentShape(Rectangle())
        .overlay {
            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            store.ensureSelection()
        }
        .onChange(of: store.searchText) { _, _ in
            store.ensureSelection()
        }
        .onChange(of: store.filter) { _, _ in
            store.ensureSelection()
        }
        .onDrop(
            of: [
                AppState.internalFileDragType,
                .fileURL,
            ],
            isTargeted: $isFileDropTargeted,
            perform: handleDrop(providers:)
        )
        .onPasteCommand(of: [.fileURL, .image, .png, .jpeg, .tiff, .plainText, .text]) { _ in
            store.addCurrentClipboard()
            store.ensureSelection()
        }
        .alert("Snippet Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    /// Drop on the panel background: create a new snippet holding the dropped files.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        handleFileProviders(providers) { urls in
            store.createSnippet(withFiles: urls)
            store.ensureSelection()
        }
    }

    /// Drop on an existing snippet row: the files collect inside that snippet.
    private func handleDrop(providers: [NSItemProvider], into snippetID: SnippetItem.ID) -> Bool {
        handleFileProviders(providers) { urls in
            store.addFiles(urls, to: snippetID)
        }
    }

    /// Pulls file URLs out of a drop (internal pane drag or Finder file URLs) and
    /// hands them to `deliver`. Returns whether it will handle the drop.
    private func handleFileProviders(
        _ providers: [NSItemProvider],
        deliver: @escaping ([URL]) -> Void
    ) -> Bool {
        if providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(AppState.internalFileDragType.identifier)
        }) {
            let urls = appState.consumeCurrentFileDragURLs()
            if !urls.isEmpty {
                deliver(urls)
                return true
            }
        }

        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        loadDroppedFiles(from: fileProviders, deliver: deliver)
        return true
    }

    private func loadDroppedFiles(
        from providers: [NSItemProvider],
        deliver: @escaping ([URL]) -> Void
    ) {
        let droppedURLCollector = SnippetDroppedURLCollector()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = Self.fileURL(from: item) {
                    droppedURLCollector.append(url.standardizedFileURL)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let droppedURLs = droppedURLCollector.urls
            guard !droppedURLs.isEmpty else {
                store.lastError = "No usable files were dropped."
                return
            }
            deliver(droppedURLs)
        }
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL {
                return url
            }
            return URL(fileURLWithPath: string)
        }
        return nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Snippets", systemImage: "text.quote")
                .font(.headline)

            Spacer()

            if store.pendingImportFileCount > 0 {
                ProgressView()
                    .controlSize(.small)
                    .help("Adding \(store.pendingImportFileCount) file\(store.pendingImportFileCount == 1 ? "" : "s")")
            }

            Button {
                store.addCurrentClipboard()
                store.ensureSelection()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .help("Save current clipboard")

            Button {
                store.chooseFiles()
                store.ensureSelection()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .help("Add files")

            Button {
                appState.hideSnippets()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide snippets")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var searchAndFilters: some View {
        @Bindable var store = store
        return VStack(spacing: 8) {
            HStack(spacing: 7) {
                Button {
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Search snippets")

                TextField("Search", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)

                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))

            Picker("Filter", selection: $store.filter) {
                ForEach(SnippetFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func snippetsList(
        selection: Binding<SnippetItem.ID?>
    ) -> some View {
        Group {
            if store.filteredSnippets.isEmpty {
                ContentUnavailableView("No Snippets", systemImage: "text.quote")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(store.filteredSnippets) { item in
                        SnippetRow(
                            item: item,
                            store: store,
                            selectAction: { selection.wrappedValue = item.id },
                            copyAction: { store.copy(item) },
                            deleteAction: { store.delete(item.id) },
                            dropAction: { providers in
                                handleDrop(providers: providers, into: item.id)
                            }
                        )
                        .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minHeight: 180, idealHeight: 230, maxHeight: 280)
        .contentShape(Rectangle())
        .onDrop(
            of: [AppState.internalFileDragType, .fileURL],
            isTargeted: $isFileDropTargeted,
            perform: handleDrop(providers:)
        )
    }

    private var selectedSnippetPanel: some View {
        ScrollView {
            Group {
                if let item = store.snippet(for: store.selectedSnippetID) {
                    SnippetDetailView(item: item, store: store)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "text.quote")
                        .frame(height: 175)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 170)
        .contentShape(Rectangle())
        .onDrop(
            of: [AppState.internalFileDragType, .fileURL],
            isTargeted: $isFileDropTargeted,
            perform: handleDrop(providers:)
        )
    }

    private var textComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Text")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextEditor(text: $draftText)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(height: 90)
                .padding(6)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button {
                    draftText = ""
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(draftText.isEmpty)
                .help("Clear")

                Spacer()

                Button {
                    store.addText(draftText)
                    draftText = ""
                    store.ensureSelection()
                } label: {
                    Label("Add Text", systemImage: "plus")
                }
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .contentShape(Rectangle())
        .onDrop(
            of: [AppState.internalFileDragType, .fileURL],
            isTargeted: $isFileDropTargeted,
            perform: handleDrop(providers:)
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}

private final class SnippetDroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedURLs: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return collectedURLs
    }

    func append(_ url: URL) {
        lock.lock()
        collectedURLs.append(url)
        lock.unlock()
    }
}

private struct SnippetRow: View {
    let item: SnippetItem
    let store: SnippetStore
    let selectAction: () -> Void
    let copyAction: () -> Void
    let deleteAction: () -> Void
    let dropAction: ([NSItemProvider]) -> Bool

    @State private var isTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: selectAction) {
                HStack(alignment: .top, spacing: 8) {
                    SnippetIconView(item: item, store: store, size: 24)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(item.displayTitle)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            if item.files.count > 1 {
                                Text("\(item.files.count)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                                    .help("\(item.files.count) files in this snippet")
                            }
                        }

                        if !item.preview.isEmpty {
                            Text(item.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag {
                store.dragProvider(for: item)
            }

            VStack(spacing: 7) {
                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")

                Button(role: .destructive, action: deleteAction) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // Dropping files onto a row adds them to that snippet (inner drop target
        // wins over the panel-wide one, which creates a new snippet instead).
        .onDrop(
            of: [AppState.internalFileDragType, .fileURL],
            isTargeted: $isTargeted,
            perform: dropAction
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}

/// One file inside a snippet, with open / reveal / remove actions.
private struct SnippetFileRow: View {
    let file: SnippetFile
    let store: SnippetStore
    let snippetID: SnippetItem.ID
    @ObservedObject var audioPlayback: SnippetAudioPlaybackController

    var body: some View {
        let url = store.assetURL(for: file)
        let fileItem = FileItem.make(url: url)
        HStack(spacing: 7) {
            SnippetThumbnailView(url: url, size: CGSize(width: 36, height: 36))

            Text(file.originalName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if fileItem.isAudioMedia {
                Button {
                    audioPlayback.toggle(fileID: file.id, url: url)
                } label: {
                    Image(systemName: audioPlayback.isPlaying(file.id) ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(audioPlayback.isPlaying(file.id) ? "Pause audio" : "Play audio")
            }

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open file")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")

            Button(role: .destructive) {
                store.removeFile(file.id, from: snippetID)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove from snippet")
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

@MainActor
private final class SnippetAudioPlaybackController: ObservableObject {
    @Published private(set) var activeFileID: SnippetFile.ID?
    @Published private(set) var isPlayingAudio = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var durationTask: Task<Void, Never>?

    func isPlaying(_ fileID: SnippetFile.ID) -> Bool {
        activeFileID == fileID && isPlayingAudio
    }

    func toggle(fileID: SnippetFile.ID, url: URL) {
        if activeFileID != fileID || player == nil {
            prepare(fileID: fileID, url: url)
        }
        guard let player else { return }
        if isPlayingAudio {
            player.pause()
            isPlayingAudio = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlayingAudio = true
        }
    }

    func seek(fileID: SnippetFile.ID, to seconds: Double) {
        guard activeFileID == fileID, let player else { return }
        let clamped = min(max(seconds, 0), max(duration, 0))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    func stop() {
        durationTask?.cancel()
        durationTask = nil
        player?.pause()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player = nil
        timeObserver = nil
        endObserver = nil
        activeFileID = nil
        isPlayingAudio = false
        currentTime = 0
        duration = 0
    }

    private func prepare(fileID: SnippetFile.ID, url: URL) {
        stop()
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        activeFileID = fileID

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = max(CMTimeGetSeconds(time), 0)
            Task { @MainActor [weak self] in
                guard let self, seconds.isFinite else { return }
                self.currentTime = seconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { [weak self, weak newPlayer] _ in
            Task { @MainActor [weak self, weak newPlayer] in
                newPlayer?.seek(to: .zero)
                self?.currentTime = 0
                self?.isPlayingAudio = false
            }
        }

        durationTask = Task { @MainActor [weak self, weak newPlayer] in
            guard let asset = newPlayer?.currentItem?.asset,
                  let loadedDuration = try? await asset.load(.duration),
                  !Task.isCancelled else { return }
            let seconds = CMTimeGetSeconds(loadedDuration)
            if seconds.isFinite {
                self?.duration = max(seconds, 0)
            }
        }
    }
}

private struct SnippetThumbnailView: View {
    let url: URL
    let size: CGSize
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(nsImage: FileItem.make(url: url).icon)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: "\(url.path)|\(Int(size.width))x\(Int(size.height))") {
            let item = FileItem.make(url: url)
            thumbnail = await ThumbnailLoader.thumbnail(
                for: item,
                pixelSize: max(size.width, size.height) * 2
            )
        }
    }
}

private struct SnippetAudioControls: View {
    let file: SnippetFile
    let url: URL
    @ObservedObject var playback: SnippetAudioPlaybackController

    private var isActive: Bool { playback.activeFileID == file.id }
    private var progress: Binding<Double> {
        Binding {
            isActive ? playback.currentTime : 0
        } set: { value in
            playback.seek(fileID: file.id, to: value)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                playback.toggle(fileID: file.id, url: url)
            } label: {
                Image(systemName: playback.isPlaying(file.id) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying(file.id) ? "Pause audio" : "Play audio")

            VStack(spacing: 2) {
                Slider(value: progress, in: 0...max(isActive ? playback.duration : 0, 0.1))
                    .disabled(!isActive || playback.duration <= 0)
                HStack {
                    Text(timeText(isActive ? playback.currentTime : 0))
                    Spacer()
                    Text(timeText(isActive ? playback.duration : 0))
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct SnippetAttachmentPreviewCard: View {
    let file: SnippetFile
    let store: SnippetStore
    @ObservedObject var audioPlayback: SnippetAudioPlaybackController

    private var url: URL { store.assetURL(for: file) }
    private var fileItem: FileItem { FileItem.make(url: url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SnippetThumbnailView(
                url: url,
                size: CGSize(width: fileItem.isAudioMedia ? 204 : 124, height: 72)
            )

            if fileItem.isAudioMedia {
                SnippetAudioControls(file: file, url: url, playback: audioPlayback)
            }

            Text(file.originalName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .frame(width: fileItem.isAudioMedia ? 216 : 136, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

private struct SnippetDetailView: View {
    let item: SnippetItem
    let store: SnippetStore
    @State private var labelDraft = ""
    @State private var labelSaveTask: Task<Void, Never>?
    @StateObject private var audioPlayback = SnippetAudioPlaybackController()
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SnippetIconView(item: item, store: store, size: 24)

                Text(item.kind.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Button {
                    store.copy(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy")

                Button(role: .destructive) {
                    store.delete(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete")
            }

            labelEditor

            preview

            if item.files.count > 1 {
                filesList
            }

            if item.kind != .text {
                assetActions
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: syncLabelDraft)
        .onChange(of: item.id) { _, _ in
            audioPlayback.stop()
            syncLabelDraft()
        }
        .onChange(of: item.title) { _, _ in
            if !labelFocused {
                syncLabelDraft()
            }
        }
        .onChange(of: labelFocused) { _, focused in
            if !focused {
                commitLabel()
            }
        }
        .onChange(of: labelDraft) { _, _ in
            if labelFocused {
                scheduleLabelSave()
            }
        }
        .onDisappear {
            audioPlayback.stop()
            commitLabel()
        }
    }

    private var labelEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Label")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Label", text: $labelDraft)
                .textFieldStyle(.roundedBorder)
                .focused($labelFocused)
                .onSubmit(commitLabel)
        }
    }

    /// Every file collected in this snippet. Drop more onto the snippet's row to add.
    private var filesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Files (\(item.files.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVStack(spacing: 3) {
                ForEach(item.files) { file in
                    SnippetFileRow(
                        file: file,
                        store: store,
                        snippetID: item.id,
                        audioPlayback: audioPlayback
                    )
                }
            }
        }
    }

    private func syncLabelDraft() {
        labelDraft = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? item.displayTitle
            : item.title
    }

    private func commitLabel() {
        labelSaveTask?.cancel()
        labelSaveTask = nil
        let normalizedTitle = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateTitle(normalizedTitle, for: item.id)
        if labelDraft != normalizedTitle {
            labelDraft = normalizedTitle
        }
    }

    private func scheduleLabelSave() {
        labelSaveTask?.cancel()
        let id = item.id
        let draft = labelDraft
        labelSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            store.updateTitle(draft, for: id)
            labelSaveTask = nil
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(item.detailText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                if item.isDetailTextTruncated {
                    Text("Preview limited to keep Workbench responsive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: 180)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
        case .image:
            attachmentPreview
        case .file:
            attachmentPreview
        }
    }

    private var attachmentPreview: some View {
        Group {
            if !item.files.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(item.files) { file in
                            SnippetAttachmentPreviewCard(
                                file: file,
                                store: store,
                                audioPlayback: audioPlayback
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: attachmentPreviewHeight)
            } else {
                if let url = store.assetURL(for: item) {
                    HStack(spacing: 10) {
                        SnippetThumbnailView(url: url, size: CGSize(width: 72, height: 72))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayTitle)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(item.originalName ?? url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    ContentUnavailableView("Missing File", systemImage: "doc")
                        .frame(height: 140)
                }
            }
        }
    }

    private var attachmentPreviewHeight: CGFloat {
        let containsAudio = item.files.contains { file in
            FileItem.make(url: store.assetURL(for: file)).isAudioMedia
        }
        return containsAudio ? 138 : 112
    }

    private var assetActions: some View {
        HStack(spacing: 8) {
            Button {
                store.reveal(item)
            } label: {
                Label("Reveal", systemImage: "arrow.up.forward.square")
            }
            .disabled(store.assetURL(for: item) == nil)

            Button {
                store.open(item)
            } label: {
                Label("Open", systemImage: "arrow.up.right")
            }
            .disabled(store.assetURL(for: item) == nil)
        }
    }
}

private struct SnippetIconView: View {
    let item: SnippetItem
    let store: SnippetStore
    let size: CGFloat

    var body: some View {
        Group {
            switch item.kind {
            case .text:
                fallbackIcon(systemName: item.kind.systemImage)
            case .image:
                if let url = primaryAssetURL {
                    SnippetThumbnailView(url: url, size: CGSize(width: size, height: size))
                } else {
                    fallbackIcon(systemName: item.kind.systemImage)
                }
            case .file:
                if let url = primaryAssetURL {
                    SnippetThumbnailView(url: url, size: CGSize(width: size, height: size))
                } else {
                    fallbackIcon(systemName: item.kind.systemImage)
                }
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(item.kind == .text ? 0.35 : 0), in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            if item.kind == .image {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }
        }
    }

    private var primaryAssetURL: URL? {
        if let first = item.files.first {
            return store.assetURL(for: first)
        }
        return store.assetURL(for: item)
    }

    private func fallbackIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.58, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}
