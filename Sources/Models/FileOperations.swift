import Foundation

/// All mutating file-system operations. Every function is collision-safe:
/// destinations that already exist get " 2", " 3", … appended.
enum FileOperations {
    static func transfer(_ sources: [URL], to directory: URL, move: Bool) async throws -> [FileMoveRecord] {
        let fm = FileManager.default
        var records: [FileMoveRecord] = []
        for source in sources {
            let destination = uniqueDestination(
                for: directory.appendingPathComponent(source.lastPathComponent)
            )
            if move {
                try fm.moveItem(at: source, to: destination)
                records.append(FileMoveRecord(source: source, destination: destination))
            } else {
                try fm.copyItem(at: source, to: destination)
            }
        }
        return records
    }

    static func transfer(
        _ sources: [URL],
        to directory: URL,
        move: Bool,
        conflictPolicy: FileConflictPolicy,
        progress: @escaping (Int64, Int64) async -> Void,
        isPaused: @escaping () async -> Bool
    ) async throws -> [FileMoveRecord] {
        let totalBytes = try await totalSize(of: sources)
        await progress(0, totalBytes)
        var completedBytes: Int64 = 0
        var records: [FileMoveRecord] = []

        for source in sources {
            try Task.checkCancellation()
            let sourceSize = try await totalSize(of: [source])
            if isSameOrDescendant(directory, of: source) {
                completedBytes += sourceSize
                await progress(completedBytes, totalBytes)
                continue
            }
            let proposedDestination = directory.appendingPathComponent(source.lastPathComponent)
            if source.standardizedFileURL == proposedDestination.standardizedFileURL {
                guard !move else {
                    completedBytes += sourceSize
                    await progress(completedBytes, totalBytes)
                    continue
                }
                let destination = uniqueDestination(for: proposedDestination)
                try await copyItem(
                    at: source,
                    to: destination,
                    completedBytes: &completedBytes,
                    totalBytes: totalBytes,
                    progress: progress,
                    isPaused: isPaused
                )
                continue
            }
            guard let destination = try resolvedDestination(
                for: proposedDestination,
                conflictPolicy: conflictPolicy
            ) else {
                completedBytes += sourceSize
                await progress(completedBytes, totalBytes)
                continue
            }

            if move {
                try await waitWhilePaused(isPaused)
                try FileManager.default.moveItem(at: source, to: destination)
                completedBytes += sourceSize
                await progress(completedBytes, totalBytes)
                records.append(FileMoveRecord(source: source, destination: destination))
            } else {
                try await copyItem(
                    at: source,
                    to: destination,
                    completedBytes: &completedBytes,
                    totalBytes: totalBytes,
                    progress: progress,
                    isPaused: isPaused
                )
            }
        }

        return records
    }

    static func trash(_ urls: [URL]) async throws -> [FileTrashRecord] {
        var records: [FileTrashRecord] = []
        for url in urls {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            if let trashedURL {
                records.append(FileTrashRecord(originalURL: url, trashedURL: trashedURL as URL))
            }
        }
        return records
    }

    static func duplicate(_ urls: [URL]) async throws {
        for url in urls {
            try FileManager.default.copyItem(at: url, to: uniqueDestination(for: url))
        }
    }

