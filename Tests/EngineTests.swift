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

// MARK: - VideoMerger

final class VideoMergerTests: XCTestCase {
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
