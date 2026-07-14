import Foundation
import Observation

struct ArchiveBrowserEntry: Identifiable, Hashable, Sendable {
    let path: String
    let isDirectory: Bool
    let uncompressedSize: UInt64?

    var id: String { path }

    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var parentPath: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    var sizeText: String {
        guard let uncompressedSize else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(uncompressedSize), countStyle: .file)
    }
}

@Observable
@MainActor
final class ArchiveBrowserStore {
    static let shared = ArchiveBrowserStore()

    private(set) var archive: FileItem?
    private(set) var entries: [ArchiveBrowserEntry] = []
    private(set) var currentPath = ""
    var selectedEntryID: ArchiveBrowserEntry.ID?
    var searchText = ""
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var loadingTask: Task<Void, Never>?

    private init() {}

    var archiveURL: URL? {
        archive?.url
    }

    var hasArchive: Bool {
        archive != nil
    }

    var isZipArchive: Bool {
        archive?.isZipArchive == true
    }

    var title: String {
        archive?.name ?? "Archive Browser"
    }

    var fileCount: Int {
        entries.filter { !$0.isDirectory }.count
    }

    var folderCount: Int {
        entries.filter(\.isDirectory).count
    }

    var selectedEntry: ArchiveBrowserEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
    }

    var selectedFilePathsForZipExtraction: [String] {
        guard let selectedEntry else { return [] }
        if !selectedEntry.isDirectory { return [selectedEntry.path] }
        let prefix = selectedEntry.path + "/"
        return entries
            .filter { !$0.isDirectory && $0.path.hasPrefix(prefix) }
            .map(\.path)
    }

    var visibleEntries: [ArchiveBrowserEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: [ArchiveBrowserEntry]
        if query.isEmpty {
            source = entries.filter { $0.parentPath == currentPath }
        } else {
            source = entries.filter { $0.path.localizedCaseInsensitiveContains(query) }
        }
        return source.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    func open(_ archive: FileItem) {
        loadingTask?.cancel()
        self.archive = archive
        entries = []
        currentPath = ""
        selectedEntryID = nil
        searchText = ""
        errorMessage = nil
        isLoading = true

        let url = archive.url
        loadingTask = Task { [weak self, archive] in
            do {
                let loaded: [ArchiveBrowserEntry]
                if archive.isZipArchive {
                    let listing = try await ZipArchiveListingReader.listing(for: url)
                    loaded = Self.entries(from: listing.entries)
                } else {
                    let paths = try await ArchiveTools.entries(in: url)
                    loaded = Self.entries(from: paths)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.archive?.id == archive.id else { return }
                    self?.entries = loaded
                    self?.selectedEntryID = loaded.first?.id
                    self?.isLoading = false
                    self?.loadingTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self?.archive?.id == archive.id {
                        self?.isLoading = false
                    }
                    self?.loadingTask = nil
                }
            } catch {
                await MainActor.run {
                    guard self?.archive?.id == archive.id else { return }
                    self?.errorMessage = error.localizedDescription
                    self?.isLoading = false
                    self?.loadingTask = nil
                }
            }
        }
    }

    func reset() {
        loadingTask?.cancel()
        loadingTask = nil
        archive = nil
        entries = []
        currentPath = ""
        selectedEntryID = nil
        searchText = ""
        isLoading = false
        errorMessage = nil
    }

    func openSelectedFolder() {
        guard let selectedEntry, selectedEntry.isDirectory else { return }
        searchText = ""
        currentPath = selectedEntry.path
        selectedEntryID = visibleEntries.first?.id
    }

    func goUp() {
        guard !currentPath.isEmpty else { return }
        if let slash = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[..<slash])
        } else {
            currentPath = ""
        }
        searchText = ""
        selectedEntryID = visibleEntries.first?.id
    }

    func revealRoot() {
        currentPath = ""
        searchText = ""
        selectedEntryID = visibleEntries.first?.id
    }

    private static func entries(from zipEntries: [ZipArchiveEntry]) -> [ArchiveBrowserEntry] {
        entries(from: zipEntries.map { entry in
            (
                path: entry.path,
                isDirectory: entry.isDirectory,
                size: Optional(entry.uncompressedSize)
            )
        })
    }

    private static func entries(from paths: [String]) -> [ArchiveBrowserEntry] {
        entries(from: paths.map { path in
            (path: path, isDirectory: path.hasSuffix("/"), size: Optional<UInt64>.none)
        })
    }

    private static func entries(
        from rawEntries: [(path: String, isDirectory: Bool, size: UInt64?)]
    ) -> [ArchiveBrowserEntry] {
        var byPath: [String: ArchiveBrowserEntry] = [:]

        for rawEntry in rawEntries {
            let path = rawEntry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { continue }

            addParentDirectories(for: path, into: &byPath)
            byPath[path] = ArchiveBrowserEntry(
                path: path,
                isDirectory: rawEntry.isDirectory,
                uncompressedSize: rawEntry.isDirectory ? nil : rawEntry.size
            )
        }

        return byPath.values.sorted { left, right in
            if left.parentPath != right.parentPath {
                return left.parentPath.localizedStandardCompare(right.parentPath) == .orderedAscending
            }
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private static func addParentDirectories(
        for path: String,
        into byPath: inout [String: ArchiveBrowserEntry]
    ) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        var parent = ""
        for component in components.dropLast() {
            parent = parent.isEmpty ? component : "\(parent)/\(component)"
            if byPath[parent] == nil {
                byPath[parent] = ArchiveBrowserEntry(
                    path: parent,
                    isDirectory: true,
                    uncompressedSize: nil
                )
            }
        }
    }
}
