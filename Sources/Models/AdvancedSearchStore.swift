import Foundation
import Observation
import UniformTypeIdentifiers

enum AdvancedSearchMatchMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case contains = "Contains"
    case regex = "Regex"

    var id: String { rawValue }
}

enum AdvancedSearchScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case activeFolder = "Active Folder"
    case home = "Home"
    case downloads = "Downloads"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .activeFolder: "folder"
        case .home: "house"
        case .downloads: "arrow.down.circle"
        }
    }

    func rootURL(activeFolder: URL) -> URL {
        switch self {
        case .activeFolder:
            activeFolder
        case .home:
            FileManager.default.homeDirectoryForCurrentUser
        case .downloads:
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }
}

struct AdvancedSearchOptions: Codable, Hashable, Sendable {
    var query = ""
    var matchMode: AdvancedSearchMatchMode = .contains
    var caseSensitive = false
    var includeSubfolders = true
    var includeHidden = false
    var searchContents = false
    var searchArchives = false
    var typePreset: FileTypePreset = .all
    var ratingFilter: StarRatingFilter = .all
    var modifiedDateFilter: ModifiedDateFilter = .all
    var fileSizeFilter: FileSizeFilter = .all
    var itemKindFilter: ItemKindFilter = .all
    var tagQuery = ""
    var scope: AdvancedSearchScope = .activeFolder

    var hasSearchCriteria: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tagQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || typePreset != .all
            || ratingFilter != .all
            || modifiedDateFilter != .all
            || fileSizeFilter != .all
            || itemKindFilter != .all
    }
}

struct AdvancedSearchResult: Identifiable, Hashable, Sendable {
    let item: FileItem
    let matchDescription: String

    var id: String {
        item.id
    }
}

struct SavedAdvancedSearch: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var options: AdvancedSearchOptions
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        options: AdvancedSearchOptions,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.options = options
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Observable
@MainActor
final class AdvancedSearchStore {
    static let shared = AdvancedSearchStore()

    var options = AdvancedSearchOptions()
    private(set) var results: [AdvancedSearchResult] = []
    private(set) var isSearching = false
    private(set) var progressDetail = ""
    private(set) var lastRootURL: URL?
    private(set) var hasRunSearch = false
    var selectedResultID: AdvancedSearchResult.ID?
    var selectedSavedSearchID: SavedAdvancedSearch.ID?
    private(set) var savedSearches: [SavedAdvancedSearch] = []
    var lastError: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private let savedSearchesKey = "advancedSearch.savedSearches.v1"

    private init() {
        loadSavedSearches()
    }

    var selectedResult: AdvancedSearchResult? {
        results.first { $0.id == selectedResultID } ?? results.first
    }

    var resultItems: [FileItem] {
        results.map(\.item)
    }

    var canRunSearch: Bool {
        options.hasSearchCriteria && !isSearching
    }

