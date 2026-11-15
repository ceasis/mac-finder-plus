import CoreGraphics
import ImageIO
import XCTest
@testable import Workbench

final class ScreenshotImageEncoderTests: XCTestCase {
    func testRasterFormatsKeepCaptureDimensions() throws {
        let image = try makeImage()
        for format in [ScreenshotFormat.png, .jpg, .tiff] {
            let data = try ScreenshotImageEncoder.encode(image, as: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, image.width)
            XCTAssertEqual(decoded.height, image.height)
        }
    }

    func testPDFProducesOnePageAtCaptureDimensions() throws {
        let image = try makeImage()
        let data = try ScreenshotImageEncoder.encode(image, as: .pdf)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 1)
        XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 32, height: 16))
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.3, green: 0.7, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        return try XCTUnwrap(context.makeImage())
    }
}
