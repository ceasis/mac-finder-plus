import AppKit
import AVFoundation
import SwiftUI

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

                Button {
                    store.createNote(on: store.selectedDay)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help(store.selectedDay == nil ? "New note" : "New note on selected day")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Hide Notes")
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

    private var note: NoteItem? {
        store.note(for: noteID)
    }

    private var images: [NoteAttachment] {
        note?.attachments.filter { $0.kind == .image } ?? []
    }

    private var recordings: [NoteAttachment] {
        note?.attachments.filter { $0.kind == .audio } ?? []
    }

    private var hasAttachments: Bool {
        !(note?.attachments.isEmpty ?? true)
    }

    private var isRecordingThisNote: Bool {
        store.recordingNoteID == noteID
    }

    private var isRecordingAnotherNote: Bool {
        store.recordingNoteID != nil && !isRecordingThisNote
    }

    private var bodyIsEmpty: Bool {
        note?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            VStack(spacing: 0) {
                editorBody
                    .frame(minHeight: 180)

                if hasAttachments {
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
            store.addImages(urls, to: noteID)
            return true
        }
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
                    .help("Record voice note")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var editorBody: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: bodyBinding)
                .font(.body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            if bodyIsEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Start writing", systemImage: "text.alignleft")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Type a note, drop images, or record a voice memo.")
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
            Text("Drop images here")
            Spacer()
            Image(systemName: "photo.on.rectangle")
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
                Text("\(images.count + recordings.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !images.isEmpty {
                        AttachmentSectionHeader(
                            title: "Images",
                            systemImage: "photo.on.rectangle",
                            count: images.count
                        )
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 80, maximum: 110), spacing: 8)],
                            alignment: .leading,
                            spacing: 10
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
                Text("\(note.body.count) chars")
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
        return body.split { $0.isWhitespace || $0.isNewline }.count
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
                .frame(height: 86)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
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
        .padding(6)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
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
