import AVFoundation
import XCTest

/// Exercises the actual drag handlers, inline AppKit rename field and embedded
/// video editor. All inputs and outputs live in one uniquely marked temp folder.
@MainActor
final class WorkbenchInteractionUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!
    private var token = ""
    private var browser: URL { root.appendingPathComponent("Browser", isDirectory: true) }
    private var gridFolder: URL { browser.appendingPathComponent("Grid Destination", isDirectory: true) }
    private var sidebarFolder: URL { root.appendingPathComponent("Sidebar Destination", isDirectory: true) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        token = UUID().uuidString
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("workbench-ui-tests-\(token)", isDirectory: true)
        for folder in [browser, gridFolder, sidebarFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try token.write(to: root.appendingPathComponent(".fixture"), atomically: true, encoding: .utf8)
        try "Rename me".write(to: browser.appendingPathComponent("Original.txt"), atomically: true, encoding: .utf8)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=")!
        try png.write(to: browser.appendingPathComponent("Image.png"))
        app = XCUIApplication()
        app.launchArguments = ["--workbench-ui-testing", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["WORKBENCH_UI_TEST_ROOT"] = root.path
        app.launchEnvironment["WORKBENCH_UI_TEST_TOKEN"] = token
    }

    override func tearDownWithError() throws {
        app?.terminate()
        UserDefaults.standard.removePersistentDomain(forName: "com.qnsub.workbench.uitests.\(token)")
        // Never remove an arbitrary path if fixture setup failed part-way.
        let temporaryDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        if let root, root.deletingLastPathComponent().path == temporaryDirectory.path,
           root.lastPathComponent == "workbench-ui-tests-\(token)" {
            try FileManager.default.removeItem(at: root)
        }
        app = nil
        root = nil
    }

    func testImageDragIntoGridFolderMovesFile() throws {
        let source = browser.appendingPathComponent("Image.png")
        let original = try Data(contentsOf: source)
        launchWorkbench()
        drag("Image.png", onto: element("file-grid-0-Grid Destination"))
        assertMoved(source, to: gridFolder.appendingPathComponent("Image.png"), expected: original)
    }

    func testVideoDragIntoGridFolderMovesFile() throws {
        let source = browser.appendingPathComponent("Video.mov")
        try UITestVideoFixture.make(at: source, workingFolder: root)
        let original = try Data(contentsOf: source)
        launchWorkbench()
        drag("Video.mov", onto: element("file-grid-0-Grid Destination"))
        assertMoved(source, to: gridFolder.appendingPathComponent("Video.mov"), expected: original)
    }

    func testImageDragOntoSidebarFolderMovesFile() throws {
        let source = browser.appendingPathComponent("Image.png")
        let original = try Data(contentsOf: source)
        launchWorkbench()
        drag("Image.png", onto: element("sidebar-folder-Sidebar Destination"))
        assertMoved(source, to: sidebarFolder.appendingPathComponent("Image.png"), expected: original)
    }

    func testReturnKeepsInlineRenameActiveUntilSecondReturn() throws {
        launchWorkbench()
        let file = element("file-grid-0-Original.txt")
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeKey(.return, modifierFlags: [])
        let field = app.textFields["file-rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "Return did not start inline rename")

        // Covers the original bug: the initiating Return was delivered to the
        // new field, immediately committing and dismissing it on the next event.
        let unexpectedlyDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !field.exists }, object: nil
        )
        unexpectedlyDismissed.isInverted = true
        wait(for: [unexpectedlyDismissed], timeout: 0.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: browser.appendingPathComponent("Original.txt").path))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed.txt")
        field.typeKey(.return, modifierFlags: [])
        assertMoved(
            browser.appendingPathComponent("Original.txt"),
            to: browser.appendingPathComponent("Renamed.txt"),
            expected: Data("Rename me".utf8)
        )
    }

    func testVideoToolbarButtonsPerformTheirActions() throws {
        let source = browser.appendingPathComponent("Video.mov")
        try UITestVideoFixture.make(at: source, workingFolder: root)
        app.launchEnvironment["WORKBENCH_UI_TEST_PREVIEW"] = source.lastPathComponent
        launchWorkbench()

        let setIn = app.buttons["video-set-in"]
        waitUntil("Video metadata did not load") { setIn.exists && setIn.isEnabled }
        let playback = app.buttons["video-playback-toggle"]
        if playback.label == "Pause" { playback.click() }
        waitUntil("Playback could not be paused") { playback.label == "Play" }

        let position = app.sliders["video-playback-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        position.adjust(toNormalizedSliderPosition: 0.3)
        let inLabel = app.staticTexts["video-trim-in-value"]
        let originalIn = inLabel.label
        setIn.click()
        waitUntil("Set In Point was not delivered") { inLabel.label != originalIn }

        position.adjust(toNormalizedSliderPosition: 0.8)
        let outLabel = app.staticTexts["video-trim-out-value"]
        let originalOut = outLabel.label
        app.buttons["video-set-out"].click()
        waitUntil("Set Out Point was not delivered") { outLabel.label != originalOut }

        app.buttons["video-capture-frame"].click()
        waitUntil("Capture Frame did not produce a PNG") {
            self.outputFiles().contains { $0.lastPathComponent.hasPrefix("Video-frame-") && $0.pathExtension == "png" }
        }

        let removeAudio = app.buttons["video-remove-audio"]
        XCTAssertTrue(removeAudio.isEnabled, "Fixture has an audio track")
        removeAudio.click()
        waitUntil("Remove Audio button did not toggle") { removeAudio.value as? String == "On" }
        removeAudio.click()
        waitUntil("Remove Audio button did not toggle back") { removeAudio.value as? String == "Off" }

        app.buttons["video-export-audio"].click()
        waitUntil("Export Audio did not produce an M4A", timeout: 30) {
            self.outputFiles().contains { $0.lastPathComponent == "Video-audio.m4a" }
        }
        let exportedAudio = AVURLAsset(url: browser.appendingPathComponent("Video-audio.m4a"))
        XCTAssertFalse(exportedAudio.tracks(withMediaType: .audio).isEmpty)
        XCTAssertTrue(exportedAudio.tracks(withMediaType: .video).isEmpty)

        app.buttons["video-export-trim"].click()
        waitUntil("Export did not produce a trimmed movie", timeout: 30) {
            self.outputFiles().contains { $0.lastPathComponent.hasPrefix("Video-trimmed.") }
        }

        app.buttons["video-capture-interval"].click()
        let interval = app.textFields["Screenshot interval"]
        XCTAssertTrue(interval.waitForExistence(timeout: 3), "Interval button did not open its popover")
        app.buttons["1 Secs"].click()
        app.buttons["Create Folder"].click()
        waitUntil("Interval capture did not create its folder", timeout: 30) {
            self.outputFiles().contains { url in
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                return contents.contains { $0.lastPathComponent == "Video.mov" }
                    && contents.contains { $0.pathExtension == "png" }
            }
        }
    }

    private func launchWorkbench(file: StaticString = #filePath, line: UInt = #line) {
        print("Workbench UI fixture root: \(root.path)")
        print("Workbench UI fixture canonical parent: \(root.deletingLastPathComponent().resolvingSymlinksInPath().path)")
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 3) {
            // macOS may restore a previous no-window session. Ask the standard
            // WindowGroup New Window command to open the test surface, without
            // changing production window restoration or startup behavior.
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Workbench launched without a window; fixture parent: \(root.deletingLastPathComponent().path)", file: file, line: line)
        print("Workbench UI test window: \(window.title)")
        XCTAssertFalse(
            app.staticTexts["Invalid UI Test Fixture"].exists,
            "Fixture validation rejected canonical parent: \(root.deletingLastPathComponent().resolvingSymlinksInPath().path)",
            file: file,
            line: line
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func drag(_ filename: String, onto destination: XCUIElement) {
        let source = element("file-grid-0-\(filename)")
        XCTAssertTrue(source.waitForExistence(timeout: 10), "Missing drag source \(filename)")
        XCTAssertTrue(destination.waitForExistence(timeout: 10), "Missing drop target")
        // The grid cell is an accessibility group containing an AppKit mouse
        // reporter, not a native clickable control. Its relative center still
        // provides a real on-screen drag path through the production handlers.
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(
            forDuration: 0.6,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 1
        )
    }

    private func assertMoved(_ source: URL, to destination: URL, expected: Data, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("File was not moved to \(destination.lastPathComponent)", file: file, line: line) {
            !FileManager.default.fileExists(atPath: source.path)
                && FileManager.default.fileExists(atPath: destination.path)
        }
        XCTAssertEqual(try Data(contentsOf: destination), expected, file: file, line: line)
    }

    private func outputFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: browser, includingPropertiesForKeys: nil)) ?? []
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, condition: @escaping () -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: timeout)
        let error = app.staticTexts["ui-test-last-error"].firstMatch
        let detail = error.exists ? error.label : ""
        XCTAssertEqual(result, .completed, "\(message)\n\(detail)", file: file, line: line)
    }
}
