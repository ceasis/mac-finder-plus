import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

enum NoteAttachmentKind: String, Codable, Sendable {
    case image
    case audio
}

struct NoteAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: NoteAttachmentKind
    var filename: String
    var originalName: String
    var createdAt: Date
    var duration: TimeInterval?
}

struct NoteItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var attachments: [NoteAttachment]

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }

    var preview: String {
        body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Observable
@MainActor
final class NotesStore {
    static let shared = NotesStore()

    private(set) var notes: [NoteItem] = []
    var selectedNoteID: NoteItem.ID?
    var searchText = ""
    var lastSavedAt: Date?
    var lastError: String?
    private(set) var recordingNoteID: NoteItem.ID?
    private(set) var recordingStartedAt: Date?

    @ObservationIgnored private var audioRecorder: AVAudioRecorder?
    @ObservationIgnored private var recordingFileURL: URL?

    private init() {
        load()
    }

    var filteredNotes: [NoteItem] {
        let sorted = notes.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { note in
            note.title.localizedCaseInsensitiveContains(query)
                || note.body.localizedCaseInsensitiveContains(query)
                || note.attachments.contains {
                    $0.originalName.localizedCaseInsensitiveContains(query)
                        || $0.filename.localizedCaseInsensitiveContains(query)
                }
        }
    }

    func ensureSelection() {
        if let selectedNoteID, notes.contains(where: { $0.id == selectedNoteID }) {
            return
        }
        if let first = filteredNotes.first ?? notes.first {
            selectedNoteID = first.id
        } else {
            selectedNoteID = createNote()
        }
    }

    func note(for id: NoteItem.ID?) -> NoteItem? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    func attachmentURL(for noteID: NoteItem.ID, attachment: NoteAttachment) -> URL {
        noteDirectory(noteID).appendingPathComponent(attachment.filename)
    }

    @discardableResult
    func createNote() -> NoteItem.ID {
        let now = Date()
        let note = NoteItem(
            id: UUID(),
            title: "",
            body: "",
            createdAt: now,
            updatedAt: now,
            attachments: []
        )
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        save()
        return note.id
    }

    func deleteSelectedNote() {
        guard let selectedNoteID else { return }
        deleteNote(selectedNoteID)
    }

    func deleteNote(_ id: NoteItem.ID) {
        if recordingNoteID == id {
            cancelRecording()
        }
        notes.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: noteDirectory(id))
        selectedNoteID = filteredNotes.first?.id ?? notes.first?.id
        save()
    }

    func updateTitle(_ id: NoteItem.ID, title: String) {
        updateNote(id) { note in
            note.title = title
        }
    }

    func updateBody(_ id: NoteItem.ID, body: String) {
        updateNote(id) { note in
            note.body = body
        }
    }

    func saveNow() {
        save()
    }

    func chooseAndAttachImages(to noteID: NoteItem.ID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        addImages(panel.urls, to: noteID)
    }

    func addImages(_ urls: [URL], to noteID: NoteItem.ID) {
        let imageURLs = urls.filter { url in
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                return type.conforms(to: .image)
            }
            return NSImage(contentsOf: url) != nil
        }
        guard !imageURLs.isEmpty else { return }

        do {
            try ensureStorage()
            try FileManager.default.createDirectory(
                at: noteDirectory(noteID),
                withIntermediateDirectories: true
            )
            var newAttachments: [NoteAttachment] = []
            for url in imageURLs {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let destination = uniqueAttachmentDestination(
                    noteID: noteID,
                    preferredName: url.lastPathComponent
                )
                try FileManager.default.copyItem(at: url, to: destination)
                newAttachments.append(
                    NoteAttachment(
                        id: UUID(),
                        kind: .image,
                        filename: destination.lastPathComponent,
                        originalName: url.lastPathComponent,
                        createdAt: Date(),
                        duration: nil
                    )
                )
            }
            appendAttachments(newAttachments, to: noteID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAttachment(_ attachmentID: NoteAttachment.ID, from noteID: NoteItem.ID) {
        guard let note = note(for: noteID),
              let attachment = note.attachments.first(where: { $0.id == attachmentID }) else {
            return
        }
        try? FileManager.default.removeItem(at: attachmentURL(for: noteID, attachment: attachment))
        updateNote(noteID) { note in
            note.attachments.removeAll { $0.id == attachmentID }
        }
    }

    func startRecording(for noteID: NoteItem.ID) {
        Task {
            do {
                guard try await requestMicrophoneAccess() else {
                    throw NotesStoreError.microphoneDenied
                }
                if recordingNoteID != nil {
                    stopRecording()
                }
                try ensureStorage()
                try FileManager.default.createDirectory(
                    at: noteDirectory(noteID),
                    withIntermediateDirectories: true
                )
                let destination = uniqueAttachmentDestination(
                    noteID: noteID,
                    preferredName: "Voice Recording \(recordingDateString()).m4a"
                )
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let recorder = try AVAudioRecorder(url: destination, settings: settings)
                recorder.isMeteringEnabled = true
                recorder.prepareToRecord()
                guard recorder.record() else {
                    throw NotesStoreError.recordingFailed
                }
                audioRecorder = recorder
                recordingNoteID = noteID
                recordingStartedAt = Date()
                recordingFileURL = destination
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        guard let recorder = audioRecorder,
              let noteID = recordingNoteID,
              let url = recordingFileURL else {
            return
        }
        let started = recordingStartedAt ?? Date()
        recorder.stop()
        audioRecorder = nil
        recordingNoteID = nil
        recordingStartedAt = nil
        recordingFileURL = nil

        let duration = max(Date().timeIntervalSince(started), 0)
        guard duration >= 0.3 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        appendAttachments([
            NoteAttachment(
                id: UUID(),
                kind: .audio,
                filename: url.lastPathComponent,
                originalName: "Voice Recording",
                createdAt: Date(),
                duration: duration
            ),
        ], to: noteID)
    }

    func cancelRecording() {
        let url = recordingFileURL
        audioRecorder?.stop()
        audioRecorder = nil
        recordingNoteID = nil
        recordingStartedAt = nil
        recordingFileURL = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func load() {
        do {
            try ensureStorage()
            guard FileManager.default.fileExists(atPath: notesFile.path) else {
                notes = []
                selectedNoteID = nil
                return
            }
            let data = try Data(contentsOf: notesFile)
            notes = try JSONDecoder().decode([NoteItem].self, from: data)
            selectedNoteID = notes.first?.id
            lastError = nil
        } catch {
            notes = []
            selectedNoteID = nil
            lastError = error.localizedDescription
        }
    }

    private func appendAttachments(_ attachments: [NoteAttachment], to noteID: NoteItem.ID) {
        guard !attachments.isEmpty else { return }
        updateNote(noteID) { note in
            note.attachments.append(contentsOf: attachments)
        }
    }

    private func updateNote(_ id: NoteItem.ID, mutation: (inout NoteItem) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        mutation(&notes[index])
        notes[index].updatedAt = Date()
        save()
    }

    private func save() {
        do {
            try ensureStorage()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(notes)
            try data.write(to: notesFile, options: [.atomic])
            lastSavedAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ensureStorage() throws {
        try FileManager.default.createDirectory(
            at: attachmentsDirectory,
            withIntermediateDirectories: true
        )
    }

    private var rootDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Panes/Notes", isDirectory: true)
    }

    private var notesFile: URL {
        rootDirectory.appendingPathComponent("notes.json")
    }

    private var attachmentsDirectory: URL {
        rootDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }

    private func noteDirectory(_ noteID: NoteItem.ID) -> URL {
        attachmentsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
    }

    private func uniqueAttachmentDestination(noteID: NoteItem.ID, preferredName: String) -> URL {
        let sanitized = preferredName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = sanitized.isEmpty ? "Attachment" : sanitized
        return FileOperations.uniqueDestination(
            for: noteDirectory(noteID).appendingPathComponent(filename)
        )
    }

    private func recordingDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    private func requestMicrophoneAccess() async throws -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
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

private enum NotesStoreError: LocalizedError {
    case microphoneDenied
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required to record voice notes."
        case .recordingFailed:
            "Voice recording could not be started."
        }
    }
}
