import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum SnippetKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case text
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .file: "File"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

/// One file attached to a snippet. A snippet can hold several, so files dropped
/// onto an existing snippet collect there instead of creating new snippets.
struct SnippetFile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var filename: String
    var originalName: String
    var kind: SnippetKind
    var addedAt: Date
}

enum SnippetFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .image: "Images"
        case .file: "Files"
        }
    }

    var kind: SnippetKind? {
        switch self {
        case .all: nil
        case .text: .text
        case .image: .image
        case .file: .file
        }
    }
}

enum SnippetSortOrder: String, CaseIterable, Identifiable, Sendable {
    case updated
    case created
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updated: "Recently Updated"
        case .created: "Recently Created"
        case .title: "Title"
        }
    }
}

enum SnippetFocusTarget: Sendable {
    case search
    case composer
    case editor
}

enum SnippetSearchQuery {
    static func terms(in query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var insideQuotes = false

        for character in query {
            if character == "\"" {
                insideQuotes.toggle()
                if !insideQuotes {
                    append(&terms, token: &current)
                }
            } else if character.isWhitespace && !insideQuotes {
                append(&terms, token: &current)
            } else {
                current.append(character)
            }
        }
        append(&terms, token: &current)
        return terms
    }

    static func matches(_ item: SnippetItem, query: String) -> Bool {
        let queryTerms = terms(in: query)
        guard !queryTerms.isEmpty else { return true }
        let searchableText = ([
            item.displayTitle,
            item.searchableText,
            item.originalName ?? "",
            item.filename ?? ""
        ] + item.normalizedTags + item.files.map(\.originalName))
            .joined(separator: " ")
            .localizedLowercase
        return queryTerms.allSatisfy { searchableText.contains($0.localizedLowercase) }
    }

    private static func append(_ terms: inout [String], token: inout String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            terms.append(trimmed)
        }
        token = ""
    }
}

struct SnippetItem: Identifiable, Codable, Hashable, Sendable {
    static let maximumTextBytes = 1_000_000
    static let listPreviewCharacterLimit = 240
    static let detailPreviewCharacterLimit = 20_000
    static let searchCharacterLimit = 50_000

    let id: UUID
    var kind: SnippetKind
    var title: String
    var text: String
    /// Primary asset — mirrors `files.first` for non-text snippets (legacy field).
    var filename: String?
    var originalName: String?
    var createdAt: Date
    var updatedAt: Date
    /// Every file attached to this snippet.
    var files: [SnippetFile] = []
    /// Optional to keep snippets written by older Workbench builds decodable.
    var isPinned: Bool? = nil
    var tags: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, title, text, filename, originalName, createdAt, updatedAt, files, isPinned, tags
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return originalName ?? kind.title
    }

    var preview: String {
        switch kind {
        case .text:
            let body = String(text.prefix(Self.listPreviewCharacterLimit))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = isTextTruncated(at: Self.listPreviewCharacterLimit) ? "..." : ""
            let excerpt = body + suffix
            return files.isEmpty ? excerpt : "\(excerpt) · \(files.count) file\(files.count == 1 ? "" : "s")"
        case .image, .file:
            if files.count > 1 { return "\(files.count) files" }
            return files.first?.originalName ?? originalName ?? filename ?? kind.title
        }
    }

    var detailText: String {
        String(text.prefix(Self.detailPreviewCharacterLimit))
    }

    var isDetailTextTruncated: Bool {
        isTextTruncated(at: Self.detailPreviewCharacterLimit)
    }

    var searchableText: String {
        String(text.prefix(Self.searchCharacterLimit))
    }

    var normalizedTags: [String] {
        (tags ?? []).filter { !$0.isEmpty }
    }

    private func isTextTruncated(at limit: Int) -> Bool {
        guard let boundary = text.index(
            text.startIndex,
            offsetBy: limit,
            limitedBy: text.endIndex
        ) else {
            return false
        }
        return boundary != text.endIndex
    }
}

private struct SnippetFileImportResult: Sendable {
    var files: [SnippetFile] = []
    var failures: [String] = []
}

