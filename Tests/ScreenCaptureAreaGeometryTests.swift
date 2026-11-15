import CoreGraphics
import XCTest
@testable import Workbench

final class ScreenCaptureAreaGeometryTests: XCTestCase {
    func testSelectionTranslatesIntoGlobalTopLeftPointsOnOffsetDisplay() {
        let display = CGRect(x: -1600, y: -350, width: 1600, height: 1000)
        let local = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            ScreenCaptureAreaGeometry.quartzRectangle(
                CGRect(x: 100, y: 70, width: 200, height: 140), in: local, on: display
            ),
            CGRect(x: -1500, y: -280, width: 200, height: 140)
        )
    }

    func testSelectionIsClippedToStartingDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 70)
        let display = CGRect(x: 300, y: 40, width: 100, height: 70)
        XCTAssertEqual(
            ScreenCaptureAreaGeometry.quartzRectangle(
                CGRect(x: 80, y: 50, width: 50, height: 50), in: bounds, on: display
            ),
            CGRect(x: 380, y: 90, width: 20, height: 20)
        )
        XCTAssertNil(ScreenCaptureAreaGeometry.quartzRectangle(
            CGRect(x: 3, y: 2, width: 1, height: 2), in: bounds, on: display
        ))
    }
}