    func run(activeFolder: URL) {
        guard options.hasSearchCriteria else {
            lastError = "Add a query or filter before running advanced search."
            return
        }

        searchTask?.cancel()
        let root = options.scope.rootURL(activeFolder: activeFolder)
        let options = options

        isSearching = true
        hasRunSearch = true
        lastError = nil
        results = []
        selectedResultID = nil
        lastRootURL = root
        progressDetail = "Scanning \(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)"

        searchTask = Task { [weak self] in
            do {
                let found = try await AdvancedFileSearch.search(
                    root: root,
                    options: options
                ) { detail in
                    await MainActor.run {
                        self?.progressDetail = detail
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.results = found
                    self?.selectedResultID = found.first?.id
                    self?.progressDetail = "\(found.count) result\(found.count == 1 ? "" : "s")"
                    self?.isSearching = false
                    self?.searchTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.progressDetail = "Search cancelled"
                    self?.isSearching = false
                    self?.searchTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.progressDetail = "Search failed"
                    self?.isSearching = false
                    self?.searchTask = nil
                }
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        progressDetail = "Search cancelled"
    }

    func clearResults() {
        results = []
        selectedResultID = nil
        hasRunSearch = false
        progressDetail = ""
    }

    func resetOptions() {
        options = AdvancedSearchOptions()
        selectedSavedSearchID = nil
        clearResults()
    }

    func saveCurrentSearch(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard options.hasSearchCriteria else {
            lastError = "Add a query or filter before saving a search."
            return
        }
        let saved = SavedAdvancedSearch(name: trimmed, options: options)
        savedSearches.insert(saved, at: 0)
        selectedSavedSearchID = saved.id
        saveSavedSearches()
    }

    func applySavedSearch(_ saved: SavedAdvancedSearch) {
        options = saved.options
        selectedSavedSearchID = saved.id
    }

    func deleteSavedSearch(_ saved: SavedAdvancedSearch) {
        savedSearches.removeAll { $0.id == saved.id }
        if selectedSavedSearchID == saved.id {
            selectedSavedSearchID = savedSearches.first?.id
        }
        saveSavedSearches()
    }

    private func loadSavedSearches() {
        guard let data = UserDefaults.standard.data(forKey: savedSearchesKey),
              let decoded = try? JSONDecoder().decode([SavedAdvancedSearch].self, from: data) else {
            savedSearches = []
            return
        }
        savedSearches = decoded
    }

    private func saveSavedSearches() {
        guard let data = try? JSONEncoder().encode(savedSearches) else { return }
        UserDefaults.standard.set(data, forKey: savedSearchesKey)
    }
}

enum AdvancedFileSearch {
    static let maximumResults = 5_000
    private static let maximumContentBytes = 1_000_000

    static func search(
        root: URL,
        options: AdvancedSearchOptions,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> [AdvancedSearchResult] {
        try await Task.detached(priority: .userInitiated) {
            let matcher = try SearchMatcher(
                query: options.query,
                mode: options.matchMode,
                caseSensitive: options.caseSensitive
            )
            let tagMatcher = try SearchMatcher(
                query: options.tagQuery,
                mode: .contains,
                caseSensitive: false
            )

            var results: [AdvancedSearchResult] = []
            var visited = 0
            let urls = try candidateURLs(root: root, options: options)

            for url in urls {
                try Task.checkCancellation()
                visited += 1
                if visited % 150 == 0 {
                    await progress("Scanned \(visited) items")
                }

                let item = FileItem.make(url: url)
                guard matchesMetadata(item, options: options) else { continue }
                guard try matchesTags(url: url, matcher: tagMatcher) else { continue }

                let match = try matchDescription(for: item, matcher: matcher, options: options)
                guard let match else { continue }

                results.append(AdvancedSearchResult(item: item, matchDescription: match))
                if results.count >= maximumResults { break }
            }

            await progress("\(results.count) result\(results.count == 1 ? "" : "s")")
            return results
        }.value
    }

    private static func candidateURLs(root: URL, options: AdvancedSearchOptions) throws -> [URL] {
        if options.includeSubfolders {
            var urls: [URL] = []
            let enumerationOptions: FileManager.DirectoryEnumerationOptions =
                options.includeHidden ? [] : [.skipsHiddenFiles]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: enumerationOptions
            ) else {
                return []
            }
            while let url = enumerator.nextObject() as? URL {
                urls.append(url)
            }
            return urls
        }

        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: options.includeHidden ? [] : [.skipsHiddenFiles]
        )
    }

    private static func matchesMetadata(_ item: FileItem, options: AdvancedSearchOptions) -> Bool {
        guard options.typePreset.matches(item) else { return false }
        guard options.ratingFilter.matches(item) else { return false }
        guard options.modifiedDateFilter.matches(created: item.created, modified: item.modified) else { return false }
        guard options.itemKindFilter.matches(isDirectory: item.isDirectory) else { return false }
        if options.fileSizeFilter != .all {
            guard !item.isDirectory, options.fileSizeFilter.matches(size: item.size) else { return false }
        }
        return true
    }

    private static func matchesTags(url: URL, matcher: SearchMatcher) throws -> Bool {
        guard matcher.hasQuery else { return true }
        let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        return tags.contains { matcher.matches($0) }
    }

    private static func matchDescription(
        for item: FileItem,
        matcher: SearchMatcher,
        options: AdvancedSearchOptions
    ) throws -> String? {
        guard matcher.hasQuery else { return "Matched filters" }

        if matcher.matches(item.name) {
            return "Name"
        }

        if options.searchContents,
           !item.isDirectory,
           item.isText,
           let contentMatch = try contentMatchDescription(for: item.url, matcher: matcher) {
            return contentMatch
        }

        if options.searchArchives,
           item.isArchive,
           let archiveMatch = try archiveMatchDescription(for: item.url, matcher: matcher) {
            return archiveMatch
        }

        return nil
    }

    private static func contentMatchDescription(for url: URL, matcher: SearchMatcher) throws -> String? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard (values?.fileSize ?? 0) <= maximumContentBytes else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .macOSRoman)
            ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, line) in lines.enumerated() where matcher.matches(String(line)) {
            let excerpt = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            return "Contents line \(offset + 1): \(excerpt.prefix(120))"
        }
        return nil
    }

    private static func archiveMatchDescription(for url: URL, matcher: SearchMatcher) throws -> String? {
        let entries = try ArchiveTools.entriesSync(in: url)
        guard let match = entries.first(where: matcher.matches) else { return nil }
        return "Archive entry: \(match)"
    }
}

struct SearchMatcher: Sendable {
    let hasQuery: Bool
    private let query: String
    private let caseSensitive: Bool
    private let regex: NSRegularExpression?

    init(
        query: String,
        mode: AdvancedSearchMatchMode,
        caseSensitive: Bool
    ) throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed
        self.caseSensitive = caseSensitive
        self.hasQuery = !trimmed.isEmpty

        if mode == .regex, !trimmed.isEmpty {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            self.regex = try NSRegularExpression(pattern: trimmed, options: options)
        } else {
            self.regex = nil
        }
    }

    func matches(_ text: String) -> Bool {
        guard hasQuery else { return true }
        if let regex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, range: range) != nil
        }
        if caseSensitive {
            return text.contains(query)
        }
        return text.localizedCaseInsensitiveContains(query)
    }
}
