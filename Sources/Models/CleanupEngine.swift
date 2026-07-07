import Foundation

enum CleanupCategoryKind: String, CaseIterable, Identifiable, Sendable {
    case largeFiles
    case oldFiles
    case staleDownloads
    case emptyFolders
    case duplicateCandidates
    case leftoverInstallers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largeFiles: "Large Files"
        case .oldFiles: "Old & Unused"
        case .staleDownloads: "Stale Downloads"
        case .emptyFolders: "Empty Folders"
        case .duplicateCandidates: "Possible Duplicates"
        case .leftoverInstallers: "Leftover Installers"
        }
    }

    var systemImage: String {
        switch self {
        case .largeFiles: "internaldrive"
        case .oldFiles: "clock"
        case .staleDownloads: "arrow.down.circle"
        case .emptyFolders: "folder"
        case .duplicateCandidates: "doc.on.doc"
        case .leftoverInstallers: "shippingbox"
        }
    }

    var detail: String {
        switch self {
        case .largeFiles: "Files larger than the size threshold."
        case .oldFiles: "Not modified recently and likely safe to review."
        case .staleDownloads: "Old files still sitting in Downloads."
        case .emptyFolders: "Folders with nothing inside."
        case .duplicateCandidates: "Same name and size in different locations."
        case .leftoverInstallers: "Old disk images and installers."
        }
    }
}

