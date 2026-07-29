import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest

@testable import Workbench

/// Shared temp-directory scaffolding + fixture helpers for the engine tests.
class EngineTestCase: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkbenchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    @discardableResult
    func writeFile(_ name: String, _ contents: String = "x", in directory: URL? = nil) throws -> URL {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func runFixtureProcess(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "EngineTestCase",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) failed during fixture setup."]
            )
        }
    }

    @discardableResult
    func makePNG(_ name: String, width: Int, height: Int, gray: CGFloat = 0.5, in directory: URL? = nil) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = (directory ?? tempDir).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "failed to write \(name)")
        return url
    }

    func dimensions(of url: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return (0, 0)
        }
        return (w, h)
    }
}

@MainActor
final class PlayerPreviewInteractionTests: XCTestCase {
    func testPlayerPreviewDoesNotInterceptPointerEvents() {
        let view = PassthroughAVPlayerView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        let child = NSView(frame: view.bounds)
        view.addSubview(child)

        XCTAssertNil(view.hitTest(NSPoint(x: 320, y: 180)))
    }
}

@MainActor
final class PreviewToolbarNSButtonTests: XCTestCase {
    func testEnabledButtonInvokesItsAction() {
        var receivedState: Bool?
        let button = PreviewToolbarNSButton(frame: .zero)
        button.configure(
            title: "Export",
            systemImage: "square.and.arrow.down",
            accessibilityLabel: "Export Video",
            help: "Export",
            isEnabled: true,
            isToggle: false,
            isOn: false
        ) { receivedState = $0 }

        button.performClick(nil)

        XCTAssertEqual(receivedState, false)
    }

    func testDisabledButtonDoesNotInvokeItsAction() {
        var invocationCount = 0
        let button = PreviewToolbarNSButton(frame: .zero)
        button.configure(
            title: "Export Audio",
            systemImage: "waveform",
            accessibilityLabel: "Export Audio",
            help: "No audio track",
            isEnabled: false,
            isToggle: false,
            isOn: false
        ) { _ in invocationCount += 1 }

        button.performClick(nil)

        XCTAssertEqual(invocationCount, 0)
    }

    func testToggleButtonReportsItsNewState() {
        var receivedState: Bool?
        let button = PreviewToolbarNSButton(frame: .zero)
        button.configure(
            title: "Remove Audio",
            systemImage: "speaker.slash",
            accessibilityLabel: "Remove Audio",
            help: "Mute audio",
            isEnabled: true,
            isToggle: true,
            isOn: false
        ) { receivedState = $0 }

        button.performClick(nil)

        XCTAssertEqual(receivedState, true)
        XCTAssertEqual(button.state, .on)
    }
}

// MARK: - FileOperations

final class FileOperationsTests: EngineTestCase {
    func testUniqueDestinationAppendsNumberOnCollision() throws {
        let original = try writeFile("photo.jpg")
        let dest = FileOperations.uniqueDestination(for: original)
        XCTAssertEqual(dest.lastPathComponent, "photo 2.jpg")
    }

    func testUniqueDestinationUnchangedWhenNoCollision() {
        let url = tempDir.appendingPathComponent("fresh.txt")
        XCTAssertEqual(FileOperations.uniqueDestination(for: url), url)
    }

    func testUniqueDestinationIncrementsPastExistingNumbered() throws {
        try writeFile("doc.txt")
        try writeFile("doc 2.txt")
        let dest = FileOperations.uniqueDestination(for: tempDir.appendingPathComponent("doc.txt"))
        XCTAssertEqual(dest.lastPathComponent, "doc 3.txt")
    }

    func testUniqueDestinationHandlesNoExtension() throws {
        try writeFile("README")
        let dest = FileOperations.uniqueDestination(for: tempDir.appendingPathComponent("README"))
        XCTAssertEqual(dest.lastPathComponent, "README 2")
    }

    func testNewFolderCreatesAndAvoidsCollision() async throws {
        let a = try await FileOperations.newFolder(named: "New Folder", in: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        let b = try await FileOperations.newFolder(named: "New Folder", in: tempDir)
        XCTAssertEqual(b.lastPathComponent, "New Folder 2")
    }

    func testNewTextFileCreatesEmptyFileAndAvoidsCollision() async throws {
        let a = try await FileOperations.newTextFile(named: "Untitled.txt", in: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try Data(contentsOf: a).count, 0)
        let b = try await FileOperations.newTextFile(named: "Untitled.txt", in: tempDir)
        XCTAssertEqual(b.lastPathComponent, "Untitled 2.txt")
    }

    func testDuplicateCreatesCopyWithSameContents() async throws {
        let file = try writeFile("orig.txt", "hello")
        try await FileOperations.duplicate([file])
        let copy = tempDir.appendingPathComponent("orig 2.txt")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "original must remain")
    }

    func testCompressFolderCreatesZipWithContents() async throws {
        let folder = tempDir.appendingPathComponent("Project", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile("note.txt", "hello zip", in: nested)

        let archive = try await FileOperations.compressToZip([folder])
        let entries = try ArchiveTools.entriesSync(in: archive)

        XCTAssertEqual(archive.lastPathComponent, "Project.zip")
        XCTAssertTrue(entries.contains("Project/Nested/note.txt"), "got \(entries)")
    }

    func testCompressSingleFileCreatesZipWithFile() async throws {
        let file = try writeFile("report.txt", "single file zip")

        let archive = try await FileOperations.compressToZip([file])
        let entries = try ArchiveTools.entriesSync(in: archive)

        XCTAssertEqual(archive.lastPathComponent, "report.txt.zip")
        XCTAssertTrue(entries.contains("report.txt"), "got \(entries)")
    }

    func testCompressMultipleFilesCreatesArchiveZip() async throws {
        let first = try writeFile("first.txt", "one")
        let second = try writeFile("second.txt", "two")

        let archive = try await FileOperations.compressToZip([first, second])
        let entries = try ArchiveTools.entriesSync(in: archive)

        XCTAssertEqual(archive.lastPathComponent, "Archive.zip")
        XCTAssertTrue(entries.contains("first.txt"), "got \(entries)")
        XCTAssertTrue(entries.contains("second.txt"), "got \(entries)")
    }

    func testRenameMovesFile() async throws {
        let file = try writeFile("before.txt", "data")
        let record = try await FileOperations.rename(file, to: "after.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.destination.path))
        XCTAssertEqual(record.destination.lastPathComponent, "after.txt")
    }

    func testTransferCopyKeepsSource() async throws {
        let src = try writeFile("a.txt", "z")
        let destDir = try await FileOperations.newFolder(named: "dest", in: tempDir)
        _ = try await FileOperations.transfer([src], to: destDir, move: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("a.txt").path))
    }

    func testTransferMoveRemovesSource() async throws {
        let src = try writeFile("b.txt", "z")
        let destDir = try await FileOperations.newFolder(named: "dest2", in: tempDir)
        let records = try await FileOperations.transfer([src], to: destDir, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(records.count, 1)
    }

    func testTransferMoveSupportsRepresentativeNonTextFileTypes() async throws {
        let sourceDir = tempDir.appendingPathComponent("source", isDirectory: true)
        let destinationDir = tempDir.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: false)
        let names = ["image.png", "video.mp4", "audio.m4a", "archive.zip", "document.pdf"]
        let sources = try names.map { try writeFile($0, "payload", in: sourceDir) }

        let records = try await FileOperations.transfer(
            sources,
            to: destinationDir,
            move: true
        )

        XCTAssertEqual(records.map(\.destination.lastPathComponent), names)
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: sourceDir.appendingPathComponent(name).path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destinationDir.appendingPathComponent(name).path
            ))
        }
    }

    func testMoveIntoNewFolderCreatesFolderAndMovesSelection() async throws {
        let first = try writeFile("first.txt", "a")
        let second = try writeFile("second.txt", "b")
        let result = try await FileOperations.moveIntoNewFolder(
            [first, second],
            folderName: "Bundle",
            in: tempDir
        )

        XCTAssertEqual(result.folder.lastPathComponent, "Bundle")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(
            try String(contentsOf: result.folder.appendingPathComponent("first.txt"), encoding: .utf8),
            "a"
        )
        XCTAssertEqual(
            try String(contentsOf: result.folder.appendingPathComponent("second.txt"), encoding: .utf8),
            "b"
        )
    }

    func testMoveToParentFolderMovesFileUpOneLevel() async throws {
        let child = tempDir.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let file = try writeFile("report.txt", "up", in: child)

        let records = try await FileOperations.moveToParentFolder([file])
        let moved = tempDir.appendingPathComponent("report.txt")

        XCTAssertEqual(records, [FileMoveRecord(source: file.standardizedFileURL, destination: moved)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "up")
    }

    func testMoveToParentFolderMovesFolderUpOneLevel() async throws {
        let child = tempDir.appendingPathComponent("Child", isDirectory: true)
        let bundle = child.appendingPathComponent("Bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try writeFile("inside.txt", "folder", in: bundle)

        let records = try await FileOperations.moveToParentFolder([bundle])
        let moved = tempDir.appendingPathComponent("Bundle", isDirectory: true)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].source.path, bundle.standardizedFileURL.path)
        XCTAssertEqual(records[0].destination.path, moved.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(
            try String(contentsOf: moved.appendingPathComponent("inside.txt"), encoding: .utf8),
            "folder"
        )
    }

    func testMoveToParentFolderAvoidsNameCollision() async throws {
        let child = tempDir.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeFile("report.txt", "existing")
        let file = try writeFile("report.txt", "moved", in: child)

        let records = try await FileOperations.moveToParentFolder([file])
        let moved = tempDir.appendingPathComponent("report 2.txt")

        XCTAssertEqual(records, [FileMoveRecord(source: file.standardizedFileURL, destination: moved)])
        XCTAssertEqual(try String(contentsOf: tempDir.appendingPathComponent("report.txt"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "moved")
    }

    func testTransferIntoSameFolderDoesNotDestroyFile() async throws {
        // Copying a file into its own directory must collision-rename, never delete.
        let src = try writeFile("keep.txt", "important")
        _ = try await FileOperations.transfer([src], to: tempDir, move: false)
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "important")
    }

    func testUndoMoveBackRestoresOriginalLocation() async throws {
        let src = try writeFile("c.txt", "z")
        let destDir = try await FileOperations.newFolder(named: "dest3", in: tempDir)
        let records = try await FileOperations.transfer([src], to: destDir, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        try await FileOperations.undo(.moveBack(title: "Move", records: records))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "undo must restore source")
    }
}

// MARK: - FolderOrganizerEngine

final class FolderOrganizerTests: EngineTestCase {
    func testOrganizeBySizeBucketsFiles() async throws {
        try writeFile("tiny.txt", "x") // ~1 byte → Tiny
        try Data(count: 2_000_000).write(to: tempDir.appendingPathComponent("big.bin")) // 2 MB → Small

        let groups = try await FolderOrganizerEngine.plan(
            in: tempDir, mode: .bySize, includeHidden: false)
        let names = Set(groups.map(\.folderName))

        XCTAssertTrue(names.contains("1 - Tiny (under 1 MB)"), "got \(names)")
        XCTAssertTrue(names.contains("2 - Small (1–10 MB)"), "got \(names)")
        let tiny = groups.first { $0.folderName.contains("Tiny") }
        XCTAssertEqual(tiny?.items.first?.name, "tiny.txt")
    }
}

final class ImageTextExtractorTests: EngineTestCase {
    func testTextOutputURLUsesImageBaseNameInSameFolder() throws {
        let image = try writeFile("receipt.png")

        let output = ImageTextExtractor.textOutputURL(for: image)

        XCTAssertEqual(output.deletingLastPathComponent().path, tempDir.path)
        XCTAssertEqual(output.lastPathComponent, "receipt.txt")
    }

    func testTextOutputURLAvoidsExistingTextFile() throws {
        let image = try writeFile("receipt.png")
        _ = try writeFile("receipt.txt", "existing text")

        let output = ImageTextExtractor.textOutputURL(for: image)

        XCTAssertEqual(output.lastPathComponent, "receipt 2.txt")
    }
}

final class FilePasteboardTests: EngineTestCase {
    func testReadsWorkbenchWrittenFileURLs() throws {
        let file = try writeFile("copy-me.txt")
        let pasteboard = NSPasteboard.withUniqueName()

        FilePasteboard.write([file], to: pasteboard)

        XCTAssertEqual(FilePasteboard.fileURLs(from: pasteboard).map(\.path), [file.path])
        XCTAssertEqual(FilePasteboard.operation(from: pasteboard), .copy)
    }

    func testPreservesCutOperationForWorkbenchPaste() throws {
        let file = try writeFile("move-me.txt")
        let pasteboard = NSPasteboard.withUniqueName()

        FilePasteboard.write([file], operation: .cut, to: pasteboard)

        XCTAssertEqual(FilePasteboard.fileURLs(from: pasteboard).map(\.path), [file.path])
        XCTAssertEqual(FilePasteboard.operation(from: pasteboard), .cut)
    }

    func testReadsLegacyFilenamePasteboardType() throws {
        let file = try writeFile("finder-style.txt")
        let pasteboard = NSPasteboard.withUniqueName()
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

        pasteboard.clearContents()
        pasteboard.setPropertyList([file.path], forType: filenamesType)

        XCTAssertEqual(FilePasteboard.fileURLs(from: pasteboard).map(\.path), [file.path])
    }

    func testReadsPathTextFallback() throws {
        let file = try writeFile("path-text.txt")
        let pasteboard = NSPasteboard.withUniqueName()

        pasteboard.clearContents()
        pasteboard.setString(file.path, forType: .string)

        XCTAssertEqual(FilePasteboard.fileURLs(from: pasteboard).map(\.path), [file.path])
    }
}

final class FileDropTests: XCTestCase {
    func testInternalDragMovesUnlessOptionIsHeld() {
        XCTAssertTrue(FileDropOperationPolicy.shouldMove(
            isInternalDrag: true,
            modifiers: []
        ))
        XCTAssertFalse(FileDropOperationPolicy.shouldMove(
            isInternalDrag: true,
            modifiers: [.option]
        ))
    }

    func testExternalDropCopiesUnlessCommandRequestsMove() {
        XCTAssertFalse(FileDropOperationPolicy.shouldMove(
            isInternalDrag: false,
            modifiers: []
        ))
        XCTAssertTrue(FileDropOperationPolicy.shouldMove(
            isInternalDrag: false,
            modifiers: [.command]
        ))
    }

    func testFileDropPayloadReadsFileURLData() throws {
        let url = URL(fileURLWithPath: "/tmp/drag-target.txt")
        let data = try XCTUnwrap(url.dataRepresentation)

        XCTAssertEqual(FileDropPayload.fileURL(from: data as NSData), url)
        XCTAssertNil(FileDropPayload.fileURL(from: "https://example.com" as NSString))
    }

    @MainActor
    func testInternalDragProviderUsesStableFileURLAndMarkerForEveryFileType() {
        let names = [
            "note.txt", "image.png", "video.mp4",
            "audio.m4a", "archive.zip", "document.pdf",
        ]

        for name in names {
            let provider = FileDragItemProvider.make(
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                suggestedName: name,
                sessionID: "session",
                internalTypeIdentifier: AppState.internalFileDragType.identifier
            )

            XCTAssertTrue(
                provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier),
                "\(name) is missing its file URL representation"
            )
            XCTAssertTrue(
                FileDragItemProvider.containsInternalMarker(
                    [provider],
                    typeIdentifier: AppState.internalFileDragType.identifier
                ),
                "\(name) is missing its Workbench drag marker"
            )
        }
    }

    func testNestedFolderTargetWinsOverContainingFolderTarget() {
        let currentFolder = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let nestedFolder = currentFolder.appendingPathComponent("Archive", isDirectory: true)

        XCTAssertEqual(
            FileDropDestinationPolicy.preferredDestination(
                fallback: currentFolder,
                activeDestinations: [currentFolder, nestedFolder]
            ),
            nestedFolder
        )
    }

    func testDropTargetIgnoresActiveFoldersOutsideFallbackHierarchy() {
        let currentFolder = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let unrelatedFolder = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)

        XCTAssertEqual(
            FileDropDestinationPolicy.preferredDestination(
                fallback: currentFolder,
                activeDestinations: [unrelatedFolder]
            ),
            currentFolder
        )
    }

    func testNestedFolderTargetWorksWhenBrowsingFilesystemRoot() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let users = URL(fileURLWithPath: "/Users", isDirectory: true)

        XCTAssertEqual(
            FileDropDestinationPolicy.preferredDestination(
                fallback: root,
                activeDestinations: [root, users]
            ),
            users
        )
    }

    func testIconGridResolvesDropToFolderUnderFinalPointer() {
        let currentFolder = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let archive = currentFolder.appendingPathComponent("Archive", isDirectory: true)
        let videoID = "video"
        let folderID = "folder"
        let visibleFrames = [
            videoID: CGRect(x: 10, y: 10, width: 110, height: 130),
            folderID: CGRect(x: 145, y: 10, width: 110, height: 130),
        ]

        XCTAssertEqual(
            FileGridDropDestinationPolicy.destination(
                at: CGPoint(x: 190, y: 70),
                folders: [(folderID, archive)],
                frames: visibleFrames,
                fallback: currentFolder
            ),
            archive
        )
    }

    func testIconGridFallsBackToCurrentFolderOutsideVisibleFolder() {
        let currentFolder = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let archive = currentFolder.appendingPathComponent("Archive", isDirectory: true)
        let folderID = "folder"

        XCTAssertEqual(
            FileGridDropDestinationPolicy.destination(
                at: CGPoint(x: 20, y: 250),
                folders: [(folderID, archive)],
                frames: [folderID: CGRect(x: 145, y: 10, width: 110, height: 130)],
                fallback: currentFolder
            ),
            currentFolder
        )
    }

    func testDropHighlightAppearsOnlyForMatchingVisibleFolder() {
        let currentFolder = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let archive = currentFolder.appendingPathComponent("Archive", isDirectory: true)
        let projects = currentFolder.appendingPathComponent("Projects", isDirectory: true)

        XCTAssertEqual(
            FileDropHighlightPolicy.visibleFolder(
                destination: archive.appendingPathComponent(".").standardizedFileURL,
                folders: [archive, projects]
            ),
            archive
        )
        XCTAssertNil(FileDropHighlightPolicy.visibleFolder(
            destination: currentFolder,
            folders: [archive, projects]
        ))
        XCTAssertNil(FileDropHighlightPolicy.visibleFolder(
            destination: nil,
            folders: [archive, projects]
        ))
    }

    func testSidebarAcceptsFolderDestinationsButNotFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Destination", isDirectory: true)
        let file = root.appendingPathComponent("Not a Folder.txt")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(SidebarFileDropPolicy.acceptsDestination(folder))
        XCTAssertFalse(SidebarFileDropPolicy.acceptsDestination(file))
    }
}

