import Foundation
import XCTest

@testable import Workbench

final class WorkbenchBuildInfoTests: XCTestCase {
    private let metadata = WorkbenchBuildMetadata(
        identifier: "20261105091530",
        builtAt: "2026-11-05T09:15:30Z",
        revision: "abcdef123456",
        hasUncommittedChanges: true,
        configuration: "Debug"
    )

    func testMetadataRoundTripsAsAPlistAndParsesItsBuildDate() throws {
        let data = try PropertyListEncoder().encode(metadata)
        let decoded = try WorkbenchBuildMetadata.decode(data)
        XCTAssertEqual(decoded, metadata)
        XCTAssertEqual(decoded.date?.timeIntervalSince1970, 1_793_870_130)
        XCTAssertEqual(decoded.sourceText, "abcdef123456 · modified sources")
    }

    func testBuildStampDistinguishesBuildsWithoutChangingTheReleaseVersion() {
        let info = buildInfo(metadata: metadata)
        XCTAssertEqual(info.version, "0.1.0")
        XCTAssertEqual(info.build, "1")
        XCTAssertEqual(info.displayBuild, "20261105091530")
        XCTAssertEqual(info.displayVersion, "Version 0.1.0 (20261105091530)")
    }

    func testDiagnosticsIncludeTheBuildTimestampRevisionAndConfiguration() {
        let info = buildInfo(metadata: metadata)
        XCTAssertTrue(info.diagnosticsText.contains("Built: 2026-11-05T09:15:30Z"))
        XCTAssertTrue(info.diagnosticsText.contains("Source: abcdef123456 · modified sources"))
        XCTAssertTrue(info.diagnosticsText.contains("Configuration: Debug"))
        XCTAssertTrue(info.diagnosticsText.contains("Bundle Build: 1"))
    }

    func testOlderBuildsFallBackToTheBundleVersionWithoutInventingADate() {
        let info = buildInfo(metadata: nil)
        XCTAssertEqual(info.displayVersion, "Version 0.1.0 (1)")
        XCTAssertTrue(info.diagnosticsText.contains("Built: Unavailable (older build)"))
    }

    func testAppBundleWasStampedBeforeItWasSigned() throws {
        let stamp = try XCTUnwrap(WorkbenchBuildMetadata.load(from: .main))
        XCTAssertFalse(stamp.identifier.isEmpty)
        XCTAssertNotNil(stamp.date)
        XCTAssertFalse(stamp.configuration.isEmpty)
        XCTAssertFalse(stamp.revision.isEmpty)
    }

    private func buildInfo(metadata: WorkbenchBuildMetadata?) -> WorkbenchBuildInfo {
        WorkbenchBuildInfo(
            appName: "Workbench",
            version: "0.1.0",
            build: "1",
            bundleID: "com.qnsub.workbench.app",
            macOSVersion: "Test macOS",
            hardwareModel: "Test Mac",
            metadata: metadata
        )
    }
}
