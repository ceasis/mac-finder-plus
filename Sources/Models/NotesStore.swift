import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

enum NoteAttachmentKind: String, Codable, Sendable {
    case image
    case audio
}

/// Whether a calendar day has any note, and whether those notes carry image or
/// audio attachments — drives the badges shown under each day.
struct NoteDayMarker: Equatable, Sendable {
    var hasNote = false
    var hasImage = false
    var hasAudio = false
}

/// How the notes list is sectioned for browsing by time.
enum NoteGrouping: String, CaseIterable, Identifiable, Sendable {
    case none = "All"
    case month = "Month"
    case year = "Year"

    var id: String { rawValue }
    var label: String { self == .none ? "All" : "By \(rawValue)" }
}

/// A titled section of notes (e.g. "July 2026" or "2026"). An empty title means
/// a single ungrouped list.
struct NoteGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let notes: [NoteItem]
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
    /// When set, the list and calendar focus on notes created on this day.
    var selectedDay: Date?
    /// How the notes list is sectioned (by month, by year, or a flat list).
    var grouping: NoteGrouping = .none
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
        var result = notes.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        if let selectedDay {
            let calendar = Calendar.current
            let target = calendar.startOfDay(for: selectedDay)
            result = result.filter { calendar.startOfDay(for: $0.createdAt) == target }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        return result.filter { note in
            note.title.localizedCaseInsensitiveContains(query)
                || note.body.localizedCaseInsensitiveContains(query)
                || note.attachments.contains {
                    $0.originalName.localizedCaseInsensitiveContains(query)
                        || $0.filename.localizedCaseInsensitiveContains(query)
                }
        }
    }

    /// Per-day summary used by the calendar to badge days that have notes and
    /// whether any of those notes carry image or audio attachments.
    func dayMarkers() -> [Date: NoteDayMarker] {
        let calendar = Calendar.current
        var result: [Date: NoteDayMarker] = [:]
        for note in notes {
            let day = calendar.startOfDay(for: note.createdAt)
            var marker = result[day] ?? NoteDayMarker()
            marker.hasNote = true
            if note.attachments.contains(where: { $0.kind == .image }) { marker.hasImage = true }
            if note.attachments.contains(where: { $0.kind == .audio }) { marker.hasAudio = true }
            result[day] = marker
        }
        return result
    }

    /// The notes list, sectioned by month or year when a grouping is active.
    /// A single-day calendar selection or "All" grouping yields one flat group.
    var noteGroups: [NoteGroup] {
        let notes = filteredNotes
        guard selectedDay == nil, grouping != .none else {
            return [NoteGroup(id: "all", title: "", notes: notes)]
        }
        let calendar = Calendar.current
        let components: Set<Calendar.Component> = grouping == .month ? [.year, .month] : [.year]
        let formatter = DateFormatter()
        formatter.dateFormat = grouping == .month ? "LLLL yyyy" : "yyyy"

        let buckets = Dictionary(grouping: notes) { note in
            calendar.dateComponents(components, from: note.createdAt)
        }
        return buckets.keys
            .sorted { (calendar.date(from: $0) ?? .distantPast) > (calendar.date(from: $1) ?? .distantPast) }
            .map { key in
                let date = calendar.date(from: key) ?? Date()
                let title = formatter.string(from: date)
                let sorted = (buckets[key] ?? []).sorted { $0.createdAt > $1.createdAt }
                return NoteGroup(id: title, title: title, notes: sorted)
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
    func createNote(on day: Date? = nil) -> NoteItem.ID {
        let now = Date()
        // Anchor the note to the chosen calendar day (keeping the current
        // time-of-day) so the calendar badges the right day; default to now.
        let created: Date
        if let day, !Calendar.current.isDate(day, inSameDayAs: now) {
            created = Self.combine(day: day, time: now) ?? day
        } else {
            created = now
        }
        let note = NoteItem(
            id: UUID(),
            title: "",
            body: "",
            createdAt: created,
            updatedAt: now,
            attachments: []
        )
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        save()
        return note.id
    }

    private static func combine(day: Date, time: Date) -> Date? {
        let calendar = Calendar.current
        let dayParts = calendar.dateComponents([.year, .month, .day], from: day)
        let timeParts = calendar.dateComponents([.hour, .minute, .second], from: time)
        var merged = DateComponents()
        merged.year = dayParts.year
        merged.month = dayParts.month
        merged.day = dayParts.day
        merged.hour = timeParts.hour
        merged.minute = timeParts.minute
        merged.second = timeParts.second
        return calendar.date(from: merged)
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
