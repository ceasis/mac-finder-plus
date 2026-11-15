import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import Workbench

final class DiskSpaceDuplicateCleanupTests: EngineTestCase {
    func testSelectionIsOptInAndNeverSelectsItsKeeper() {
        let group = selectionGroup(paths: ["/Users/example/first.bin", "/Users/example/second.bin"])
        var selection = DiskSpaceDuplicateSelection(group: group)

        XCTAssertEqual(selection.keeperPath, group.files[0].path)
        XCTAssertTrue(selection.selectedPaths.isEmpty)
        selection.select(selection.keeperPath, selected: true, in: group)
        XCTAssertTrue(selection.selectedPaths.isEmpty)

        selection.selectExtras(in: group)
        XCTAssertEqual(selection.selectedPaths, [group.files[1].path])
        selection.clear()
        XCTAssertTrue(selection.selectedPaths.isEmpty)
    }

    func testSelectionPrefersAndNeverSelectsProtectedSystemCopy() {
        let group = selectionGroup(paths: [
            "/Users/example/first.bin", "/System/Library/protected.bin", "/Users/example/second.bin",
        ])
        var selection = DiskSpaceDuplicateSelection(group: group)

        XCTAssertEqual(selection.keeperPath, group.files[1].path)
        XCTAssertTrue(selection.selectedPaths.isEmpty)
        selection.keep(group.files[0].path, in: group)
        selection.select(group.files[1].path, selected: true, in: group)
        selection.selectExtras(in: group)
        XCTAssertEqual(selection.selectedPaths, [group.files[2].path])
    }

    func testChangingKeeperDeselectsThatCopyAndRejectsUnknownKeeper() {
        let group = selectionGroup(paths: ["/Users/example/first.bin", "/Users/example/second.bin"])
        var selection = DiskSpaceDuplicateSelection(group: group)
        selection.selectExtras(in: group)
        selection.keep(group.files[1].path, in: group)

        XCTAssertEqual(selection.keeperPath, group.files[1].path)
        XCTAssertTrue(selection.selectedPaths.isEmpty)
        selection.keep("/Users/example/not-in-group.bin", in: group)
        XCTAssertEqual(selection.keeperPath, group.files[1].path)
    }

    func testRejectsKeeperInTrashSelectionWithoutAnyMutation() async throws {
        let fixture = try makeFixture(copyCount: 2)
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: Set(fixture.files.map(\.path)),
            isProtected: { _ in false },
            trashItem: Self.simulatedTrash(in: fixture.trashFolder)
        )