extension SnippetItem {
    /// Custom decoding so snippets saved before multi-file support still load
    /// (their JSON has no `files` key).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(SnippetKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decode(String.self, forKey: .text)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        files = try container.decodeIfPresent([SnippetFile].self, forKey: .files) ?? []
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
    }
}

@Observable
@MainActor
final class SnippetStore {
    static let shared = SnippetStore()

    private enum PreferenceKey {
        static let filter = "snippets.filter"
        static let sortOrder = "snippets.sortOrder"
        static let showsPinnedOnly = "snippets.showsPinnedOnly"
        static let composerExpanded = "snippets.composerExpanded"
    }

    private(set) var snippets: [SnippetItem] = []
    var selectedSnippetID: SnippetItem.ID?
    var searchText = ""
    var filter: SnippetFilter {
        didSet { defaults.set(filter.rawValue, forKey: PreferenceKey.filter) }
    }
    var sortOrder: SnippetSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: PreferenceKey.sortOrder) }
    }
    var showsPinnedOnly: Bool {
        didSet { defaults.set(showsPinnedOnly, forKey: PreferenceKey.showsPinnedOnly) }
    }
    var isComposerExpanded: Bool {
        didSet { defaults.set(isComposerExpanded, forKey: PreferenceKey.composerExpanded) }
    }
    var pendingFocusTarget: SnippetFocusTarget?
    var searchFocusTick = 0
    var composerFocusTick = 0
    var editorFocusTick = 0
    var lastError: String?
    private(set) var pendingImportFileCount = 0
    private let rootDirectory: URL
    private let defaults: UserDefaults

    init(storageRoot: URL? = nil, defaults: UserDefaults = .standard) {
        rootDirectory = storageRoot ?? Self.defaultRootDirectory
        self.defaults = defaults
        filter = SnippetFilter(
            rawValue: defaults.string(forKey: PreferenceKey.filter) ?? ""
        ) ?? .all
        sortOrder = SnippetSortOrder(
            rawValue: defaults.string(forKey: PreferenceKey.sortOrder) ?? ""
        ) ?? .updated
        showsPinnedOnly = defaults.object(forKey: PreferenceKey.showsPinnedOnly) as? Bool ?? false
        isComposerExpanded = defaults.object(forKey: PreferenceKey.composerExpanded) as? Bool ?? true
        load()
    }

    var filteredSnippets: [SnippetItem] {
        return snippets
            .filter { item in
                guard let kind = filter.kind else { return true }
                return item.kind == kind
            }
            .filter { !showsPinnedOnly || ($0.isPinned ?? false) }
            .filter { item in
                SnippetSearchQuery.matches(item, query: searchText)
            }
            .sorted(by: snippetSort)
    }

    func ensureSelection() {
        let visible = filteredSnippets
        if let selectedSnippetID, visible.contains(where: { $0.id == selectedSnippetID }) {
            return
        }
        selectedSnippetID = visible.first?.id ?? snippets.first?.id
    }

    func reloadFromDisk() {
        load()
    }

    func snippet(for id: SnippetItem.ID?) -> SnippetItem? {
        guard let id else { return nil }
        return snippets.first { $0.id == id }
    }

    func assetURL(for item: SnippetItem) -> URL? {
        guard let filename = item.filename else { return nil }
        return assetsDirectory.appendingPathComponent(filename)
    }

    @discardableResult
    func addText(_ text: String, title: String? = nil) -> SnippetItem.ID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard text.utf8.count <= SnippetItem.maximumTextBytes else {
            lastError = "That text is too large for a snippet. Add it as a file instead."
            return nil
        }
        let now = Date()
        let preferredTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let item = SnippetItem(
            id: UUID(),
            kind: .text,
            title: preferredTitle.isEmpty ? self.title(forText: trimmed) : preferredTitle,
            text: text,
            filename: nil,
            originalName: nil,
            createdAt: now,
            updatedAt: now,
            files: []
        )
        insert(item)
        return item.id
    }

    func focusSearch() {
        pendingFocusTarget = .search
        searchFocusTick += 1
    }

    func focusComposer() {
        isComposerExpanded = true
        pendingFocusTarget = .composer
        composerFocusTick += 1
    }

    func focusEditor() {
        pendingFocusTarget = .editor
        editorFocusTick += 1
    }

    func selectAdjacentSnippet(offset: Int) {
        let visible = filteredSnippets
        guard !visible.isEmpty else { return }
        guard let selectedSnippetID,
              let index = visible.firstIndex(where: { $0.id == selectedSnippetID }) else {
            self.selectedSnippetID = visible.first?.id
            return
        }
        let destination = min(max(index + offset, 0), visible.count - 1)
        self.selectedSnippetID = visible[destination].id
    }

    func addCurrentClipboard() {
        let pasteboard = NSPasteboard.general
        let urls = NotesStore.fileURLs(from: pasteboard)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            addFiles(urls)
            return
        }

        if let image = NotesStore.image(from: pasteboard) {
            addImage(image, originalName: "Pasted Image")
            return
        }

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addText(text)
            return
        }

        lastError = "Clipboard does not contain text, an image, or copied files."
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.message = "Choose files to save as snippets."
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    func assetURL(for file: SnippetFile) -> URL {
        assetsDirectory.appendingPathComponent(file.filename)
    }

    private nonisolated static func importFiles(
        _ urls: [URL],
        into assetsDirectory: URL
    ) -> SnippetFileImportResult {
        var result = SnippetFileImportResult()
        do {
            try FileManager.default.createDirectory(
                at: assetsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            result.failures = urls.map { "\($0.lastPathComponent): \(error.localizedDescription)" }
            return result
        }

        for sourceURL in urls {
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            }

            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                result.failures.append("\(sourceURL.lastPathComponent): not a usable file")
                continue
            }

            let destination = importDestination(for: sourceURL, in: assetsDirectory)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                result.files.append(SnippetFile(
                    id: UUID(),
                    filename: destination.lastPathComponent,
                    originalName: sourceURL.lastPathComponent,
                    kind: snippetKind(for: destination),
                    addedAt: Date()
                ))
            } catch {
                result.failures.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    private func startFileImport(
        _ urls: [URL],
        apply: @escaping ([SnippetFile]) -> Void
    ) {
        guard !urls.isEmpty else { return }
        lastError = nil
        pendingImportFileCount += urls.count
        let destinationDirectory = assetsDirectory

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Self.importFiles(urls, into: destinationDirectory)
            }.value

            pendingImportFileCount = max(0, pendingImportFileCount - urls.count)
            if !result.files.isEmpty {
                apply(result.files)
            }
            if !result.failures.isEmpty {
                lastError = result.files.isEmpty
                    ? "No files were added. \(result.failures[0])"
                    : "Some files could not be added. \(result.failures[0])"
            } else if result.files.isEmpty {
                lastError = "No usable files were added."
            }
        }
    }

    func waitForPendingImports() async {
        while pendingImportFileCount > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// One file per snippet — used by "Choose Files…" and clipboard capture.
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        startFileImport(urls) { [self] imported in
            let now = Date()
            let added = imported.map { file in
                SnippetItem(
                    id: UUID(),
                    kind: file.kind,
                    title: file.originalName,
                    text: "",
                    filename: file.filename,
                    originalName: file.originalName,
                    createdAt: now,
                    updatedAt: now,
                    files: [file]
                )
            }
            snippets.insert(contentsOf: added, at: 0)
            selectedSnippetID = added.first?.id
            save()
        }
    }

    /// A drop onto empty space: one new labelled snippet holding every dropped file.
    func createSnippet(withFiles urls: [URL]) {
        guard !urls.isEmpty else { return }
        startFileImport(urls) { [self] imported in
            guard let first = imported.first else { return }
            let now = Date()
            var item = SnippetItem(
                id: UUID(),
                kind: first.kind,
                title: imported.count == 1 ? first.originalName : "\(imported.count) files",
                text: "",
                filename: first.filename,
                originalName: first.originalName,
                createdAt: now,
                updatedAt: now,
                files: imported
            )
            normalizePrimary(&item)
            insert(item)
        }
    }

    /// A drop onto an existing snippet: the files collect inside it.
    func addFiles(_ urls: [URL], to id: SnippetItem.ID) {
        guard !urls.isEmpty, snippets.contains(where: { $0.id == id }) else { return }
        startFileImport(urls) { [self] imported in
            guard let index = snippets.firstIndex(where: { $0.id == id }) else {
                discardImportedFiles(imported)
                return
            }
            migrateLegacyFile(&snippets[index])
            snippets[index].files.append(contentsOf: imported)
            snippets[index].updatedAt = Date()
            normalizePrimary(&snippets[index])
            selectedSnippetID = id
            save()
        }
    }

    private func discardImportedFiles(_ files: [SnippetFile]) {
        for file in files {
            try? FileManager.default.removeItem(at: assetURL(for: file))
        }
    }

    func removeFile(_ fileID: SnippetFile.ID, from id: SnippetItem.ID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }),
              let fileIndex = snippets[index].files.firstIndex(where: { $0.id == fileID }) else { return }
        let url = assetURL(for: snippets[index].files[fileIndex])
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        snippets[index].files.remove(at: fileIndex)
        // A file snippet with nothing left has no content — drop it entirely.
        if snippets[index].files.isEmpty && snippets[index].kind != .text {
            let snippetID = snippets[index].id
            snippets.removeAll { $0.id == snippetID }
            selectedSnippetID = filteredSnippets.first?.id ?? snippets.first?.id
            save()
            return
        }
        snippets[index].updatedAt = Date()
        normalizePrimary(&snippets[index])
        save()
    }

    /// Keeps the legacy primary fields in step with `files.first`.
    private func normalizePrimary(_ item: inout SnippetItem) {
        guard item.kind != .text else { return }
        if let first = item.files.first {
            item.filename = first.filename
            item.originalName = first.originalName
            item.kind = item.files.allSatisfy { $0.kind == .image } ? .image : .file
        } else {
            item.filename = nil
            item.originalName = nil
        }
    }

    /// Lifts a pre-multi-file snippet's single asset into its `files` list.
    private func migrateLegacyFile(_ item: inout SnippetItem) {
        guard item.files.isEmpty, let filename = item.filename else { return }
        item.files = [SnippetFile(
            id: UUID(),
            filename: filename,
            originalName: item.originalName ?? filename,
            kind: item.kind == .image ? .image : .file,
            addedAt: item.createdAt
        )]
    }

    func addImage(_ image: NSImage, originalName: String = "Pasted Image") {
        do {
            try ensureStorage()
            guard let data = Self.pngData(for: image) else {
                lastError = "Could not save that image."
                return
            }
            let destination = uniqueAssetDestination(
                preferredName: "\(originalName) \(dateStamp()).png"
            )
            try data.write(to: destination, options: [.atomic])
            let now = Date()
            let file = SnippetFile(
                id: UUID(),
                filename: destination.lastPathComponent,
                originalName: originalName,
                kind: .image,
                addedAt: now
            )
            insert(SnippetItem(
                id: UUID(),
                kind: .image,
                title: originalName,
                text: "",
                filename: destination.lastPathComponent,
                originalName: originalName,
                createdAt: now,
                updatedAt: now,
                files: [file]
            ))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func copy(_ item: SnippetItem) {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(item.text, forType: .string)
        case .image:
            if item.files.count > 1 {
                copyFiles(item.files, to: pasteboard)
                break
            }
            guard let url = assetURL(for: item),
                  FileManager.default.fileExists(atPath: url.path) else {
                lastError = "The image file for this snippet is missing."
                return
            }
            pasteboard.clearContents()
            if let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            } else {
                pasteboard.writeObjects([url as NSURL])
            }
            pasteboard.setString(url.path, forType: .string)
        case .file:
            let files = item.files.isEmpty
                ? assetURL(for: item).map { [$0] } ?? []
                : item.files.map(assetURL(for:))
            let existingFiles = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existingFiles.isEmpty else {
                lastError = "The file for this snippet is missing."
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(existingFiles.map { $0 as NSURL })
            pasteboard.setString(existingFiles.map(\.path).joined(separator: "\n"), forType: .string)
        }
        selectedSnippetID = item.id
    }

    func copySelectedSnippet() {
        guard let item = snippet(for: selectedSnippetID) else { return }
        copy(item)
    }

    func togglePinned(_ id: SnippetItem.ID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].isPinned = !(snippets[index].isPinned ?? false)
        snippets[index].updatedAt = Date()
        selectedSnippetID = id
        save()
    }

    func toggleSelectedSnippetPinned() {
        guard let selectedSnippetID else { return }
        togglePinned(selectedSnippetID)
    }

    func updateText(_ text: String, for id: SnippetItem.ID) {
        guard text.utf8.count <= SnippetItem.maximumTextBytes else {
            lastError = "That text is too large for a snippet. Add it as a file instead."
            return
        }
        guard let index = snippets.firstIndex(where: { $0.id == id }),
              snippets[index].kind == .text,
              snippets[index].text != text else { return }
        snippets[index].text = text
        snippets[index].updatedAt = Date()
        selectedSnippetID = id
        save()
    }

    func updateTags(_ tags: [String], for id: SnippetItem.ID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        var seen: Set<String> = []
        let normalized = tags.compactMap { value -> String? in
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return nil }
            let key = tag.localizedLowercase
            guard seen.insert(key).inserted else { return nil }
            return tag
        }
        guard snippets[index].normalizedTags != normalized else { return }
        snippets[index].tags = normalized
        snippets[index].updatedAt = Date()
        selectedSnippetID = id
        save()
    }

    @discardableResult
    func duplicate(_ id: SnippetItem.ID) -> SnippetItem.ID? {
        guard let source = snippet(for: id) else { return nil }
        do {
            try ensureStorage()
            let now = Date()
            var copiedFiles: [SnippetFile] = []
            for file in source.files {
                let sourceURL = assetURL(for: file)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
                let destination = Self.importDestination(for: sourceURL, in: assetsDirectory)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                copiedFiles.append(SnippetFile(
                    id: UUID(),
                    filename: destination.lastPathComponent,
                    originalName: file.originalName,
                    kind: file.kind,
                    addedAt: now
                ))
            }

            var copy = SnippetItem(
                id: UUID(),
                kind: source.kind,
                title: "\(source.displayTitle) Copy",
                text: source.text,
                filename: copiedFiles.first?.filename,
                originalName: copiedFiles.first?.originalName ?? source.originalName,
                createdAt: now,
                updatedAt: now,
                files: copiedFiles,
                isPinned: false,
                tags: source.normalizedTags
            )
            normalizePrimary(&copy)
            insert(copy)
            return copy.id
        } catch {
            lastError = "Could not duplicate the snippet. \(error.localizedDescription)"
            return nil
        }
    }

    func duplicateSelectedSnippet() {
        guard let selectedSnippetID else { return }
        duplicate(selectedSnippetID)
    }

    func deleteSelectedSnippet() {
        guard let selectedSnippetID else { return }
        delete(selectedSnippetID)
    }

    func updateTitle(_ title: String, for id: SnippetItem.ID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snippets[index].title != normalizedTitle else { return }
        snippets[index].title = normalizedTitle
        snippets[index].updatedAt = Date()
        selectedSnippetID = id
        save()
    }

    func dragProvider(for item: SnippetItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: item.text as NSString)
        case .image, .file:
            guard let url = assetURL(for: item),
                  FileManager.default.fileExists(atPath: url.path) else {
                return NSItemProvider(object: item.displayTitle as NSString)
            }
            let provider = NSItemProvider(contentsOf: url)
                ?? NSItemProvider(object: url as NSURL)
            provider.suggestedName = item.originalName ?? url.lastPathComponent
            return provider
        }
    }

    func reveal(_ item: SnippetItem) {
        guard let url = assetURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: SnippetItem) {
        guard let url = assetURL(for: item) else { return }
        NSWorkspace.shared.open(url)
    }

    func delete(_ id: SnippetItem.ID) {
        guard let item = snippets.first(where: { $0.id == id }) else { return }
        for file in item.files {
            let url = assetURL(for: file)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if item.files.isEmpty, let url = assetURL(for: item),
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        snippets.removeAll { $0.id == id }
        selectedSnippetID = filteredSnippets.first?.id ?? snippets.first?.id
        save()
    }

    private func insert(_ item: SnippetItem) {
        snippets.insert(item, at: 0)
        selectedSnippetID = item.id
        save()
    }

    private func copyFiles(_ files: [SnippetFile], to pasteboard: NSPasteboard) {
        let urls = files.map(assetURL(for:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            lastError = "The files for this snippet are missing."
            return
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func snippetSort(_ lhs: SnippetItem, _ rhs: SnippetItem) -> Bool {
        let lhsPinned = lhs.isPinned ?? false
        let rhsPinned = rhs.isPinned ?? false
        if lhsPinned != rhsPinned { return lhsPinned }

        switch sortOrder {
        case .updated:
            if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
            return lhs.updatedAt > rhs.updatedAt
        case .created:
            if lhs.createdAt == rhs.createdAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        case .title:
            let comparison = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            if comparison == .orderedSame { return lhs.updatedAt > rhs.updatedAt }
            return comparison == .orderedAscending
        }
    }

    private nonisolated static func snippetKind(for url: URL) -> SnippetKind {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image) ? .image : .file
        }
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) {
            return .image
        }
        return .file
    }

    private func title(forText text: String) -> String {
        let firstLine = text.prefix { !$0.isNewline }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstLine.isEmpty else { return "Text" }
        if firstLine.count <= 42 {
            return firstLine
        }
        return String(firstLine.prefix(39)) + "..."
    }

    private func uniqueAssetDestination(preferredName: String) -> URL {
        let url = URL(fileURLWithPath: preferredName)
        let rawBase = url.deletingPathExtension().lastPathComponent
        let rawExtension = url.pathExtension
        let base = Self.sanitizedFileComponent(rawBase.isEmpty ? "Snippet" : rawBase)
        let suffix = rawExtension.isEmpty ? "" : ".\(Self.sanitizedFileComponent(rawExtension))"
        var destination = assetsDirectory.appendingPathComponent(base + suffix)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = assetsDirectory.appendingPathComponent("\(base) \(counter)\(suffix)")
            counter += 1
        }
        return destination
    }

    private nonisolated static func importDestination(
        for sourceURL: URL,
        in assetsDirectory: URL
    ) -> URL {
        let extensionValue = sourceURL.pathExtension
        let baseValue = sourceURL.deletingPathExtension().lastPathComponent
        let base = sanitizedFileComponent(baseValue.isEmpty ? "Snippet" : baseValue)
        let suffix = extensionValue.isEmpty ? "" : ".\(sanitizedFileComponent(extensionValue))"
        let storedName = "\(UUID().uuidString)-\(base)\(suffix)"
        return assetsDirectory.appendingPathComponent(storedName)
    }

    private nonisolated static func sanitizedFileComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = value
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Snippet" : sanitized
    }

    private func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func load() {
        do {
            try ensureStorage()
            guard FileManager.default.fileExists(atPath: snippetsFile.path) else {
                snippets = []
                selectedSnippetID = nil
                return
            }
            let data = try Data(contentsOf: snippetsFile)
            var decoded = try JSONDecoder().decode([SnippetItem].self, from: data)
            // Lift legacy single-asset snippets into the multi-file `files` list.
            for index in decoded.indices {
                migrateLegacyFile(&decoded[index])
            }
            snippets = decoded
            selectedSnippetID = snippets.first?.id
            lastError = nil
        } catch {
            snippets = []
            selectedSnippetID = nil
            lastError = error.localizedDescription
        }
    }

    private func save() {
        do {
            try ensureStorage()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snippets)
            try data.write(to: snippetsFile, options: [.atomic])
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ensureStorage() throws {
        try FileManager.default.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )
    }

    private static var defaultRootDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Panes/Snippets", isDirectory: true)
    }

    private var assetsDirectory: URL {
        rootDirectory.appendingPathComponent("Assets", isDirectory: true)
    }

    private var snippetsFile: URL {
        rootDirectory.appendingPathComponent("snippets.json")
    }
}