@MainActor
final class RecentFolderStoreTests: EngineTestCase {
    func testShowsOnlyThreeFoldersAccessedWithinEightHoursNewestFirst() throws {
        let suiteName = "RecentFolderStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_000_000)
        let folders = try (1...5).map { index in
            let folder = tempDir.appendingPathComponent("Folder \(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        }
        let store = RecentFolderStore(defaults: defaults, now: { now })

        store.record(folders[0], at: now.addingTimeInterval(-9 * 60 * 60))
        store.record(folders[1], at: now.addingTimeInterval(-4 * 60 * 60))
        store.record(folders[2], at: now.addingTimeInterval(-3 * 60 * 60))
        store.record(folders[3], at: now.addingTimeInterval(-2 * 60 * 60))
        store.record(folders[4], at: now.addingTimeInterval(-1 * 60 * 60))

        XCTAssertEqual(
            store.visibleEntries(excluding: []).map(\.path),
            [folders[4], folders[3], folders[2]].map(\.path)
        )
    }

    func testVisibleEntriesExcludeOpenFoldersAndStillFillThreeRows() throws {
        let suiteName = "RecentFolderStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_500_000)
        let folders = try (1...4).map { index in
            let folder = tempDir.appendingPathComponent("Folder \(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        }
        let store = RecentFolderStore(defaults: defaults, now: { now })
        for (index, folder) in folders.enumerated() {
            store.record(folder, at: now.addingTimeInterval(TimeInterval(index)))
        }

        let visible = store.visibleEntries(excluding: [folders[3].path])

        XCTAssertEqual(
            visible.map(\.path),
            [folders[2], folders[1], folders[0]].map(\.path)
        )
    }

    func testRevisitingFolderMovesItToTopAndPersists() throws {
        let suiteName = "RecentFolderStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 2_000_000)
        let first = tempDir.appendingPathComponent("First", isDirectory: true)
        let second = tempDir.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)

        let store = RecentFolderStore(defaults: defaults, now: { now })
        store.record(first, at: now.addingTimeInterval(-60))
        store.record(second, at: now.addingTimeInterval(-30))
        store.record(first, at: now)

        XCTAssertEqual(store.entries.map(\.path), [first.path, second.path])
        let restored = RecentFolderStore(defaults: defaults, now: { now })
        XCTAssertEqual(restored.entries, store.entries)
    }

    func testPaneNavigationReportsTheFolderBeingLeft() throws {
        let destination = tempDir.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        let pane = PaneModel(url: tempDir)
        var transitions: [(previous: URL, next: URL)] = []
        pane.folderAccessChanged = { previous, next in
            transitions.append((previous, next))
        }

        pane.navigate(to: destination)

        XCTAssertEqual(
            transitions.map { $0.previous.standardizedFileURL },
            [tempDir.standardizedFileURL]
        )
        XCTAssertEqual(
            transitions.map { $0.next.standardizedFileURL },
            [destination.standardizedFileURL]
        )
    }
}

@MainActor
final class AppCommandResponderTests: XCTestCase {
    func testPasteRoutesToFocusedTextEditor() {
        let textView = NSTextView()
        var routedAction: Selector?
        weak var routedTarget: AnyObject?

        let didRoute = AppCommandResponder.pasteIntoFocusedTextEditor(
            firstResponder: textView
        ) { action, target in
            routedAction = action
            routedTarget = target
            return true
        }

        XCTAssertTrue(didRoute)
        XCTAssertEqual(routedAction, #selector(NSText.paste(_:)))
        XCTAssertTrue(routedTarget === textView)
    }

    func testPasteFallsBackWhenFileBrowserOwnsFocus() {
        var didSendAction = false

        let didRoute = AppCommandResponder.pasteIntoFocusedTextEditor(
            firstResponder: NSResponder()
        ) { _, _ in
            didSendAction = true
            return true
        }

        XCTAssertFalse(didRoute)
        XCTAssertFalse(didSendAction)
    }

    func testCutRoutesToFocusedTextEditor() {
        let textView = NSTextView()
        var routedAction: Selector?
        weak var routedTarget: AnyObject?

        let didRoute = AppCommandResponder.cutFocusedTextEditor(
            firstResponder: textView
        ) { action, target in
            routedAction = action
            routedTarget = target
            return true
        }

        XCTAssertTrue(didRoute)
        XCTAssertEqual(routedAction, #selector(NSText.cut(_:)))
        XCTAssertTrue(routedTarget === textView)
    }
}

@MainActor
final class PomodoroStoreTests: XCTestCase {
    func testUsesSmartDefaultsAndElapsedWallClockTime() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(store.focusMinutes, 25)
        XCTAssertEqual(store.shortBreakMinutes, 5)
        XCTAssertEqual(store.longBreakMinutes, 15)
        XCTAssertEqual(store.remainingSeconds, 1_500)

        store.start(at: start)
        store.tick(at: start.addingTimeInterval(61.2))
        XCTAssertEqual(store.remainingSeconds, 1_439)

        store.pause(at: start.addingTimeInterval(90.5))
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.remainingSeconds, 1_410)

        store.tick(at: start.addingTimeInterval(600))
        XCTAssertEqual(store.remainingSeconds, 1_410)
    }

    func testFourFocusSessionsEarnLongBreak() {
        var soundCount = 0
        let (store, defaults, suiteName) = makeStore {
            soundCount += 1
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var date = Date(timeIntervalSinceReferenceDate: 2_000)

        for completedSession in 1...4 {
            if store.phase != .focus {
                store.skip()
            }
            let duration = store.remainingSeconds
            store.start(at: date)
            date = date.addingTimeInterval(duration)
            store.tick(at: date)

            XCTAssertEqual(store.completedFocusSessions, completedSession)
        }

        XCTAssertEqual(store.phase, .longBreak)
        XCTAssertEqual(store.focusSessionsInCycle, 4)
        XCTAssertEqual(soundCount, 4)
        XCTAssertFalse(store.isRunning)

        store.skip()
        XCTAssertEqual(store.phase, .focus)
        XCTAssertEqual(store.focusSessionsInCycle, 0)
    }

    func testAutoStartBeginsNextSessionAfterCompletion() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        store.playCompletionSound = false
        store.autoStartNextSession = true

        store.start(at: start)
        store.tick(at: start.addingTimeInterval(store.totalSeconds))

        XCTAssertEqual(store.phase, .shortBreak)
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.remainingSeconds, 300)

        store.tick(at: start.addingTimeInterval(1_500 + 60))
        XCTAssertEqual(store.remainingSeconds, 240)
    }

    private func makeStore(
        completionSound: @escaping @MainActor () -> Void = {}
    ) -> (PomodoroStore, UserDefaults, String) {
        let suiteName = "PomodoroStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PomodoroStore(
            defaults: defaults,
            schedulesTimer: false,
            completionSound: completionSound
        )
        return (store, defaults, suiteName)
    }
}

// MARK: - TextLineOperations (editor line commands)

final class TextLineOperationsTests: XCTestCase {
    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    func testDuplicateLineInMiddle() {
        let edit = TextLineOperations.duplicate("a\nb\nc", selection: caret(2))
        XCTAssertEqual(edit.text, "a\nb\nb\nc")
    }

    func testDuplicateSingleLineWithoutTrailingNewline() {
        let edit = TextLineOperations.duplicate("abc", selection: caret(0))
        XCTAssertEqual(edit.text, "abc\nabc")
    }

    func testDeleteLine() {
        let edit = TextLineOperations.delete("a\nb\nc", selection: caret(2))
        XCTAssertEqual(edit.text, "a\nc")
    }

    func testMoveLineUp() {
        let edit = TextLineOperations.moveUp("a\nb\nc", selection: caret(2))
        XCTAssertEqual(edit?.text, "b\na\nc")
    }

    func testMoveLineDown() {
        let edit = TextLineOperations.moveDown("a\nb\nc", selection: caret(2))
        XCTAssertEqual(edit?.text, "a\nc\nb")
    }

    func testMoveUpAtTopReturnsNil() {
        XCTAssertNil(TextLineOperations.moveUp("a\nb\nc", selection: caret(0)))
    }

    func testMoveDownAtBottomReturnsNil() {
        XCTAssertNil(TextLineOperations.moveDown("a\nb\nc", selection: caret(4)))
    }

    func testMoveMultiLineSelectionUp() {
        // Select lines "b" and "c" (locations 2...4), move up over "a".
        let edit = TextLineOperations.moveUp("a\nb\nc\nd", selection: NSRange(location: 2, length: 3))
        XCTAssertEqual(edit?.text, "b\nc\na\nd")
    }

    func testLeadingWhitespaceIsCaptured() {
        XCTAssertEqual(TextLineOperations.leadingWhitespace("    hello", at: 6), "    ")
        XCTAssertEqual(TextLineOperations.leadingWhitespace("\t\tx", at: 2), "\t\t")
        XCTAssertEqual(TextLineOperations.leadingWhitespace("none", at: 1), "")
    }
}

// MARK: - FileKeyboardSelection

final class FileKeyboardSelectionTests: XCTestCase {
    private let ids = ["a", "b", "c", "d"]

    func testShiftRightExtendsSingleSelectionToTwoItems() {
        let result = FileKeyboardSelection.move(
            ids: ids,
            focusedID: "a",
            rangeAnchorID: "a",
            selectedIDs: Set(["a"]),
            delta: 1,
            extending: true
        )

        XCTAssertEqual(result.selection, Set(["a", "b"]))
        XCTAssertEqual(result.focusedID, "b")
        XCTAssertEqual(result.rangeAnchorID, "a")
    }

    func testShiftDownExtendsFromMouseSelectedItemWithoutKeyboardAnchor() {
        let result = FileKeyboardSelection.move(
            ids: ids,
            focusedID: nil,
            rangeAnchorID: nil,
            selectedIDs: Set(["b"]),
            delta: 1,
            extending: true
        )

        XCTAssertEqual(result.selection, Set(["b", "c"]))
        XCTAssertEqual(result.focusedID, "c")
        XCTAssertEqual(result.rangeAnchorID, "b")
    }

    func testRepeatedShiftRightKeepsOriginalAnchor() {
        let first = FileKeyboardSelection.move(
            ids: ids,
            focusedID: "a",
            rangeAnchorID: "a",
            selectedIDs: Set(["a"]),
            delta: 1,
            extending: true
        )
        let second = FileKeyboardSelection.move(
            ids: ids,
            focusedID: first.focusedID,
            rangeAnchorID: first.rangeAnchorID,
            selectedIDs: first.selection,
            delta: 1,
            extending: true
        )

        XCTAssertEqual(second.selection, Set(["a", "b", "c"]))
        XCTAssertEqual(second.focusedID, "c")
        XCTAssertEqual(second.rangeAnchorID, "a")
    }

    func testShiftLeftExtendsBackFromAnchor() {
        let result = FileKeyboardSelection.move(
            ids: ids,
            focusedID: "b",
            rangeAnchorID: "b",
            selectedIDs: Set(["b"]),
            delta: -1,
            extending: true
        )

        XCTAssertEqual(result.selection, Set(["a", "b"]))
        XCTAssertEqual(result.focusedID, "a")
        XCTAssertEqual(result.rangeAnchorID, "b")
    }

    func testPlainArrowCollapsesExtendedSelectionAndResetsAnchor() {
        let result = FileKeyboardSelection.move(
            ids: ids,
            focusedID: "b",
            rangeAnchorID: "a",
            selectedIDs: Set(["a", "b"]),
            delta: 1,
            extending: false
        )

        XCTAssertEqual(result.selection, Set(["c"]))
        XCTAssertEqual(result.focusedID, "c")
        XCTAssertEqual(result.rangeAnchorID, "c")
    }
}

// MARK: - FileGridKeyboardNavigation

final class FileGridKeyboardNavigationTests: XCTestCase {
    func testMeasuredColumnCountUsesActualGridPositions() {
        let frames = [
            "a": CGRect(x: 10, y: 10, width: 90, height: 120),
            "b": CGRect(x: 125, y: 10, width: 90, height: 120),
            "c": CGRect(x: 240, y: 10, width: 90, height: 120),
            "d": CGRect(x: 10, y: 155, width: 90, height: 120),
            "e": CGRect(x: 125.4, y: 155, width: 90, height: 120),
        ]

        XCTAssertEqual(FileGridKeyboardNavigation.columnCount(from: frames), 3)
    }

    func testDownMovesToTheSameColumnInTheNextRow() throws {
        let ids = ["a", "b", "c", "d", "e", "f"]
        let delta = FileGridKeyboardNavigation.verticalDelta(
            ids: ids,
            focusedID: "b",
            selectedIDs: ["b"],
            columnCount: 3,
            direction: 1
        )

        XCTAssertEqual(delta, 3)
        let result = FileKeyboardSelection.move(
            ids: ids,
            focusedID: "b",
            rangeAnchorID: "b",
            selectedIDs: ["b"],
            delta: try XCTUnwrap(delta),
            extending: false
        )
        XCTAssertEqual(result.focusedID, "e")
    }