        try assertRefusedWithoutMutation(result, fixture: fixture)
    }

    func testRejectsKeeperOutsideSnapshotWithoutAnyMutation() async throws {
        let fixture = try makeFixture(copyCount: 2)
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.root.appendingPathComponent("unknown.bin").path,
            selectedPaths: [fixture.files[1].path],
            isProtected: { _ in false },
            trashItem: Self.simulatedTrash(in: fixture.trashFolder)
        )

        try assertRefusedWithoutMutation(result, fixture: fixture)
    }

    func testRejectsProtectedCandidateBeforeMutation() async throws {
        let fixture = try makeFixture(copyCount: 2)
        let protectedPath = fixture.files[1].path
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: [protectedPath],
            isProtected: { $0 == protectedPath },
            trashItem: Self.simulatedTrash(in: fixture.trashFolder)
        )

        try assertRefusedWithoutMutation(result, fixture: fixture)
    }

    func testMovesOnlySelectedDuplicateToSimulatedTrashAndUndoRestoresIt() async throws {
        let fixture = try makeFixture(copyCount: 3)
        let selected = fixture.files[1]
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: [selected.path],
            isProtected: { _ in false },
            trashItem: Self.simulatedTrash(in: fixture.trashFolder)
        )

        XCTAssertNil(result.errorMessage)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.originalURL, selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.files[2].path))
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(try Data(contentsOf: record.trashedURL), fixture.payload)

        try await FileOperations.undo(.putBack(title: "Remove Duplicates", records: result.records))
        XCTAssertEqual(try Data(contentsOf: selected), fixture.payload)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trashFolder.path).isEmpty)
    }

    func testAllCandidatesAreValidatedBeforeFirstMove() async throws {
        let fixture = try makeFixture(copyCount: 3)
        // The first selected copy is valid; the last one is no longer a duplicate.
        try Data(repeating: 99, count: fixture.payload.count).write(to: fixture.files[2])
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: Set(fixture.files.dropFirst().map(\.path)),
            isProtected: { _ in false },
            trashItem: Self.simulatedTrash(in: fixture.trashFolder)
        )

        try assertRefusedWithoutMutation(result, fixture: fixture)
    }

    func testChangedContentIsRejectedEvenWhenFileSizeStillMatches() async throws {
        let fixture = try makeFixture(copyCount: 2)
        try Data(repeating: 99, count: fixture.payload.count).write(to: fixture.files[1])
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: [fixture.files[1].path],
            isProtected: { _ in false },
            trashItem: Self.simulatedTrash(in: fixture.trashFolder)
        )

        try assertRefusedWithoutMutation(result, fixture: fixture)
    }

    func testMissingKeeperPreventsAnyMove() async throws {
        let fixture = try makeFixture(copyCount: 2)
        try FileManager.default.removeItem(at: fixture.files[0])
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: [fixture.files[1].path],
            isProtected: { _ in false },
            trashItem: Self.simulatedTrash(in: fixture.trashFolder)
        )

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.files[1].path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trashFolder.path).isEmpty)
    }

    func testSymbolicLinkReplacementIsRejectedWithoutMovingItsTarget() async throws {
        let fixture = try makeFixture(copyCount: 2)
        try FileManager.default.removeItem(at: fixture.files[1])
        try FileManager.default.createSymbolicLink(at: fixture.files[1], withDestinationURL: fixture.files[0])
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: [fixture.files[1].path],
            isProtected: { _ in false },
            trashItem: Self.simulatedTrash(in: fixture.trashFolder)
        )

        try assertRefusedWithoutMutation(result, fixture: fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.files[0]), fixture.payload)
    }

    func testPartialFailurePreservesCompletedTrashRecordsForUndo() async throws {
        let fixture = try makeFixture(copyCount: 3)
        let failingPath = fixture.files[2].path
        let simulateTrash = Self.simulatedTrash(in: fixture.trashFolder)
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: Set(fixture.files.dropFirst().map(\.path)),
            isProtected: { _ in false },
            trashItem: { url in
                if url.path == failingPath { throw CocoaError(.fileWriteNoPermission) }
                return try simulateTrash(url)
            }
        )

        XCTAssertNotNil(result.errorMessage)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(result.records.map(\.originalURL), [fixture.files[1]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.files[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.files[2].path))

        try await FileOperations.undo(.putBack(title: "Remove Duplicates", records: result.records))
        XCTAssertEqual(try Data(contentsOf: fixture.files[1]), fixture.payload)
    }

    func testRewriteWithRestoredModificationTimeIsRejectedBeforeNextMove() async throws {
        let fixture = try makeFixture(copyCount: 3)
        let firstCandidate = fixture.files[1]
        let nextCandidate = fixture.files[2]
        let originalIdentity = try Self.fileIdentity(at: nextCandidate)
        let changedPayload = Data(repeating: 99, count: fixture.payload.count)
        let simulateTrash = Self.simulatedTrash(in: fixture.trashFolder)
        let result = await DiskSpaceDuplicateCleanup.trash(
            group: fixture.group,
            keeperPath: fixture.files[0].path,
            selectedPaths: Set(fixture.files.dropFirst().map(\.path)),
            isProtected: { _ in false },
            trashItem: { url in
                let destination = try simulateTrash(url)
                if url == firstCandidate {
                    try Self.rewritePreservingModificationTime(nextCandidate, data: changedPayload)
                }
                return destination
            }
        )

        XCTAssertNotNil(result.errorMessage)
        XCTAssertEqual(result.records.map(\.originalURL), [firstCandidate])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.files[0].path))
        XCTAssertEqual(try Data(contentsOf: nextCandidate), changedPayload)
        let changedIdentity = try Self.fileIdentity(at: nextCandidate)
        XCTAssertEqual(changedIdentity.st_ino, originalIdentity.st_ino)
        XCTAssertEqual(changedIdentity.st_size, originalIdentity.st_size)
        XCTAssertEqual(changedIdentity.st_mtimespec.tv_sec, originalIdentity.st_mtimespec.tv_sec)
        XCTAssertEqual(changedIdentity.st_mtimespec.tv_nsec, originalIdentity.st_mtimespec.tv_nsec)
        XCTAssertTrue(changedIdentity.st_ctimespec.tv_sec != originalIdentity.st_ctimespec.tv_sec
                      || changedIdentity.st_ctimespec.tv_nsec != originalIdentity.st_ctimespec.tv_nsec,
                      "The fixture must change ctime while preserving inode, size, and mtime.")
    }

    func testPrecancelledCleanupDoesNotMutateFiles() async throws {
        let fixture = try makeFixture(copyCount: 2)
        let ready = expectation(description: "Caller is paused before invoking cleanup")
        let startBarrier = DuplicateCleanupStartBarrier(ready: ready)
        let simulateTrash = Self.simulatedTrash(in: fixture.trashFolder)
        let task = Task {
            await startBarrier.wait()
            return await DiskSpaceDuplicateCleanup.trash(
                group: fixture.group,
                keeperPath: fixture.files[0].path,
                selectedPaths: [fixture.files[1].path],
                isProtected: { _ in false },
                trashItem: simulateTrash
            )
        }
        await fulfillment(of: [ready], timeout: 10)
        task.cancel()
        await startBarrier.release()
        let result = await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertNil(result.errorMessage)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(fixture.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trashFolder.path).isEmpty)
    }

    private func selectionGroup(paths: [String]) -> DiskSpaceDuplicateGroup {
        DiskSpaceDuplicateGroup(hash: "selection-only", logicalBytes: 1, files: paths.map {
            DiskSpaceDuplicateFile(path: $0, kind: .other, bytes: 1, logicalBytes: 1, modified: .distantPast)
        })
    }

    private func makeFixture(copyCount: Int) throws -> DuplicateCleanupFixture {
        // /var is a symlink on macOS; the production service intentionally
        // rejects symlinked parent paths, so use the resolved fixture root.
        let root = tempDir.resolvingSymlinksInPath()
        let sourceFolder = root.appendingPathComponent("sources", isDirectory: true)
        let trashFolder = root.appendingPathComponent("simulated-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        let payload = Data((0..<4_096).map { UInt8($0 % 251) })
        let files = try (0..<copyCount).map { index -> URL in
            let url = sourceFolder.appendingPathComponent("copy-\(index).bin")
            try payload.write(to: url)
            return url
        }
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let size = Int64(payload.count)
        let group = DiskSpaceDuplicateGroup(hash: hash, logicalBytes: size, files: files.map {
            DiskSpaceDuplicateFile(path: $0.path, kind: .other, bytes: size,
                                   logicalBytes: size, modified: .distantPast)
        })
        return DuplicateCleanupFixture(root: root, files: files, payload: payload,
                                       group: group, trashFolder: trashFolder)
    }

    private static func simulatedTrash(in folder: URL) -> DiskSpaceDuplicateCleanup.TrashItem {
        { url in
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    private func assertRefusedWithoutMutation(
        _ result: DiskSpaceDuplicateCleanupResult,
        fixture: DuplicateCleanupFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNotNil(result.errorMessage, file: file, line: line)
        XCTAssertFalse(result.wasCancelled, file: file, line: line)
        XCTAssertTrue(result.records.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                      file: file, line: line)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trashFolder.path).isEmpty,
                      file: file, line: line)
    }

    private static func fileIdentity(at url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return info
    }

    private static func rewritePreservingModificationTime(_ url: URL, data: Data) throws {
        let original = try fileIdentity(at: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        var timestamps = [original.st_atimespec, original.st_mtimespec]
        guard futimens(handle.fileDescriptor, &timestamps) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

private struct DuplicateCleanupFixture: Sendable {
    let root: URL
    let files: [URL]
    let payload: Data
    let group: DiskSpaceDuplicateGroup
    let trashFolder: URL
}

private actor DuplicateCleanupStartBarrier {
    private let ready: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(ready: XCTestExpectation) { self.ready = ready }

    func wait() async {
        ready.fulfill()
        if !isReleased {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
