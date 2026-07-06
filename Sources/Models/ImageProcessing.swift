import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image resizing, rotation/flips, and downsampling via ImageIO + CoreImage.
enum ImageProcessing {
    private static let ciContext = CIContext()

    enum Transform {
        case rotateLeft
        case rotateRight
        case flipHorizontal
        case flipVertical

        /// `CIImage.oriented(_:)` applies the correction for an EXIF orientation,
        /// which is exactly the visual transform we want.
        var orientation: CGImagePropertyOrientation {
            switch self {
            case .rotateLeft: .left
            case .rotateRight: .right
            case .flipHorizontal: .upMirrored
            case .flipVertical: .downMirrored
            }
        }
    }
    enum Mode: Hashable {
        case maxDimension(Int)
        case percent(Int)
    }

    enum Format: String, CaseIterable, Identifiable {
        case original = "Original"
        case jpeg = "JPEG"
        case png = "PNG"
        var id: String { rawValue }
    }

    struct Options {
        var mode: Mode
        var format: Format
    }

    struct ProcessingError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes a resized copy next to the original (collision-safe) and returns its URL.
    /// Never touches the original file.
    @discardableResult
    nonisolated static func resize(_ url: URL, options: Options) async throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ProcessingError(message: "“\(url.lastPathComponent)” is not a readable image.")
        }

        let targetMax: Int
        switch options.mode {
        case .maxDimension(let dimension):
            targetMax = dimension
        case .percent(let percent):
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard max(width, height) > 0 else {
                throw ProcessingError(
                    message: "Couldn’t read the dimensions of “\(url.lastPathComponent)”."
                )
            }
            targetMax = Swift.max(1, max(width, height) * percent / 100)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMax,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            throw ProcessingError(message: "Couldn’t decode “\(url.lastPathComponent)”.")
        }

        let destinationType: UTType
        switch options.format {
        case .jpeg: destinationType = .jpeg
        case .png: destinationType = .png
        case .original:
            destinationType = (CGImageSourceGetType(source) as String?)
                .flatMap { UTType($0) } ?? .jpeg
        }

        if let written = write(image, as: destinationType, nextTo: url) {
            return written
        }
        // Some source formats (RAW, WebP, …) can be read but not written — fall back to JPEG.
        if destinationType != .jpeg, let written = write(image, as: .jpeg, nextTo: url) {
            return written
        }
        throw ProcessingError(
            message: "Couldn’t save a resized copy of “\(url.lastPathComponent)”."
        )
    }

    /// Rotates or flips an image IN PLACE (like Finder's Rotate quick action).
    /// Writes to a hidden temp file in the same folder, then atomically replaces
    /// the original so a failure never corrupts it.
    nonisolated static func transform(_ url: URL, _ operation: Transform) async throws {
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ProcessingError(message: "“\(url.lastPathComponent)” is not a readable image.")
        }
        image = image.oriented(operation.orientation)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw ProcessingError(message: "Couldn’t render “\(url.lastPathComponent)”.")
        }

        var sourceType: UTType = .jpeg
        var sourceProperties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let identifier = CGImageSourceGetType(source) as String?,
           let type = UTType(identifier) {
            sourceType = type
            sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] ?? [:]
        }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).transforming")
        try? FileManager.default.removeItem(at: temp)
        guard let writer = CGImageDestinationCreateWithURL(
            temp as CFURL, sourceType.identifier as CFString, 1, nil
        ) else {
            throw ProcessingError(
                message: "“\(url.lastPathComponent)” is in a format that can’t be rewritten."
            )
        }
        sourceProperties[kCGImagePropertyOrientation] = 1
        if var tiff = sourceProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            sourceProperties[kCGImagePropertyTIFFDictionary] = tiff
        }
        sourceProperties[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(writer, cgImage, sourceProperties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: temp)
            throw ProcessingError(message: "Couldn’t save “\(url.lastPathComponent)”.")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Decode an image downsampled to at most `maxPixel` on its longest side (for previews).
    nonisolated static func downsampled(url: URL, maxPixel: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func write(
        _ image: CGImage, as type: UTType, nextTo original: URL
    ) -> URL? {
        let ext = type.preferredFilenameExtension ?? "jpg"
        let baseName = original.deletingPathExtension().lastPathComponent
        let candidate = original.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(image.width)x\(image.height).\(ext)")
        let destination = FileOperations.uniqueDestination(for: candidate)
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, type.identifier as CFString, 1, nil
        ) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        return CGImageDestinationFinalize(writer) ? destination : nil
    }
}