    func testDownDoesNotJumpSidewaysWhenLastRowHasNoIconInThatColumn() {
        let delta = FileGridKeyboardNavigation.verticalDelta(
            ids: ["a", "b", "c", "d"],
            focusedID: "c",
            selectedIDs: ["c"],
            columnCount: 3,
            direction: 1
        )

        XCTAssertNil(delta)
    }
}

// MARK: - Snippets

@MainActor
final class SnippetStoreTests: EngineTestCase {
    func testFileSnippetKeepsIconSourceLabelAndFileDragRepresentation() async throws {
        let storageRoot = tempDir.appendingPathComponent("SnippetStore", isDirectory: true)
        let source = try writeFile("reference.pdf", "sample")
        let store = SnippetStore(storageRoot: storageRoot)

        store.addFiles([source])
        await store.waitForPendingImports()

        let item = try XCTUnwrap(store.snippets.first)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.originalName, "reference.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.assetURL(for: item)).path))

        store.updateTitle("Project Reference", for: item.id)
        let renamedItem = try XCTUnwrap(store.snippet(for: item.id))
        XCTAssertEqual(renamedItem.displayTitle, "Project Reference")

        let provider = store.dragProvider(for: renamedItem)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertEqual(provider.suggestedName, "reference.pdf")
    }

    // MARK: Multi-file snippets

    private func makeStore() -> SnippetStore {
        SnippetStore(storageRoot: tempDir.appendingPathComponent("SnippetStore", isDirectory: true))
    }

    func testDroppingOneFileCreatesSnippetLabelledWithFilename() async throws {
        let store = makeStore()
        store.createSnippet(withFiles: [try writeFile("notes.txt", "x")])
        await store.waitForPendingImports()

        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertEqual(store.snippets[0].title, "notes.txt")
        XCTAssertEqual(store.snippets[0].files.count, 1)
    }

    func testFileImportIsScheduledWithoutBlockingTheMainActor() async throws {
        let store = makeStore()
        store.createSnippet(withFiles: [try writeFile("background-copy.txt", "content")])

        XCTAssertEqual(store.pendingImportFileCount, 1)
        XCTAssertTrue(store.snippets.isEmpty)

        await store.waitForPendingImports()
        XCTAssertEqual(store.pendingImportFileCount, 0)
        XCTAssertEqual(store.snippets.first?.title, "background-copy.txt")
    }

    func testDroppingSeveralFilesCreatesOneSnippetHoldingThemAll() async throws {
        let store = makeStore()
        store.createSnippet(withFiles: [
            try writeFile("a.txt", "a"), try writeFile("b.txt", "b"),
        ])
        await store.waitForPendingImports()

        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertEqual(store.snippets[0].files.count, 2)
        XCTAssertEqual(store.snippets[0].title, "2 files")
    }

    func testDroppingIntoExistingSnippetAppendsRatherThanCreating() async throws {
        let store = makeStore()
        store.createSnippet(withFiles: [try writeFile("a.txt", "a")])
        await store.waitForPendingImports()
        let id = store.snippets[0].id

        store.addFiles([try writeFile("b.txt", "b"), try writeFile("c.txt", "c")], to: id)
        await store.waitForPendingImports()

        XCTAssertEqual(store.snippets.count, 1, "must not create extra snippets")
        XCTAssertEqual(store.snippets[0].files.count, 3)
        XCTAssertEqual(Set(store.snippets[0].files.map(\.originalName)), ["a.txt", "b.txt", "c.txt"])
    }

    func testRemovingOneOfManyFilesKeepsSnippet() async throws {
        let store = makeStore()
        store.createSnippet(withFiles: [
            try writeFile("a.txt", "a"), try writeFile("b.txt", "b"),
        ])
        await store.waitForPendingImports()
        let snippet = store.snippets[0]
        store.removeFile(snippet.files[0].id, from: snippet.id)

        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertEqual(store.snippets[0].files.count, 1)
    }

    func testRemovingLastFileDeletesSnippet() async throws {
        let store = makeStore()
        store.createSnippet(withFiles: [try writeFile("only.txt", "x")])
        await store.waitForPendingImports()
        let snippet = store.snippets[0]
        store.removeFile(snippet.files[0].id, from: snippet.id)

        XCTAssertTrue(store.snippets.isEmpty)
    }

    /// Snippets saved before multi-file support have no `files` key — they must
    /// still decode rather than wiping the user's library.
    func testLegacySnippetJSONWithoutFilesStillDecodes() throws {
        let json = Data("""
        {"id":"11111111-1111-1111-1111-111111111111","kind":"file","title":"old",
         "text":"","filename":"f.txt","originalName":"f.txt",
         "createdAt":0,"updatedAt":0}
        """.utf8)
        let item = try JSONDecoder().decode(SnippetItem.self, from: json)

        XCTAssertEqual(item.filename, "f.txt")
        XCTAssertTrue(item.files.isEmpty)
    }

    func testLargeTextPreviewIsBounded() {
        let text = String(repeating: "long line of text ", count: 100_000)
        let now = Date()
        let item = SnippetItem(
            id: UUID(),
            kind: .text,
            title: "Large",
            text: text,
            filename: nil,
            originalName: nil,
            createdAt: now,
            updatedAt: now
        )

        XCTAssertLessThanOrEqual(item.preview.count, SnippetItem.listPreviewCharacterLimit + 3)
        XCTAssertEqual(item.detailText.count, SnippetItem.detailPreviewCharacterLimit)
        XCTAssertTrue(item.isDetailTextTruncated)
    }

    func testOversizedTextIsRejected() {
        let store = makeStore()
        store.addText(String(repeating: "x", count: SnippetItem.maximumTextBytes + 1))

        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertNotNil(store.lastError)
    }
}

// MARK: - BatchRenameEngine

final class BatchRenameTests: EngineTestCase {
    private func options(
        pattern: String,
        padding: Int = 3,
        start: Int = 1,
        preservesExtension: Bool = true
    ) -> BatchRenameOptions {
        BatchRenameOptions(
            pattern: pattern,
            dateFormat: "yyyyMMdd",
            sequenceStart: start,
            sequencePadding: padding,
            preservesExtension: preservesExtension
        )
    }

    func testSequencePaddingAndExtensionPreserved() async throws {
        let items = [
            FileItem.make(url: try writeFile("a.jpg")),
            FileItem.make(url: try writeFile("b.jpg")),
        ]
        let previews = await BatchRenameEngine.previews(for: items, options: options(pattern: "shot-{seq}"))
        XCTAssertEqual(previews.map(\.newName), ["shot-001.jpg", "shot-002.jpg"])
    }

    func testNameTokenIsSubstituted() async throws {
        let item = FileItem.make(url: try writeFile("holiday.png"))
        let previews = await BatchRenameEngine.previews(for: [item], options: options(pattern: "{name}-edited"))
        XCTAssertEqual(previews.first?.newName, "holiday-edited.png")
    }

    func testDuplicateInBatchIsFlagged() async throws {
        let items = [
            FileItem.make(url: try writeFile("a.txt")),
            FileItem.make(url: try writeFile("b.txt")),
        ]
        let previews = await BatchRenameEngine.previews(for: items, options: options(pattern: "fixed"))
        XCTAssertEqual(previews[1].warning, "Duplicate in batch")
    }

    func testRenameActuallyMovesFiles() async throws {
        let url = try writeFile("original.txt")
        let record = try await BatchRenameEngine.rename([FileItem.make(url: url)], options: options(pattern: "renamed-{seq}"))
        XCTAssertEqual(record.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(record.first?.destination.lastPathComponent, "renamed-001.txt")
    }
}

// MARK: - DuplicateFinder

final class DuplicateFinderTests: EngineTestCase {
    func testFindsIdenticalImagesAcrossFolders() async throws {
        let left = try await FileOperations.newFolder(named: "left", in: tempDir)
        let right = try await FileOperations.newFolder(named: "right", in: tempDir)
        // Identical content in both, plus a unique image in each.
        try makePNG("dup.png", width: 40, height: 40, gray: 0.3, in: left)
        try makePNG("dup.png", width: 40, height: 40, gray: 0.3, in: right)
        try makePNG("onlyleft.png", width: 40, height: 40, gray: 0.9, in: left)
        try makePNG("onlyright.png", width: 40, height: 40, gray: 0.1, in: right)

        let result = try await DuplicateFinder.findAcross(
            leftFolder: left, rightFolder: right, includeHidden: false)

        XCTAssertEqual(result.duplicateGroupCount, 1)
        XCTAssertEqual(result.leftItems.count, 1)
        XCTAssertEqual(result.rightItems.count, 1)
        XCTAssertEqual(result.leftItems.first?.name, "dup.png")
    }
}

// MARK: - FolderCompare

final class FolderCompareTests: EngineTestCase {
    func testDetectsOnlyLeftAndOnlyRight() async throws {
        let left = try await FileOperations.newFolder(named: "L", in: tempDir)
        let right = try await FileOperations.newFolder(named: "R", in: tempDir)
        try writeFile("shared.txt", "same", in: left)
        try writeFile("shared.txt", "same", in: right)
        try writeFile("leftonly.txt", "x", in: left)
        try writeFile("rightonly.txt", "y", in: right)

        let result = try await FolderCompare.compare(
            leftFolder: left, rightFolder: right, includeHidden: false, progress: { _, _ in })

        XCTAssertEqual(result.summary.onlyLeft, 1)
        XCTAssertEqual(result.summary.onlyRight, 1)
    }
}

// MARK: - FileItem preview classification

final class FileItemClassificationTests: EngineTestCase {
    private func item(_ name: String) throws -> FileItem {
        FileItem.make(url: try writeFile(name))
    }

    func testTextAndSourceFilesAreText() throws {
        for name in ["notes.txt", "readme.md", "server.log", "data.csv", "app.swift", "config.json"] {
            let item = try item(name)
            XCTAssertTrue(item.isText, "\(name) should be text")
            XCTAssertFalse(item.isImage, "\(name) should not be image")
            XCTAssertFalse(item.isRichDocument, "\(name) should not be a rich document")
        }
    }

    func testRichDocumentsAreClassified() throws {
        for name in ["report.pdf", "memo.rtf", "sheet.xlsx", "deck.pptx"] {
            let item = try item(name)
            XCTAssertTrue(item.isRichDocument, "\(name) should be a rich document")
            XCTAssertFalse(item.isText, "\(name) should not be text")
        }
    }

    func testImageIsNotText() throws {
        let img = FileItem.make(url: try makePNG("photo.png", width: 10, height: 10))
        XCTAssertTrue(img.isImage)
        XCTAssertFalse(img.isText)
        XCTAssertFalse(img.isRichDocument)
    }

    func testAudioIsPlayableMedia() throws {
        let item = try item("recording.mp3")
        XCTAssertTrue(item.isAudioMedia)
        XCTAssertTrue(item.isPlayableMedia)
        XCTAssertTrue(item.isPreviewable)
    }

    func testUnknownBinaryFallsThrough() throws {
        let item = try item("blob.bin")
        XCTAssertFalse(item.isText)
        XCTAssertFalse(item.isRichDocument)
        XCTAssertFalse(item.isImage)
    }

    func testDirectoryIsNeverTextOrDocument() async throws {
        let dir = try await FileOperations.newFolder(named: "folder", in: tempDir)
        let item = FileItem.make(url: dir)
        XCTAssertTrue(item.isDirectory)
        XCTAssertFalse(item.isText)
        XCTAssertFalse(item.isRichDocument)
    }

    func testSpreadsheetAndApplicationBundlesAreClassified() throws {
        let csv = FileItem.make(url: try writeFile("table.csv", "Name,Value\nA,1\n"))
        XCTAssertTrue(csv.isSpreadsheet)
        XCTAssertTrue(csv.isDelimitedSpreadsheet)

        let numbers = tempDir.appendingPathComponent("Budget.numbers", isDirectory: true)
        try FileManager.default.createDirectory(at: numbers, withIntermediateDirectories: true)
        XCTAssertTrue(FileItem.make(url: numbers).isSpreadsheet)

        let app = tempDir.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let application = FileItem.make(url: app)
        XCTAssertTrue(application.isDirectory)
        XCTAssertTrue(application.isApplicationBundle)
    }

    func testAdditionalToolTypesAreClassified() throws {
        let installer = tempDir.appendingPathComponent("Installer.pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: installer, withIntermediateDirectories: true)

        XCTAssertTrue(FileItem.make(url: try writeFile("disk.dmg")).isDiskImage)
        XCTAssertTrue(FileItem.make(url: installer).isInstallerPackage)
        XCTAssertTrue(FileItem.make(url: installer).isToolPackage)
        XCTAssertTrue(FileItem.make(url: try writeFile("deck.key")).isPresentation)
        XCTAssertTrue(FileItem.make(url: try writeFile("typeface.otf")).isFontFile)
        XCTAssertTrue(FileItem.make(url: try writeFile("book.epub")).isEPUB)
        XCTAssertTrue(FileItem.make(url: try writeFile("bundle.tar.gz")).isArchive)
        XCTAssertTrue(FileItem.make(url: try writeFile("person.vcf")).isContactCard)
    }
}

final class TextFilePreviewLoaderTests: EngineTestCase {
    func testLargeCSVPreviewShowsHeaderAndFirstTenDataRows() async throws {
        let value = String(repeating: "x", count: 640)
        let firstRows = (1...30).map { "\($0),\(value)" }.joined(separator: "\n")
        let repeatedTail = String(repeating: "\n9999,\(value)", count: 21_000)
        let url = try writeFile(
            "large.csv",
            "row,value\n\(firstRows)\(repeatedTail)"
        )

        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertGreaterThan(fileSize ?? 0, 13_000_000)

        let result = try await TextFilePreviewLoader.loadDelimited(
            from: url,
            separator: .comma
        )

        XCTAssertEqual(result.limit, .rows(10))
        XCTAssertEqual(result.header, ["row", "value"])
        XCTAssertEqual(result.rows.count, 10)
        XCTAssertEqual(result.rows.first, ["1", value])
        XCTAssertEqual(result.rows.last, ["10", value])
    }

    func testCSVPreviewTreatsQuotedNewlinesAsPartOfOneRow() async throws {
        let url = try writeFile(
            "quoted.csv",
            """
            name,notes
            Alice,"Line one
            Line two"
            Bob,Visible only after the preview limit
            """
        )

        let result = try await TextFilePreviewLoader.loadDelimited(
            from: url,
            separator: .comma,
            dataRowLimit: 1
        )

        XCTAssertEqual(result.limit, .rows(1))
        XCTAssertEqual(result.header, ["name", "notes"])
        XCTAssertEqual(result.rows, [["Alice", "Line one\nLine two"]])
    }