    @discardableResult
    static func extractZip(_ archive: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let destination = uniqueDestination(for: archiveExtractionFolder(for: archive))
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                try runZipExtraction(archive: archive, destination: destination)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
            return destination
        }.value
    }

    @discardableResult
    static func extractZipEntry(_ archive: URL, entryPath: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let safeEntryPath = try validatedArchiveEntryPath(entryPath)
            let destinationRoot = try reusableArchiveExtractionFolder(for: archive)
            let temporaryRoot = fm.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temporaryRoot) }

            try runZipEntryExtraction(
                archive: archive,
                entryPath: safeEntryPath,
                destination: temporaryRoot
            )

            let extractedFile = temporaryRoot.appendingPathComponent(safeEntryPath)
            guard fm.fileExists(atPath: extractedFile.path) else {
                throw FileOperationError.extractionFailed(
                    archiveName: archive.lastPathComponent,
                    detail: "The selected file could not be found after extraction."
                )
            }

            let finalURL = destinationRoot.appendingPathComponent(safeEntryPath)
            try fm.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let outputURL = uniqueDestination(for: finalURL)
            try fm.moveItem(at: extractedFile, to: outputURL)
            return outputURL
        }.value
    }

    @discardableResult
    static func newFolder(named name: String, in directory: URL) async throws -> URL {
        let destination = uniqueDestination(for: directory.appendingPathComponent(name))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String) async throws -> FileMoveRecord {
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: destination)
        return FileMoveRecord(source: url, destination: destination)
    }

    static func undo(_ action: FileUndoAction) async throws {
        switch action {
        case let .moveBack(_, records):
            for record in records.reversed() {
                let restoreURL = uniqueDestination(for: record.source)
                try FileManager.default.moveItem(at: record.destination, to: restoreURL)
            }
        case let .putBack(_, records):
            for record in records.reversed() {
                let restoreURL = uniqueDestination(for: record.originalURL)
                try FileManager.default.moveItem(at: record.trashedURL, to: restoreURL)
            }
        }
    }

    static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            var name = "\(base) \(counter)"
            if !ext.isEmpty { name += ".\(ext)" }
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private static func archiveExtractionFolder(for archive: URL) -> URL {
        let baseName = archive.deletingPathExtension().lastPathComponent
        let folderName = baseName.isEmpty ? "Archive" : baseName
        return archive.deletingLastPathComponent().appendingPathComponent(folderName)
    }

    private static func reusableArchiveExtractionFolder(for archive: URL) throws -> URL {
        let fm = FileManager.default
        let folder = archiveExtractionFolder(for: archive)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return folder
            }
            let uniqueFolder = uniqueDestination(for: folder)
            try fm.createDirectory(at: uniqueFolder, withIntermediateDirectories: false)
            return uniqueFolder
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private static func validatedArchiveEntryPath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw FileOperationError.invalidArchiveEntry(path)
        }
        return trimmed
    }

    static func totalSize(of urls: [URL]) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            try urls.reduce(Int64(0)) { partial, url in
                try Task.checkCancellation()
                return partial + totalSize(of: url)
            }
        }.value
    }

    private static func resolvedDestination(
        for url: URL,
        conflictPolicy: FileConflictPolicy
    ) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        switch conflictPolicy {
        case .keepBoth:
            return uniqueDestination(for: url)
        case .replace:
            try fm.removeItem(at: url)
            return url
        case .skip:
            return nil
        }
    }

    private static func totalSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0)
        }

        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        )
        while let entry = enumerator?.nextObject() as? URL {
            if Task.isCancelled { return total }
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private static func copyItem(
        at source: URL,
        to destination: URL,
        completedBytes: inout Int64,
        totalBytes: Int64,
        progress: @escaping (Int64, Int64) async -> Void,
        isPaused: @escaping () async -> Bool
    ) async throws {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        do {
            if isDirectory.boolValue {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                let enumerator = FileManager.default.enumerator(
                    at: source,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: []
                )
                while let entry = enumerator?.nextObject() as? URL {
                    try Task.checkCancellation()
                    try await waitWhilePaused(isPaused)
                    let relativePath = relativePath(from: source, to: entry)
                    guard !relativePath.isEmpty else { continue }
                    let outputURL = destination.appendingPathComponent(relativePath)
                    let values = try? entry.resourceValues(
                        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                    )
                    if values?.isDirectory == true {
                        try FileManager.default.createDirectory(
                            at: outputURL,
                            withIntermediateDirectories: true
                        )
                    } else if values?.isRegularFile == true {
                        try await copyRegularFile(
                            at: entry,
                            to: outputURL,
                            completedBytes: &completedBytes,
                            totalBytes: totalBytes,
                            progress: progress,
                            isPaused: isPaused
                        )
                    } else {
                        try FileManager.default.createDirectory(
                            at: outputURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.copyItem(at: entry, to: outputURL)
                    }
                }
            } else {
                try await copyRegularFile(
                    at: source,
                    to: destination,
                    completedBytes: &completedBytes,
                    totalBytes: totalBytes,
                    progress: progress,
                    isPaused: isPaused
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func copyRegularFile(
        at source: URL,
        to destination: URL,
        completedBytes: inout Int64,
        totalBytes: Int64,
        progress: @escaping (Int64, Int64) async -> Void,
        isPaused: @escaping () async -> Bool
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }

        let chunkSize = 2 * 1024 * 1024
        while true {
            try Task.checkCancellation()
            try await waitWhilePaused(isPaused)
            guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else {
                break
            }
            try output.write(contentsOf: data)
            completedBytes += Int64(data.count)
            await progress(completedBytes, totalBytes)
        }
    }

    private static func waitWhilePaused(
        _ isPaused: @escaping () async -> Bool
    ) async throws {
        while await isPaused() {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private static func isSameOrDescendant(_ directory: URL, of source: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let directoryPath = directory.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        return directoryPath == sourcePath || directoryPath.hasPrefix(sourcePath + "/")
    }

    private static func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath) else { return child.lastPathComponent }
        return String(childPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func runZipExtraction(archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let error = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let detail = [output, error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw FileOperationError.extractionFailed(
                archiveName: archive.lastPathComponent,
                detail: detail
            )
        }
    }

    private static func runZipEntryExtraction(
        archive: URL,
        entryPath: String,
        destination: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", archive.path, entryPath, "-d", destination.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let error = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let detail = [output, error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw FileOperationError.extractionFailed(
                archiveName: archive.lastPathComponent,
                detail: detail
            )
        }
    }
}

private enum FileOperationError: LocalizedError {
    case extractionFailed(archiveName: String, detail: String)
    case invalidArchiveEntry(String)

    var errorDescription: String? {
        switch self {
        case let .extractionFailed(archiveName, detail):
            if detail.isEmpty {
                return "Couldn’t extract “\(archiveName)”."
            }
            return "Couldn’t extract “\(archiveName)”: \(detail)"
        case let .invalidArchiveEntry(path):
            return "Couldn’t extract unsafe ZIP entry “\(path)”."
        }
    }
}
