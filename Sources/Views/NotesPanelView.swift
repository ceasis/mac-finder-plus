import AVFoundation
import SwiftUI

struct NotesPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = NotesStore.shared

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Notes", text: $store.searchText)
                        .textFieldStyle(.plain)
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
                .padding(.vertical, 8)

                Divider()

                if store.filteredNotes.isEmpty {
                    ContentUnavailableView("No Notes", systemImage: "note.text")
                } else {
                    List(selection: $store.selectedNoteID) {
                        ForEach(store.filteredNotes) { note in
                            NoteListRow(note: note)
                                .tag(note.id)
                        }
                    }
                    .listStyle(.sidebar)
                }

                Divider()

                HStack {
                    Button {
                        store.createNote()
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .help("New note")

                    Spacer()

                    Button(role: .destructive) {
                        store.deleteSelectedNote()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(store.selectedNoteID == nil)
                    .help("Delete note")
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let note = store.note(for: store.selectedNoteID) {
                NoteEditorView(store: store, noteID: note.id)
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "note.text")
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .onAppear { store.ensureSelection() }
        .alert("Notes Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}

private struct NoteListRow: View {
    let note: NoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(note.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if imageCount > 0 {
                    Label("\(imageCount)", systemImage: "photo")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                if audioCount > 0 {
                    Label("\(audioCount)", systemImage: "waveform")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }

            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var imageCount: Int {
        note.attachments.filter { $0.kind == .image }.count
    }

    private var audioCount: Int {
        note.attachments.filter { $0.kind == .audio }.count
    }
}

private struct NoteEditorView: View {
    let store: NotesStore
    let noteID: NoteItem.ID

    private var note: NoteItem? {
        store.note(for: noteID)
    }

    private var images: [NoteAttachment] {
        note?.attachments.filter { $0.kind == .image } ?? []
    }

    private var recordings: [NoteAttachment] {
        note?.attachments.filter { $0.kind == .audio } ?? []
    }

    private var isRecordingThisNote: Bool {
        store.recordingNoteID == noteID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Untitled Note", text: titleBinding)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)

                Spacer()

                Button {
                    store.saveNow()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save note")

                Button {
                    store.chooseAndAttachImages(to: noteID)
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .help("Attach images")

                if isRecordingThisNote {
                    Button {
                        store.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

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
                        Label("Record", systemImage: "mic.circle")
                    }
                    .disabled(store.recordingNoteID != nil)
                    .help("Record voice note")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: bodyBinding)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                }
                .frame(minWidth: 360)

                attachmentsPanel
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }

            Divider()

            HStack {
                if isRecordingThisNote {
                    RecordingTimerView(startedAt: store.recordingStartedAt)
                } else if let saved = store.lastSavedAt {
                    Label(saved.formatted(date: .omitted, time: .shortened), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let note {
                    Text("\(note.body.count) chars")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.addImages(urls, to: noteID)
            return true
        }
    }

    private var attachmentsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !images.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Images", systemImage: "photo.on.rectangle")
                            .font(.headline)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(images) { attachment in
                                NoteImageAttachmentView(
                                    store: store,
                                    noteID: noteID,
                                    attachment: attachment
                                )
                            }
                        }
                    }
                }

                if !recordings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Voice", systemImage: "waveform")
                            .font(.headline)
                        ForEach(recordings) { attachment in
                            NoteAudioAttachmentRow(
                                store: store,
                                noteID: noteID,
                                attachment: attachment
                            )
                        }
                    }
                }

                if images.isEmpty && recordings.isEmpty {
                    ContentUnavailableView("No Attachments", systemImage: "paperclip")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(14)
        }
        .background(.quaternary.opacity(0.18))
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
}

private struct NoteImageAttachmentView: View {
    let store: NotesStore
    let noteID: NoteItem.ID
    let attachment: NoteAttachment
    @State private var image: NSImage?

    private var url: URL {
        store.attachmentURL(for: noteID, attachment: attachment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Open image")

            HStack(spacing: 4) {
                Text(attachment.originalName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(role: .destructive) {
                    store.deleteAttachment(attachment.id, from: noteID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove image")
            }
        }
        .task(id: url) {
            image = NSImage(contentsOf: url)
        }
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
        .padding(8)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
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
