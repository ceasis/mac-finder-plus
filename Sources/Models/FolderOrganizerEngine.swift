import Foundation

enum FolderOrganizeMode: String, CaseIterable, Identifiable, Sendable {
    case byType = "By Type"
    case byMonth = "By Month"
    case byYear = "By Year"
    case bySize = "By Size"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .byType:
            "Sort loose files into Images, Videos, Documents, and other type folders."
        case .byMonth:
            "Group loose files into YYYY-MM folders by modified date."
        case .byYear:
            "Group loose files into YYYY folders by modified date."
        case .bySize:
            "Group loose files into folders by how big they are, from Tiny to Huge."
        }
    }
}

struct OrganizePlanItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let size: Int64
    let modified: Date
    let destinationFolder: String
    let destinationURL: URL

    init(
        url: URL,
        name: String,
        size: Int64,
        modified: Date,
        destinationFolder: String,
        rootFolder: URL
    ) {
        self.id = url.path
        self.url = url
        self.name = name
        self.size = size
        self.modified = modified
        self.destinationFolder = destinationFolder
        self.destinationURL = rootFolder
            .appendingPathComponent(destinationFolder, isDirectory: true)
            .appendingPathComponent(name)
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct OrganizeGroupSummary: Identifiable, Sendable {
    let folderName: String
    var items: [OrganizePlanItem]

    var id: String { folderName }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + max($1.size, 0) }
    }

    var totalBytesText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

enum FolderOrganizerEngine {
    private static let ignoredNames: Set<String> = [".DS_Store"]

    static func plan(
        in folder: URL,
        mode: FolderOrganizeMode,
        includeHidden: Bool
    ) async throws -> [OrganizeGroupSummary] {
        try await Task.detached(priority: .userInitiated) {
            try planDetached(in: folder, mode: mode, includeHidden: includeHidden)
        }.value
    }

    static func apply(
        _ items: [OrganizePlanItem],
        conflictPolicy: FileConflictPolicy
    ) async throws -> [FileMoveRecord] {
        try await Task.detached(priority: .userInitiated) {
            try applyDetached(items, conflictPolicy: conflictPolicy)
        }.value
    }

    private static func planDetached(
        in folder: URL,
        mode: FolderOrganizeMode,
        includeHidden: Bool
    ) throws -> [OrganizeGroupSummary] {
        let root = folder.standardizedFileURL
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: options
        )

        var grouped: [String: [OrganizePlanItem]] = [:]

        for url in urls {
            try Task.checkCancellation()
            let item = FileItem.make(url: url)
            guard !item.isDirectory else { continue }
            guard !ignoredNames.contains(item.name) else { continue }

            let destinationFolder = destinationFolderName(for: item, mode: mode)
            guard destinationFolder != item.url.deletingLastPathComponent().lastPathComponent else {
                continue
            }

            let planItem = OrganizePlanItem(
                url: item.url,
                name: item.name,
                size: max(item.size, 0),
                modified: item.modified,
                destinationFolder: destinationFolder,
                rootFolder: root
            )
            grouped[destinationFolder, default: []].append(planItem)
        }

        return grouped
            .map { folderName, items in
                OrganizeGroupSummary(
                    folderName: folderName,
                    items: items.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                )
            }
            .sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
    }

    private static func applyDetached(
        _ items: [OrganizePlanItem],
        conflictPolicy: FileConflictPolicy
    ) throws -> [FileMoveRecord] {
        let fm = FileManager.default
        var records: [FileMoveRecord] = []
        let folders = Set(items.map { $0.destinationURL.deletingLastPathComponent() })
        for folder in folders {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        for item in items {
            try Task.checkCancellation()
            let destinationDirectory = item.destinationURL.deletingLastPathComponent()
            guard let destination = try resolvedMoveDestination(
                for: item.destinationURL,
                conflictPolicy: conflictPolicy
            ) else {
                continue
            }
            if item.url.standardizedFileURL == destination.standardizedFileURL {
                continue
            }
            try fm.moveItem(at: item.url, to: destination)
            records.append(FileMoveRecord(source: item.url, destination: destination))
        }
        return records
    }

    private static func destinationFolderName(for item: FileItem, mode: FolderOrganizeMode) -> String {
        switch mode {
        case .byType:
            return typeFolderName(for: item)
        case .byMonth:
            return monthFolderName(for: item.modified)
        case .byYear:
            return yearFolderName(for: item.modified)
        case .bySize:
            return sizeFolderName(for: max(item.size, 0))
        }
    }

    /// Buckets a file by size. The leading number keeps the created folders in
    /// size order on disk and in the plan preview (which sorts by name).
    private static func sizeFolderName(for size: Int64) -> String {
        let mb: Int64 = 1_000_000
        let gb: Int64 = 1_000_000_000
        switch size {
        case ..<mb: return "1 - Tiny (under 1 MB)"
        case ..<(10 * mb): return "2 - Small (1–10 MB)"
        case ..<(100 * mb): return "3 - Medium (10–100 MB)"
        case ..<gb: return "4 - Large (100 MB–1 GB)"
        default: return "5 - Huge (over 1 GB)"
        }
    }

    private static func typeFolderName(for item: FileItem) -> String {
        if FileTypePreset.images.matches(item) { return "Images" }
        if FileTypePreset.videos.matches(item) { return "Videos" }
        if FileTypePreset.audio.matches(item) { return "Audio" }
        if FileTypePreset.documents.matches(item) { return "Documents" }
        if FileTypePreset.archives.matches(item) { return "Archives" }
        return "Other"
    }

    private static func monthFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private static func yearFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }

    private static func resolvedMoveDestination(
        for proposed: URL,
        conflictPolicy: FileConflictPolicy
    ) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposed.path) else { return proposed }
        switch conflictPolicy {
        case .keepBoth:
            return FileOperations.uniqueDestination(for: proposed)
        case .skip:
            return nil
        case .replace:
            try fm.removeItem(at: proposed)
            return proposed
        }
    }
}