    func testCSVPreviewCapsPathologicallyWideRowsBeforeRendering() async throws {
        let wideValue = String(repeating: "x", count: TextFilePreviewLoader.delimitedByteCap * 2)
        let url = try writeFile(
            "wide.csv",
            "name,value\nfirst,\(wideValue)\nsecond,not visible"
        )

        let result = try await TextFilePreviewLoader.loadDelimited(
            from: url,
            separator: .comma
        )

        XCTAssertEqual(result.limit, .bytes(TextFilePreviewLoader.delimitedByteCap))
        XCTAssertEqual(result.header, ["name", "value"])
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testCSVPreviewParsesQuotedCommasAndEscapedQuotes() async throws {
        let url = try writeFile(
            "quoted-fields.csv",
            "name,notes\nAlice,\"Hello, \"\"Workbench\"\"\""
        )

        let result = try await TextFilePreviewLoader.loadDelimited(
            from: url,
            separator: .comma
        )

        XCTAssertEqual(result.header, ["name", "notes"])
        XCTAssertEqual(result.rows, [["Alice", "Hello, \"Workbench\""]])
        XCTAssertNil(result.limit)
    }

    func testCSVPreviewTreatsCRLFAsRecordBoundary() async throws {
        let url = try writeFile(
            "windows-line-endings.csv",
            ",Title,Ingredients,Instructions,Image_Name,Cleaned_Ingredients\r\n"
                + "0,Miso-Butter Roast Chicken,\"['whole chicken', 'salt']\",Roast it,image.jpg,\"['whole chicken', 'salt']\"\r\n"
                + "1,Second Recipe,\"['flour']\",Bake it,second.jpg,\"['flour']\""
        )

        let result = try await TextFilePreviewLoader.loadDelimited(
            from: url,
            separator: .comma,
            dataRowLimit: 1
        )

        XCTAssertEqual(
            result.header,
            ["", "Title", "Ingredients", "Instructions", "Image_Name", "Cleaned_Ingredients"]
        )
        XCTAssertEqual(
            result.rows,
            [["0", "Miso-Butter Roast Chicken", "['whole chicken', 'salt']", "Roast it", "image.jpg", "['whole chicken', 'salt']"]]
        )
        XCTAssertEqual(result.limit, .rows(1))
    }

    func testTSVPreviewUsesFirstRecordAsHeader() async throws {
        let url = try writeFile(
            "table.tsv",
            "name\tvalue\nAlpha\t1\nBeta\t2"
        )

        let result = try await TextFilePreviewLoader.loadDelimited(
            from: url,
            separator: .tab
        )

        XCTAssertEqual(result.header, ["name", "value"])
        XCTAssertEqual(result.rows, [["Alpha", "1"], ["Beta", "2"]])
        XCTAssertNil(result.limit)
    }
}

final class InlineRenameSelectionTests: XCTestCase {
    func testFileRenameSelectsTheNameWithoutItsExtension() {
        XCTAssertEqual(
            InlineRenameSelection.range(for: "Quarterly Report.final.pdf", isDirectory: false),
            NSRange(location: 0, length: 22)
        )
    }

    func testExtensionlessFileAndFolderSelectTheirEntireName() {
        XCTAssertEqual(
            InlineRenameSelection.range(for: "README", isDirectory: false),
            NSRange(location: 0, length: 6)
        )
        XCTAssertEqual(
            InlineRenameSelection.range(for: "Project Archive", isDirectory: true),
            NSRange(location: 0, length: 15)
        )
    }
}

// MARK: - Calendar Tool

final class CalendarToolDateMathTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private var anchorDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
    }

    func testMovesBySelectedPeriod() {
        XCTAssertEqual(
            components(of: CalendarToolDateMath.date(
                byMoving: .week,
                offset: 1,
                from: anchorDate,
                calendar: calendar
            )),
            DateComponents(year: 2026, month: 7, day: 22)
        )
        XCTAssertEqual(
            components(of: CalendarToolDateMath.date(
                byMoving: .month,
                offset: 1,
                from: anchorDate,
                calendar: calendar
            )),
            DateComponents(year: 2026, month: 8, day: 15)
        )
        XCTAssertEqual(
            components(of: CalendarToolDateMath.date(
                byMoving: .year,
                offset: 1,
                from: anchorDate,
                calendar: calendar
            )),
            DateComponents(year: 2027, month: 7, day: 15)
        )
    }

    func testWeekContainsSevenLocaleOrderedDays() throws {
        let dates = CalendarToolDateMath.weekDates(containing: anchorDate, calendar: calendar)

        XCTAssertEqual(dates.count, 7)
        XCTAssertEqual(components(of: try XCTUnwrap(dates.first)), DateComponents(year: 2026, month: 7, day: 13))
        XCTAssertEqual(components(of: try XCTUnwrap(dates.last)), DateComponents(year: 2026, month: 7, day: 19))
    }

    func testWeekRangeSupportsUpToTenWeeks() throws {
        let dates = CalendarToolDateMath.weekDates(
            containing: anchorDate,
            numberOfWeeks: 10,
            calendar: calendar
        )

        XCTAssertEqual(dates.count, 70)
        XCTAssertEqual(components(of: try XCTUnwrap(dates.first)), DateComponents(year: 2026, month: 7, day: 13))
        XCTAssertEqual(components(of: try XCTUnwrap(dates.last)), DateComponents(year: 2026, month: 9, day: 20))
    }

    func testWeekRowsMarkOnlyMonthTransitions() throws {
        let weeks = CalendarToolDateMath.weekRows(
            containing: anchorDate,
            numberOfWeeks: 4,
            calendar: calendar
        )

        XCTAssertEqual(weeks.count, 4)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
        XCTAssertFalse(CalendarToolDateMath.startsInDifferentMonth(
            weeks[1],
            than: weeks[0],
            calendar: calendar
        ))
        XCTAssertFalse(CalendarToolDateMath.startsInDifferentMonth(
            weeks[2],
            than: weeks[1],
            calendar: calendar
        ))
        XCTAssertTrue(CalendarToolDateMath.startsInDifferentMonth(
            weeks[3],
            than: weeks[2],
            calendar: calendar
        ))
        XCTAssertEqual(
            components(of: try XCTUnwrap(weeks[3].first)),
            DateComponents(year: 2026, month: 8, day: 3)
        )
    }

    func testMonthGridAlwaysContainsSixWeeks() throws {
        let dates = CalendarToolDateMath.monthGrid(containing: anchorDate, calendar: calendar)

        XCTAssertEqual(dates.count, 42)
        XCTAssertEqual(components(of: try XCTUnwrap(dates.first)), DateComponents(year: 2026, month: 6, day: 29))
        XCTAssertEqual(components(of: try XCTUnwrap(dates.last)), DateComponents(year: 2026, month: 8, day: 9))
    }

    func testYearContainsAllTwelveMonths() throws {
        let months = CalendarToolDateMath.months(inYearContaining: anchorDate, calendar: calendar)

        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(components(of: try XCTUnwrap(months.first)), DateComponents(year: 2026, month: 1, day: 1))
        XCTAssertEqual(components(of: try XCTUnwrap(months.last)), DateComponents(year: 2026, month: 12, day: 1))
    }

    private func components(of date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }
}

final class CalendarToolDateRangeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testRangeNormalizesDraggedBackwardSelection() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 15))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 9))!

        let range = CalendarToolDateRange(startDate: start, endDate: end, calendar: calendar)

        XCTAssertEqual(components(of: range.startDate), DateComponents(year: 2026, month: 8, day: 2))
        XCTAssertEqual(components(of: range.endDate), DateComponents(year: 2026, month: 8, day: 4))
        XCTAssertEqual(range.dayCount(calendar: calendar), 3)
        XCTAssertTrue(range.contains(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 22))!,
            calendar: calendar
        ))
    }

    func testRangeOverlapIsInclusive() {
        let first = CalendarToolDateRange(
            startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!,
            endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 4))!,
            calendar: calendar
        )
        let second = CalendarToolDateRange(
            startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 4))!,
            endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 5))!,
            calendar: calendar
        )

        XCTAssertTrue(first.overlaps(second))
    }

    private func components(of date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }
}

final class CalendarToolReminderLeadTimeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testHoursAndDaysResolveNotificationTriggerDate() {
        let range = CalendarToolDateRange(
            startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!,
            endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))!,
            calendar: calendar
        )

        XCTAssertEqual(
            components(of: CalendarToolReminderLeadTime(value: 4, unit: .hours).triggerDate(
                for: range,
                calendar: calendar
            )!),
            DateComponents(year: 2026, month: 8, day: 1, hour: 20, minute: 0)
        )
        XCTAssertEqual(
            components(of: CalendarToolReminderLeadTime(value: 2, unit: .days).triggerDate(
                for: range,
                calendar: calendar
            )!),
            DateComponents(year: 2026, month: 7, day: 31, hour: 0, minute: 0)
        )
    }

    func testLeadValueIsClampedToSupportedRange() {
        XCTAssertEqual(CalendarToolReminderLeadTime(value: -8, unit: .hours).value, 1)
        XCTAssertEqual(CalendarToolReminderLeadTime(value: 900, unit: .days).value, 365)
    }

    private func components(of date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}

@MainActor
final class CalendarToolReminderStoreTests: XCTestCase {
    private final class FakeCalendarReminderNotificationScheduler: CalendarToolReminderNotificationScheduling {
        private(set) var scheduledReminders: [CalendarToolReminder] = []
        private(set) var cancelledReminders: [CalendarToolReminder] = []

        func schedule(_ reminder: CalendarToolReminder, calendar: Calendar, now: Date) {
            scheduledReminders.append(reminder)
        }

        func cancel(_ reminder: CalendarToolReminder) {
            cancelledReminders.append(reminder)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testAddsAndPersistsRangeReminder() {
        withStore { store, defaults, scheduler in
            let range = CalendarToolDateRange(
                startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!,
                endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 4))!,
                calendar: calendar
            )
            let leadTime = CalendarToolReminderLeadTime(value: 2, unit: .hours)

            let reminder = store.add(
                title: "   Project sprint   ",
                range: range,
                notificationLeadTime: leadTime,
                calendar: calendar,
                now: calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
            )

            XCTAssertEqual(reminder.title, "Project sprint")
            XCTAssertEqual(reminder.notificationLeadTime, leadTime)
            XCTAssertEqual(scheduler.scheduledReminders.map(\.id), [reminder.id])
            XCTAssertTrue(store.hasReminder(
                on: calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))!,
                calendar: calendar
            ))

            let reloaded = CalendarToolReminderStore(
                defaults: defaults,
                notificationScheduler: scheduler
            )
            XCTAssertEqual(reloaded.reminders.count, 1)
            XCTAssertEqual(reloaded.reminders[0].title, "Project sprint")
            XCTAssertEqual(reloaded.reminders[0].notificationLeadTime, leadTime)
            XCTAssertEqual(reloaded.reminders(overlapping: range).count, 1)
        }
    }

    func testDeleteReminderPersistsRemoval() {
        withStore { store, defaults, scheduler in
            let range = CalendarToolDateRange(
                startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!,
                endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!,
                calendar: calendar
            )
            let reminder = store.add(title: "", range: range)

            XCTAssertEqual(reminder.title, "Reminder")
            store.delete(reminder)

            XCTAssertEqual(scheduler.cancelledReminders.map(\.id), [reminder.id])
            XCTAssertTrue(CalendarToolReminderStore(
                defaults: defaults,
                notificationScheduler: scheduler
            ).reminders.isEmpty)
        }
    }

    func testLegacyReminderJSONLoadsWithDefaultNotificationLeadTime() throws {
        struct LegacyReminder: Codable {
            let id: UUID
            var title: String
            var range: CalendarToolDateRange
            let createdAt: Date
        }

        let suiteName = "CalendarToolReminderStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacy = LegacyReminder(
            id: UUID(),
            title: "Old reminder",
            range: CalendarToolDateRange(
                startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!,
                endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))!,
                calendar: calendar
            ),
            createdAt: calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "calendarTool.reminders")

        let store = CalendarToolReminderStore(
            defaults: defaults,
            notificationScheduler: FakeCalendarReminderNotificationScheduler()
        )

        XCTAssertEqual(store.reminders.first?.notificationLeadTime, .defaultValue)
    }

    private func withStore(
        _ body: (
            CalendarToolReminderStore,
            UserDefaults,
            FakeCalendarReminderNotificationScheduler
        ) -> Void
    ) {
        let suiteName = "CalendarToolReminderStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = FakeCalendarReminderNotificationScheduler()
        body(CalendarToolReminderStore(
            defaults: defaults,
            notificationScheduler: scheduler
        ), defaults, scheduler)
    }
}

// MARK: - Pro Tools Access

final class ProToolsAccessPolicyTests: XCTestCase {
    func testRequiresScreenRecordingAndMicrophone() {
        XCTAssertEqual(
            ProToolsAccessPolicy.requiredPermissions,
            [.screenRecording, .microphone]
        )
    }

    func testMissingPermissionsTracksBothRequirements() {
        XCTAssertEqual(
            ProToolsAccessPolicy.missingPermissions(
                screenRecording: .notDetermined,
                microphone: .denied
            ),
            [.screenRecording, .microphone]
        )
        XCTAssertEqual(
            ProToolsAccessPolicy.missingPermissions(
                screenRecording: .granted,
                microphone: .denied
            ),
            [.microphone]
        )
        XCTAssertTrue(ProToolsAccessPolicy.missingPermissions(
            screenRecording: .granted,
            microphone: .granted
        ).isEmpty)
    }
}

// MARK: - ModifiedDateFilter

