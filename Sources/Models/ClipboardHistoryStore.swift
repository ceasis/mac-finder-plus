import AppKit
import Foundation
import Observation

enum ClipboardHistoryKind: String, Codable, Sendable {
    case text
    case names
    case paths
    case files

    var title: String {
        switch self {
        case .text: "Text"
        case .names: "Names"
        case .paths: "Paths"
        case .files: "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .names: "textformat"
        case .paths: "doc.plaintext"
        case .files: "doc.on.doc"
        }
    }
}

enum FilePasteboard {
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let promisedFileURLType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]

        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) {
            urls.append(contentsOf: objects.compactMap(fileURL(from:)))
        }

        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }

        let itemURLs = pasteboard.pasteboardItems?.flatMap { item -> [URL] in
            var itemResults: [URL] = []
            let urlTypes: [NSPasteboard.PasteboardType] = [
                .fileURL,
                .URL,
                promisedFileURLType,
            ]
            for type in urlTypes {
                if let string = item.string(forType: type),
                   let url = fileURL(from: string) {
                    itemResults.append(url)
                }
            }
            if let paths = item.propertyList(forType: filenamesType) as? [String] {
                itemResults.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
            }
            return itemResults
        } ?? []
        urls.append(contentsOf: itemURLs)

        if urls.isEmpty,
           let text = pasteboard.string(forType: .string) {
            urls.append(contentsOf: fileURLs(fromPathText: text))
        }

        return uniqueExistingFileURLs(urls)
    }

    static func write(_ urls: [URL], to pasteboard: NSPasteboard) {
        let existingURLs = uniqueExistingFileURLs(urls)
        guard !existingURLs.isEmpty else { return }
        let paths = existingURLs.map(\.path)

        pasteboard.clearContents()
        pasteboard.writeObjects(existingURLs as [NSURL])
        pasteboard.setPropertyList(paths, forType: filenamesType)
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private static func fileURL(from object: Any) -> URL? {
        if let url = object as? URL, url.isFileURL {
            return url
        }
        if let url = object as? NSURL {
            let bridgedURL = url as URL
            if bridgedURL.isFileURL {
                return bridgedURL
            }
        }
        return nil
    }

    private static func fileURL(from string: String) -> URL? {
        if let url = URL(string: string), url.isFileURL {
            return url
        }
        if string.hasPrefix("/") {
            return URL(fileURLWithPath: string)
        }
        return nil
    }

    private static func fileURLs(fromPathText text: String) -> [URL] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap(fileURL(from:))
    }

    private static func uniqueExistingFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let standardized = url.standardizedFileURL
            guard standardized.isFileURL,
                  FileManager.default.fileExists(atPath: standardized.path) else {
                return false
            }
            return seen.insert(standardized.path).inserted
        }
    }
}

