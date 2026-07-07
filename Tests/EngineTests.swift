import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Panes

/// Shared temp-directory scaffolding + fixture helpers for the engine tests.
class EngineTestCase: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PanesTests-\(UUID().uuidString)", isDirectory: true)
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

// MARK: - FileGridKeyboardSelection

final class FileGridKeyboardSelectionTests: XCTestCase {
    private let ids = ["a", "b", "c", "d"]

    func testShiftRightExtendsSingleSelectionToTwoItems() {
        let result = FileGridKeyboardSelection.move(
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

    func testRepeatedShiftRightKeepsOriginalAnchor() {
        let first = FileGridKeyboardSelection.move(
            ids: ids,
            focusedID: "a",
            rangeAnchorID: "a",
            selectedIDs: Set(["a"]),
            delta: 1,
            extending: true
        )
        let second = FileGridKeyboardSelection.move(
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
        let result = FileGridKeyboardSelection.move(
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
        let result = FileGridKeyboardSelection.move(
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
}

// MARK: - ImageProcessing

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