final class ModifiedDateFilterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 11,
            hour: 12
        ))!
    }

    func testWithinHour() {
        let recent = calendar.date(byAdding: .minute, value: -30, to: now)!
        let earlier = calendar.date(byAdding: .hour, value: -2, to: now)!

        XCTAssertTrue(ModifiedDateFilter.withinHour.matches(modified: recent, now: now, calendar: calendar))
        XCTAssertFalse(ModifiedDateFilter.withinHour.matches(modified: earlier, now: now, calendar: calendar))
    }

    func testTodayUsesLastTwentyFourHours() {
        let twentyThreeHoursAgo = calendar.date(byAdding: .hour, value: -23, to: now)!
        let twentyFiveHoursAgo = calendar.date(byAdding: .hour, value: -25, to: now)!

        XCTAssertTrue(ModifiedDateFilter.today.matches(modified: twentyThreeHoursAgo, now: now, calendar: calendar))
        XCTAssertFalse(ModifiedDateFilter.today.matches(modified: twentyFiveHoursAgo, now: now, calendar: calendar))
    }

    func testWithinWeekUsesLastSevenDays() {
        let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now)!
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: now)!

        XCTAssertTrue(ModifiedDateFilter.withinWeek.matches(modified: sixDaysAgo, now: now, calendar: calendar))
        XCTAssertFalse(ModifiedDateFilter.withinWeek.matches(modified: eightDaysAgo, now: now, calendar: calendar))
    }

    func testWithinMonthUsesRollingCalendarMonth() {
        let twentyEightDaysAgo = calendar.date(byAdding: .day, value: -28, to: now)!
        let fiveWeeksAgo = calendar.date(byAdding: .day, value: -35, to: now)!

        XCTAssertTrue(ModifiedDateFilter.withinMonth.matches(
            modified: twentyEightDaysAgo,
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(ModifiedDateFilter.withinMonth.matches(
            modified: fiveWeeksAgo,
            now: now,
            calendar: calendar
        ))
    }

    func testCreatedOrModifiedDateCanMatch() {
        let recent = calendar.date(byAdding: .minute, value: -20, to: now)!
        let old = calendar.date(byAdding: .day, value: -10, to: now)!

        XCTAssertTrue(ModifiedDateFilter.withinHour.matches(
            created: recent,
            modified: old,
            now: now,
            calendar: calendar
        ))
        XCTAssertTrue(ModifiedDateFilter.withinHour.matches(
            created: old,
            modified: recent,
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(ModifiedDateFilter.withinHour.matches(
            created: old,
            modified: old,
            now: now,
            calendar: calendar
        ))
    }

    func testOlderThanOneAndTwoYears() {
        let eighteenMonthsAgo = calendar.date(byAdding: .month, value: -18, to: now)!
        let threeYearsAgo = calendar.date(byAdding: .year, value: -3, to: now)!

        XCTAssertTrue(ModifiedDateFilter.olderThanOneYear.matches(
            modified: eighteenMonthsAgo,
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(ModifiedDateFilter.olderThanTwoYears.matches(
            modified: eighteenMonthsAgo,
            now: now,
            calendar: calendar
        ))
        XCTAssertTrue(ModifiedDateFilter.olderThanTwoYears.matches(
            modified: threeYearsAgo,
            now: now,
            calendar: calendar
        ))
    }
}

// MARK: - FileSizeFilter

final class FileSizeFilterTests: XCTestCase {
    func testPresetsMatchTheirLabelledSize() {
        let megabyte: Int64 = 1_024 * 1_024
        let gigabyte = megabyte * 1_024
        let oneHundredSixAndAHalfMegabytes = megabyte * 106 + megabyte / 2
        let fourHundredNinetyNineMegabytes = megabyte * 499

        XCTAssertTrue(FileSizeFilter.upToOneMegabyte.matches(size: megabyte))
        XCTAssertFalse(FileSizeFilter.upToOneMegabyte.matches(size: megabyte * 2))
        XCTAssertTrue(FileSizeFilter.oneToTenMegabytes.matches(size: megabyte * 10))
        XCTAssertFalse(FileSizeFilter.oneToTenMegabytes.matches(size: megabyte * 20))
        XCTAssertTrue(FileSizeFilter.tenToHundredMegabytes.matches(size: oneHundredSixAndAHalfMegabytes))
        XCTAssertFalse(FileSizeFilter.hundredMegabytesToOneGigabyte.matches(
            size: oneHundredSixAndAHalfMegabytes
        ))
        XCTAssertTrue(FileSizeFilter.hundredMegabytesToOneGigabyte.matches(
            size: fourHundredNinetyNineMegabytes
        ))
        XCTAssertTrue(FileSizeFilter.hundredMegabytesToOneGigabyte.matches(size: gigabyte))
        XCTAssertTrue(FileSizeFilter.hundredMegabytesToOneGigabyte.matches(size: gigabyte * 8))
        XCTAssertFalse(FileSizeFilter.hundredMegabytesToOneGigabyte.matches(size: megabyte * 200))
        XCTAssertTrue(FileSizeFilter.oneGigabyteOrLarger.matches(size: gigabyte * 2))
    }

    func testFolderMatchRequiresAFileInItsContents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 10 * 1_024 * 1_024).write(to: nested.appendingPathComponent("large.bin"))

        let containsOneToTenMegabyteFile = try await PaneModel.folderContainsMatchingFile(
            in: root,
            filter: .oneToTenMegabytes,
            includeHidden: false
        )
        let containsHundredMegabyteFile = try await PaneModel.folderContainsMatchingFile(
            in: root,
            filter: .hundredMegabytesToOneGigabyte,
            includeHidden: false
        )

        XCTAssertTrue(containsOneToTenMegabyteFile)
        XCTAssertFalse(containsHundredMegabyteFile)
    }
}

// MARK: - ItemKindFilter

final class ItemKindFilterTests: XCTestCase {
    func testFileAndFolderFiltersAreMutuallyExclusive() {
        XCTAssertTrue(ItemKindFilter.files.matches(isDirectory: false))
        XCTAssertFalse(ItemKindFilter.files.matches(isDirectory: true))
        XCTAssertTrue(ItemKindFilter.folders.matches(isDirectory: true))
        XCTAssertFalse(ItemKindFilter.folders.matches(isDirectory: false))
    }
}

// MARK: - PaneModel navigation

@MainActor
final class PaneModelNavigationTests: EngineTestCase {
    func testNavigatingToCurrentFolderRefreshesIt() {
        let model = PaneModel(url: tempDir)
        model.loadError = "Stale error"

        model.navigate(to: tempDir)

        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.isLoading)
    }

    func testClearQuickFiltersResetsDateSizeAndKind() {
        let model = PaneModel(url: tempDir)
        model.modifiedDateFilter = .today
        model.fileSizeFilter = .oneToTenMegabytes
        model.itemKindFilter = .files

        XCTAssertTrue(model.hasQuickFilters)

        model.clearQuickFilters()

        XCTAssertEqual(model.modifiedDateFilter, .all)
        XCTAssertEqual(model.fileSizeFilter, .all)
        XCTAssertEqual(model.itemKindFilter, .all)
        XCTAssertFalse(model.hasQuickFilters)
    }

    func testFilteringPrunesHiddenItemsFromSelection() throws {
        let image = FileItem.make(url: try writeFile("photo.png"))
        let hiddenText = FileItem.make(url: try writeFile("notes.txt"))
        let model = PaneModel(url: tempDir)
        model.items = [image, hiddenText]
        model.selection = [image.id, hiddenText.id]

        model.typePreset = .images

        XCTAssertEqual(model.displayItems.map(\.id), [image.id])
        XCTAssertEqual(model.selection, [image.id])
        XCTAssertEqual(model.selectedItems.map(\.id), [image.id])
    }

    func testVisiblePaneRefreshesWhenExternalFileAppears() async throws {
        let model = PaneModel(url: tempDir)
        model.startMonitoring()
        defer { model.stopMonitoring() }

        let didLoadInitialListing = await waitUntil { !model.isLoading }
        XCTAssertTrue(didLoadInitialListing)
        XCTAssertTrue(model.items.isEmpty)

        try writeFile("browser-download.zip")

        let didObserveDownload = await waitUntil {
            model.items.contains { $0.name == "browser-download.zip" }
        }
        XCTAssertTrue(didObserveDownload)
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

// MARK: - ImageProcessing

final class DocumentPDFConverterTests: EngineTestCase {
    func testConvertsPlainTextDocumentToPDF() async throws {
        let source = try writeFile("journal.txt", "A short note for PDF conversion.")
        let item = FileItem.make(url: source)

        XCTAssertTrue(DocumentPDFConverter.canConvert(item))

        let output = try await DocumentPDFConverter.convert(item)
        let header = try Data(contentsOf: output).prefix(4)

        XCTAssertEqual(output.lastPathComponent, "journal-converted.pdf")
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "%PDF")
    }

    func testDoesNotOfferConversionForExistingPDF() throws {
        let source = try writeFile("existing.pdf", "%PDF-1.7")

        XCTAssertFalse(DocumentPDFConverter.canConvert(FileItem.make(url: source)))
    }

    func testOffersConversionForPagesDocuments() throws {
        let source = try writeFile("journal.pages", "")

        XCTAssertTrue(DocumentPDFConverter.canConvert(FileItem.make(url: source)))
    }
}

final class TextAndSpreadsheetToolsTests: EngineTestCase {
    func testFormatsAndMinifiesJSONIntoNewFiles() async throws {
        let source = try writeFile("settings.json", "{\"b\":2,\"a\":[\"x\",true]}")

        let formatted = try await TextFileTools.formatJSON(at: source)
        let minified = try await TextFileTools.minifyJSON(at: source)
        try await TextFileTools.validateJSON(at: formatted)
        try await TextFileTools.validateJSON(at: minified)

        XCTAssertEqual(formatted.lastPathComponent, "settings-formatted.json")
        XCTAssertEqual(minified.lastPathComponent, "settings-minified.json")
        XCTAssertTrue(try String(contentsOf: formatted, encoding: .utf8).contains("\n"))
        XCTAssertFalse(try String(contentsOf: minified, encoding: .utf8).contains("\n"))
    }

    func testConvertsQuotedCSVToTSVAndReportsTableShape() async throws {
        let source = try writeFile(
            "table.csv",
            "Name,Notes\nA,\"two, values\"\nB,\"line one\nline two\"\n"
        )

        let summary = try await SpreadsheetTools.summary(at: source)
        let tsv = try await SpreadsheetTools.convertDelimitedText(at: source, to: .tsv)
        let roundTrip = try await SpreadsheetTools.convertDelimitedText(at: tsv, to: .csv)

        XCTAssertEqual(summary.rowCount, 3)
        XCTAssertEqual(summary.columnCount, 2)
        XCTAssertEqual(tsv.lastPathComponent, "table-converted.tsv")
        XCTAssertTrue(try String(contentsOf: tsv, encoding: .utf8).contains("A\ttwo, values"))
        XCTAssertTrue(try String(contentsOf: roundTrip, encoding: .utf8).contains("\"two, values\""))
    }

    func testReadsApplicationBundleDetails() throws {
        let app = tempDir.appendingPathComponent("Example.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleDisplayName": "Example",
            "CFBundleIdentifier": "com.example.app",
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "Example",
            "LSMinimumSystemVersion": "14.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let details = try XCTUnwrap(ApplicationBundleTools.details(for: FileItem.make(url: app)))

        XCTAssertEqual(details.name, "Example")
        XCTAssertEqual(details.bundleIdentifier, "com.example.app")
        XCTAssertEqual(details.build, "42")
    }
}

final class AdditionalFileToolsTests: EngineTestCase {
    func testReadsContactCardDetails() async throws {
        let contact = try writeFile(
            "ada.vcf",
            """
            BEGIN:VCARD
            VERSION:3.0
            FN:Ada Lovelace
            ORG:Analytical Engines
            EMAIL;TYPE=WORK:ada@example.com
            TEL;TYPE=CELL:+63 900 123 4567
            END:VCARD
            """
        )

        let details = try await ContactCardTools.details(at: contact)

        XCTAssertEqual(details.name, "Ada Lovelace")
        XCTAssertEqual(details.organization, "Analytical Engines")
        XCTAssertEqual(details.emails, ["ada@example.com"])
        XCTAssertEqual(details.phones, ["+63 900 123 4567"])
    }

    func testReadsEBookMetadata() async throws {
        let metaInf = tempDir.appendingPathComponent("META-INF", isDirectory: true)
        let ops = tempDir.appendingPathComponent("OPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        try writeFile(
            "container.xml",
            """
            <?xml version="1.0"?>
            <container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>
            """,
            in: metaInf
        )
        try writeFile(
            "package.opf",
            """
            <?xml version="1.0"?>
            <package><metadata><title>Test Book</title><creator>Test Author</creator><language>en</language></metadata></package>
            """,
            in: ops
        )
        let book = tempDir.appendingPathComponent("book.epub")
        try runProcess(
            "/usr/bin/zip",
            ["-q", "-r", book.path, "META-INF", "OPS"],
            currentDirectory: tempDir
        )

        let details = try await EBookTools.details(at: book)

        XCTAssertEqual(details.title, "Test Book")
        XCTAssertEqual(details.author, "Test Author")
        XCTAssertEqual(details.language, "en")
    }

    func testListsAndExtractsTarArchive() async throws {
        let payload = try writeFile("payload.txt", "archive contents")
        let archive = tempDir.appendingPathComponent("payload.tar")
        try runProcess(
            "/usr/bin/tar",
            ["-cf", archive.path, "-C", tempDir.path, payload.lastPathComponent]
        )

        let entries = try await ArchiveTools.entries(in: archive)
        let output = try await ArchiveTools.extract(at: archive)

        XCTAssertEqual(entries, ["payload.txt"])
        XCTAssertEqual(
            try String(contentsOf: output.appendingPathComponent("payload.txt"), encoding: .utf8),
            "archive contents"
        )
    }

    func testListsZipArchiveSynchronously() throws {
        let source = tempDir.appendingPathComponent("zip-source", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile("inside.txt", "zip contents", in: nested)

        let archive = tempDir.appendingPathComponent("payload.zip")
        try runFixtureProcess(
            "/usr/bin/zip",
            ["-q", "-r", archive.path, "nested"],
            currentDirectory: source
        )

        let entries = try ArchiveTools.entriesSync(in: archive)

        XCTAssertTrue(entries.contains("nested/inside.txt"), "got \(entries)")
    }

    private func runProcess(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AdditionalFileToolsTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) failed during test setup."]
            )
        }
    }
}

final class AdvancedSearchTests: EngineTestCase {
    func testSearchOptionsRequireActualCriteria() {
        var options = AdvancedSearchOptions()
        XCTAssertFalse(options.hasSearchCriteria)

        options.searchContents = true
        options.searchArchives = true
        options.includeHidden = true
        options.scope = .home
        XCTAssertFalse(options.hasSearchCriteria)

        options.query = "needle"
        XCTAssertTrue(options.hasSearchCriteria)

        options.query = ""
        options.typePreset = .documents
        XCTAssertTrue(options.hasSearchCriteria)
    }

    func testSearchMatchesTextFileContents() async throws {
        let notes = tempDir.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try writeFile("meeting.txt", "agenda\nneedle lives here", in: notes)
        try writeFile("plain.txt", "also has a needle", in: tempDir)
        try writeFile("photo.jpg", "needle", in: tempDir)

        var options = AdvancedSearchOptions()
        options.query = "needle"
        options.searchContents = true
        options.includeSubfolders = true
        options.typePreset = .documents

        let results = try await AdvancedFileSearch.search(root: tempDir, options: options) { _ in }

        XCTAssertEqual(Set(results.map { $0.item.name }), ["meeting.txt", "plain.txt"])
        XCTAssertTrue(results.allSatisfy { $0.matchDescription.hasPrefix("Contents line") })
    }

    func testSearchMatchesZipArchiveEntries() async throws {
        let source = tempDir.appendingPathComponent("zip-source", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile("secret.txt", "hidden payload", in: nested)

        let archive = tempDir.appendingPathComponent("bundle.zip")
        try runFixtureProcess(
            "/usr/bin/zip",
            ["-q", "-r", archive.path, "nested"],
            currentDirectory: source
        )
        try FileManager.default.removeItem(at: source)

        var options = AdvancedSearchOptions()
        options.query = "secret.txt"
        options.searchArchives = true
        options.includeSubfolders = false

        let results = try await AdvancedFileSearch.search(root: tempDir, options: options) { _ in }

        XCTAssertEqual(results.map { $0.item.name }, ["bundle.zip"])
        XCTAssertEqual(results.first?.matchDescription, "Archive entry: nested/secret.txt")
    }
}

final class DiskSpaceAnalyzerTests: EngineTestCase {
    func testSizeBucketsUseRequestedBoundaries() {
        let thresholds = DiskSpaceSizeThresholds(
            smallMaximum: 50,
            mediumMaximum: 250,
            largeMaximum: 1_000
        )

        XCTAssertEqual(DiskSpaceSizeBucket.bucket(for: 49, thresholds: thresholds), .small)
        XCTAssertEqual(DiskSpaceSizeBucket.bucket(for: 50, thresholds: thresholds), .medium)
        XCTAssertEqual(DiskSpaceSizeBucket.bucket(for: 250, thresholds: thresholds), .large)
        XCTAssertEqual(DiskSpaceSizeBucket.bucket(for: 1_000, thresholds: thresholds), .extraLarge)
    }

    func testAnalyzerAggregatesTypesDatesSizesAndApplications() async throws {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let thisYear = try XCTUnwrap(calendar.date(from: DateComponents(year: currentYear, month: 2, day: 1)))
        let lastYear = try XCTUnwrap(calendar.date(from: DateComponents(year: currentYear - 1, month: 2, day: 1)))
        let twoYearsAgo = try XCTUnwrap(calendar.date(from: DateComponents(year: currentYear - 2, month: 2, day: 1)))
        let old = try XCTUnwrap(calendar.date(from: DateComponents(year: currentYear - 4, month: 2, day: 1)))

        try makeSizedFile("report.pdf", size: 8_192, modified: thisYear)
        try makeSizedFile("photo.jpg", size: 8_192, modified: lastYear)
        try makeSizedFile("movie.mp4", size: 8_192, modified: twoYearsAgo)
        try makeSizedFile("audio.mp3", size: 8_192, modified: old)
        try makeSizedFile("backup.zip", size: 8_192, modified: old)
        try makeSizedFile("other.bin", size: 8_192, modified: thisYear)

        let app = tempDir.appendingPathComponent("Sample.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try makeSizedFile("Sample", size: 16_384, modified: lastYear, in: contents)
        try FileManager.default.setAttributes([.modificationDate: lastYear], ofItemAtPath: app.path)

        let analysis = try await DiskSpaceAnalyzerEngine.analyze(
            options: DiskSpaceScanOptions(root: tempDir)
        )

        XCTAssertGreaterThan(bytes(in: analysis.typeSlices, id: DiskSpaceContentKind.documents.rawValue), 0)
        XCTAssertGreaterThan(bytes(in: analysis.typeSlices, id: DiskSpaceContentKind.images.rawValue), 0)
        XCTAssertGreaterThan(bytes(in: analysis.typeSlices, id: DiskSpaceContentKind.video.rawValue), 0)
        XCTAssertGreaterThan(bytes(in: analysis.typeSlices, id: DiskSpaceContentKind.audio.rawValue), 0)
        XCTAssertGreaterThan(bytes(in: analysis.typeSlices, id: DiskSpaceContentKind.archives.rawValue), 0)
        XCTAssertGreaterThan(bytes(in: analysis.typeSlices, id: DiskSpaceContentKind.apps.rawValue), 0)
        XCTAssertEqual(analysis.applications.first?.name, "Sample")
        XCTAssertEqual(analysis.deletionCandidates(for: .documents).first?.name, "report.pdf")
        XCTAssertEqual(analysis.deletionCandidates(for: .apps).first?.name, "Sample.app")
        XCTAssertTrue(analysis.deletionCandidates(for: .apps).first?.isDirectory ?? false)

        XCTAssertGreaterThan(bytes(in: analysis.dateSlices, id: DiskSpaceDateBucket.thisYear.rawValue), 0)
        XCTAssertGreaterThan(bytes(in: analysis.dateSlices, id: DiskSpaceDateBucket.lastYear.rawValue), 0)
        XCTAssertGreaterThan(bytes(in: analysis.dateSlices, id: DiskSpaceDateBucket.twoYearsAgo.rawValue), 0)
        XCTAssertGreaterThan(bytes(in: analysis.dateSlices, id: DiskSpaceDateBucket.older.rawValue), 0)

        XCTAssertEqual(analysis.typeSlices.reduce(0) { $0 + $1.bytes }, analysis.totalBytes)
        XCTAssertEqual(analysis.dateSlices.reduce(0) { $0 + $1.bytes }, analysis.totalBytes)
        XCTAssertEqual(analysis.sizeSlices.reduce(0) { $0 + $1.bytes }, analysis.totalBytes)
    }

    func testAnalyzerKeepsTheLargestFiftyDeletionCandidatesPerType() async throws {
        let now = Date()
        for index in 1...55 {
            try makeSizedFile(
                "photo-\(index).jpg",
                size: index * 4_096,
                modified: now
            )
        }

        let analysis = try await DiskSpaceAnalyzerEngine.analyze(
            options: DiskSpaceScanOptions(root: tempDir)
        )
        let candidates = analysis.deletionCandidates(for: .images)

        XCTAssertEqual(candidates.count, 50)
        XCTAssertEqual(candidates.first?.name, "photo-55.jpg")
        XCTAssertFalse(candidates.contains { $0.name == "photo-1.jpg" })
        XCTAssertTrue(zip(candidates, candidates.dropFirst()).allSatisfy { $0.bytes >= $1.bytes })
    }

    func testSystemManagedPathsAreMarkedAsProtectedCandidates() {
        let systemCandidate = DiskSpaceDeletionCandidate(
            path: "/System/Library/CoreServices/Finder.app",
            kind: .apps,
            bytes: 1,
            modified: .now,
            isDirectory: true
        )
        let userCandidate = DiskSpaceDeletionCandidate(
            path: "/Applications/Example.app",
            kind: .apps,
            bytes: 1,
            modified: .now,
            isDirectory: true
        )

        XCTAssertTrue(systemCandidate.isSystemItem)
        XCTAssertFalse(userCandidate.isSystemItem)
    }

    func testAnalysisSnapshotRoundTripsThroughJSON() async throws {
        try makeSizedFile("archive.zip", size: 8_192, modified: .now)
        let analysis = try await DiskSpaceAnalyzerEngine.analyze(
            options: DiskSpaceScanOptions(root: tempDir)
        )
        let completedAt = Date(timeIntervalSinceReferenceDate: 123_456)
        let snapshot = DiskSpaceAnalysisSnapshot(analysis: analysis, completedAt: completedAt)

        let restored = try JSONDecoder().decode(
            DiskSpaceAnalysisSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(restored.completedAt, completedAt)
        XCTAssertEqual(restored.analysis.totalBytes, analysis.totalBytes)
        XCTAssertEqual(restored.analysis.volumePath, analysis.volumePath)
        XCTAssertEqual(
            restored.analysis.deletionCandidates(for: .archives).first?.name,
            "archive.zip"
        )
    }

    private func makeSizedFile(
        _ name: String,
        size: Int,
        modified: Date,
        in directory: URL? = nil
    ) throws {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try Data(repeating: 0xA5, count: size).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func bytes(in slices: [DiskSpaceSlice], id: String) -> Int64 {
        slices.first(where: { $0.id == id })?.bytes ?? 0
    }
}

@MainActor
final class PDFToolsTests: EngineTestCase {
    private func makePDF(_ name: String, pageCount: Int) throws -> URL {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 160, height: 120))
            image.lockFocus()
            NSColor(calibratedRed: CGFloat(index) / 4, green: 0.4, blue: 0.7, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
            image.unlockFocus()
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        let url = tempDir.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url))
        return url
    }

    func testMergeAndExtractKeepRequestedPages() async throws {
        let first = try makePDF("first.pdf", pageCount: 2)
        let second = try makePDF("second.pdf", pageCount: 1)

        let merged = try await PDFTools.merge([first, second], toFolder: tempDir)
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 3)

        let extracted = try await PDFTools.extract([3, 1], from: merged)
        XCTAssertEqual(PDFDocument(url: extracted)?.pageCount, 2)
        XCTAssertEqual(try PDFTools.parsePageRange("1-2,3", pageCount: 3), [1, 2, 3])
    }

    func testSplitRotateAndExportPages() async throws {
        let source = try makePDF("source.pdf", pageCount: 2)

        let splitFolder = try await PDFTools.split(source)
        let splitFiles = try FileManager.default.contentsOfDirectory(
            at: splitFolder,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(splitFiles.filter { $0.pathExtension == "pdf" }.count, 2)

        let pngFolder = try await PDFTools.exportPagesAsPNGs(source)
        let pngFiles = try FileManager.default.contentsOfDirectory(
            at: pngFolder,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(pngFiles.filter { $0.pathExtension == "png" }.count, 2)

        let rotated = try await PDFTools.rotate(source, degrees: 90)
        XCTAssertEqual(PDFDocument(url: rotated)?.page(at: 0)?.rotation, 90)
    }

    func testWatermarkOptimizeAndPasswordRoundTrip() async throws {
        let source = try makePDF("secure.pdf", pageCount: 1)

        let watermarked = try await PDFTools.addWatermark("DRAFT", to: source)
        XCTAssertEqual(PDFDocument(url: watermarked)?.page(at: 0)?.annotations.count, 1)

        let optimized = try PDFTools.optimize(watermarked)
        XCTAssertEqual(PDFDocument(url: optimized)?.pageCount, 1)

        let protected = try PDFTools.protect(source, password: "test-password")
        XCTAssertTrue(PDFDocument(url: protected)?.isEncrypted == true)
        XCTAssertTrue(try PDFTools.details(at: protected).contains("Password protected"))

        let unlocked = try PDFTools.removePassword("test-password", from: protected)
        XCTAssertEqual(PDFDocument(url: unlocked)?.pageCount, 1)
        XCTAssertFalse(PDFDocument(url: unlocked)?.isEncrypted ?? true)
    }
}

final class ImageProcessingTests: EngineTestCase {
    func testResizeShrinksLongestSide() async throws {
        let src = try makePNG("big.png", width: 200, height: 100)
        let out = try await ImageProcessing.resize(src, options: .init(mode: .maxDimension(50), format: .png))
        let (w, h) = dimensions(of: out)
        XCTAssertLessThanOrEqual(max(w, h), 50)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "original must be untouched")
    }

    func testRotateRightSwapsDimensionsInPlace() async throws {
        let src = try makePNG("r.png", width: 100, height: 50)
        try await ImageProcessing.transform(src, .rotateRight)
        let (w, h) = dimensions(of: src)
        XCTAssertEqual(w, 50)
        XCTAssertEqual(h, 100)
    }

    func testFlipKeepsDimensions() async throws {
        let src = try makePNG("f.png", width: 80, height: 60)
        try await ImageProcessing.transform(src, .flipHorizontal)
        let (w, h) = dimensions(of: src)
        XCTAssertEqual(w, 80)
        XCTAssertEqual(h, 60)
    }

    func testOptimizeAndThumbnailCreateNewImageCopies() async throws {
        let src = try makePNG("source.png", width: 1200, height: 800)

        let optimized = try await ImageProcessing.optimize(src)
        XCTAssertEqual(optimized.pathExtension, "jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: optimized.path))

        let thumbnail = try await ImageProcessing.createThumbnail(src)
        let (width, height) = dimensions(of: thumbnail)
        XCTAssertEqual(thumbnail.pathExtension, "png")
        XCTAssertLessThanOrEqual(max(width, height), 512)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "original must be untouched")
    }

    func testGrayscaleCreatesNeutralCopyWithoutChangingOriginal() async throws {
        let source = try makeColorPNG("color.png", color: .init(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))

        let output = try await ImageProcessing.grayscale(source)
        let pixel = try pixelColor(at: output)

        XCTAssertEqual(output.lastPathComponent, "color-grayscale.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "original must be untouched")
        XCTAssertEqual(pixel.red, pixel.green, accuracy: 0.01)
        XCTAssertEqual(pixel.green, pixel.blue, accuracy: 0.01)
    }

    private func makeColorPNG(_ name: String, color: CGColor) throws -> URL {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let url = tempDir.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixelColor(at url: URL) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ImageProcessing.ProcessingError(message: "Couldn’t read the grayscale test image.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ImageProcessing.ProcessingError(message: "Couldn’t read the grayscale test pixel.")
        }
        return (
            CGFloat(data[0]) / 255,
            CGFloat(data[1]) / 255,
            CGFloat(data[2]) / 255
        )
    }
}

final class AudioConverterTests: EngineTestCase {
    private func makeSilentWAV(_ name: String, seconds: Int = 1) throws -> URL {
        let sampleRate: UInt32 = 8_000
        let samples = Int(sampleRate) * seconds
        let audioByteCount = samples * 2
        var data = Data()

        func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + audioByteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(sampleRate)
        appendLittleEndian(sampleRate * 2)
        appendLittleEndian(UInt16(2))
        appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(audioByteCount))
        data.append(Data(repeating: 0, count: audioByteCount))

        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testConvertsAudioToM4A() async throws {
        let source = try makeSilentWAV("tone.wav")
        let item = FileItem.make(url: source)
        XCTAssertTrue(item.isAudioMedia)

        let output = try await AudioConverter.convertToM4A(item)

        XCTAssertEqual(output.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
}

// MARK: - VideoTransformer

final class VideoTransformerTests: XCTestCase {
    func testRotatingLandscapeVideoSwapsTheRenderDimensions() {
        let geometry = VideoTransformer.transformGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity,
            operation: .rotateClockwise
        )

        XCTAssertEqual(geometry.renderSize.width, 1080, accuracy: 0.001)
        XCTAssertEqual(geometry.renderSize.height, 1920, accuracy: 0.001)
        assertGeometryFits(
            geometry,
            naturalSize: CGSize(width: 1920, height: 1080)
        )
    }

    func testFlipKeepsAnAlreadyPortraitVideoInsideItsRenderCanvas() {
        let geometry = VideoTransformer.transformGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0),
            operation: .flipHorizontal
        )

        XCTAssertEqual(geometry.renderSize.width, 1080, accuracy: 0.001)
        XCTAssertEqual(geometry.renderSize.height, 1920, accuracy: 0.001)
        assertGeometryFits(
            geometry,
            naturalSize: CGSize(width: 1920, height: 1080)
        )
    }

    func testLongVideoWarningUsesFifteenMinutes() {
        XCTAssertEqual(VideoTransformer.longVideoWarningDuration, 15 * 60)
    }

    private func assertGeometryFits(_ geometry: VideoTransformGeometry, naturalSize: CGSize) {
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: naturalSize.width, y: 0),
            CGPoint(x: 0, y: naturalSize.height),
            CGPoint(x: naturalSize.width, y: naturalSize.height),
        ].map { $0.applying(geometry.transform) }

        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        XCTAssertEqual(minX, 0, accuracy: 0.001)
        XCTAssertEqual(minY, 0, accuracy: 0.001)
        XCTAssertEqual(maxX, geometry.renderSize.width, accuracy: 0.001)
        XCTAssertEqual(maxY, geometry.renderSize.height, accuracy: 0.001)
    }
}

final class VideoTrimmerTimeTextTests: XCTestCase {
    func testPreciseTimeTextShowsHundredths() {
        XCTAssertEqual(VideoTrimmer.preciseTimeText(0), "0:00.00")
        XCTAssertEqual(VideoTrimmer.preciseTimeText(62.345), "1:02.35")
        XCTAssertEqual(VideoTrimmer.preciseTimeText(3_723.456), "1:02:03.46")
    }

    func testPreciseTimeTextCarriesRoundedHundredthsIntoTheNextMinute() {
        XCTAssertEqual(VideoTrimmer.preciseTimeText(59.999), "1:00.00")
    }
}

final class VideoFilmstripTests: XCTestCase {
    func testSampleTimesUseTheCenterOfEvenlySpacedSections() {
        XCTAssertEqual(
            VideoFilmstrip.sampleTimes(duration: 10, count: 4),
            [1.25, 3.75, 6.25, 8.75]
        )
    }

    func testSampleTimesRejectInvalidInputs() {
        XCTAssertTrue(VideoFilmstrip.sampleTimes(duration: 0, count: 4).isEmpty)
        XCTAssertTrue(VideoFilmstrip.sampleTimes(duration: 10, count: 0).isEmpty)
        XCTAssertTrue(VideoFilmstrip.sampleTimes(duration: .infinity, count: 4).isEmpty)
    }

    func testTimelinePositionMapsAndClampsToVideoTime() {
        XCTAssertEqual(VideoFilmstrip.time(at: 25, width: 100, duration: 20), 5)
        XCTAssertEqual(VideoFilmstrip.time(at: -10, width: 100, duration: 20), 0)
        XCTAssertEqual(VideoFilmstrip.time(at: 120, width: 100, duration: 20), 20)
    }

    func testTrimHandlesKeepAMinimumSelection() {
        XCTAssertEqual(
            VideoFilmstrip.clampedInTime(9.98, outTime: 10, duration: 10),
            9.9,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VideoFilmstrip.clampedOutTime(0.02, inTime: 0, duration: 10),
            0.1,
            accuracy: 0.0001
        )
    }
}

final class VideoIntervalFrameCaptureTests: XCTestCase {
    func testCaptureTimesStartAtZeroAndDoNotIncludeTheVideoEndpoint() {
        XCTAssertEqual(
            VideoIntervalFrameCapture.captureTimes(duration: 10, interval: 3),
            [0, 3, 6, 9]
        )
        XCTAssertEqual(
            VideoIntervalFrameCapture.captureTimes(duration: 10, interval: 5),
            [0, 5]
        )
    }

    func testFrameCountRejectsIntervalsBelowOneTenthSecond() {
        XCTAssertEqual(
            VideoIntervalFrameCapture.frameCount(duration: 10, interval: 0.09),
            0
        )
    }

    func testCaptureTimesRejectMoreThanTheSafeFileLimit() {
        XCTAssertGreaterThan(
            VideoIntervalFrameCapture.frameCount(duration: 2_000, interval: 0.1),
            VideoIntervalFrameCapture.maximumFrameCount
        )
        XCTAssertTrue(
            VideoIntervalFrameCapture.captureTimes(duration: 2_000, interval: 0.1).isEmpty
        )
    }
}

// MARK: - VideoMerger

final class VideoMergeOrderTests: XCTestCase {
    func testFileViewOrderKeepsTheSelectedSequence() {
        let items = [
            item(named: "third.mov", modified: 3),
            item(named: "first.mov", modified: 1),
            item(named: "second.mov", modified: 2),
        ]

        XCTAssertEqual(
            VideoMergeOrder.fileView.arrange(items).map(\.name),
            ["third.mov", "first.mov", "second.mov"]
        )
    }

    func testNameAndModifiedDatePresetsArrangeTheSelectedFiles() {
        let items = [
            item(named: "clip 10.mov", modified: 3),
            item(named: "clip 2.mov", modified: 1),
            item(named: "clip 1.mov", modified: 2),
        ]

        XCTAssertEqual(
            VideoMergeOrder.nameAscending.arrange(items).map(\.name),
            ["clip 1.mov", "clip 2.mov", "clip 10.mov"]
        )
        XCTAssertEqual(
            VideoMergeOrder.modifiedNewest.arrange(items).map(\.name),
            ["clip 10.mov", "clip 1.mov", "clip 2.mov"]
        )
    }

    private func item(named name: String, modified: TimeInterval) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: false,
            isHidden: false,
            size: 1,
            created: Date(timeIntervalSince1970: modified),
            modified: Date(timeIntervalSince1970: modified),
            kind: "Movie",
            contentType: .movie,
            rating: 0
        )
    }
}