struct CleanupSuggestion: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let category: CleanupCategoryKind
    let reason: String

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modified: Date,
        category: CleanupCategoryKind,
        reason: String
    ) {
        self.id = url.path
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.category = category
        self.reason = reason
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct CleanupCategorySummary: Identifiable, Sendable {
    let kind: CleanupCategoryKind
    var suggestions: [CleanupSuggestion]

    var id: CleanupCategoryKind { kind }

    var totalBytes: Int64 {
        suggestions.reduce(0) { $0 + max($1.size, 0) }
    }

    var totalBytesText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

enum CleanupScanScope: String, CaseIterable, Identifiable, Sendable {
    case home = "Home"
    case downloads = "Downloads"
    case activeFolder = "Active Folder"

    var id: String { rawValue }

    func rootURL(activeFolder: URL?) -> URL? {
        switch self {
        case .home:
            FileManager.default.homeDirectoryForCurrentUser
        case .downloads:
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .activeFolder:
            activeFolder
        }
    }
}

struct CleanupScanOptions: Sendable {
    var root: URL
    var largeFileThreshold: Int64 = 100 * 1_024 * 1_024
    var oldFileAge: TimeInterval = 365 * 24 * 3_600
    var staleDownloadAge: TimeInterval = 90 * 24 * 3_600
    var installerAge: TimeInterval = 30 * 24 * 3_600
    var maxFiles = 15_000

    var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .standardizedFileURL
    }
}

enum CleanupEngine {
    private static let skippedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Library",
    ]
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "iso"]
    private static let ignoredFileNames: Set<String> = [".DS_Store"]

    static func scan(
        options: CleanupScanOptions,
        progress: @escaping @Sendable (Double, String) async -> Void = { _, _ in }
    ) async throws -> [CleanupCategorySummary] {
        try await Task.detached(priority: .userInitiated) {
            try await scanDetached(options: options, progress: progress)
        }.value
    }

    private static func scanDetached(
        options: CleanupScanOptions,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> [CleanupCategorySummary] {
        let now = Date()
        let oldCutoff = now.addingTimeInterval(-options.oldFileAge)
        let staleDownloadCutoff = now.addingTimeInterval(-options.staleDownloadAge)
        let installerCutoff = now.addingTimeInterval(-options.installerAge)
        let downloadsRoot = options.downloadsDirectory

        var largeFiles: [CleanupSuggestion] = []
        var oldFiles: [CleanupSuggestion] = []
        var staleDownloads: [CleanupSuggestion] = []
        var emptyFolders: [CleanupSuggestion] = []
        var leftoverInstallers: [CleanupSuggestion] = []
        var duplicateIndex: [String: [IndexedCleanupFile]] = [:]

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .contentAccessDateKey, .isHiddenKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: options.root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants]
        ) else {
            return emptyCategories()
        }

        var scannedCount = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if shouldSkip(url, relativeTo: options.root) {
                enumerator.skipDescendants()
                continue
            }

            scannedCount += 1
            if scannedCount % 200 == 0 {
                let value = min(Double(scannedCount) / Double(options.maxFiles), 0.95)
                await progress(value, "Scanned \(scannedCount) items")
            }
            if scannedCount > options.maxFiles {
                await progress(0.97, "Scan limit reached")
                break
            }

            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let isDirectory = values?.isDirectory ?? false
            let isHidden = values?.isHidden ?? false
            if isHidden { continue }

            let name = url.lastPathComponent
            if !isDirectory, ignoredFileNames.contains(name) { continue }

            let modified = values?.contentModificationDate ?? .distantPast
            let accessed = values?.contentAccessDate ?? modified
            let size = Int64(values?.fileSize ?? 0)

            if isDirectory {
                if isEmptyDirectory(at: url) {
                    emptyFolders.append(
                        CleanupSuggestion(
                            url: url,
                            name: name,
                            isDirectory: true,
                            size: 0,
                            modified: modified,
                            category: .emptyFolders,
                            reason: "Folder is empty"
                        )
                    )
                }
                continue
            }

            let standardURL = url.standardizedFileURL
            let ext = url.pathExtension.lowercased()

            if size >= options.largeFileThreshold {
                largeFiles.append(
                    CleanupSuggestion(
                        url: url,
                        name: name,
                        isDirectory: false,
                        size: size,
                        modified: modified,
                        category: .largeFiles,
                        reason: "Larger than \(ByteCountFormatter.string(fromByteCount: options.largeFileThreshold, countStyle: .file))"
                    )
                )
            }

            let referenceDate = max(modified, accessed)
            if referenceDate < oldCutoff {
                oldFiles.append(
                    CleanupSuggestion(
                        url: url,
                        name: name,
                        isDirectory: false,
                        size: size,
                        modified: modified,
                        category: .oldFiles,
                        reason: "Not modified since \(modified.formatted(date: .abbreviated, time: .omitted))"
                    )
                )
            }

            if let downloadsRoot,
               standardURL.path.hasPrefix(downloadsRoot.path),
               modified < staleDownloadCutoff {
                staleDownloads.append(
                    CleanupSuggestion(
                        url: url,
                        name: name,
                        isDirectory: false,
                        size: size,
                        modified: modified,
                        category: .staleDownloads,
                        reason: "In Downloads since \(modified.formatted(date: .abbreviated, time: .omitted))"
                    )
                )
            }

            if installerExtensions.contains(ext),
               modified < installerCutoff,
               isInstallerLocation(url, downloadsRoot: downloadsRoot) {
                leftoverInstallers.append(
                    CleanupSuggestion(
                        url: url,
                        name: name,
                        isDirectory: false,
                        size: size,
                        modified: modified,
                        category: .leftoverInstallers,
                        reason: "Installer image from \(modified.formatted(date: .abbreviated, time: .omitted))"
                    )
                )
            }

            let duplicateKey = "\(name.lowercased())|\(size)"
            duplicateIndex[duplicateKey, default: []].append(
                IndexedCleanupFile(
                    url: url,
                    name: name,
                    size: size,
                    modified: modified
                )
            )
        }

        await progress(0.98, "Grouping suggestions")

        let duplicateCandidates = duplicateIndex.values
            .filter { $0.count > 1 }
            .flatMap { group -> [CleanupSuggestion] in
                let sorted = group.sorted {
                    $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
                return sorted.dropFirst().map { file in
                    CleanupSuggestion(
                        url: file.url,
                        name: file.name,
                        isDirectory: false,
                        size: file.size,
                        modified: file.modified,
                        category: .duplicateCandidates,
                        reason: "Same name and size as another copy"
                    )
                }
            }

        var categories: [CleanupCategorySummary] = [
            .init(kind: .largeFiles, suggestions: sortSuggestions(largeFiles)),
            .init(kind: .oldFiles, suggestions: sortSuggestions(oldFiles)),
            .init(kind: .staleDownloads, suggestions: sortSuggestions(staleDownloads)),
            .init(kind: .emptyFolders, suggestions: sortSuggestions(emptyFolders)),
            .init(
                kind: .duplicateCandidates,
                suggestions: sortSuggestions(Array(duplicateCandidates))
            ),
            .init(kind: .leftoverInstallers, suggestions: sortSuggestions(leftoverInstallers)),
        ]
        categories = categories.filter { !$0.suggestions.isEmpty }
        await progress(1, "Found \(categories.reduce(0) { $0 + $1.suggestions.count }) suggestions")
        return categories
    }

    private static func emptyCategories() -> [CleanupCategorySummary] {
        []
    }

    private static func sortSuggestions(_ suggestions: [CleanupSuggestion]) -> [CleanupSuggestion] {
        suggestions.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func shouldSkip(_ url: URL, relativeTo root: URL) -> Bool {
        let standardizedRoot = root.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        if standardizedURL == standardizedRoot { return false }

        let components = standardizedURL.pathComponents
        for name in skippedDirectoryNames {
            if components.contains(name) { return true }
        }
        if components.contains(".Trash") { return true }
        return false
    }

    private static func isEmptyDirectory(at url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        let meaningful = contents.filter {
            !ignoredFileNames.contains($0.lastPathComponent)
        }
        return meaningful.isEmpty
    }

    private static func isInstallerLocation(_ url: URL, downloadsRoot: URL?) -> Bool {
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        if parent == "downloads" || parent == "desktop" { return true }
        if let downloadsRoot, url.standardizedFileURL.path.hasPrefix(downloadsRoot.path) {
            return true
        }
        return false
    }
}

private struct IndexedCleanupFile: Sendable {
    let url: URL
    let name: String
    let size: Int64
    let modified: Date
}
