import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

enum NoteAttachmentKind: String, Codable, Sendable {
    case image
    case audio
    case video
    case file
}

/// Whether a calendar day has any note, and whether those notes carry journal
/// attachments — drives the badges shown under each day.
struct NoteDayMarker: Equatable, Sendable {
    var hasNote = false
    var hasImage = false
    var hasAudio = false
    var hasVideo = false
    var hasFile = false
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
    var displayWidth: Double?
    var updatedAt: Date?
}

struct NoteItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var richBodyData: Data?
    var createdAt: Date
    var updatedAt: Date
    var attachments: [NoteAttachment]

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }

    var preview: String {
        NoteInlineAttachmentMarkup.displayText(from: body)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum NoteInlineAttachmentMarkup {
    private static let markerPattern = #"\[\[note-image:([0-9A-Fa-f-]{36})\]\]"#
    private static let markerRegex = try? NSRegularExpression(pattern: markerPattern)

    static func marker(for id: UUID) -> String {
        "[[note-image:\(id.uuidString)]]"
    }

    static func imageIDs(in body: String) -> Set<UUID> {
        Set(imageMarkerMatches(in: body).map(\.id))
    }

    @discardableResult
    static func appendMissingImageMarkers(to body: inout String, for attachments: [NoteAttachment]) -> Bool {
        let existingIDs = imageIDs(in: body)
        let missingMarkers = attachments
            .filter { $0.kind == .image && !existingIDs.contains($0.id) }
            .map { marker(for: $0.id) }
        guard !missingMarkers.isEmpty else { return false }

        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body += body.hasSuffix("\n") ? "\n" : "\n\n"
        }
        body += missingMarkers.joined(separator: "\n\n")
        return true
    }

    static func removingImageMarker(for id: UUID, from body: String) -> String {
        var result = body.replacingOccurrences(of: marker(for: id), with: "")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    static func displayText(from body: String) -> String {
        guard let markerRegex else { return body }
        let range = NSRange(location: 0, length: (body as NSString).length)
        return markerRegex
            .stringByReplacingMatches(in: body, range: range, withTemplate: "")
            .replacingOccurrences(of: "\u{fffc}", with: "")
    }

    static func imageMarkerMatches(in body: String) -> [(range: NSRange, id: UUID)] {
        guard let markerRegex else { return [] }
        let nsBody = body as NSString
        let range = NSRange(location: 0, length: nsBody.length)
        return markerRegex.matches(in: body, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let id = UUID(uuidString: nsBody.substring(with: match.range(at: 1))) else {
                return nil
            }
            return (match.range, id)
        }
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
    /// whether any of those notes carry media or file attachments.
    func dayMarkers() -> [Date: NoteDayMarker] {
        let calendar = Calendar.current
        var result: [Date: NoteDayMarker] = [:]
        for note in notes {
            let day = calendar.startOfDay(for: note.createdAt)
            var marker = result[day] ?? NoteDayMarker()
            marker.hasNote = true
            if note.attachments.contains(where: { $0.kind == .image }) { marker.hasImage = true }
            if note.attachments.contains(where: { $0.kind == .audio }) { marker.hasAudio = true }
            if note.attachments.contains(where: { $0.kind == .video }) { marker.hasVideo = true }
            if note.attachments.contains(where: { $0.kind == .file }) { marker.hasFile = true }
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
            richBodyData: nil,
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

    func updateRichBodyData(_ id: NoteItem.ID, richBodyData: Data?) {
        updateNote(id) { note in
            note.richBodyData = richBodyData
        }
    }

    func saveNow() {
        save()
    }

    func chooseAndAttachImages(to noteID: NoteItem.ID) {
        chooseAndAttachFiles(to: noteID)
    }

    func chooseAndAttachFiles(to noteID: NoteItem.ID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls, to: noteID)
    }

    func addImages(_ urls: [URL], to noteID: NoteItem.ID) {
        let imageURLs = urls.filter { url in
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                return type.conforms(to: .image)
            }
            return NSImage(contentsOf: url) != nil
        }
        addFiles(imageURLs, to: noteID)
    }

    @discardableResult
    func addFiles(
        _ urls: [URL],
        to noteID: NoteItem.ID,
        insertImageMarkers: Bool = true
    ) -> [NoteAttachment] {
        let fileURLs = urls.filter { url in
            guard url.isFileURL else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory != true
        }
        guard !fileURLs.isEmpty else { return [] }

        do {
            try ensureStorage()
            try FileManager.default.createDirectory(
                at: noteDirectory(noteID),
                withIntermediateDirectories: true
            )
            var newAttachments: [NoteAttachment] = []
            for url in fileURLs {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let kind = attachmentKind(for: url)
                let destination = uniqueAttachmentDestination(
                    noteID: noteID,
                    preferredName: url.lastPathComponent
                )
                try FileManager.default.copyItem(at: url, to: destination)
                newAttachments.append(
                    NoteAttachment(
                        id: UUID(),
                        kind: kind,
                        filename: destination.lastPathComponent,
                        originalName: url.lastPathComponent,
                        createdAt: Date(),
                        duration: nil
                    )
                )
            }
            appendAttachments(newAttachments, to: noteID, insertImageMarkers: insertImageMarkers)
            return newAttachments
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func pasteAttachments(to noteID: NoteItem.ID) {
        if !pasteAttachmentsIfAvailable(to: noteID) {
            lastError = "Clipboard does not contain an image or copied file."
        }
    }

    @discardableResult
    func pasteAttachmentsIfAvailable(to noteID: NoteItem.ID) -> Bool {
        let pasteboard = NSPasteboard.general
        let urls = Self.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            addFiles(urls, to: noteID)
            return true
        }

        let images = Self.images(from: pasteboard)
        if !images.isEmpty {
            addPastedImages(images, to: noteID)
            return true
        }

        return false
    }

    func canPasteAttachments() -> Bool {
        Self.hasAttachmentContent(in: NSPasteboard.general)
    }

    func ensureInlineImageMarkers(in noteID: NoteItem.ID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let imageAttachments = notes[index].attachments.filter { $0.kind == .image }
        guard !imageAttachments.isEmpty else { return }
        var body = notes[index].body
        guard NoteInlineAttachmentMarkup.appendMissingImageMarkers(
            to: &body,
            for: imageAttachments
        ) else {
            return
        }
        notes[index].body = body
        save()
    }

    func pruneInlineImageAttachments(in noteID: NoteItem.ID, keeping referencedIDs: Set<UUID>) {
        guard let note = note(for: noteID) else { return }
        let removals = note.attachments.filter { attachment in
            attachment.kind == .image && !referencedIDs.contains(attachment.id)
        }
        guard !removals.isEmpty else { return }

        for attachment in removals {
            try? FileManager.default.removeItem(at: attachmentURL(for: noteID, attachment: attachment))
        }
        let removalIDs = Set(removals.map(\.id))
        updateNote(noteID) { note in
            note.attachments.removeAll { removalIDs.contains($0.id) }
        }
    }

    func updateImageDisplayWidth(
        _ width: Double,
        for attachmentID: NoteAttachment.ID,
        in noteID: NoteItem.ID
    ) {
        updateNote(noteID) { note in
            guard let index = note.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                return
            }
            note.attachments[index].displayWidth = width
            note.attachments[index].updatedAt = Date()
        }
    }

    func transformImageAttachment(
        _ attachmentID: NoteAttachment.ID,
        in noteID: NoteItem.ID,
        operation: ImageProcessing.Transform
    ) {
        guard let note = note(for: noteID),
              let attachment = note.attachments.first(where: { $0.id == attachmentID }),
              attachment.kind == .image else {
            return
        }
        let url = attachmentURL(for: noteID, attachment: attachment)
        Task {
            do {
                try await ImageProcessing.transform(url, operation)
                bumpAttachmentVersion(attachmentID, in: noteID)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func replaceImageAttachmentContents(
        _ attachmentID: NoteAttachment.ID,
        in noteID: NoteItem.ID,
        with sourceURL: URL
    ) {
        guard let note = note(for: noteID),
              let attachment = note.attachments.first(where: { $0.id == attachmentID }),
              attachment.kind == .image else {
            return
        }
        let destination = attachmentURL(for: noteID, attachment: attachment)
        do {
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destination, options: [.atomic])
            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            bumpAttachmentVersion(attachmentID, in: noteID)
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
            if attachment.kind == .image {
                note.body = NoteInlineAttachmentMarkup.removingImageMarker(
                    for: attachment.id,
                    from: note.body
                )
            }
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

    func prepareVideoAttachmentDestination(for noteID: NoteItem.ID) throws -> URL {
        try ensureStorage()
        try FileManager.default.createDirectory(
            at: noteDirectory(noteID),
            withIntermediateDirectories: true
        )
        return uniqueAttachmentDestination(
            noteID: noteID,
            preferredName: "Video Journal \(recordingDateString()).mov"
        )
    }

    func finishVideoRecording(at url: URL, for noteID: NoteItem.ID, startedAt: Date) {
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        guard duration >= 0.3 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        appendAttachments([
            NoteAttachment(
                id: UUID(),
                kind: .video,
                filename: url.lastPathComponent,
                originalName: "Video Journal",
                createdAt: Date(),
                duration: duration
            ),
        ], to: noteID)
    }

    func discardAttachmentFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
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

    private func appendAttachments(
        _ attachments: [NoteAttachment],
        to noteID: NoteItem.ID,
        insertImageMarkers: Bool = false
    ) {
        guard !attachments.isEmpty else { return }
        updateNote(noteID) { note in
            note.attachments.append(contentsOf: attachments)
            if insertImageMarkers {
                NoteInlineAttachmentMarkup.appendMissingImageMarkers(
                    to: &note.body,
                    for: attachments
                )
            }
        }
    }

    private func bumpAttachmentVersion(_ attachmentID: NoteAttachment.ID, in noteID: NoteItem.ID) {
        updateNote(noteID) { note in
            guard let index = note.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                return
            }
            note.attachments[index].updatedAt = Date()
        }
    }

    @discardableResult
    func addPastedImage(
        _ image: NSImage,
        to noteID: NoteItem.ID,
        insertImageMarker: Bool = true
    ) -> NoteAttachment? {
        addPastedImages([image], to: noteID, insertImageMarker: insertImageMarker).first
    }

    @discardableResult
    func addPastedImages(
        _ images: [NSImage],
        to noteID: NoteItem.ID,
        insertImageMarker: Bool = true
    ) -> [NoteAttachment] {
        do {
            try ensureStorage()
            try FileManager.default.createDirectory(
                at: noteDirectory(noteID),
                withIntermediateDirectories: true
            )

            var attachments: [NoteAttachment] = []
            for image in images {
                guard let data = Self.pngData(for: image) else {
                    continue
                }
                let destination = uniqueAttachmentDestination(
                    noteID: noteID,
                    preferredName: "Pasted Image \(recordingDateString()).png"
                )
                try data.write(to: destination, options: [.atomic])
                attachments.append(NoteAttachment(
                    id: UUID(),
                    kind: .image,
                    filename: destination.lastPathComponent,
                    originalName: "Pasted Image",
                    createdAt: Date(),
                    duration: nil
                ))
            }

            guard !attachments.isEmpty else {
                throw NotesStoreError.pastedImageFailed
            }
            appendAttachments(attachments, to: noteID, insertImageMarkers: insertImageMarker)
            return attachments
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    private func attachmentKind(for url: URL) -> NoteAttachmentKind {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        }
        if NSImage(contentsOf: url) != nil {
            return .image
        }
        return .file
    }

    nonisolated static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) {
            urls.append(contentsOf: objects.compactMap { object in
                if let url = object as? URL, url.isFileURL {
                    return url
                }
                if let url = object as? NSURL, (url as URL).isFileURL {
                    return url as URL
                }
                return nil
            })
        }
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String],
           !paths.isEmpty {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }
        let itemURLs = pasteboard.pasteboardItems?.compactMap { item -> URL? in
            let urlTypes: [NSPasteboard.PasteboardType] = [
                .fileURL,
                .URL,
                NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            ]
            for type in urlTypes {
                if let string = item.string(forType: type),
                   let url = fileURL(from: string) {
                    return url
                }
            }
            if let paths = item.propertyList(forType: filenamesType) as? [String],
               let path = paths.first {
                return URL(fileURLWithPath: path)
            }
            return nil
        } ?? []
        urls.append(contentsOf: itemURLs)
        return uniqueFileURLs(urls)
    }

    private nonisolated static func hasAttachmentContent(in pasteboard: NSPasteboard) -> Bool {
        !fileURLs(from: pasteboard).isEmpty || !images(from: pasteboard).isEmpty
    }

    private nonisolated static func fileURL(from string: String) -> URL? {
        if let url = URL(string: string), url.isFileURL {
            return url
        }
        if string.hasPrefix("/") {
            return URL(fileURLWithPath: string)
        }
        return nil
    }

    private nonisolated static func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let key = url.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }

    nonisolated static func image(from pasteboard: NSPasteboard) -> NSImage? {
        images(from: pasteboard).first
    }

    nonisolated static func images(from pasteboard: NSPasteboard) -> [NSImage] {
        let preferredTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.heic.identifier),
        ]

        let itemImages = pasteboard.pasteboardItems?.compactMap { item -> NSImage? in
            for type in preferredTypes where item.types.contains(type) {
                if let data = item.data(forType: type),
                   let image = NSImage(data: data) {
                    return image
                }
            }
            for type in item.types where UTType(type.rawValue)?.conforms(to: .image) == true {
                if let data = item.data(forType: type),
                   let image = NSImage(data: data) {
                    return image
                }
            }
            return nil
        } ?? []
        if !itemImages.isEmpty {
            return itemImages
        }

        if let image = NSImage(pasteboard: pasteboard) {
            return [image]
        }
        for type in preferredTypes {
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data) {
                return [image]
            }
        }
        return []
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
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
    case pastedImageFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required to record voice notes."
        case .recordingFailed:
            "Voice recording could not be started."
        case .pastedImageFailed:
            "Pasted image could not be saved."
        }
    }
}
