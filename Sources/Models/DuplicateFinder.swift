import CryptoKit
import Foundation

struct DuplicateFinderResult: Equatable {
    var leftItems: [FileItem]
    var rightItems: [FileItem]
    var duplicateGroupCount: Int

    var duplicateFileCount: Int {
        leftItems.count + rightItems.count
    }
}

enum DuplicateFinder {
    static func findAcross(
        leftFolder: URL,
        rightFolder: URL,
        includeHidden: Bool,
        progress: @escaping (Double, String) async -> Void = { _, _ in }
    ) async throws -> DuplicateFinderResult {
        await progress(0.02, "Indexing left folder")
        let leftFiles = try mediaFiles(in: leftFolder, includeHidden: includeHidden)
        await progress(0.08, "Indexing right folder")
        let rightFiles = try mediaFiles(in: rightFolder, includeHidden: includeHidden)

        let leftBySize = Dictionary(grouping: leftFiles, by: \.size)
        let rightBySize = Dictionary(grouping: rightFiles, by: \.size)
        let sharedSizes = Set(leftBySize.keys).intersection(rightBySize.keys)
        let leftCandidates = sharedSizes.flatMap { leftBySize[$0] ?? [] }
        let rightCandidates = sharedSizes.flatMap { rightBySize[$0] ?? [] }
        let totalCandidates = leftCandidates.count + rightCandidates.count
        guard totalCandidates > 0 else {
            return DuplicateFinderResult(leftItems: [], rightItems: [], duplicateGroupCount: 0)
        }

        var leftHashes: [String: [IndexedMediaFile]] = [:]
        var rightHashes: [String: [IndexedMediaFile]] = [:]
        var hashedCount = 0

        for file in leftCandidates {
            try Task.checkCancellation()
            let hash = try sha256(for: file.url)
            leftHashes[hash, default: []].append(file)
            hashedCount += 1
            await progressValue(hashedCount, totalCandidates, progress)
        }

        for file in rightCandidates {
            try Task.checkCancellation()
            let hash = try sha256(for: file.url)
            rightHashes[hash, default: []].append(file)
            hashedCount += 1
            await progressValue(hashedCount, totalCandidates, progress)
        }

        let duplicateHashes = Set(leftHashes.keys).intersection(rightHashes.keys)
        let leftItems = duplicateHashes
            .flatMap { leftHashes[$0] ?? [] }
            .map(\.item)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let rightItems = duplicateHashes
            .flatMap { rightHashes[$0] ?? [] }
            .map(\.item)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return DuplicateFinderResult(
            leftItems: leftItems,
            rightItems: rightItems,
            duplicateGroupCount: duplicateHashes.count
        )
    }

    private static func progressValue(
        _ hashedCount: Int,
        _ totalCandidates: Int,
        _ progress: (Double, String) async -> Void
    ) async {
        let value = 0.1 + 0.88 * (Double(hashedCount) / Double(totalCandidates))
        await progress(value, "Hashing \(hashedCount) of \(totalCandidates)")
    }

    private static func mediaFiles(
        in root: URL,
        includeHidden: Bool
    ) throws -> [IndexedMediaFile] {
        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: options
        ) else {
            return []
        }

        var files: [IndexedMediaFile] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let item = FileItem.make(url: url)
            guard !item.isDirectory, item.size > 0, item.isDuplicateSearchMedia else { continue }
            files.append(IndexedMediaFile(item: item))
        }
        return files
    }

    private static func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 4 * 1024 * 1024),
                  !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct IndexedMediaFile: Equatable {
    var item: FileItem
    var url: URL { item.url }
    var size: Int64 { item.size }
}

private extension FileItem {
    var isDuplicateSearchMedia: Bool {
        isImage || isVideoMedia
    }
}