final class PaneSortPresetTests: XCTestCase {
    func testSortPresetsApplyExpectedPrimaryOrderAndNameTieBreak() {
        let items = [
            item(named: "Beta.txt", size: 20, modified: 2, kind: "Text", rating: 2),
            item(named: "Alpha.png", size: 20, modified: 3, kind: "Image", rating: 5),
            item(named: "Gamma.txt", size: 10, modified: 1, kind: "Text", rating: 5),
        ]

        XCTAssertEqual(
            PaneSortPreset.nameAscending.arrange(items).map(\.name),
            ["Alpha.png", "Beta.txt", "Gamma.txt"]
        )
        XCTAssertEqual(
            PaneSortPreset.modifiedNewest.arrange(items).map(\.name),
            ["Alpha.png", "Beta.txt", "Gamma.txt"]
        )
        XCTAssertEqual(
            PaneSortPreset.sizeLargest.arrange(items).map(\.name),
            ["Alpha.png", "Beta.txt", "Gamma.txt"]
        )
        XCTAssertEqual(
            PaneSortPreset.kindAscending.arrange(items).map(\.name),
            ["Alpha.png", "Beta.txt", "Gamma.txt"]
        )
        XCTAssertEqual(
            PaneSortPreset.ratingHighest.arrange(items).map(\.name),
            ["Alpha.png", "Gamma.txt", "Beta.txt"]
        )
    }

