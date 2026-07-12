import AVFoundation
import CoreVideo
import Foundation

struct VideoMergeOptions: Sendable {
    var secondsPerImage: Double
    var size: CGSize
    /// false = aspect-fit with black bars, true = aspect-fill (cropped).
    var fill: Bool
}

enum VideoMergeSource: Sendable {
    case image(URL)
    case video(URL)
}

/// One export entry point for image-only, video-only, and mixed media sequences.
enum MediaVideoRenderer {
    private static let imagePreparationWeight = 0.25

    @discardableResult
    static func merge(
        _ sources: [VideoMergeSource],
        outputDirectory: URL,
        options: VideoMergeOptions,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        guard sources.count >= 2 else {
            throw SlideshowRenderer.RenderError(message: "Select at least two images or videos.")
        }

        let imageURLs = sources.compactMap { source -> URL? in
            guard case let .image(url) = source else { return nil }
            return url
        }
        let videoURLs = sources.compactMap { source -> URL? in
            guard case let .video(url) = source else { return nil }
            return url
        }

        if imageURLs.count == sources.count {
            let output = outputURL(in: outputDirectory)
            do {
                try await SlideshowRenderer.render(
                    images: imageURLs,
                    to: output,
                    options: options,
                    progress: progress
                )
                return output
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }

        if videoURLs.count == sources.count {
            return try await VideoMerger.merge(
                videoURLs,
                outputDirectory: outputDirectory,
                options: options,
                progress: progress
            )
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Workbench-VideoMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        var videoInputs: [URL] = []
        var imageIndex = 0
        for source in sources {
            try Task.checkCancellation()
            switch source {
            case let .video(url):
                videoInputs.append(url)
            case let .image(url):
                let currentImageIndex = imageIndex
                let stagedClip = stagingDirectory.appendingPathComponent(
                    String(format: "image-%03d.mp4", currentImageIndex)
                )
                try await SlideshowRenderer.render(
                    images: [url],
                    to: stagedClip,
                    options: options
                ) { clipProgress in
                    let completed = (Double(currentImageIndex) + clipProgress) / Double(imageURLs.count)
                    await progress(completed * imagePreparationWeight)
                }
                videoInputs.append(stagedClip)
                imageIndex += 1
            }
        }

        return try await VideoMerger.merge(
            videoInputs,
            outputDirectory: outputDirectory,
            options: options
        ) { mergeProgress in
            await progress(
                imagePreparationWeight + mergeProgress * (1 - imagePreparationWeight)
            )
        }
    }

    private static func outputURL(in folder: URL) -> URL {
        FileOperations.uniqueDestination(
            for: folder.appendingPathComponent("Merged Video.mp4")
        )
    }
}

/// Renders a set of photos into an H.264 MP4 slideshow with AVAssetWriter.
/// Each photo is shown for a fixed duration; one frame is written per photo,
/// so output files stay small regardless of duration.
enum SlideshowRenderer {
    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static func render(
        images: [URL],
        to output: URL,
        options: VideoMergeOptions,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
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
        let photoDuration = CMTime(seconds: options.secondsPerImage, preferredTimescale: timescale)
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
            await progress(Double(index + 1) / Double(images.count))
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
