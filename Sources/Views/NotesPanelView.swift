import AppKit
import AVFoundation
import AVKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

private let noteToolbarButtonSide: CGFloat = 24.2
private let noteToolbarIconSize: CGFloat = 13.2

struct NotesPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = NotesStore.shared

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            NotesSidebar(store: store) {
                appState.hideNotes()
            }
            .navigationSplitViewColumnWidth(min: 232, ideal: 250, max: 320)
        } detail: {
            if let note = store.note(for: store.selectedNoteID) {
                NoteEditorView(store: store, noteID: note.id)
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "note.text")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .onAppear { store.ensureSelection() }
        .alert("Notes Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .background(
            Button("", action: { appState.hideNotes() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}

private struct NotesSidebar: View {
    let store: NotesStore
    let onClose: () -> Void

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Notes", systemImage: "note.text")
                    .font(.headline)

                Spacer()

                PanelIconButton(systemName: "square.and.pencil", help: store.selectedDay == nil ? "New note" : "New note on selected day") {
                    store.createNote(on: store.selectedDay)
                }

                PanelIconButton(systemName: "xmark", help: "Hide Notes") {
                    onClose()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            NotesCalendarView(store: store, selectedDay: $store.selectedDay)

            if let day = store.selectedDay {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(day.formatted(date: .abbreviated, time: .omitted))
                    Spacer()
                    Button("Show All") { store.selectedDay = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()

            NotesSearchField(text: $store.searchText)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            if store.selectedDay == nil {
                Picker("Group notes", selection: $store.grouping) {
                    ForEach(NoteGrouping.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .help("Group notes by month or year")
            }

            Divider()

            if store.filteredNotes.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "note.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedNoteID) {
                    ForEach(store.noteGroups) { group in
                        if group.title.isEmpty {
                            ForEach(group.notes) { note in
                                noteRow(note)
                            }
                        } else {
                            Section(group.title) {
                                ForEach(group.notes) { note in
                                    noteRow(note)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .contentMargins(.top, 8, for: .scrollContent)
            }

            Divider()

            HStack(spacing: 8) {
                Text("\(store.filteredNotes.count) note\(store.filteredNotes.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    store.deleteSelectedNote()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(store.selectedNoteID == nil)
                .help("Delete selected note")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func noteRow(_ note: NoteItem) -> some View {
        NoteListRow(note: note)
            .tag(note.id)
            .contextMenu {
                Button("Delete Note", role: .destructive) {
                    store.deleteNote(note.id)
                }
            }
    }
}

private struct NotesSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Notes", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
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
    }
}

private struct NoteListRow: View {
    let note: NoteItem

    private var imageCount: Int {
        note.attachments.filter { $0.kind == .image }.count
    }

    private var audioCount: Int {
        note.attachments.filter { $0.kind == .audio }.count
    }

    private var videoCount: Int {
        note.attachments.filter { $0.kind == .video }.count
    }

    private var fileCount: Int {
        note.attachments.filter { $0.kind == .file }.count
    }

    private var attachmentCount: Int {
        note.attachments.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(note.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineSpacing(1)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if attachmentCount > 0 {
                    HStack(spacing: 3) {
                        if imageCount > 0 {
                            Image(systemName: "photo")
                        }
                        if audioCount > 0 {
                            Image(systemName: "waveform")
                        }
                        if videoCount > 0 {
                            Image(systemName: "video")
                        }
                        if fileCount > 0 {
                            Image(systemName: "doc")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Text(previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if attachmentCount > 0 {
                    Text("-")
                    Text("\(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(.vertical, 7)
    }

    private var previewText: String {
        let trimmed = note.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No text yet" : trimmed
    }
}

private struct NoteEditorView: View {
    let store: NotesStore
    let noteID: NoteItem.ID
    @State private var isVideoRecorderPresented = false
    @State private var annotatingImage: NoteAttachment?
    @State private var editorBridge = NoteEditorBridge()

    private var note: NoteItem? {
        store.note(for: noteID)
    }

    private var images: [NoteAttachment] {
        note?.attachments.filter { $0.kind == .image } ?? []
    }

    private var recordings: [NoteAttachment] {
        note?.attachments.filter { $0.kind == .audio } ?? []
    }

    private var videos: [NoteAttachment] {
        note?.attachments.filter { $0.kind == .video } ?? []
    }

    private var files: [NoteAttachment] {
        note?.attachments.filter { $0.kind == .file } ?? []
    }

    private var hasAttachments: Bool {
        !(note?.attachments.isEmpty ?? true)
    }

    private var hasNonImageAttachments: Bool {
        !recordings.isEmpty || !videos.isEmpty || !files.isEmpty
    }

    private var nonImageAttachmentCount: Int {
        recordings.count + videos.count + files.count
    }

    private var isRecordingThisNote: Bool {
        store.recordingNoteID == noteID
    }

    private var isRecordingAnotherNote: Bool {
        store.recordingNoteID != nil && !isRecordingThisNote
    }

    private var selectedImageAttachment: NoteAttachment? {
        guard let selectedImageID = editorBridge.selectedImageID else { return nil }
        return images.first { $0.id == selectedImageID }
    }

    private var bodyIsEmpty: Bool {
        guard let note else { return true }
        return NoteInlineAttachmentMarkup.displayText(from: note.body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty && images.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            formatToolbar
            Divider()

            VStack(spacing: 0) {
                editorBody
                    .frame(minHeight: 180)

                if hasNonImageAttachments {
                    Divider()
                    attachmentsPanel
                        .frame(minHeight: 120, maxHeight: 240)
                }
            }

            Divider()
            statusBar
        }
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            store.addFiles(urls, to: noteID)
            return true
        }
        .onPasteCommand(of: [.fileURL, .image, .png, .jpeg, .tiff]) { _ in
            store.pasteAttachments(to: noteID)
        }
        .task(id: noteID) {
            store.ensureInlineImageMarkers(in: noteID)
        }
        .sheet(item: $annotatingImage) { attachment in
            ImageAnnotationEditorView(
                title: attachment.originalName,
                imageURL: store.attachmentURL(for: noteID, attachment: attachment),
                saveButtonTitle: "Save"
            ) {
                annotatingImage = nil
            } onSave: { outputURL in
                store.replaceImageAttachmentContents(
                    attachment.id,
                    in: noteID,
                    with: outputURL
                )
                annotatingImage = nil
            }
        }
    }

    private var formatToolbar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    editorBridge.toggleBold()
                } label: {
                    toolbarIcon("bold")
                }
                .help("Bold")

                Button {
                    editorBridge.applyTextStyle(.header)
                } label: {
                    toolbarIcon("textformat.size.larger")
                }
                .help("Header Text")
                .accessibilityLabel("Header Text")

                Button {
                    editorBridge.applyTextStyle(.body)
                } label: {
                    toolbarIcon("textformat.size.smaller")
                }
                .help("Body Text")
                .accessibilityLabel("Body Text")

                toolbarSeparator

                Button {
                    editorBridge.applyListStyle(.bullet)
                } label: {
                    toolbarIcon("list.bullet")
                }
                .help("Bullet List")
                .accessibilityLabel("Bullet List")

                Button {
                    editorBridge.applyListStyle(.numbered)
                } label: {
                    toolbarIcon("list.number")
                }
                .help("Numbered List")
                .accessibilityLabel("Numbered List")

                toolbarSeparator

                Button {
                    editorBridge.setAlignment(.left)
                } label: {
                    toolbarIcon("text.alignleft")
                }
                .help("Align left")

                Button {
                    editorBridge.setAlignment(.center)
                } label: {
                    toolbarIcon("text.aligncenter")
                }
                .help("Align center")

                Button {
                    editorBridge.setAlignment(.right)
                } label: {
                    toolbarIcon("text.alignright")
                }
                .help("Align right")

                Button {
                    editorBridge.setAlignment(.justified)
                } label: {
                    toolbarIcon("text.justify")
                }
                .help("Justify")

                Spacer(minLength: 8)
            }

            if let selectedImageAttachment {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: noteToolbarIconSize, weight: .medium))
                        .frame(width: noteToolbarButtonSide, height: noteToolbarButtonSide)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: imageWidthBinding(for: selectedImageAttachment),
                        in: 120...760,
                        step: 10
                    )
                    .frame(width: 170)
                    .help("Resize selected image")
                    .horizontalResizeCursor()

                    Button {
                        store.transformImageAttachment(
                            selectedImageAttachment.id,
                            in: noteID,
                            operation: .rotateLeft
                        )
                    } label: {
                        toolbarIcon("rotate.left")
                    }
                    .help("Rotate left")

                    Button {
                        store.transformImageAttachment(
                            selectedImageAttachment.id,
                            in: noteID,
                            operation: .rotateRight
                        )
                    } label: {
                        toolbarIcon("rotate.right")
                    }
                    .help("Rotate right")

                    Button {
                        store.transformImageAttachment(
                            selectedImageAttachment.id,
                            in: noteID,
                            operation: .flipHorizontal
                        )
                    } label: {
                        toolbarIcon("flip.horizontal")
                    }
                    .help("Flip horizontal")

                    Button {
                        store.transformImageAttachment(
                            selectedImageAttachment.id,
                            in: noteID,
                            operation: .flipVertical
                        )
                    } label: {
                        toolbarIcon("flip.vertical")
                    }
                    .help("Flip vertical")

                    Button {
                        annotatingImage = selectedImageAttachment
                    } label: {
                        toolbarIcon("pencil.tip.crop.circle")
                    }
                    .help("Annotate selected image")

                    Spacer(minLength: 8)
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var toolbarSeparator: some View {
        Divider()
            .frame(height: noteToolbarButtonSide)
            .padding(.horizontal, 2)
    }

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: noteToolbarIconSize, weight: .medium))
            .frame(width: noteToolbarButtonSide, height: noteToolbarButtonSide)
            .contentShape(Rectangle())
            .clickableCursor()
    }

    private func imageWidthBinding(for attachment: NoteAttachment) -> Binding<Double> {
        Binding(
            get: { attachment.displayWidth ?? 520 },
            set: { store.updateImageDisplayWidth($0, for: attachment.id, in: noteID) }
        )
    }

    private var editorHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Untitled Note", text: titleBinding)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    if let note {
                        Text("Updated \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("-")
                        Text("\(wordCount) words")
                        if hasAttachments {
                            Text("-")
                            Text("\(note.attachments.count) attachments")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 16)

            HStack(spacing: 6) {
                Button {
                    store.saveNow()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save note")

                Button {
                    store.chooseAndAttachFiles(to: noteID)
                } label: {
                    Image(systemName: "paperclip")
                }
                .help("Attach files")

                Button {
                    store.pasteAttachments(to: noteID)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .help("Paste image or copied files")

                if isRecordingThisNote {
                    Button {
                        store.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop recording")

                    Button {
                        store.cancelRecording()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Cancel recording")
                } else {
                    Button {
                        store.startRecording(for: noteID)
                    } label: {
                        Image(systemName: "mic.circle")
                    }
                    .disabled(isRecordingAnotherNote)
                    .help("Record voice journal")

                    Button {
                        isVideoRecorderPresented = true
                    } label: {
                        Image(systemName: "video.circle")
                    }
                    .disabled(isRecordingAnotherNote)
                    .help("Record video journal")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .sheet(isPresented: $isVideoRecorderPresented) {
            NoteVideoRecorderSheet(store: store, noteID: noteID)
                .frame(width: 600, height: 520)
        }
    }

    private var editorBody: some View {
        ZStack(alignment: .topLeading) {
            NoteBodyTextEditor(
                text: bodyBinding,
                richBodyData: richBodyBinding,
                imageAttachments: images,
                attachmentURL: { attachment in
                    store.attachmentURL(for: noteID, attachment: attachment)
                },
                bridge: editorBridge,
                canPasteAttachments: {
                    store.canPasteAttachments()
                },
                onPasteFileURLs: { urls in
                    store.addFiles(urls, to: noteID, insertImageMarkers: false)
                },
                onPasteImage: { image in
                    store.addPastedImage(image, to: noteID, insertImageMarker: false)
                },
                onInlineImageIDsChanged: { ids in
                    store.pruneInlineImageAttachments(in: noteID, keeping: ids)
                },
                onResizeInlineImage: { id, width in
                    store.updateImageDisplayWidth(width, for: id, in: noteID)
                }
            )

            if bodyIsEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Start writing", systemImage: "text.alignleft")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Type a note, paste images, drop files, or record a voice or video journal.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .allowsHitTesting(false)
            }

            if !hasAttachments {
                VStack {
                    Spacer()
                    attachmentDropStrip
                }
                .padding(16)
                .allowsHitTesting(false)
            }
        }
    }

    private var attachmentDropStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
            Text("Drop files here or paste images")
            Spacer()
            Image(systemName: "doc.on.clipboard")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private var attachmentsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Attachments", systemImage: "paperclip")
                    .font(.headline)
                Spacer()
                Text("\(nonImageAttachmentCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !recordings.isEmpty {
                        AttachmentSectionHeader(
                            title: "Voice",
                            systemImage: "waveform",
                            count: recordings.count
                        )
                        VStack(spacing: 8) {
                            ForEach(recordings) { attachment in
                                NoteAudioAttachmentRow(
                                    store: store,
                                    noteID: noteID,
                                    attachment: attachment
                                )
                            }
                        }
                    }

                    if !videos.isEmpty {
                        AttachmentSectionHeader(
                            title: "Video",
                            systemImage: "video",
                            count: videos.count
                        )
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 10)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(videos) { attachment in
                                NoteVideoAttachmentView(
                                    store: store,
                                    noteID: noteID,
                                    attachment: attachment
                                )
                            }
                        }
                    }

                    if !files.isEmpty {
                        AttachmentSectionHeader(
                            title: "Files",
                            systemImage: "doc",
                            count: files.count
                        )
                        VStack(spacing: 8) {
                            ForEach(files) { attachment in
                                NoteFileAttachmentRow(
                                    store: store,
                                    noteID: noteID,
                                    attachment: attachment
                                )
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if isRecordingThisNote {
                RecordingTimerView(startedAt: store.recordingStartedAt)
            } else if let saved = store.lastSavedAt {
                Label("Saved \(saved.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let note {
                Text("\(NoteInlineAttachmentMarkup.displayText(from: note.body).count) chars")
                    .foregroundStyle(.secondary)
                if hasAttachments {
                    Text("-")
                        .foregroundStyle(.tertiary)
                    Text("\(note.attachments.count) attachments")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var wordCount: Int {
        guard let body = note?.body else { return 0 }
        return NoteInlineAttachmentMarkup.displayText(from: body)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { note?.title ?? "" },
            set: { store.updateTitle(noteID, title: $0) }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { note?.body ?? "" },
            set: { store.updateBody(noteID, body: $0) }
        )
    }

    private var richBodyBinding: Binding<Data?> {
        Binding(
            get: { note?.richBodyData },
            set: { store.updateRichBodyData(noteID, richBodyData: $0) }
        )
    }
}

private struct AttachmentSectionHeader: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct NoteVideoAttachmentView: View {
    let store: NotesStore
    let noteID: NoteItem.ID
    let attachment: NoteAttachment
    @State private var thumbnail: NSImage?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var endObserver: NSObjectProtocol?

    private var url: URL {
        store.attachmentURL(for: noteID, attachment: attachment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                } else if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "video")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if player == nil {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white, .black.opacity(0.38))
                    }
                    .buttonStyle(.plain)
                    .help("Play video")
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.quaternary, lineWidth: 1)
            )

            HStack(spacing: 8) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.originalName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(durationText(attachment.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open video")

                Button(role: .destructive) {
                    teardownPlayback()
                    store.deleteAttachment(attachment.id, from: noteID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete video")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            thumbnail = makeThumbnail()
        }
        .onDisappear {
            teardownPlayback()
        }
    }

    private func togglePlayback() {
        if player == nil {
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: newPlayer.currentItem,
                queue: .main
            ) { _ in
                Task { @MainActor in
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
        endObserver = nil
        isPlaying = false
    }

    private func makeThumbnail() -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "Video journal" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct NoteFileAttachmentRow: View {
    let store: NotesStore
    let noteID: NoteItem.ID
    let attachment: NoteAttachment

    private var url: URL {
        store.attachmentURL(for: noteID, attachment: attachment)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.originalName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open file")

            Button(role: .destructive) {
                store.deleteAttachment(attachment.id, from: noteID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete file")
        }
        .padding(9)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private var fileDetailText: String {
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey])
        let kind = values?.localizedTypeDescription ?? "File"
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        if let size {
            return "\(kind) - \(size)"
        }
        return kind
    }
}

private struct NoteAudioAttachmentRow: View {
    let store: NotesStore
    let noteID: NoteItem.ID
    let attachment: NoteAttachment
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    private var url: URL {
        store.attachmentURL(for: noteID, attachment: attachment)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause" : "Play")

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.originalName)
                    .font(.callout)
                    .lineLimit(1)
                Text(durationText(attachment.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                player?.pause()
                store.deleteAttachment(attachment.id, from: noteID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete recording")
        }
        .padding(9)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .onDisappear {
            player?.pause()
        }
    }

    private func togglePlayback() {
        if player == nil {
            player = AVPlayer(url: url)
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.seek(to: .zero)
            player.play()
            isPlaying = true
        }
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "Voice recording" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct NoteVideoRecorderSheet: View {
    let store: NotesStore
    let noteID: NoteItem.ID
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = NoteVideoRecorder()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Video Journal", systemImage: "video")
                    .font(.headline)
                Spacer()
                PanelIconButton(systemName: "xmark", help: "Close") {
                    if recorder.isRecording {
                        recorder.cancelRecording()
                    }
                    dismiss()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ZStack {
                if let session = recorder.session {
                    NoteCameraPreviewView(session: session)
                } else if recorder.lastError == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("Camera Unavailable", systemImage: "video.slash")
                }

                if recorder.isRecording {
                    VStack {
                        HStack {
                            RecordingTimerView(startedAt: recorder.startedAt)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.48), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)

            if let error = recorder.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            Divider()

            HStack(spacing: 8) {
                if recorder.isRecording {
                    Button {
                        recorder.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button {
                        recorder.cancelRecording()
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        recorder.startRecording(for: noteID, store: store)
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!recorder.isReady)

                    Spacer()

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(.bar)
        }
        .task {
            await recorder.prepare()
        }
        .onChange(of: recorder.lastSavedURL) { _, savedURL in
            if savedURL != nil {
                dismiss()
            }
        }
        .onDisappear {
            recorder.teardown()
        }
    }
}

private struct NoteCameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewContainerView, context: Context) {
        nsView.previewLayer.session = session
    }
}

private final class CameraPreviewContainerView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

@Observable
@MainActor
private final class NoteVideoRecorder {
    private(set) var session: AVCaptureSession?
    private(set) var isReady = false
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var lastSavedURL: URL?
    private(set) var lastError: String?

    @ObservationIgnored private var movieOutput: AVCaptureMovieFileOutput?
    @ObservationIgnored private var recordingDelegate: NoteVideoRecordingDelegate?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingNoteID: NoteItem.ID?
    @ObservationIgnored private weak var pendingStore: NotesStore?
    @ObservationIgnored private var shouldDiscardRecording = false

    func prepare() async {
        guard session == nil else { return }
        do {
            guard await requestAccess(for: .video) else {
                throw NoteVideoRecorderError.cameraDenied
            }
            guard await requestAccess(for: .audio) else {
                throw NoteVideoRecorderError.microphoneDenied
            }

            guard let camera = AVCaptureDevice.default(for: .video) else {
                throw NoteVideoRecorderError.cameraUnavailable
            }
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                throw NoteVideoRecorderError.microphoneUnavailable
            }

            let captureSession = AVCaptureSession()
            let output = AVCaptureMovieFileOutput()
            captureSession.beginConfiguration()
            captureSession.sessionPreset = .high

            let videoInput = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(videoInput) else {
                throw NoteVideoRecorderError.cameraUnavailable
            }
            captureSession.addInput(videoInput)

            let audioInput = try AVCaptureDeviceInput(device: microphone)
            guard captureSession.canAddInput(audioInput) else {
                throw NoteVideoRecorderError.microphoneUnavailable
            }
            captureSession.addInput(audioInput)

            guard captureSession.canAddOutput(output) else {
                throw NoteVideoRecorderError.recordingUnavailable
            }
            captureSession.addOutput(output)
            captureSession.commitConfiguration()
            captureSession.startRunning()

            movieOutput = output
            session = captureSession
            isReady = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startRecording(for noteID: NoteItem.ID, store: NotesStore) {
        guard let movieOutput, isReady, !movieOutput.isRecording else { return }
        do {
            let destination = try store.prepareVideoAttachmentDestination(for: noteID)
            let delegate = NoteVideoRecordingDelegate { [weak self] url, error in
                self?.finishRecording(outputURL: url, error: error)
            }
            pendingURL = destination
            pendingNoteID = noteID
            pendingStore = store
            recordingDelegate = delegate
            shouldDiscardRecording = false
            startedAt = Date()
            isRecording = true
            lastSavedURL = nil
            lastError = nil
            movieOutput.startRecording(to: destination, recordingDelegate: delegate)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopRecording() {
        guard let movieOutput, movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    func cancelRecording() {
        shouldDiscardRecording = true
        if let movieOutput, movieOutput.isRecording {
            movieOutput.stopRecording()
        } else if let pendingURL {
            pendingStore?.discardAttachmentFile(at: pendingURL)
            clearRecordingState()
        }
    }

    func teardown() {
        if isRecording {
            cancelRecording()
        }
        session?.stopRunning()
        session = nil
        movieOutput = nil
        isReady = false
    }

    private func finishRecording(outputURL: URL, error: Error?) {
        let url = pendingURL ?? outputURL
        let noteID = pendingNoteID
        let store = pendingStore
        let started = startedAt ?? Date()
        let shouldDiscard = shouldDiscardRecording
        clearRecordingState()

        guard !shouldDiscard else {
            store?.discardAttachmentFile(at: url)
            return
        }

        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
            ?? (error == nil)
        guard finished else {
            store?.discardAttachmentFile(at: url)
            lastError = error?.localizedDescription ?? NoteVideoRecorderError.recordingFailed.localizedDescription
            return
        }
        guard let noteID, let store else {
            store?.discardAttachmentFile(at: url)
            return
        }
        store.finishVideoRecording(at: url, for: noteID, startedAt: started)
        lastSavedURL = url
    }

    private func clearRecordingState() {
        isRecording = false
        startedAt = nil
        shouldDiscardRecording = false
        recordingDelegate = nil
        pendingURL = nil
        pendingNoteID = nil
        pendingStore = nil
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

private final class NoteVideoRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let onFinish: @MainActor @Sendable (URL, Error?) -> Void

    init(onFinish: @escaping @MainActor @Sendable (URL, Error?) -> Void) {
        self.onFinish = onFinish
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let onFinish = onFinish
        Task { @MainActor in
            onFinish(outputFileURL, error)
        }
    }
}

private enum NoteVideoRecorderError: LocalizedError {
    case cameraDenied
    case microphoneDenied
    case cameraUnavailable
    case microphoneUnavailable
    case recordingUnavailable
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .cameraDenied:
            "Camera access is required to record video journals."
        case .microphoneDenied:
            "Microphone access is required to record video journals."
        case .cameraUnavailable:
            "No camera is available for video journals."
        case .microphoneUnavailable:
            "No microphone is available for video journals."
        case .recordingUnavailable:
            "Video recording is not available."
        case .recordingFailed:
            "Video journal recording could not be saved."
        }
    }
}

private struct RecordingTimerView: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(recordingText(now: context.date), systemImage: "record.circle")
                .foregroundStyle(.red)
        }
    }

    private func recordingText(now: Date) -> String {
        guard let startedAt else { return "Recording" }
        let seconds = max(Int(now.timeIntervalSince(startedAt)), 0)
        return String(format: "Recording %d:%02d", seconds / 60, seconds % 60)
    }
}

private let noteInlineImageIDAttribute = NSAttributedString.Key("WorkbenchNoteInlineImageID")
private let noteInlineImageDisplayWidthAttribute = NSAttributedString.Key("WorkbenchNoteInlineImageDisplayWidth")

private enum NoteTextStyle {
    case header
    case body

    var font: NSFont {
        switch self {
        case .header:
            NSFont.boldSystemFont(ofSize: 22)
        case .body:
            NSFont.systemFont(ofSize: NSFont.systemFontSize)
        }
    }
}

private enum NoteListStyle {
    case bullet
    case numbered

    var emptyPrefix: String {
        switch self {
        case .bullet: "• "
        case .numbered: "1. "
        }
    }
}

@Observable
@MainActor
private final class NoteEditorBridge {
    @ObservationIgnored weak var textView: PasteAwareNSTextView?
    var selectedImageID: UUID?

    func toggleBold() {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = (textView.typingAttributes[.font] as? NSFont)
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            textView.typingAttributes[.font] = toggledBoldFont(font)
            return
        }

        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            storage.addAttribute(.font, value: toggledBoldFont(font), range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    func applyTextStyle(_ style: NoteTextStyle) {
        guard let textView else { return }
        let range = paragraphRange(in: textView)
        if range.length == 0 {
            textView.typingAttributes[.font] = style.font
            return
        }
        textView.textStorage?.addAttribute(.font, value: style.font, range: range)
        textView.didChangeText()
    }

    func applyListStyle(_ style: NoteListStyle) {
        guard let textView else { return }
        guard let storage = textView.textStorage, storage.length > 0 else {
            textView.insertText(style.emptyPrefix, replacementRange: textView.selectedRange())
            return
        }

        let selectedRange = textView.selectedRange()
        let string = textView.string as NSString
        let range = paragraphRange(in: textView)
        let paragraphRanges = paragraphRanges(in: string, covering: range)
        guard !paragraphRanges.isEmpty else { return }

        let shouldRemove = paragraphRanges.allSatisfy { paragraphRange in
            existingListMarker(in: string, paragraphRange: paragraphRange)?.style == style
        }

        var numberedIndex = 1
        var edits: [(range: NSRange, replacement: NSAttributedString)] = []
        for paragraphRange in paragraphRanges {
            let marker = existingListMarker(in: string, paragraphRange: paragraphRange)
            if shouldRemove, let marker {
                edits.append((marker.range, NSAttributedString(string: "")))
                continue
            }

            let prefix: String
            switch style {
            case .bullet:
                prefix = "• "
            case .numbered:
                prefix = "\(numberedIndex). "
                numberedIndex += 1
            }

            let attributes = attributesForListMarker(
                at: paragraphRange.location,
                storage: storage,
                textView: textView
            )
            let replacement = NSAttributedString(string: prefix, attributes: attributes)
            if let marker {
                edits.append((marker.range, replacement))
            } else {
                edits.append((
                    NSRange(location: paragraphRange.location, length: 0),
                    replacement
                ))
            }
        }

        applyListEdits(edits, to: storage)
        textView.setSelectedRange(adjustedSelection(selectedRange, after: edits, finalLength: storage.length))
        textView.didChangeText()
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        guard let textView else { return }
        let range = paragraphRange(in: textView)
        if range.length == 0 {
            let paragraphStyle = mutableParagraphStyle(
                from: textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
            )
            paragraphStyle.alignment = alignment
            textView.typingAttributes[.paragraphStyle] = paragraphStyle
            return
        }

        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            let paragraphStyle = mutableParagraphStyle(from: value as? NSParagraphStyle)
            paragraphStyle.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    @discardableResult
    func updateSelection(from textView: NSTextView) -> UUID? {
        guard let storage = textView.textStorage, storage.length > 0 else {
            selectedImageID = nil
            return nil
        }

        let selection = textView.selectedRange()
        var candidateLocations: [Int] = []
        if selection.location < storage.length {
            candidateLocations.append(selection.location)
        }
        if selection.length > 0 {
            let last = min(selection.location + selection.length - 1, storage.length - 1)
            candidateLocations.append(last)
        } else if selection.location > 0 {
            candidateLocations.append(selection.location - 1)
        }

        for location in candidateLocations where location >= 0 && location < storage.length {
            let attributes = storage.attributes(at: location, effectiveRange: nil)
            if attributes[.attachment] != nil,
               let idString = attributes[noteInlineImageIDAttribute] as? String,
               let id = UUID(uuidString: idString) {
                selectedImageID = id
                return id
            }
        }
        selectedImageID = nil
        return nil
    }

    private func paragraphRange(in textView: NSTextView) -> NSRange {
        let string = textView.string as NSString
        guard string.length > 0 else { return NSRange(location: 0, length: 0) }
        let selection = textView.selectedRange()
        let location = min(selection.location, string.length)
        let length = min(selection.length, string.length - location)
        return string.paragraphRange(for: NSRange(location: location, length: length))
    }

    private func paragraphRanges(in string: NSString, covering range: NSRange) -> [NSRange] {
        guard string.length > 0 else { return [] }
        var result: [NSRange] = []
        var cursor = min(range.location, string.length - 1)
        let end = min(NSMaxRange(range), string.length)
        repeat {
            let paragraphRange = string.paragraphRange(for: NSRange(location: cursor, length: 0))
            result.append(paragraphRange)
            let next = NSMaxRange(paragraphRange)
            guard next > cursor else { break }
            cursor = next
        } while cursor < end
        return result
    }

    private func existingListMarker(
        in string: NSString,
        paragraphRange: NSRange
    ) -> (style: NoteListStyle, range: NSRange)? {
        let paragraphStart = paragraphRange.location
        let paragraphEnd = NSMaxRange(paragraphRange)
        guard paragraphStart < paragraphEnd else { return nil }

        if paragraphEnd - paragraphStart >= 2,
           string.substring(with: NSRange(location: paragraphStart, length: 2)) == "• " {
            return (.bullet, NSRange(location: paragraphStart, length: 2))
        }

        var cursor = paragraphStart
        while cursor < paragraphEnd,
              let scalar = UnicodeScalar(string.character(at: cursor)),
              CharacterSet.decimalDigits.contains(scalar) {
            cursor += 1
        }
        guard cursor > paragraphStart,
              cursor + 1 < paragraphEnd else {
            return nil
        }

        let punctuation = string.character(at: cursor)
        let spacer = string.character(at: cursor + 1)
        guard (punctuation == 46 || punctuation == 41),
              spacer == 32 || spacer == 9 else {
            return nil
        }

        var markerEnd = cursor + 2
        while markerEnd < paragraphEnd {
            let character = string.character(at: markerEnd)
            guard character == 32 || character == 9 else { break }
            markerEnd += 1
        }
        return (.numbered, NSRange(location: paragraphStart, length: markerEnd - paragraphStart))
    }

    private func attributesForListMarker(
        at location: Int,
        storage: NSTextStorage,
        textView: NSTextView
    ) -> [NSAttributedString.Key: Any] {
        guard storage.length > 0 else { return textView.typingAttributes }
        let attributeLocation = min(max(location, 0), storage.length - 1)
        return storage.attributes(at: attributeLocation, effectiveRange: nil)
    }

    private func applyListEdits(
        _ edits: [(range: NSRange, replacement: NSAttributedString)],
        to storage: NSTextStorage
    ) {
        storage.beginEditing()
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        storage.endEditing()
    }

    private func adjustedSelection(
        _ selection: NSRange,
        after edits: [(range: NSRange, replacement: NSAttributedString)],
        finalLength: Int
    ) -> NSRange {
        func adjustedLocation(_ location: Int, includeInsertionAtLocation: Bool) -> Int {
            var adjusted = location
            for edit in edits {
                let replacementLength = edit.replacement.length
                let delta = replacementLength - edit.range.length
                let editEnd = NSMaxRange(edit.range)
                if editEnd < location || (includeInsertionAtLocation && edit.range.location <= location) {
                    adjusted += delta
                }
            }
            return min(max(adjusted, 0), finalLength)
        }

        let start = adjustedLocation(selection.location, includeInsertionAtLocation: true)
        let end = adjustedLocation(NSMaxRange(selection), includeInsertionAtLocation: false)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func toggledBoldFont(_ font: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        if manager.traits(of: font).contains(.boldFontMask) {
            return manager.convert(font, toNotHaveTrait: .boldFontMask)
        }
        return manager.convert(font, toHaveTrait: .boldFontMask)
    }

    private func mutableParagraphStyle(from style: NSParagraphStyle?) -> NSMutableParagraphStyle {
        if let style = style?.mutableCopy() as? NSMutableParagraphStyle {
            return style
        }
        return NSMutableParagraphStyle()
    }
}

private struct NoteBodyTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var richBodyData: Data?
    let imageAttachments: [NoteAttachment]
    let attachmentURL: (NoteAttachment) -> URL
    let bridge: NoteEditorBridge
    let canPasteAttachments: () -> Bool
    let onPasteFileURLs: ([URL]) -> [NoteAttachment]
    let onPasteImage: (NSImage) -> NoteAttachment?
    let onInlineImageIDsChanged: (Set<UUID>) -> Void
    let onResizeInlineImage: (UUID, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            richBodyData: $richBodyData,
            imageAttachments: imageAttachments,
            attachmentURL: attachmentURL,
            bridge: bridge,
            canPasteAttachments: canPasteAttachments,
            onPasteFileURLs: onPasteFileURLs,
            onPasteImage: onPasteImage,
            onInlineImageIDsChanged: onInlineImageIDsChanged,
            onResizeInlineImage: onResizeInlineImage
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = PasteAwareNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.canPasteAttachments = context.coordinator.handleCanPasteAttachments
        textView.onPasteFileURLs = context.coordinator.handlePasteFileURLs
        textView.onPasteImage = context.coordinator.handlePasteImage
        textView.onInlineImageClick = context.coordinator.handleInlineImageClick
        textView.onResizeInlineImage = context.coordinator.handleResizeInlineImage
        textView.fileURLForInlineImage = context.coordinator.fileURLForInlineImage
        textView.registerForDraggedTypes(PasteAwareNSTextView.supportedAttachmentDragTypes)
        bridge.textView = textView
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.typingAttributes = context.coordinator.typingAttributes
        context.coordinator.applyModelText(
            text,
            richBodyData: richBodyData,
            to: textView,
            availableWidth: context.coordinator.availableImageWidth(for: scrollView)
        )

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.configure(
            text: $text,
            richBodyData: $richBodyData,
            imageAttachments: imageAttachments,
            attachmentURL: attachmentURL,
            bridge: bridge,
            canPasteAttachments: canPasteAttachments,
            onPasteFileURLs: onPasteFileURLs,
            onPasteImage: onPasteImage,
            onInlineImageIDsChanged: onInlineImageIDsChanged,
            onResizeInlineImage: onResizeInlineImage
        )
        guard let textView = scrollView.documentView as? PasteAwareNSTextView else { return }
        textView.canPasteAttachments = context.coordinator.handleCanPasteAttachments
        textView.onPasteFileURLs = context.coordinator.handlePasteFileURLs
        textView.onPasteImage = context.coordinator.handlePasteImage
        textView.onInlineImageClick = context.coordinator.handleInlineImageClick
        textView.onResizeInlineImage = context.coordinator.handleResizeInlineImage
        textView.fileURLForInlineImage = context.coordinator.fileURLForInlineImage
        textView.typingAttributes = context.coordinator.typingAttributes
        bridge.textView = textView

        let availableWidth = context.coordinator.availableImageWidth(for: scrollView)
        let imageSignature = context.coordinator.imageSignature(availableWidth: availableWidth)
        if context.coordinator.renderedBody != text
            || context.coordinator.renderedRichBodyData != richBodyData
            || context.coordinator.renderedImageSignature != imageSignature {
            context.coordinator.applyModelText(
                text,
                richBodyData: richBodyData,
                to: textView,
                availableWidth: availableWidth
            )
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var richBodyData: Binding<Data?>
        var imageAttachments: [NoteAttachment]
        var attachmentURL: (NoteAttachment) -> URL
        var bridge: NoteEditorBridge
        var canPasteAttachments: () -> Bool
        var onPasteFileURLs: ([URL]) -> [NoteAttachment]
        var onPasteImage: (NSImage) -> NoteAttachment?
        var onInlineImageIDsChanged: (Set<UUID>) -> Void
        var onResizeInlineImage: (UUID, Double) -> Void
        var renderedBody: String?
        var renderedRichBodyData: Data?
        var renderedImageSignature = ""
        private var isApplyingModelText = false

        var typingAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        }

        init(
            text: Binding<String>,
            richBodyData: Binding<Data?>,
            imageAttachments: [NoteAttachment],
            attachmentURL: @escaping (NoteAttachment) -> URL,
            bridge: NoteEditorBridge,
            canPasteAttachments: @escaping () -> Bool,
            onPasteFileURLs: @escaping ([URL]) -> [NoteAttachment],
            onPasteImage: @escaping (NSImage) -> NoteAttachment?,
            onInlineImageIDsChanged: @escaping (Set<UUID>) -> Void,
            onResizeInlineImage: @escaping (UUID, Double) -> Void
        ) {
            self.text = text
            self.richBodyData = richBodyData
            self.imageAttachments = imageAttachments
            self.attachmentURL = attachmentURL
            self.bridge = bridge
            self.canPasteAttachments = canPasteAttachments
            self.onPasteFileURLs = onPasteFileURLs
            self.onPasteImage = onPasteImage
            self.onInlineImageIDsChanged = onInlineImageIDsChanged
            self.onResizeInlineImage = onResizeInlineImage
        }

        func configure(
            text: Binding<String>,
            richBodyData: Binding<Data?>,
            imageAttachments: [NoteAttachment],
            attachmentURL: @escaping (NoteAttachment) -> URL,
            bridge: NoteEditorBridge,
            canPasteAttachments: @escaping () -> Bool,
            onPasteFileURLs: @escaping ([URL]) -> [NoteAttachment],
            onPasteImage: @escaping (NSImage) -> NoteAttachment?,
            onInlineImageIDsChanged: @escaping (Set<UUID>) -> Void,
            onResizeInlineImage: @escaping (UUID, Double) -> Void
        ) {
            self.text = text
            self.richBodyData = richBodyData
            self.imageAttachments = imageAttachments
            self.attachmentURL = attachmentURL
            self.bridge = bridge
            self.canPasteAttachments = canPasteAttachments
            self.onPasteFileURLs = onPasteFileURLs
            self.onPasteImage = onPasteImage
            self.onInlineImageIDsChanged = onInlineImageIDsChanged
            self.onResizeInlineImage = onResizeInlineImage
        }

        func handleCanPasteAttachments() -> Bool {
            canPasteAttachments()
        }

        @MainActor
        func handleInlineImageClick(_ id: UUID, in textView: PasteAwareNSTextView) {
            bridge.selectedImageID = id
            updateInlineImageControls(in: textView, selectedID: id)
        }

        @MainActor
        func fileURLForInlineImage(_ id: UUID) -> URL? {
            guard let attachment = imageAttachments.first(where: { $0.id == id && $0.kind == .image }) else {
                return nil
            }
            return attachmentURL(attachment)
        }

        @MainActor
        func handleResizeInlineImage(_ id: UUID, width: Double) {
            if let index = imageAttachments.firstIndex(where: { $0.id == id }) {
                imageAttachments[index].displayWidth = width
            }
            onResizeInlineImage(id, width)
        }

        @MainActor
        func handlePasteFileURLs(_ urls: [URL], into textView: PasteAwareNSTextView) -> Bool {
            let attachments = onPasteFileURLs(urls)
            guard !attachments.isEmpty else { return false }
            insertInlineImages(
                attachments.filter { $0.kind == .image }.map { ($0, Optional<NSImage>.none) },
                into: textView
            )
            return true
        }

        @MainActor
        func handlePasteImage(_ image: NSImage, into textView: PasteAwareNSTextView) -> Bool {
            guard let attachment = onPasteImage(image) else { return false }
            insertInlineImages([(attachment, image)], into: textView)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModelText,
                  let textView = notification.object as? NSTextView,
                  let attributedText = textView.textStorage else {
                return
            }
            let body = serializeBody(from: attributedText)
            let archivedData = archiveRichBodyData(from: attributedText)
            renderedBody = body
            renderedRichBodyData = archivedData
            text.wrappedValue = body
            richBodyData.wrappedValue = archivedData
            onInlineImageIDsChanged(inlineImageIDs(in: attributedText))
            updateSelectedInlineImage(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? PasteAwareNSTextView else { return }
            updateSelectedInlineImage(from: textView)
        }

        @MainActor
        func applyModelText(
            _ body: String,
            richBodyData: Data?,
            to textView: NSTextView,
            availableWidth: CGFloat
        ) {
            let selectedRange = textView.selectedRange()
            isApplyingModelText = true
            textView.textStorage?.setAttributedString(
                attributedBody(
                    for: body,
                    richBodyData: richBodyData,
                    availableWidth: availableWidth
                )
            )
            textView.typingAttributes = typingAttributes
            textView.setSelectedRange(clamped(selectedRange, length: textView.string.utf16.count))
            isApplyingModelText = false
            renderedBody = body
            renderedRichBodyData = richBodyData
            renderedImageSignature = imageSignature(availableWidth: availableWidth)
            updateSelectedInlineImage(from: textView)
        }

        @MainActor
        func availableImageWidth(for scrollView: NSScrollView) -> CGFloat {
            let inset = (scrollView.documentView as? NSTextView)?.textContainerInset.width ?? 20
            return max(160, min(620, scrollView.contentSize.width - inset * 2 - 12))
        }

        func imageSignature(availableWidth: CGFloat) -> String {
            let ids = imageAttachments
                .map {
                    [
                        $0.id.uuidString,
                        $0.filename,
                        String($0.displayWidth ?? 0),
                        String($0.updatedAt?.timeIntervalSinceReferenceDate ?? 0),
                    ].joined(separator: ":")
                }
                .joined(separator: "|")
            return "\(Int(availableWidth))|\(ids)"
        }

        @MainActor
        private func updateSelectedInlineImage(from textView: NSTextView) {
            let selectedID = bridge.updateSelection(from: textView)
            if let textView = textView as? PasteAwareNSTextView {
                updateInlineImageControls(in: textView, selectedID: selectedID)
            }
        }

        @MainActor
        private func updateInlineImageControls(
            in textView: PasteAwareNSTextView,
            selectedID: UUID?
        ) {
            guard let selectedID,
                  let attachment = imageAttachments.first(where: { $0.id == selectedID }),
                  let imageFrame = textView.inlineImageFrame(for: selectedID) else {
                textView.showInlineImageControls(nil)
                return
            }

            textView.showInlineImageControls(PasteAwareNSTextView.InlineImageSelection(
                id: selectedID,
                imageFrame: imageFrame,
                width: attachment.displayWidth ?? Double(imageFrame.width),
                minimumWidth: 120,
                maximumWidth: 760
            ))
        }

        @MainActor
        private func attributedBody(
            for body: String,
            richBodyData: Data?,
            availableWidth: CGFloat
        ) -> NSAttributedString {
            if let richBodyData,
               let attributedText = unarchiveRichBodyData(richBodyData) {
                let refreshed = refreshingInlineImages(
                    in: attributedText,
                    availableWidth: availableWidth
                )
                return appendingMissingInlineImages(
                    from: body,
                    to: refreshed,
                    availableWidth: availableWidth
                )
            }
            return attributedBodyFromMarkup(for: body, availableWidth: availableWidth)
        }

        @MainActor
        private func attributedBodyFromMarkup(for body: String, availableWidth: CGFloat) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            let nsBody = body as NSString
            var cursor = 0
            for match in NoteInlineAttachmentMarkup.imageMarkerMatches(in: body) {
                if match.range.location > cursor {
                    let textRange = NSRange(location: cursor, length: match.range.location - cursor)
                    result.append(NSAttributedString(
                        string: nsBody.substring(with: textRange),
                        attributes: typingAttributes
                    ))
                }

                if let attachment = imageAttachments.first(where: { $0.id == match.id }) {
                    result.append(inlineImageString(
                        for: attachment,
                        image: nil,
                        availableWidth: availableWidth
                    ))
                } else {
                    result.append(NSAttributedString(
                        string: nsBody.substring(with: match.range),
                        attributes: typingAttributes
                    ))
                }
                cursor = NSMaxRange(match.range)
            }

            if cursor < nsBody.length {
                result.append(NSAttributedString(
                    string: nsBody.substring(from: cursor),
                    attributes: typingAttributes
                ))
            }
            return result
        }

        @MainActor
        private func refreshingInlineImages(
            in attributedText: NSAttributedString,
            availableWidth: CGFloat
        ) -> NSAttributedString {
            let mutable = NSMutableAttributedString(attributedString: attributedText)
            var replacements: [(NSRange, NSAttributedString)] = []
            var cursor = 0
            while cursor < mutable.length {
                var range = NSRange(location: 0, length: 0)
                let attributes = mutable.attributes(at: cursor, effectiveRange: &range)
                if attributes[.attachment] != nil,
                   let idString = attributes[noteInlineImageIDAttribute] as? String,
                   let id = UUID(uuidString: idString),
                   let attachment = imageAttachments.first(where: { $0.id == id }) {
                    replacements.append((
                        range,
                        inlineImageString(
                            for: attachment,
                            image: nil,
                            availableWidth: availableWidth
                        )
                    ))
                }
                cursor = NSMaxRange(range)
            }

            for replacement in replacements.reversed() {
                mutable.replaceCharacters(in: replacement.0, with: replacement.1)
            }
            return mutable
        }

        @MainActor
        private func appendingMissingInlineImages(
            from body: String,
            to attributedText: NSAttributedString,
            availableWidth: CGFloat
        ) -> NSAttributedString {
            let existingIDs = inlineImageIDs(in: attributedText)
            let missingIDs = NoteInlineAttachmentMarkup.imageMarkerMatches(in: body)
                .map(\.id)
                .filter { !existingIDs.contains($0) }
            guard !missingIDs.isEmpty else { return attributedText }

            let mutable = NSMutableAttributedString(attributedString: attributedText)
            if mutable.length > 0 {
                mutable.append(NSAttributedString(string: "\n\n", attributes: typingAttributes))
            }
            for (index, id) in missingIDs.enumerated() {
                if index > 0 {
                    mutable.append(NSAttributedString(string: "\n\n", attributes: typingAttributes))
                }
                if let attachment = imageAttachments.first(where: { $0.id == id }) {
                    mutable.append(inlineImageString(
                        for: attachment,
                        image: nil,
                        availableWidth: availableWidth
                    ))
                }
            }
            return mutable
        }

        @MainActor
        private func insertInlineImages(
            _ images: [(attachment: NoteAttachment, image: NSImage?)],
            into textView: NSTextView
        ) {
            guard !images.isEmpty else { return }
            let availableWidth = max(
                160,
                min(620, textView.bounds.width - textView.textContainerInset.width * 2 - 12)
            )
            let insertion = NSMutableAttributedString(string: "")
            let selectedRange = textView.selectedRange()
            let currentText = textView.string as NSString
            if selectedRange.location > 0,
               selectedRange.location <= currentText.length,
               currentText.substring(with: NSRange(location: selectedRange.location - 1, length: 1)) != "\n" {
                insertion.append(NSAttributedString(string: "\n", attributes: typingAttributes))
            }

            for (index, item) in images.enumerated() {
                if index > 0 {
                    insertion.append(NSAttributedString(string: "\n\n", attributes: typingAttributes))
                }
                insertion.append(inlineImageString(
                    for: item.attachment,
                    image: item.image,
                    availableWidth: availableWidth
                ))
            }
            insertion.append(NSAttributedString(string: "\n", attributes: typingAttributes))
            textView.insertText(insertion, replacementRange: selectedRange)
        }

        @MainActor
        private func inlineImageString(
            for attachment: NoteAttachment,
            image: NSImage?,
            availableWidth: CGFloat
        ) -> NSAttributedString {
            let requestedWidth = CGFloat(attachment.displayWidth ?? Double(min(availableWidth, 520)))
            let maxImageWidth = min(max(requestedWidth, 80), max(availableWidth, 80))
            let sourceImage = image ?? NSImage(contentsOf: attachmentURL(attachment))
            let displayImage = sourceImage.map {
                Self.scaledImage($0, maxWidth: maxImageWidth, maxHeight: 720)
            } ?? NSWorkspace.shared.icon(forFile: attachmentURL(attachment).path)
            let textAttachment = NSTextAttachment()
            textAttachment.attachmentCell = NSTextAttachmentCell(imageCell: displayImage)

            let attributed = NSMutableAttributedString(attachment: textAttachment)
            attributed.addAttribute(
                noteInlineImageIDAttribute,
                value: attachment.id.uuidString,
                range: NSRange(location: 0, length: attributed.length)
            )
            attributed.addAttribute(
                noteInlineImageDisplayWidthAttribute,
                value: Double(displayImage.size.width),
                range: NSRange(location: 0, length: attributed.length)
            )
            return attributed
        }

        private func serializeBody(from attributedText: NSAttributedString) -> String {
            guard attributedText.length > 0 else { return "" }
            let nsString = attributedText.string as NSString
            var result = ""
            var cursor = 0
            while cursor < attributedText.length {
                var range = NSRange(location: 0, length: 0)
                let attributes = attributedText.attributes(at: cursor, effectiveRange: &range)
                if attributes[.attachment] != nil {
                    if let idString = attributes[noteInlineImageIDAttribute] as? String,
                       let id = UUID(uuidString: idString) {
                        result += NoteInlineAttachmentMarkup.marker(for: id)
                    }
                } else {
                    result += nsString
                        .substring(with: range)
                        .replacingOccurrences(of: "\u{fffc}", with: "")
                }
                cursor = NSMaxRange(range)
            }
            return result
        }

        private func archiveRichBodyData(from attributedText: NSAttributedString) -> Data? {
            try? NSKeyedArchiver.archivedData(
                withRootObject: NSAttributedString(attributedString: attributedText),
                requiringSecureCoding: false
            )
        }

        private func unarchiveRichBodyData(_ data: Data) -> NSAttributedString? {
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
                return nil
            }
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString
        }

        private func inlineImageIDs(in attributedText: NSAttributedString) -> Set<UUID> {
            guard attributedText.length > 0 else { return [] }
            var ids = Set<UUID>()
            var cursor = 0
            while cursor < attributedText.length {
                var range = NSRange(location: 0, length: 0)
                let attributes = attributedText.attributes(at: cursor, effectiveRange: &range)
                if attributes[.attachment] != nil,
                   let idString = attributes[noteInlineImageIDAttribute] as? String,
                   let id = UUID(uuidString: idString) {
                    ids.insert(id)
                }
                cursor = NSMaxRange(range)
            }
            return ids
        }

        private func clamped(_ range: NSRange, length: Int) -> NSRange {
            guard length > 0 else { return NSRange(location: 0, length: 0) }
            let location = min(range.location, length)
            return NSRange(location: location, length: min(range.length, length - location))
        }

        @MainActor
        private static func scaledImage(_ image: NSImage, maxWidth: CGFloat, maxHeight: CGFloat) -> NSImage {
            let sourceSize = image.size
            guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
            let scale = min(maxWidth / sourceSize.width, maxHeight / sourceSize.height)
            let targetSize = NSSize(
                width: max(1, sourceSize.width * scale),
                height: max(1, sourceSize.height * scale)
            )
            let output = NSImage(size: targetSize)
            output.lockFocus()
            image.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: NSRect(origin: .zero, size: sourceSize),
                operation: .copy,
                fraction: 1
            )
            output.unlockFocus()
            return output
        }
    }
}

private final class PasteAwareNSTextView: NSTextView {
    static let supportedAttachmentDragTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.image.identifier),
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
    ]

    struct InlineImageSelection {
        let id: UUID
        let imageFrame: NSRect
        let width: Double
        let minimumWidth: Double
        let maximumWidth: Double
    }

    private struct PendingInlineImageDrag {
        let id: UUID
        let location: Int
        let mouseDownPoint: NSPoint
    }

    var canPasteAttachments: (() -> Bool)?
    var onPasteFileURLs: (@MainActor ([URL], PasteAwareNSTextView) -> Bool)?
    var onPasteImage: (@MainActor (NSImage, PasteAwareNSTextView) -> Bool)?
    var onInlineImageClick: (@MainActor (UUID, PasteAwareNSTextView) -> Void)?
    var onResizeInlineImage: (@MainActor (UUID, Double) -> Void)?
    var fileURLForInlineImage: (@MainActor (UUID) -> URL?)?
    private var inlineImageOverlay: InlineImageControlsOverlay?
    private var pendingInlineImageDrag: PendingInlineImageDrag?

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if isPasteAction(item.action), canPasteAttachments?() == true {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = inlineImageHit(at: event.locationInWindow) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: hit.location, length: 1))
            pendingInlineImageDrag = PendingInlineImageDrag(
                id: hit.id,
                location: hit.location,
                mouseDownPoint: event.locationInWindow
            )
            onInlineImageClick?(hit.id, self)
            return
        }
        pendingInlineImageDrag = nil
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pendingInlineImageDrag else {
            super.mouseDragged(with: event)
            return
        }

        let dx = event.locationInWindow.x - pendingInlineImageDrag.mouseDownPoint.x
        let dy = event.locationInWindow.y - pendingInlineImageDrag.mouseDownPoint.y
        guard hypot(dx, dy) >= 3 else { return }
        beginInlineImageDrag(pendingInlineImageDrag, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pendingInlineImageDrag != nil {
            pendingInlineImageDrag = nil
            return
        }
        super.mouseUp(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hasDraggedAttachmentContent(in: sender.draggingPasteboard)
            ? .copy
            : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hasDraggedAttachmentContent(in: sender.draggingPasteboard)
            ? .copy
            : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        hasDraggedAttachmentContent(in: sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls = NotesStore.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            moveInsertionPoint(to: sender.draggingLocation)
            return onPasteFileURLs?(urls, self) == true
        }

        let images = NotesStore.images(from: pasteboard)
        if !images.isEmpty {
            moveInsertionPoint(to: sender.draggingLocation)
            return pasteImages(images)
        }

        return super.performDragOperation(sender)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        pendingInlineImageDrag = nil
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let urls = NotesStore.fileURLs(from: pasteboard)
        if !urls.isEmpty, onPasteFileURLs?(urls, self) == true {
            return
        }
        let images = NotesStore.images(from: pasteboard)
        if !images.isEmpty, pasteImages(images) {
            return
        }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if pasteInlineAttachmentIfAvailable() {
            return
        }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        if pasteInlineAttachmentIfAvailable() {
            return
        }
        super.pasteAsRichText(sender)
    }

    func showInlineImageControls(_ selection: InlineImageSelection?) {
        guard let selection else {
            inlineImageOverlay?.removeFromSuperview()
            inlineImageOverlay = nil
            return
        }

        let overlayFrame = selection.imageFrame.insetBy(dx: -8, dy: -8)

        let localImageFrame = selection.imageFrame.offsetBy(
            dx: -overlayFrame.minX,
            dy: -overlayFrame.minY
        )
        let overlaySelection = InlineImageControlsOverlay.Selection(
            id: selection.id,
            imageFrame: localImageFrame,
            width: selection.width,
            minimumWidth: selection.minimumWidth,
            maximumWidth: selection.maximumWidth
        )

        if let inlineImageOverlay {
            inlineImageOverlay.frame = overlayFrame.integral
            inlineImageOverlay.update(selection: overlaySelection)
        } else {
            let overlay = InlineImageControlsOverlay(
                frame: overlayFrame.integral,
                selection: overlaySelection,
                isFlipped: isFlipped
            )
            overlay.onResize = { [weak self] id, width in
                self?.onResizeInlineImage?(id, width)
            }
            addSubview(overlay)
            inlineImageOverlay = overlay
        }
    }

    func inlineImageFrame(for id: UUID) -> NSRect? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        var result: NSRect?
        textStorage.enumerateAttribute(
            noteInlineImageIDAttribute,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, range, stop in
            guard (value as? String) == id.uuidString,
                  let frame = self.attachmentFrame(at: range.location) else {
                return
            }
            result = frame
            stop.pointee = true
        }
        return result
    }

    private func pasteInlineAttachmentIfAvailable() -> Bool {
        let pasteboard = NSPasteboard.general
        let urls = NotesStore.fileURLs(from: pasteboard)
        if !urls.isEmpty, onPasteFileURLs?(urls, self) == true {
            return true
        }
        let images = NotesStore.images(from: pasteboard)
        if !images.isEmpty, pasteImages(images) {
            return true
        }
        return false
    }

    private func isPasteAction(_ action: Selector?) -> Bool {
        guard let action else { return false }
        return action == #selector(paste(_:))
            || action == #selector(pasteAsPlainText(_:))
            || action == #selector(pasteAsRichText(_:))
    }

    private func hasDraggedAttachmentContent(in pasteboard: NSPasteboard) -> Bool {
        !NotesStore.fileURLs(from: pasteboard).isEmpty || !NotesStore.images(from: pasteboard).isEmpty
    }

    private func pasteImages(_ images: [NSImage]) -> Bool {
        var didPaste = false
        for image in images {
            if onPasteImage?(image, self) == true {
                didPaste = true
            }
        }
        return didPaste
    }

    private func beginInlineImageDrag(_ pending: PendingInlineImageDrag, with event: NSEvent) {
        guard let fileURL = fileURLForInlineImage?(pending.id) else {
            pendingInlineImageDrag = nil
            return
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let image = NSImage(contentsOf: fileURL) ?? NSWorkspace.shared.icon(forFile: fileURL.path)
        let fallbackOrigin = convert(event.locationInWindow, from: nil)
        let draggingFrame = inlineImageFrame(for: pending.id) ?? NSRect(
            x: fallbackOrigin.x - 48,
            y: fallbackOrigin.y - 48,
            width: 96,
            height: 96
        )
        draggingItem.setDraggingFrame(draggingFrame, contents: image)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        pendingInlineImageDrag = nil
    }

    private func moveInsertionPoint(to windowPoint: NSPoint) {
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: insertionLocation(at: windowPoint), length: 0))
    }

    private func insertionLocation(at windowPoint: NSPoint) -> Int {
        guard let layoutManager, let textContainer, let textStorage else {
            return string.utf16.count
        }
        guard textStorage.length > 0 else { return 0 }

        let viewPoint = convert(windowPoint, from: nil)
        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        layoutManager.ensureLayout(for: textContainer)

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let insertionIndex = characterIndex + (fraction > 0.5 ? 1 : 0)
        return min(max(insertionIndex, 0), textStorage.length)
    }

    private func inlineImageHit(at windowPoint: NSPoint) -> (id: UUID, location: Int)? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
            return nil
        }

        let viewPoint = convert(windowPoint, from: nil)
        layoutManager.ensureLayout(for: textContainer)
        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let candidateLocations = [characterIndex, characterIndex - 1, characterIndex + 1]

        for location in candidateLocations where location >= 0 && location < textStorage.length {
            guard let id = inlineImageID(at: location),
                  let frame = attachmentFrame(at: location),
                  frame.insetBy(dx: -8, dy: -8).contains(viewPoint) else {
                continue
            }
            return (id, location)
        }
        return nil
    }

    private func inlineImageID(at location: Int) -> UUID? {
        guard let textStorage, location >= 0, location < textStorage.length else { return nil }
        let attributes = textStorage.attributes(at: location, effectiveRange: nil)
        guard attributes[.attachment] != nil,
              let idString = attributes[noteInlineImageIDAttribute] as? String else {
            return nil
        }
        return UUID(uuidString: idString)
    }

    private func attachmentFrame(at location: Int) -> NSRect? {
        guard let layoutManager, let textContainer, let textStorage,
              location >= 0, location < textStorage.length else {
            return nil
        }

        let characterRange = NSRange(location: location, length: 1)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.location != NSNotFound else { return nil }

        var frame = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if let attachment = textStorage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment,
           let attachmentCell = attachment.attachmentCell {
            let cellSize = attachmentCell.cellSize()
            if frame.width < cellSize.width * 0.5 || frame.height < cellSize.height * 0.5 {
                let lineFrame = layoutManager.lineFragmentUsedRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
                let glyphLocation = layoutManager.location(forGlyphAt: glyphRange.location)
                frame = NSRect(
                    x: lineFrame.minX + glyphLocation.x,
                    y: lineFrame.minY + max(0, lineFrame.height - cellSize.height) / 2,
                    width: cellSize.width,
                    height: cellSize.height
                )
            }
        }

        frame.origin.x += textContainerOrigin.x
        frame.origin.y += textContainerOrigin.y
        return frame.integral
    }
}

private final class InlineImageControlsOverlay: NSView {
    struct Selection {
        let id: UUID
        let imageFrame: NSRect
        let width: Double
        let minimumWidth: Double
        let maximumWidth: Double
    }

    var onResize: ((UUID, Double) -> Void)?

    private var selection: Selection
    private let coordinateIsFlipped: Bool
    private let resizeHandle = InlineImageResizeHandleView()

    override var isFlipped: Bool {
        coordinateIsFlipped
    }

    init(frame: NSRect, selection: Selection, isFlipped: Bool) {
        self.selection = selection
        self.coordinateIsFlipped = isFlipped
        super.init(frame: frame)
        setupControls()
        update(selection: selection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(selection: Selection) {
        self.selection = selection
        resizeHandle.update(
            id: selection.id,
            width: selection.width,
            minimumWidth: selection.minimumWidth,
            maximumWidth: selection.maximumWidth
        )
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()

        let handleSize: CGFloat = 14
        let handleY: CGFloat
        if isFlipped {
            handleY = selection.imageFrame.maxY - handleSize / 2
        } else {
            handleY = selection.imageFrame.minY - handleSize / 2
        }
        resizeHandle.frame = NSRect(
            x: selection.imageFrame.maxX - handleSize / 2,
            y: handleY,
            width: handleSize,
            height: handleSize
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let borderRect = selection.imageFrame.insetBy(dx: -2, dy: -2)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: borderRect, xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()

        drawHandle(at: NSPoint(x: borderRect.minX, y: borderRect.minY))
        drawHandle(at: NSPoint(x: borderRect.maxX, y: borderRect.minY))
        drawHandle(at: NSPoint(x: borderRect.minX, y: borderRect.maxY))
        drawHandle(at: NSPoint(x: borderRect.maxX, y: borderRect.maxY))
    }

    override func mouseDown(with event: NSEvent) {
        // Keep the text selection on the image when clicking inside the overlay.
    }

    private func setupControls() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        resizeHandle.onResize = { [weak self] id, width in
            self?.onResize?(id, width)
        }
        addSubview(resizeHandle)
    }

    private func drawHandle(at center: NSPoint) {
        let size: CGFloat = 8
        let rect = NSRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
        NSColor.controlBackgroundColor.setFill()
        NSColor.controlAccentColor.setStroke()
        let handle = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        handle.fill()
        handle.lineWidth = 1.5
        handle.stroke()
    }

}

private final class InlineImageResizeHandleView: NSView {
    var onResize: ((UUID, Double) -> Void)?

    private var id: UUID?
    private var width: Double = 120
    private var minimumWidth: Double = 120
    private var maximumWidth: Double = 760
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: Double = 120

    override var isFlipped: Bool {
        true
    }

    func update(id: UUID, width: Double, minimumWidth: Double, maximumWidth: Double) {
        self.id = id
        self.width = width
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragStartWidth = width
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id else { return }
        let delta = Double(event.locationInWindow.x - dragStartX)
        let nextWidth = min(max(dragStartWidth + delta, minimumWidth), maximumWidth)
        width = nextWidth
        onResize?(id, nextWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlAccentColor.setFill()
        let knob = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        knob.fill()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let firstLine = NSBezierPath()
        firstLine.move(to: NSPoint(x: bounds.midX + 1, y: bounds.midY - 3))
        firstLine.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY))
        firstLine.lineWidth = 1.2
        firstLine.stroke()

        let secondLine = NSBezierPath()
        secondLine.move(to: NSPoint(x: bounds.midX - 3, y: bounds.midY - 3))
        secondLine.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY + 4))
        secondLine.lineWidth = 1.2
        secondLine.stroke()
    }
}
