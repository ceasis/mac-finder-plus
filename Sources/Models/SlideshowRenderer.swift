import AVFoundation
import CoreVideo
import Foundation

/// Renders a set of photos into an H.264 MP4 slideshow with AVAssetWriter.
/// Each photo is shown for a fixed duration; one frame is written per photo,
/// so output files stay small regardless of duration.
enum SlideshowRenderer {
    struct Options {
        var secondsPerPhoto: Double
        var size: CGSize
        /// false = aspect-fit with black bars, true = aspect-fill (cropped).
        var fill: Bool
    }

    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static func render(
        images: [URL],
        to output: URL,
        options: Options,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard !images.isEmpty else {
            throw RenderError(message: "No images to render.")
        }
        let width = Int(options.size.width)
        let height = Int(options.size.height)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RenderError(message: "Couldn’t start writing the video.")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let photoDuration = CMTime(seconds: options.secondsPerPhoto, preferredTimescale: timescale)
        let totalDuration = CMTimeMultiply(photoDuration, multiplier: Int32(images.count))

        for (index, url) in images.enumerated() {
            if Task.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }
            guard let cgImage = await ImageProcessing.downsampled(
                url: url, maxPixel: max(width, height)
            ) else {
                writer.cancelWriting()
                throw RenderError(message: "Couldn’t read “\(url.lastPathComponent)”.")
            }
            guard let buffer = pixelBuffer(
                from: cgImage, width: width, height: height,
                fill: options.fill, pool: adaptor.pixelBufferPool
            ) else {
                writer.cancelWriting()
                throw RenderError(message: "Couldn’t render “\(url.lastPathComponent)”.")
            }
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let time = CMTimeMultiply(photoDuration, multiplier: Int32(index))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                let failure = writer.error
                writer.cancelWriting()
                throw failure ?? RenderError(message: "Failed writing photo \(index + 1).")
            }
            // Re-append the last photo just before the end so it holds for its full duration.
            if index == images.count - 1 {
                while !input.isReadyForMoreMediaData {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                let holdTime = totalDuration - CMTime(value: 20, timescale: timescale)
                adaptor.append(buffer, withPresentationTime: holdTime)
            }
            progress(Double(index + 1) / Double(images.count))
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: totalDuration)
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? RenderError(message: "The video could not be completed.")
        }
    }

    private nonisolated static func pixelBuffer(
        from image: CGImage, width: Int, height: Int, fill: Bool, pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32ARGB,
                attributes as CFDictionary, &pixelBuffer
            )
        }
        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let canvas = CGSize(width: CGFloat(width), height: CGFloat(height))
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = fill
            ? max(canvas.width / imageSize.width, canvas.height / imageSize.height)
            : min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: (canvas.width - drawSize.width) / 2,
            y: (canvas.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        return buffer
    }
}
