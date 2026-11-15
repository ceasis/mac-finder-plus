import CryptoKit
import Darwin
import Foundation

/// Selection is deliberately opt-in, and the designated keeper can never be trashed.
struct DiskSpaceDuplicateSelection: Equatable {
    private(set) var keeperPath: String
    private(set) var selectedPaths: Set<String> = []

    init(group: DiskSpaceDuplicateGroup) {
        keeperPath = group.files.first(where: \.isSystemItem)?.path ?? group.files.first?.path ?? ""
    }

    mutating func keep(_ path: String, in group: DiskSpaceDuplicateGroup) {
        guard group.files.contains(where: { $0.path == path }) else { return }
        keeperPath = path
        selectedPaths.remove(path)
    }

    mutating func select(_ path: String, selected: Bool, in group: DiskSpaceDuplicateGroup) {
        guard path != keeperPath,
              let file = group.files.first(where: { $0.path == path }),
              !file.isSystemItem else { return }
        if selected { selectedPaths.insert(path) } else { selectedPaths.remove(path) }
    }

    mutating func selectExtras(in group: DiskSpaceDuplicateGroup) {
        selectedPaths = Set(group.files.filter { $0.path != keeperPath && !$0.isSystemItem }.map(\.path))
    }

    mutating func clear() { selectedPaths.removeAll() }
}

struct DiskSpaceDuplicateCleanupResult {
    var records: [FileTrashRecord] = []
    var errorMessage: String?
    var wasCancelled = false
}

enum DiskSpaceDuplicateCleanup {
    typealias TrashItem = @Sendable (URL) throws -> URL

    /// Validation and hashing never run on the main actor. A partial failure returns all
    /// completed trash records so the caller can still register Undo for those files.
    static func trash(
        group: DiskSpaceDuplicateGroup,
        keeperPath: String,
        selectedPaths: Set<String>,
        isProtected: @escaping @Sendable (String) -> Bool = { DiskSpaceSystemItem.isProtected($0) },
        trashItem: @escaping TrashItem = { try moveToTrash($0) }
    ) async -> DiskSpaceDuplicateCleanupResult {
        guard !Task.isCancelled else { return DiskSpaceDuplicateCleanupResult(wasCancelled: true) }
        let worker = Task.detached(priority: .userInitiated) {
            perform(group: group, keeperPath: keeperPath, selectedPaths: selectedPaths,
                    isProtected: isProtected, trashItem: trashItem)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func perform(
        group: DiskSpaceDuplicateGroup,
        keeperPath: String,
        selectedPaths: Set<String>,
        isProtected: (String) -> Bool,
        trashItem: TrashItem
    ) -> DiskSpaceDuplicateCleanupResult {
        var result = DiskSpaceDuplicateCleanupResult()
        do {
            try Task.checkCancellation()
            guard !selectedPaths.isEmpty,
                  !selectedPaths.contains(keeperPath),
                  group.files.contains(where: { $0.path == keeperPath }),
                  selectedPaths.isSubset(of: Set(group.files.map(\.path))) else {
                throw CleanupError.invalidSelection
            }
            guard selectedPaths.allSatisfy({ !isProtected($0) }) else {
                throw CleanupError.protectedFile
            }

            let keeperURL = URL(fileURLWithPath: keeperPath)
            let keeper = try checkedFile(keeperURL, expectedHash: group.hash, expectedSize: group.logicalBytes)
            let candidates = try group.files.filter { selectedPaths.contains($0.path) }.map { file in
                (file.url, try checkedFile(file.url, expectedHash: group.hash, expectedSize: group.logicalBytes))
            }
            // Check all files before the first mutation, then check identities again before each move.
            for (url, snapshot) in candidates {
                try Task.checkCancellation()
                guard try identity(keeperURL) == keeper, try identity(url) == snapshot else {
                    throw CleanupError.changedFile
                }
                let trashedURL = try trashItem(url)
                result.records.append(FileTrashRecord(originalURL: url, trashedURL: trashedURL))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            result.wasCancelled = true
        } catch {
            result.errorMessage = error.localizedDescription
        }
        return result
    }

    private static func checkedFile(_ url: URL, expectedHash: String, expectedSize: Int64) throws -> FileIdentity {
        try Task.checkCancellation()
        let before = try identity(url)
        guard before.size == expectedSize else { throw CleanupError.changedFile }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CleanupError.unreadableFile(url.lastPathComponent) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0, FileIdentity(openedInfo) == before else {
            throw CleanupError.changedFile
        }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == expectedHash, try identity(url) == before else { throw CleanupError.changedFile }
        return before
    }

    private static func identity(_ url: URL) throws -> FileIdentity {
        // Resolving only the parent also rejects a directory swapped for a symbolic link.
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.resolvingSymlinksInPath().path == parent.path else { throw CleanupError.changedFile }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CleanupError.unreadableFile(url.lastPathComponent)
        }
        return FileIdentity(info)
    }

    private static func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw CleanupError.unreadableFile(url.lastPathComponent) }
        return result as URL
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private enum CleanupError: LocalizedError {
        case invalidSelection, protectedFile, changedFile, unreadableFile(String)
        var errorDescription: String? {
            switch self {
            case .invalidSelection: "Choose a copy to keep and select only the other copies to move to Trash."
            case .protectedFile: "System files cannot be removed with duplicate cleanup."
            case .changedFile: "A file changed since this scan. Nothing else was moved. Analyze again before cleaning up."
            case .unreadableFile(let name): "The file ‘\(name)’ is unavailable or is no longer a regular file. Analyze again."
            }
        }
    }
}