    private func item(
        named name: String,
        size: Int64,
        modified: TimeInterval,
        kind: String,
        rating: Int
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: false,
            isHidden: false,
            size: size,
            created: Date(timeIntervalSince1970: modified),
            modified: Date(timeIntervalSince1970: modified),
            kind: kind,
            contentType: nil,
            rating: rating
        )
    }
}

final class VideoMergerTests: XCTestCase {
    func testAudioInsertionUsesOnlyTheRangeOverlappingVideo() throws {
        let segment = try XCTUnwrap(VideoMerger.audioInsertionSegment(
            videoTimeRange: CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 600),
                duration: CMTime(seconds: 5, preferredTimescale: 600)
            ),
            audioTimeRange: CMTimeRange(
                start: CMTime(seconds: 2, preferredTimescale: 600),
                duration: CMTime(seconds: 2, preferredTimescale: 600)
            ),
            compositionStart: CMTime(seconds: 10, preferredTimescale: 600)
        ))

        XCTAssertEqual(CMTimeGetSeconds(segment.sourceTimeRange.start), 2, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(segment.sourceTimeRange.duration), 2, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(segment.destinationStart), 11, accuracy: 0.001)
    }

    func testLandscapeClipIsCenteredInTallerMergeCanvas() {
        let layout = VideoMerger.mergeLayout(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity,
            renderSize: CGSize(width: 1920, height: 1920)
        )
        let corners = transformedCorners(
            using: layout.transform,
            naturalSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(layout.contentSize.width, 1920, accuracy: 0.001)
        XCTAssertEqual(layout.contentSize.height, 1080, accuracy: 0.001)
        XCTAssertEqual(corners.map(\.x).min() ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(corners.map(\.x).max() ?? 0, 1920, accuracy: 0.001)
        XCTAssertEqual(corners.map(\.y).min() ?? 0, 420, accuracy: 0.001)
        XCTAssertEqual(corners.map(\.y).max() ?? 0, 1500, accuracy: 0.001)
    }

    func testPortraitClipUsesItsPreferredTransformInsideMergeCanvas() {
        let layout = VideoMerger.mergeLayout(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0),
            renderSize: CGSize(width: 1080, height: 1920)
        )
        let corners = transformedCorners(
            using: layout.transform,
            naturalSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(layout.contentSize.width, 1080, accuracy: 0.001)
        XCTAssertEqual(layout.contentSize.height, 1920, accuracy: 0.001)
        XCTAssertEqual(corners.map(\.x).min() ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(corners.map(\.x).max() ?? 0, 1080, accuracy: 0.001)
        XCTAssertEqual(corners.map(\.y).min() ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(corners.map(\.y).max() ?? 0, 1920, accuracy: 0.001)
    }

    private func transformedCorners(
        using transform: CGAffineTransform,
        naturalSize: CGSize
    ) -> [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: naturalSize.width, y: 0),
            CGPoint(x: 0, y: naturalSize.height),
            CGPoint(x: naturalSize.width, y: naturalSize.height),
        ].map { $0.applying(transform) }
    }
}

final class VideoMergerExportTests: EngineTestCase {
    private let videoWidth = 640
    private let videoHeight = 480

    func testCapturesCurrentVideoFrameBesideSourceAsUniquePNG() async throws {
        let source = try await makeVideo(
            "capture-source.mp4",
            color: CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        )

        let first = try await VideoFrameCapture.capture(url: source, at: 0.2)
        let second = try await VideoFrameCapture.capture(url: source, at: 0.2)

        XCTAssertEqual(first.deletingLastPathComponent(), source.deletingLastPathComponent())
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertTrue(first.lastPathComponent.hasPrefix("capture-source-frame-"))
        XCTAssertEqual(dimensions(of: first).0, videoWidth)
        XCTAssertEqual(dimensions(of: first).1, videoHeight)
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testIntervalCaptureCreatesFolderWithOriginalVideoAndScreenshots() async throws {
        let source = try await makeVideo(
            "interval-source.mp4",
            color: CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
        )

        let result = try await VideoIntervalFrameCapture.capture(
            url: source,
            every: 0.2
        )

        XCTAssertEqual(
            result.folderURL.deletingLastPathComponent(),
            source.deletingLastPathComponent()
        )
        XCTAssertEqual(result.copiedVideoURL.lastPathComponent, source.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.copiedVideoURL.path))
        XCTAssertEqual(result.screenshotURLs.count, 3)
        XCTAssertTrue(result.screenshotURLs.allSatisfy { $0.pathExtension == "png" })
        XCTAssertTrue(
            result.screenshotURLs.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            }
        )
    }

    func testExportsSelectedRangeAsAudioOnlyM4A() async throws {
        let source = try makeAudio("audio-source.caf", duration: 0.5)
        let hasAudioTrack = await AudioRangeExporter.hasAudioTrack(in: source)

        XCTAssertTrue(hasAudioTrack)

        let output = try await AudioRangeExporter.export(
            url: source,
            inTime: 0.1,
            outTime: 0.4,
            outputSuffix: "audio"
        )
        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let outputDuration = CMTimeGetSeconds(try await asset.load(.duration))

        XCTAssertEqual(output.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(audioTracks.isEmpty)
        XCTAssertTrue(videoTracks.isEmpty)
        XCTAssertGreaterThan(outputDuration, 0.1)
        XCTAssertLessThan(outputDuration, 0.5)
    }

    func testBuildsNormalizedAudioWaveformSamples() async throws {
        let source = try makeAudio("waveform-source.caf", duration: 0.5)

        let samples = try await AudioWaveform.samples(for: source, count: 64)

        XCTAssertEqual(samples.count, 64)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(samples.max() ?? 0, 1, accuracy: 0.001)
    }

    func testAudioTrimUsesCollisionSafeTrimmedName() async throws {
        let source = try makeAudio("trim-source.caf", duration: 0.5)

        let first = try await AudioRangeExporter.export(
            url: source,
            inTime: 0.1,
            outTime: 0.4,
            outputSuffix: "trimmed"
        )
        let second = try await AudioRangeExporter.export(
            url: source,
            inTime: 0.1,
            outTime: 0.4,
            outputSuffix: "trimmed"
        )

        XCTAssertEqual(first.lastPathComponent, "trim-source-trimmed.m4a")
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(second.lastPathComponent.hasPrefix("trim-source-trimmed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSourceVideoCanBeTransformed() async throws {
        let source = try await makeVideo(
            "source.mp4",
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )

        let output = try await VideoTransformer.transform(source, operation: .flipHorizontal)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testMergeExportsBothVideoClips() async throws {
        let first = try await makeVideo(
            "first.mp4",
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let second = try await makeVideo(
            "second.mp4",
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        )

        let output = try await VideoMerger.merge([first, second], outputDirectory: tempDir)
        let asset = AVURLAsset(url: output)
        let duration: CMTime = try await asset.load(.duration)
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.8)
        XCTAssertFalse(videoTracks.isEmpty)
    }

    func testMixedImageAndVideoSequenceExports() async throws {
        let image = try makePNG("still.png", width: videoWidth, height: videoHeight, gray: 0.2)
        let video = try await makeVideo(
            "clip.mp4",
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        )

        let output = try await MediaVideoRenderer.merge(
            [.image(image), .video(video)],
            outputDirectory: tempDir,
            options: .init(
                secondsPerImage: 1,
                size: CGSize(width: videoWidth, height: videoHeight),
                fill: false
            )
        )
        let asset = AVURLAsset(url: output)
        let duration: CMTime = try await asset.load(.duration)
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 1.3)
        guard let videoTrack = videoTracks.first else {
            return XCTFail("The mixed-media export has no video track.")
        }
        let naturalSize: CGSize = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: videoWidth, height: videoHeight))
    }

    private func makeVideo(_ name: String, color: CGColor) async throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let pixelBuffer = try makePixelBuffer(color: color)
            XCTAssertTrue(adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
            ))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ImageProcessing.ProcessingError(message: "Couldn’t create test video.")
        }
        return url
    }

    private func makeAudio(_ name: String, duration: Double) throws -> URL {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw ImageProcessing.ProcessingError(message: "Couldn’t create an audio format.")
        }

        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded(.up))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let channelData = buffer.floatChannelData else {
            throw ImageProcessing.ProcessingError(message: "Couldn’t create an audio buffer.")
        }
        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let phase = Double(frame) / sampleRate * 440 * 2 * Double.pi
            channelData[0][frame] = Float(sin(phase) * 0.1)
        }

        let url = tempDir.appendingPathComponent(name)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func makePixelBuffer(color: CGColor) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            videoWidth,
            videoHeight,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ImageProcessing.ProcessingError(message: "Couldn’t create a test video frame.")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: videoWidth,
            height: videoHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw ImageProcessing.ProcessingError(message: "Couldn’t draw a test video frame.")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight))
        return pixelBuffer
    }
}

// MARK: - CleanupEngine

final class CleanupEngineTests: EngineTestCase {
    func testFindsLargeFiles() async throws {
        let large = tempDir.appendingPathComponent("huge.bin")
        try Data(count: 120 * 1_024).write(to: large)
        let options = CleanupScanOptions(
            root: tempDir,
            largeFileThreshold: 100 * 1_024,
            maxFiles: 100
        )
        let categories = try await CleanupEngine.scan(options: options)
        let largeCategory = categories.first { $0.kind == .largeFiles }
        XCTAssertEqual(largeCategory?.suggestions.map(\.name), ["huge.bin"])
    }

    func testFindsEmptyFolders() async throws {
        let empty = tempDir.appendingPathComponent("empty-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try writeFile("keep.txt", in: tempDir)
        let options = CleanupScanOptions(root: tempDir, maxFiles: 100)
        let categories = try await CleanupEngine.scan(options: options)
        let emptyCategory = categories.first { $0.kind == .emptyFolders }
        XCTAssertEqual(emptyCategory?.suggestions.map(\.name), ["empty-folder"])
    }

    func testFindsDuplicateCandidates() async throws {
        let left = tempDir.appendingPathComponent("left", isDirectory: true)
        let right = tempDir.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        let payload = Data("duplicate".utf8)
        try payload.write(to: left.appendingPathComponent("photo.jpg"))
        try payload.write(to: right.appendingPathComponent("photo.jpg"))
        let options = CleanupScanOptions(root: tempDir, maxFiles: 100)
        let categories = try await CleanupEngine.scan(options: options)
        let duplicates = categories.first { $0.kind == .duplicateCandidates }
        XCTAssertEqual(duplicates?.suggestions.count, 1)
    }
}

// MARK: - FolderOrganizerEngine

final class FolderOrganizerEngineTests: EngineTestCase {
    func testPlansByType() async throws {
        try writeFile("photo.jpg", in: tempDir)
        try writeFile("notes.txt", in: tempDir)
        let groups = try await FolderOrganizerEngine.plan(
            in: tempDir,
            mode: .byType,
            includeHidden: false
        )
        XCTAssertEqual(Set(groups.map(\.folderName)), ["Documents", "Images"])
        XCTAssertEqual(groups.first(where: { $0.folderName == "Images" })?.items.count, 1)
    }

    func testSkipsFilesAlreadyInDestinationFolder() async throws {
        let images = tempDir.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try writeFile("photo.jpg", in: images)
        let groups = try await FolderOrganizerEngine.plan(
            in: tempDir,
            mode: .byType,
            includeHidden: false
        )
        XCTAssertTrue(groups.isEmpty)
    }

    func testApplyMovesFilesIntoFolders() async throws {
        let source = try writeFile("clip.mov", in: tempDir)
        let item = OrganizePlanItem(
            url: source,
            name: "clip.mov",
            size: 4,
            modified: Date(),
            destinationFolder: "Videos",
            rootFolder: tempDir
        )
        let records = try await FolderOrganizerEngine.apply([item], conflictPolicy: .keepBoth)
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Videos/clip.mov").path))
    }
}

// MARK: - Calculator

final class CalculatorExpressionEngineTests: XCTestCase {
    func testArithmeticPrecedenceAndUnicodeOperators() throws {
        XCTAssertEqual(try value("2 + 3 × 4"), 14, accuracy: 1e-12)
        XCTAssertEqual(try value("(2 + 3) ÷ 5"), 1, accuracy: 1e-12)
    }

    func testPowerIsRightAssociativeAndBindsBeforeUnaryMinus() throws {
        XCTAssertEqual(try value("2^3^2"), 512, accuracy: 1e-12)
        XCTAssertEqual(try value("-2^2"), -4, accuracy: 1e-12)
        XCTAssertEqual(try value("(-2)^2"), 4, accuracy: 1e-12)
    }

    func testImplicitMultiplicationAndConstants() throws {
        XCTAssertEqual(try value("2π"), 2 * .pi, accuracy: 1e-12)
        XCTAssertEqual(try value("2(3 + 4)"), 14, accuracy: 1e-12)
    }

    func testDegreeAndRadianTrigonometry() throws {
        XCTAssertEqual(try value("sin(30)", angleUnit: .degrees), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try value("sin(π / 2)", angleUnit: .radians), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("asin(0.5)", angleUnit: .degrees), 30, accuracy: 1e-12)
    }