struct ClipboardHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: ClipboardHistoryKind
    var title: String
    var text: String
    var paths: [String]
    var createdAt: Date

    var itemCount: Int {
        switch kind {
        case .text, .names, .paths:
            text.split(separator: "\n", omittingEmptySubsequences: false).count
        case .files:
            paths.count
        }
    }

    var detailText: String {
        kind == .files ? paths.joined(separator: "\n") : text
    }

    var fileURLs: [URL] {
        paths.map { URL(fileURLWithPath: $0) }
    }

    var existingFileURLs: [URL] {
        fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The entry as a web link, if its text is a single http/https URL. Drives
    /// the "Open URL" action so copied links can open in the default browser.
    var webURL: URL? {
        guard kind != .files else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

@Observable
@MainActor
final class ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    private(set) var entries: [ClipboardHistoryEntry] = []
    var selectedEntryID: ClipboardHistoryEntry.ID?
    var searchText = ""
    var lastError: String?

    private let maxEntries = 200
    @ObservationIgnored private var monitorTimer: Timer?
    @ObservationIgnored private var lastSeenPasteboardChangeCount = NSPasteboard.general.changeCount

    private init() {
        load()
    }

    var filteredEntries: [ClipboardHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.text.localizedCaseInsensitiveContains(query)
                || entry.paths.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func ensureSelection() {
        if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) {
            return
        }
        selectedEntryID = filteredEntries.first?.id ?? entries.first?.id
    }

    func reloadFromDisk() {
        load()
    }

    func entry(for id: ClipboardHistoryEntry.ID?) -> ClipboardHistoryEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    func copyNames(_ names: [String]) {
        let trimmed = names.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        let text = trimmed.joined(separator: "\n")
        writeTextToPasteboard(text)
        record(kind: .names, title: title(for: trimmed, fallback: "Names"), text: text, paths: [])
    }

    func copyPaths(_ paths: [String]) {
        let trimmed = paths.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        let text = trimmed.joined(separator: "\n")
        writeTextToPasteboard(text)
        record(
            kind: .paths,
            title: "\(trimmed.count) Path\(trimmed.count == 1 ? "" : "s")",
            text: text,
            paths: trimmed
        )
    }

    func copyFiles(_ urls: [URL]) {
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else { return }
        writeFilesToPasteboard(existingURLs)
        let paths = existingURLs.map(\.path)
        let names = existingURLs.map(\.lastPathComponent)
        record(
            kind: .files,
            title: title(for: names, fallback: "Files"),
            text: names.joined(separator: "\n"),
            paths: paths
        )
    }

    func copyText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        writeTextToPasteboard(text)
        record(kind: .text, title: title(forText: trimmed), text: text, paths: [])
    }

    func startMonitoring() {
        guard monitorTimer == nil else { return }
        lastSeenPasteboardChangeCount = NSPasteboard.general.changeCount
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.capturePasteboardIfChanged()
            }
        }
    }

    func captureCurrentPasteboard(reportError: Bool = true) {
        if !recordPasteboard(NSPasteboard.general), reportError {
            lastError = "The clipboard does not contain text or files."
        }
        lastSeenPasteboardChangeCount = NSPasteboard.general.changeCount
    }

    func restoreToPasteboard(_ entry: ClipboardHistoryEntry) {
        switch entry.kind {
        case .text, .names, .paths:
            writeTextToPasteboard(entry.text)
        case .files:
            writeFilesToPasteboard(entry.existingFileURLs)
        }
        selectedEntryID = entry.id
    }

    func reveal(_ entry: ClipboardHistoryEntry) {
        let urls = entry.paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func deleteSelectedEntry() {
        guard let selectedEntryID else { return }
        deleteEntry(selectedEntryID)
    }

    func deleteEntry(_ id: ClipboardHistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        selectedEntryID = filteredEntries.first?.id ?? entries.first?.id
        save()
    }

    func clear() {
        entries.removeAll()
        selectedEntryID = nil
        save()
    }

    private func record(
        kind: ClipboardHistoryKind,
        title: String,
        text: String,
        paths: [String]
    ) {
        entries.removeAll {
            $0.kind == kind && $0.text == text && $0.paths == paths
        }
        let entry = ClipboardHistoryEntry(
            id: UUID(),
            kind: kind,
            title: title,
            text: text,
            paths: paths,
            createdAt: Date()
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        selectedEntryID = entry.id
        save()
    }

    private func capturePasteboardIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastSeenPasteboardChangeCount else { return }
        lastSeenPasteboardChangeCount = pasteboard.changeCount
        _ = recordPasteboard(pasteboard)
    }

    @discardableResult
    private func recordPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        let urls = FilePasteboard.fileURLs(from: pasteboard)

        if !urls.isEmpty {
            let paths = urls.map(\.path)
            let names = urls.map(\.lastPathComponent)
            record(
                kind: .files,
                title: title(for: names, fallback: "Files"),
                text: names.joined(separator: "\n"),
                paths: paths
            )
            return true
        }

        guard let text = pasteboard.string(forType: .string) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        record(kind: .text, title: title(forText: trimmed), text: text, paths: [])
        return true
    }

    private func title(for names: [String], fallback: String) -> String {
        if names.count == 1 {
            return names[0]
        }
        return "\(names.count) \(fallback)"
    }

    private func title(forText text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return "Text" }
        if firstLine.count <= 42 {
            return firstLine
        }
        return String(firstLine.prefix(39)) + "..."
    }

    private func writeTextToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastSeenPasteboardChangeCount = NSPasteboard.general.changeCount
    }

    private func writeFilesToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        FilePasteboard.write(urls, to: pasteboard)
        lastSeenPasteboardChangeCount = pasteboard.changeCount
    }

    private func load() {
        do {
            try ensureStorage()
            guard FileManager.default.fileExists(atPath: historyFile.path) else {
                entries = []
                selectedEntryID = nil
                return
            }
            let data = try Data(contentsOf: historyFile)
            entries = try JSONDecoder().decode([ClipboardHistoryEntry].self, from: data)
            selectedEntryID = entries.first?.id
            lastError = nil
        } catch {
            entries = []
            selectedEntryID = nil
            lastError = error.localizedDescription
        }
    }

    private func save() {
        do {
            try ensureStorage()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: historyFile, options: [.atomic])
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ensureStorage() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
    }

    private var rootDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Panes/ClipboardHistory", isDirectory: true)
    }

    private var historyFile: URL {
        rootDirectory.appendingPathComponent("history.json")
    }
}