    func testScientificFunctionsFactorialAndPercent() throws {
        XCTAssertEqual(try value("sqrt(81) + 5!"), 129, accuracy: 1e-12)
        XCTAssertEqual(try value("log(1000)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try value("25%"), 0.25, accuracy: 1e-12)
        XCTAssertEqual(try value("mod(17, 5)"), 2, accuracy: 1e-12)
    }

    func testCompiledExpressionUsesGraphVariableAndAnswer() throws {
        let expression = try CalculatorExpressionEngine.compile("x^2 + ans")
        let result = try expression.evaluate(in: CalculatorEvaluationContext(
            x: 3,
            answer: 4,
            memory: nil,
            angleUnit: .degrees
        ))
        XCTAssertEqual(result, 13, accuracy: 1e-12)
    }

    func testInvalidOperationsProvideErrors() {
        XCTAssertThrowsError(try value("1 / 0"))
        XCTAssertThrowsError(try value("sqrt(-1)"))
        XCTAssertThrowsError(try value("unknown(2)"))
        XCTAssertThrowsError(try value("2 +"))
    }

    func testFloatingPointFallbackAlsoAvoidsScientificNotation() {
        let small = CalculatorExpressionEngine.formatted(1e-20, grouping: false)
        let large = CalculatorExpressionEngine.formatted(1e20, grouping: false)

        XCTAssertEqual(small, "0.00000000000000000001")
        XCTAssertEqual(large, "100000000000000000000")
        XCTAssertFalse(small.lowercased().contains("e"))
        XCTAssertFalse(large.lowercased().contains("e"))
    }

    private func value(
        _ expression: String,
        angleUnit: CalculatorAngleUnit = .degrees
    ) throws -> Double {
        try CalculatorExpressionEngine.evaluate(
            expression,
            context: .standard(angleUnit: angleUnit)
        )
    }
}

final class CalculatorExactExpressionEngineTests: XCTestCase {
    private let context = CalculatorExactContext(answer: .zero, memory: nil)

    func testLongIntegerIsReturnedInFullWithoutScientificNotation() throws {
        let input = "1212112312312124141414242"
        let result = try CalculatorExactExpressionEngine.evaluate(input, context: context)

        XCTAssertEqual(result.description, input)
        XCTAssertFalse(result.description.lowercased().contains("e"))
    }

    func testDecimalArithmeticRemainsExact() throws {
        XCTAssertEqual(try exact("0.1 + 0.2"), "0.3")
        XCTAssertEqual(try exact("1 / 8"), "0.125")
        XCTAssertEqual(try exact("99999999999999999999 + 1"), "100000000000000000000")
    }

    func testRepeatingDecimalsUseCompactRecurrenceNotationForDisplay() throws {
        XCTAssertEqual(try displayed("25000 / 6"), "4166.(6)")
        XCTAssertEqual(try displayed("1 / 6"), "0.1(6)")
        XCTAssertEqual(try displayed("1 / 7"), "0.(142857)")
        XCTAssertEqual(try displayed("-1 / 6"), "−0.1(6)")
    }

    func testFiniteDecimalsAndLongIntegersAreNotCompacted() throws {
        let integer = "1212112312312124141414242"

        XCTAssertEqual(try displayed("1 / 8"), "0.125")
        XCTAssertEqual(try displayed(integer), integer)
    }

    func testResultCanContainOneThousandDigits() throws {
        let result = try exact("10^999")

        XCTAssertEqual(result.count, 1_000)
        XCTAssertEqual(result.first, "1")
        XCTAssertTrue(result.dropFirst().allSatisfy { $0 == "0" })
    }

    func testResultOverOneThousandDigitsIsRejected() {
        XCTAssertThrowsError(try exact("10^1000")) { error in
            XCTAssertEqual(error as? CalculatorExactError, .digitLimitExceeded)
        }
    }

    private func exact(_ expression: String) throws -> String {
        try CalculatorExactExpressionEngine.evaluate(expression, context: context).description
    }

    private func displayed(_ expression: String) throws -> String {
        try CalculatorExactExpressionEngine.evaluate(
            expression,
            context: context
        ).displayDescription
    }
}

@MainActor
final class CalculatorStoreTests: XCTestCase {
    func testEvaluationRecordsHistoryAndPersistsAnswer() {
        withStore { store, defaults in
            store.expression = "6 × 7"
            store.evaluate()

            XCTAssertEqual(store.resultText, "42")
            XCTAssertEqual(store.lastAnswer, 42, accuracy: 1e-12)
            XCTAssertEqual(store.history.first?.expression, "6 × 7")

            let reloaded = CalculatorStore(defaults: defaults)
            XCTAssertEqual(reloaded.lastAnswer, 42, accuracy: 1e-12)
            XCTAssertEqual(reloaded.history.first?.result, "42")
        }
    }

    func testMemoryOperationsPersist() {
        withStore { store, defaults in
            store.expression = "12.5"
            store.addToMemory()
            store.expression = "2.5"
            store.subtractFromMemory()

            XCTAssertEqual(store.memoryValue ?? .nan, 10, accuracy: 1e-12)
            XCTAssertEqual(CalculatorStore(defaults: defaults).memoryValue ?? .nan, 10, accuracy: 1e-12)

            store.clearMemory()
            XCTAssertNil(store.memoryValue)
        }
    }

    func testBinaryFunctionKeyBuildsAnEvaluatableExpression() {
        withStore { store, _ in
            store.insert("17")
            store.applyBinaryFunction("mod")
            store.insert("5")
            store.insertParenthesis()
            store.evaluate()

            XCTAssertEqual(store.expression, "mod(17,5)")
            XCTAssertEqual(store.resultText, "2")
        }
    }

    func testLongResultStaysExactAcrossAnswerHistoryAndReload() {
        withStore { store, defaults in
            store.expression = "10^999"
            store.evaluate()

            XCTAssertEqual(store.resultText.count, 1_000)
            XCTAssertFalse(store.resultText.lowercased().contains("e"))
            XCTAssertEqual(store.history.first?.exactValue, store.resultText)

            store.insert("+")
            store.insert("1")
            XCTAssertEqual(store.expression, "ans+1")
            store.evaluate()
            XCTAssertEqual(store.resultText.count, 1_000)
            XCTAssertTrue(store.resultText.hasSuffix("001"))

            let reloaded = CalculatorStore(defaults: defaults)
            reloaded.expression = "ans+1"
            reloaded.evaluate()
            XCTAssertTrue(reloaded.resultText.hasSuffix("002"))
        }
    }

    func testRepeatingResultIsCompactWhileStoredAnswerKeepsFullPrecision() {
        withStore { store, defaults in
            store.expression = "25000 / 6"
            store.evaluate()

            XCTAssertEqual(store.resultText, "4166.(6)")
            XCTAssertEqual(store.history.first?.result, "4166.(6)")
            let fullPrecision = store.history.first?.exactValue
            XCTAssertNotNil(fullPrecision)
            XCTAssertTrue(fullPrecision?.hasPrefix("4166.666666") == true)
            XCTAssertGreaterThan(fullPrecision?.count ?? 0, store.resultText.count)

            let reloaded = CalculatorStore(defaults: defaults)
            reloaded.expression = "ans"
            XCTAssertEqual(reloaded.resultText, "4166.(6)")
        }
    }

    func testExpressionInputIsLimitedToOneHundredCharacters() {
        withStore { store, _ in
            store.expression = String(repeating: "1", count: 101)

            XCTAssertEqual(store.expression.count, CalculatorStore.maximumExpressionLength)
            XCTAssertEqual(store.errorMessage, "Expressions are limited to 100 characters.")
        }
    }

    func testMemoryPreservesLongExactValue() {
        withStore { store, defaults in
            store.expression = "10^999"
            store.addToMemory()

            XCTAssertEqual(store.memoryText?.count, 1_000)
            XCTAssertEqual(CalculatorStore(defaults: defaults).memoryText, store.memoryText)

            store.clear()
            store.recallMemory()
            XCTAssertEqual(store.expression, "mem")
            store.insert("+")
            store.insert("1")
            store.evaluate()
            XCTAssertTrue(store.resultText.hasSuffix("001"))
        }
    }

    func testGraphSamplingAndAutomaticDomain() {
        withStore { store, _ in
            store.graphEquations = [
                CalculatorGraphEquation(
                    id: UUID(),
                    expression: "x^2",
                    isEnabled: true,
                    colorIndex: 0
                ),
            ]
            store.graphXMinimum = -2
            store.graphXMaximum = 2

            let series = store.graphSeries(sampleCount: 201)
            XCTAssertEqual(series.count, 1)
            XCTAssertEqual(series[0].points.count, 201)
            XCTAssertEqual(series[0].points[100].x, 0, accuracy: 1e-12)
            XCTAssertEqual(series[0].points[100].y, 0, accuracy: 1e-12)

            let yDomain = store.yDomain(for: series)
            XCTAssertLessThan(yDomain.lowerBound, 0)
            XCTAssertGreaterThan(yDomain.upperBound, 3.5)
        }
    }

    func testGraphSamplerBreaksAtReciprocalDiscontinuity() {
        withStore { store, _ in
            store.graphEquations = [
                CalculatorGraphEquation(
                    id: UUID(),
                    expression: "1/x",
                    isEnabled: true,
                    colorIndex: 0
                ),
            ]
            store.graphXMinimum = -1
            store.graphXMaximum = 1

            let points = store.graphSeries(sampleCount: 201)[0].points
            XCTAssertGreaterThan(Set(points.map(\.segment)).count, 1)
            XCTAssertFalse(points.contains(where: { abs($0.x) < 1e-12 }))
        }
    }

    private func withStore(
        _ body: (CalculatorStore, UserDefaults) -> Void
    ) {
        let suiteName = "CalculatorStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(CalculatorStore(defaults: defaults), defaults)
    }
}

// MARK: - Terminal

final class TerminalTextSanitizerTests: XCTestCase {
    func testRemovesANSISequencesAndAppliesBackspace() {
        let text = "\u{1B}[31mred\u{1B}[0m ab\u{8}c"

        XCTAssertEqual(TerminalTextSanitizer.clean(text), "red ac")
    }
}

final class PrivilegedShellCommandTests: XCTestCase {
    func testUsesTheSystemAuthorizationDialogWithoutEmbeddingTheCommandOrPasswordInAppleScript() {
        XCTAssertEqual(PrivilegedShellCommand.executableURL.path, "/usr/bin/osascript")
        let command = "printf 'reusable command'"
        let arguments = PrivilegedShellCommand.arguments(for: command)
        XCTAssertEqual(arguments.last, command)

        let authorizationScript = arguments.dropLast().joined(separator: " ")
        XCTAssertFalse(authorizationScript.contains(command))
        XCTAssertTrue(authorizationScript.contains("with administrator privileges"))
        XCTAssertFalse(authorizationScript.localizedCaseInsensitiveContains("password"))
    }

    func testRemovesSimpleSudoPrefixBecauseMacOSAlreadyRunsTheCommandAsAdministrator() {
        XCTAssertEqual(
            PrivilegedShellCommand.commandWithoutSimpleSudoPrefix("sudo id -u"),
            "id -u"
        )
        XCTAssertEqual(
            PrivilegedShellCommand.commandWithoutSimpleSudoPrefix("/usr/bin/sudo whoami"),
            "whoami"
        )
        XCTAssertEqual(
            PrivilegedShellCommand.commandWithoutSimpleSudoPrefix("sudo -u guest whoami"),
            "sudo -u guest whoami"
        )
    }

    func testRecognizesMacOSAuthorizationCancellation() {
        XCTAssertTrue(PrivilegedShellCommand.wasCancelled(
            "execution error: User canceled. (-128)"
        ))
        XCTAssertFalse(PrivilegedShellCommand.wasCancelled("Permission denied"))
    }
}

@MainActor
final class TerminalStoreTests: XCTestCase {
    func testRunsCommandsAndTracksTheShellWorkingDirectory() async throws {
        let (store, defaults, suiteName) = makeStore()
        store.start(at: FileManager.default.homeDirectoryForCurrentUser)
        defer {
            store.stop(appendMessage: false)
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(store.isRunning)
        store.commandText = "tty"
        store.executeCommand()
        let hasPseudoTerminal = await waitUntil {
            !store.isExecuting && store.output.contains("/dev/tty")
        }
        XCTAssertTrue(hasPseudoTerminal)

        store.commandText = "export WORKBENCH_TERMINAL_TEST='persistent-shell'; printf 'hello-from-shell'; cd /"
        store.executeCommand()

        let finished = await waitUntil {
            !store.isExecuting && store.output.contains("hello-from-shell")
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(store.lastExitCode, 0)
        XCTAssertEqual(store.currentDirectory.path, "/")

        store.commandText = "printf \"$WORKBENCH_TERMINAL_TEST\""
        store.executeCommand()
        let retainedEnvironment = await waitUntil {
            !store.isExecuting && store.output.contains("persistent-shell")
        }
        XCTAssertTrue(retainedEnvironment)
    }

    func testCommandHistoryMovesBackwardAndForward() async {
        let (store, defaults, suiteName) = makeStore()
        store.start(at: FileManager.default.homeDirectoryForCurrentUser)
        defer {
            store.stop(appendMessage: false)
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.commandText = "printf first"
        store.executeCommand()
        _ = await waitUntil { !store.isExecuting }

        store.commandText = "printf second"
        store.executeCommand()
        _ = await waitUntil { !store.isExecuting }

        store.previousCommand()
        XCTAssertEqual(store.commandText, "printf second")
        store.previousCommand()
        XCTAssertEqual(store.commandText, "printf first")
        store.nextCommand()
        XCTAssertEqual(store.commandText, "printf second")
        store.nextCommand()
        XCTAssertEqual(store.commandText, "")
    }

    func testRecentCommandsAndPresetsPersist() async {
        let (store, defaults, suiteName) = makeStore()
        store.start(at: FileManager.default.homeDirectoryForCurrentUser)
        defer {
            store.stop(appendMessage: false)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let command = "printf reusable-command"
        store.commandText = command
        store.executeCommand()
        _ = await waitUntil { !store.isExecuting }

        XCTAssertEqual(store.recentCommands.first, command)
        store.addPreset(command)
        XCTAssertTrue(store.isPreset(command))

        let reloaded = TerminalStore(shellPath: "/bin/zsh", defaults: defaults)
        XCTAssertEqual(reloaded.recentCommands.first, command)
        XCTAssertEqual(reloaded.presetCommands.first, command)

        reloaded.togglePreset(command)
        XCTAssertFalse(reloaded.isPreset(command))
    }

    func testSendsInteractiveInputToTheRunningCommand() async {
        let (store, defaults, suiteName) = makeStore()
        store.start(at: FileManager.default.homeDirectoryForCurrentUser)
        defer {
            store.stop(appendMessage: false)
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.commandText = "read reply; printf 'reply=%s' \"$reply\""
        store.executeCommand()
        XCTAssertTrue(store.isExecuting)

        store.commandText = "interactive-value"
        store.executeCommand()

        let finished = await waitUntil {
            !store.isExecuting && store.output.contains("reply=interactive-value")
        }
        XCTAssertTrue(finished)
        XCTAssertFalse(store.recentCommands.contains("interactive-value"))
    }

    func testPasswordPromptUsesSecureInputWithoutSavingOrEchoingIt() async {
        let (store, defaults, suiteName) = makeStore()
        store.start(at: FileManager.default.homeDirectoryForCurrentUser)
        defer {
            store.stop(appendMessage: false)
            defaults.removePersistentDomain(forName: suiteName)
        }

        store.commandText = "printf 'Password:'; read secret; printf '\\nsecret-length=%s' \"${#secret}\""
        store.executeCommand()

        let requestedSecureInput = await waitUntil {
            store.isAwaitingSecureInput
        }
        XCTAssertTrue(requestedSecureInput)

        let secret = "do-not-save-me"
        store.commandText = secret
        store.executeCommand()

        let finished = await waitUntil {
            !store.isExecuting && store.output.contains("secret-length=14")
        }
        XCTAssertTrue(finished)
        XCTAssertFalse(store.output.contains(secret))
        XCTAssertFalse(store.recentCommands.contains(secret))
    }

    private func makeStore() -> (TerminalStore, UserDefaults, String) {
        let suiteName = "TerminalStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (TerminalStore(shellPath: "/bin/zsh", defaults: defaults), defaults, suiteName)
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
