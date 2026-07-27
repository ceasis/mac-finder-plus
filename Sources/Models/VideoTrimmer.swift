import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaTransformOperation: String, CaseIterable, Sendable {
    case rotateCounterclockwise
    case rotateClockwise
    case flipHorizontal
    case flipVertical

    var title: String {
        switch self {
        case .rotateCounterclockwise: "Rotate Counterclockwise"
        case .rotateClockwise: "Rotate Clockwise"
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        }
    }

    var imageTransform: ImageProcessing.Transform {
        switch self {
        case .rotateCounterclockwise: .rotateLeft
        case .rotateClockwise: .rotateRight
        case .flipHorizontal: .flipHorizontal
        case .flipVertical: .flipVertical
        }
    }

    var outputSuffix: String {
        switch self {
        case .rotateCounterclockwise: "rotated-counterclockwise"
        case .rotateClockwise: "rotated-clockwise"
        case .flipHorizontal: "flipped-horizontal"
        case .flipVertical: "flipped-vertical"
        }
    }
}

struct VideoTransformGeometry {
    let transform: CGAffineTransform
    let renderSize: CGSize
}

enum VideoTransformer {
    static let longVideoWarningDuration: Double = 15 * 60

    static func duration(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }

    @discardableResult
    static func transform(
        _ url: URL,
        operation: MediaTransformOperation,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” has no usable video duration."
            )
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” has no video track to transform."
            )
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let geometry = transformGeometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            operation: operation
        )

        let composition = AVMutableVideoComposition()
        composition.renderSize = geometry.renderSize
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let framesPerSecond = frameRate.isFinite && frameRate > 0 ? frameRate : 30
        composition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(max(framesPerSecond.rounded(), 1))
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(geometry.transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” can’t be exported for this transformation."
            )
        }
        let output = outputURL(
            for: url,
            suffix: operation.outputSuffix,
            supportedTypes: export.supportedFileTypes
        )
        export.outputURL = output.url
        export.outputFileType = output.fileType
        export.videoComposition = composition
        export.shouldOptimizeForNetworkUse = true

        let exportBox = VideoTransformExportSessionBox(export)
        let progressTask = Task {
            while !Task.isCancelled {
                await progress(Double(exportBox.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exportBox.export {
                        continuation.resume(with: $0)
                    }
                }
            } onCancel: {
                exportBox.cancel()
            }
            await progress(1)
            return output.url
        } catch {
            try? FileManager.default.removeItem(at: output.url)
            throw error
        }
    }

    static func transformGeometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        operation: MediaTransformOperation
    ) -> VideoTransformGeometry {
        let naturalRect = CGRect(origin: .zero, size: naturalSize)
        let preferredRect = naturalRect.applying(preferredTransform)
        let baseTransform = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -preferredRect.minX,
                y: -preferredRect.minY
            )
        )
        let width = abs(preferredRect.width)
        let height = abs(preferredRect.height)

        let operationTransform: CGAffineTransform
        let renderSize: CGSize
        switch operation {
        case .rotateClockwise:
            operationTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
            renderSize = CGSize(width: height, height: width)
        case .rotateCounterclockwise:
            operationTransform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
            renderSize = CGSize(width: height, height: width)
        case .flipHorizontal:
            operationTransform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
            renderSize = CGSize(width: width, height: height)
        case .flipVertical:
            operationTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
            renderSize = CGSize(width: width, height: height)
        }
        return VideoTransformGeometry(
            transform: baseTransform.concatenating(operationTransform),
            renderSize: renderSize
        )
    }

    private static func outputURL(
        for source: URL,
        suffix: String,
        supportedTypes: [AVFileType]
    ) -> (url: URL, fileType: AVFileType) {
        let outputType: AVFileType
        if supportedTypes.contains(.mp4) {
            outputType = .mp4
        } else if supportedTypes.contains(.mov) {
            outputType = .mov
        } else if let first = supportedTypes.first {
            outputType = first
        } else {
            outputType = .mov
        }

        let outputExtension = UTType(outputType.rawValue)?.preferredFilenameExtension
            ?? source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        let candidate = source.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(suffix).\(outputExtension)")
        return (FileOperations.uniqueDestination(for: candidate), outputType)
    }
}

enum VideoFrameCapture {
    @discardableResult
    static func capture(url: URL, at seconds: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” has no video track to capture."
            )
        }

        let videoTimeRange = try await videoTrack.load(.timeRange)
        guard videoTimeRange.isValid, !videoTimeRange.isEmpty else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” has no usable video frames."
            )
        }

        let requestedTime = CMTime(
            seconds: seconds.isFinite ? max(seconds, 0) : 0,
            preferredTimescale: 600
        )
        let captureTime = clampedCaptureTime(requestedTime, to: videoTimeRange)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let result = try await generator.image(at: captureTime)
        let destination = outputURL(for: url, at: result.actualTime)
        try writePNG(result.image, to: destination)
        return destination
    }

    static func writePNG(_ image: CGImage, to destination: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessing.ProcessingError(
                message: "Couldn’t create “\(destination.lastPathComponent)”."
            )
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw ImageProcessing.ProcessingError(
                message: "Couldn’t save “\(destination.lastPathComponent)”."
            )
        }
    }

    static func outputURL(for videoURL: URL, at time: CMTime) -> URL {
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let candidate = videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-frame-\(timestampToken(for: time)).png")
        return FileOperations.uniqueDestination(for: candidate)
    }

    static func timestampToken(for time: CMTime) -> String {
        let seconds = CMTimeGetSeconds(time)
        let totalMilliseconds = seconds.isFinite
            ? max(Int64((seconds * 1_000).rounded()), 0)
            : 0
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let wholeSeconds = (totalMilliseconds / 1_000) % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(
            format: "%02lld-%02lld-%02lld-%03lld",
            hours,
            minutes,
            wholeSeconds,
            milliseconds
        )
    }

    private static func clampedCaptureTime(
        _ requestedTime: CMTime,
        to videoTimeRange: CMTimeRange
    ) -> CMTime {
        guard requestedTime.isValid, !requestedTime.isIndefinite else {
            return videoTimeRange.start
        }
        if CMTimeCompare(requestedTime, videoTimeRange.start) < 0 {
            return videoTimeRange.start
        }

        let end = CMTimeRangeGetEnd(videoTimeRange)
        if CMTimeCompare(requestedTime, end) < 0 {
            return requestedTime
        }
        let finalMoment = CMTimeSubtract(
            end,
            CMTime(value: 1, timescale: max(end.timescale, 600))
        )
        return CMTimeCompare(finalMoment, videoTimeRange.start) >= 0
            ? finalMoment
            : videoTimeRange.start
    }
}

struct VideoIntervalCaptureResult: Sendable {
    let folderURL: URL
    let copiedVideoURL: URL
    let screenshotURLs: [URL]
}

enum VideoIntervalFrameCapture {
    static let maximumFrameCount = 10_000
    static let minimumInterval = 0.1

    static func frameCount(duration: Double, interval: Double) -> Int {
        guard duration.isFinite,
              duration > 0,
              interval.isFinite,
              interval >= minimumInterval else {
            return 0
        }
        let count = ceil(duration / interval)
        guard count.isFinite, count <= Double(Int.max) else { return Int.max }
        return max(Int(count), 1)
    }

    static func captureTimes(duration: Double, interval: Double) -> [Double] {
        let count = frameCount(duration: duration, interval: interval)
        guard count > 0, count <= maximumFrameCount else { return [] }
        return (0..<count).map { Double($0) * interval }
    }

    @discardableResult
    static func capture(
        url: URL,
        every interval: Double,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) async -> Void = { _, _ in }
    ) async throws -> VideoIntervalCaptureResult {
        guard interval.isFinite, interval >= minimumInterval else {
            throw ImageProcessing.ProcessingError(
                message: "The screenshot interval must be at least 100 milliseconds."
            )
        }

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” has no video track to capture."
            )
        }

        let timeRange = try await videoTrack.load(.timeRange)
        let duration = CMTimeGetSeconds(timeRange.duration)
        guard timeRange.isValid,
              !timeRange.isEmpty,
              duration.isFinite,
              duration > 0 else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” has no usable video frames."
            )
        }

        let times = captureTimes(duration: duration, interval: interval)
        let count = frameCount(duration: duration, interval: interval)
        guard count <= maximumFrameCount else {
            throw ImageProcessing.ProcessingError(
                message: "This interval would create more than "
                    + "\(maximumFrameCount.formatted()) screenshots. Choose a longer interval."
            )
        }
        guard !times.isEmpty else {
            throw ImageProcessing.ProcessingError(
                message: "No screenshot times could be created for this video."
            )
        }

        let fileManager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let proposedFolder = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName) Screenshots", isDirectory: true)
        let folderURL = FileOperations.uniqueDestination(for: proposedFolder)

        do {
            try fileManager.createDirectory(
                at: folderURL,
                withIntermediateDirectories: false
            )
            let copiedVideoURL = folderURL.appendingPathComponent(url.lastPathComponent)
            await progress(0, times.count)
            try Task.checkCancellation()
            try fileManager.copyItem(at: url, to: copiedVideoURL)

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            defer { generator.cancelAllCGImageGeneration() }

            let numberWidth = max(String(times.count).count, 4)
            var screenshotURLs: [URL] = []
            screenshotURLs.reserveCapacity(times.count)

            for (index, relativeSeconds) in times.enumerated() {
                try Task.checkCancellation()
                let relativeTime = CMTime(
                    seconds: relativeSeconds,
                    preferredTimescale: 600
                )
                let requestedTime = CMTimeAdd(timeRange.start, relativeTime)
                let result = try await generator.image(at: requestedTime)
                try Task.checkCancellation()

                let actualRelativeTime = CMTimeSubtract(result.actualTime, timeRange.start)
                let sequence = String(format: "%0*d", numberWidth, index + 1)
                let fileName = "\(baseName)-frame-\(sequence)-"
                    + "\(VideoFrameCapture.timestampToken(for: actualRelativeTime)).png"
                let destination = folderURL.appendingPathComponent(fileName)
                try VideoFrameCapture.writePNG(result.image, to: destination)
                screenshotURLs.append(destination)
                await progress(index + 1, times.count)
            }

            return VideoIntervalCaptureResult(
                folderURL: folderURL,
                copiedVideoURL: copiedVideoURL,
                screenshotURLs: screenshotURLs
            )
        } catch {
            try? fileManager.removeItem(at: folderURL)
            throw error
        }
    }
}

struct VideoMergeLayout {
    let transform: CGAffineTransform
    let contentSize: CGSize
}

enum VideoMerger {
    private struct PreparedClip {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let videoTimeRange: CMTimeRange
        let audioTimeRange: CMTimeRange?
        let duration: CMTime
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let frameRate: Float
    }

    @discardableResult
    static func merge(
        _ urls: [URL],
        outputDirectory: URL,
        options: VideoMergeOptions? = nil,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        guard urls.count >= 2 else {
            throw ImageProcessing.ProcessingError(message: "Select at least two videos to merge.")
        }

        var clips: [PreparedClip] = []
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw ImageProcessing.ProcessingError(
                    message: "“\(url.lastPathComponent)” has no video track to merge."
                )
            }
            let videoTimeRange = try await videoTrack.load(.timeRange)
            let duration = videoTimeRange.duration
            let seconds = CMTimeGetSeconds(duration)
            guard videoTimeRange.isValid, !videoTimeRange.isEmpty,
                  seconds.isFinite, seconds > 0 else {
                throw ImageProcessing.ProcessingError(
                    message: "“\(url.lastPathComponent)” has no usable video duration."
                )
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let audioTrack = audioTracks.first
            let loadedAudioTimeRange = try await audioTrack?.load(.timeRange)
            let audioTimeRange = loadedAudioTimeRange.flatMap { timeRange in
                let audioSeconds = CMTimeGetSeconds(timeRange.duration)
                return timeRange.isValid && !timeRange.isEmpty
                    && audioSeconds.isFinite && audioSeconds > 0
                    ? timeRange
                    : nil
            }
            clips.append(PreparedClip(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: audioTrack,
                videoTimeRange: videoTimeRange,
                audioTimeRange: audioTimeRange,
                duration: duration,
                naturalSize: try await videoTrack.load(.naturalSize),
                preferredTransform: try await videoTrack.load(.preferredTransform),
                frameRate: try await videoTrack.load(.nominalFrameRate)
            ))
            await progress(Double(index + 1) / Double(urls.count) * 0.05)
        }

        // Composition segments still read from these assets while export is running.
        let sourceAssets = clips.map(\.asset)
        let renderSize = options.map { normalizedRenderSize($0.size) } ?? maximumRenderSize(for: clips)
        let fillFrame = options?.fill ?? false
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let frameRate = clips.map(\.frameRate).filter { $0.isFinite && $0 > 0 }.max() ?? 30
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(max(frameRate.rounded(), 1))
        )
        let includeAudio = options?.includeAudio ?? true

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var cursor = CMTime.zero
        for clip in clips {
            try Task.checkCancellation()
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ImageProcessing.ProcessingError(message: "Couldn’t prepare a merged video track.")
            }
            try compositionVideoTrack.insertTimeRange(
                clip.videoTimeRange,
                of: clip.videoTrack,
                at: cursor
            )

            if let audioTrack = clip.audioTrack,
               let audioTimeRange = clip.audioTimeRange,
               includeAudio,
               let audioSegment = audioInsertionSegment(
                   videoTimeRange: clip.videoTimeRange,
                   audioTimeRange: audioTimeRange,
                   compositionStart: cursor
               ) {
                guard let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw ImageProcessing.ProcessingError(
                        message: "Couldn’t prepare the merged audio track."
                    )
                }
                try compositionAudioTrack.insertTimeRange(
                    audioSegment.sourceTimeRange,
                    of: audioTrack,
                    at: audioSegment.destinationStart
                )
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: clip.duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(
                assetTrack: compositionVideoTrack
            )
            layerInstruction.setTransform(
                mergeLayout(
                    naturalSize: clip.naturalSize,
                    preferredTransform: clip.preferredTransform,
                    renderSize: renderSize,
                    fill: fillFrame
                ).transform,
                at: cursor
            )
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)
            cursor = CMTimeAdd(cursor, clip.duration)
        }
        videoComposition.instructions = instructions

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ImageProcessing.ProcessingError(message: "Couldn’t prepare the merged video for export.")
        }
        let output = outputURL(in: outputDirectory, supportedTypes: export.supportedFileTypes)
        export.outputURL = output.url
        export.outputFileType = output.fileType
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        await progress(0.10)

        let exportBox = VideoMergeExportSessionBox(export)
        let progressTask = Task {
            while !Task.isCancelled {
                await progress(0.10 + Double(exportBox.progress) * 0.90)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exportBox.export {
                        continuation.resume(with: $0)
                    }
                }
            } onCancel: {
                exportBox.cancel()
            }
            withExtendedLifetime(sourceAssets) {}
            await progress(1)
            return output.url
        } catch {
            try? FileManager.default.removeItem(at: output.url)
            throw error
        }
    }

    static func audioInsertionSegment(
        videoTimeRange: CMTimeRange,
        audioTimeRange: CMTimeRange,
        compositionStart: CMTime
    ) -> (sourceTimeRange: CMTimeRange, destinationStart: CMTime)? {
        let overlap = CMTimeRangeGetIntersection(videoTimeRange, otherRange: audioTimeRange)
        let durationSeconds = CMTimeGetSeconds(overlap.duration)
        guard overlap.isValid, !overlap.isEmpty,
              durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }

        let offset = CMTimeSubtract(overlap.start, videoTimeRange.start)
        let offsetSeconds = CMTimeGetSeconds(offset)
        guard offsetSeconds.isFinite, offsetSeconds >= 0 else {
            return nil
        }
        return (
            sourceTimeRange: overlap,
            destinationStart: CMTimeAdd(compositionStart, offset)
        )
    }

    static func mergeLayout(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize,
        fill: Bool = false
    ) -> VideoMergeLayout {
        let naturalRect = CGRect(origin: .zero, size: naturalSize)
        let preferredRect = naturalRect.applying(preferredTransform)
        let baseTransform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -preferredRect.minX, y: -preferredRect.minY)
        )
        let contentSize = CGSize(width: abs(preferredRect.width), height: abs(preferredRect.height))
        let horizontalScale = renderSize.width / max(contentSize.width, 1)
        let verticalScale = renderSize.height / max(contentSize.height, 1)
        let scale = fill ? max(horizontalScale, verticalScale) : min(horizontalScale, verticalScale)
        let scaledSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let translation = CGAffineTransform(
            translationX: (renderSize.width - scaledSize.width) / 2,
            y: (renderSize.height - scaledSize.height) / 2
        )
        return VideoMergeLayout(
            transform: baseTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(translation),
            contentSize: contentSize
        )
    }

    private static func maximumRenderSize(for clips: [PreparedClip]) -> CGSize {
        let width = clips.reduce(CGFloat.zero) { partial, clip in
            max(partial, abs(CGRect(origin: .zero, size: clip.naturalSize).applying(clip.preferredTransform).width))
        }
        let height = clips.reduce(CGFloat.zero) { partial, clip in
            max(partial, abs(CGRect(origin: .zero, size: clip.naturalSize).applying(clip.preferredTransform).height))
        }
        return CGSize(width: evenDimension(width), height: evenDimension(height))
    }

    private static func normalizedRenderSize(_ size: CGSize) -> CGSize {
        CGSize(width: evenDimension(size.width), height: evenDimension(size.height))
    }

    private static func evenDimension(_ value: CGFloat) -> CGFloat {
        max(2, (value.rounded() / 2).rounded(.down) * 2)
    }

    private static func outputURL(
        in folder: URL,
        supportedTypes: [AVFileType]
    ) -> (url: URL, fileType: AVFileType) {
        let outputType: AVFileType
        if supportedTypes.contains(.mp4) {
            outputType = .mp4
        } else if supportedTypes.contains(.mov) {
            outputType = .mov
        } else if let first = supportedTypes.first {
            outputType = first
        } else {
            outputType = .mov
        }
        let outputExtension = UTType(outputType.rawValue)?.preferredFilenameExtension ?? "mov"
        let candidate = folder.appendingPathComponent("Merged Video.\(outputExtension)")
        return (FileOperations.uniqueDestination(for: candidate), outputType)
    }
}

enum VideoTrimmer {
    static func duration(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }

    @discardableResult
    static func export(
        url: URL,
        inTime: Double,
        outTime: Double,
        muteAudio: Bool = false,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard outTime > inTime else {
            throw ImageProcessing.ProcessingError(message: "Trim out point must be after the in point.")
        }
        let presetName = muteAudio
            ? AVAssetExportPresetHighestQuality
            : AVAssetExportPresetPassthrough
        guard let export = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” can’t be exported with the selected settings."
            )
        }
        let exportBox = TrimExportSessionBox(export)

        let output = outputURL(for: url, supportedTypes: export.supportedFileTypes)
        export.outputURL = output.url
        export.outputFileType = output.fileType
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: max(inTime, 0), preferredTimescale: 600),
            duration: CMTime(seconds: outTime - inTime, preferredTimescale: 600)
        )
        export.shouldOptimizeForNetworkUse = true

        if muteAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if !audioTracks.isEmpty {
                let audioMix = AVMutableAudioMix()
                audioMix.inputParameters = audioTracks.map { track in
                    let parameters = AVMutableAudioMixInputParameters(track: track)
                    parameters.setVolume(0, at: .zero)
                    return parameters
                }
                export.audioMix = audioMix
            }
        }

        let progressTask = Task {
            while !Task.isCancelled {
                await progress(Double(exportBox.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exportBox.export {
                        continuation.resume(with: $0)
                    }
                }
            } onCancel: {
                exportBox.cancel()
            }
            await progress(1)
            return output.url
        } catch {
            try? FileManager.default.removeItem(at: output.url)
            throw error
        }
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let wholeSeconds = max(Int(seconds.rounded()), 0)
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let remainingSeconds = wholeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func preciseTimeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let totalCentiseconds = max(Int((seconds * 100).rounded()), 0)
        let hours = totalCentiseconds / 360_000
        let minutes = (totalCentiseconds % 360_000) / 6_000
        let remainingSeconds = (totalCentiseconds % 6_000) / 100
        let centiseconds = totalCentiseconds % 100
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d.%02d",
                hours,
                minutes,
                remainingSeconds,
                centiseconds
            )
        }
        return String(format: "%d:%02d.%02d", minutes, remainingSeconds, centiseconds)
    }

    private static func outputURL(
        for source: URL,
        supportedTypes: [AVFileType]
    ) -> (url: URL, fileType: AVFileType) {
        let preferredType: AVFileType
        if source.pathExtension.localizedCaseInsensitiveCompare("mp4") == .orderedSame,
           supportedTypes.contains(.mp4) {
            preferredType = .mp4
        } else if supportedTypes.contains(.mov) {
            preferredType = .mov
        } else {
            preferredType = supportedTypes.first ?? .mov
        }

        let outputExtension = preferredType == .mp4 ? "mp4" : "mov"
        let baseName = source.deletingPathExtension().lastPathComponent
        let candidate = source.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-trimmed.\(outputExtension)")
        return (FileOperations.uniqueDestination(for: candidate), preferredType)
    }
}

enum AudioRangeExporter {
    static func hasAudioTrack(in url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        return tracks?.isEmpty == false
    }

    @discardableResult
    static func export(
        url: URL,
        inTime: Double,
        outTime: Double,
        outputSuffix: String,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        guard inTime.isFinite,
              outTime.isFinite,
              outTime - inTime >= 0.1 else {
            throw ImageProcessing.ProcessingError(
                message: "The audio out point must be after the in point."
            )
        }

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” has no audio track to export."
            )
        }

        let audioTimeRange = try await audioTrack.load(.timeRange)
        let requestedRange = CMTimeRange(
            start: CMTime(seconds: max(inTime, 0), preferredTimescale: 600),
            duration: CMTime(seconds: outTime - max(inTime, 0), preferredTimescale: 600)
        )
        let exportRange = CMTimeRangeGetIntersection(
            requestedRange,
            otherRange: audioTimeRange
        )
        let exportDuration = CMTimeGetSeconds(exportRange.duration)
        guard exportRange.isValid,
              !exportRange.isEmpty,
              exportDuration.isFinite,
              exportDuration >= 0.1 else {
            throw ImageProcessing.ProcessingError(
                message: "The selected range contains no exportable audio."
            )
        }

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ), export.supportedFileTypes.contains(.m4a) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” can’t be exported as M4A audio."
            )
        }

        let output = outputURL(for: url, suffix: outputSuffix)
        export.outputURL = output
        export.outputFileType = .m4a
        export.timeRange = exportRange
        export.shouldOptimizeForNetworkUse = true

        let exportBox = VideoAudioExportSessionBox(export)
        let progressTask = Task {
            while !Task.isCancelled {
                await progress(Double(exportBox.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exportBox.export {
                        continuation.resume(with: $0)
                    }
                }
            } onCancel: {
                exportBox.cancel()
            }
            await progress(1)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func outputURL(for source: URL, suffix: String) -> URL {
        let baseName = source.deletingPathExtension().lastPathComponent
        let candidate = source.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(suffix).m4a")
        return FileOperations.uniqueDestination(for: candidate)
    }
}

enum AudioWaveform {
    static func samples(for url: URL, count: Int) async throws -> [Float] {
        guard count > 0 else { return [] }

        return try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw ImageProcessing.ProcessingError(
                    message: "“\(url.lastPathComponent)” has no audio track."
                )
            }

            let loadedDuration = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(loadedDuration)
            guard duration.isFinite, duration > 0 else {
                throw ImageProcessing.ProcessingError(
                    message: "“\(url.lastPathComponent)” has no usable audio duration."
                )
            }

            let formatDescriptions = try await track.load(.formatDescriptions)
            let sampleRate = formatDescriptions.lazy.compactMap { description in
                CMAudioFormatDescriptionGetStreamBasicDescription(description)?
                    .pointee.mSampleRate
            }.first(where: { $0.isFinite && $0 > 0 }) ?? 44_100

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ImageProcessing.ProcessingError(
                    message: "“\(url.lastPathComponent)” can’t be decoded for a waveform."
                )
            }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? ImageProcessing.ProcessingError(
                    message: "Couldn’t read “\(url.lastPathComponent)” for a waveform."
                )
            }

            var peaks = [Float](repeating: 0, count: count)
            var processedFrames = 0
            let estimatedFrames = max(Int((duration * sampleRate).rounded(.up)), 1)
            let sampleStride = max(estimatedFrames / max(count * 128, 1), 1)

            while let sampleBuffer = output.copyNextSampleBuffer() {
                if Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }

                guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                    continue
                }
                let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
                let byteCount = CMBlockBufferGetDataLength(dataBuffer)
                let valueCount = byteCount / MemoryLayout<Float>.size
                guard frameCount > 0, valueCount > 0 else { continue }

                var values = [Float](repeating: 0, count: valueCount)
                let copyStatus = values.withUnsafeMutableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return kCMBlockBufferBadCustomBlockSourceErr
                    }
                    return CMBlockBufferCopyDataBytes(
                        dataBuffer,
                        atOffset: 0,
                        dataLength: byteCount,
                        destination: baseAddress
                    )
                }
                guard copyStatus == kCMBlockBufferNoErr else { continue }

                let channelCount = max(valueCount / frameCount, 1)
                for frame in stride(from: 0, to: frameCount, by: sampleStride) {
                    let globalFrame = min(processedFrames + frame, estimatedFrames - 1)
                    let bin = min(
                        Int(Double(globalFrame) / Double(estimatedFrames) * Double(count)),
                        count - 1
                    )
                    let firstValue = frame * channelCount
                    let lastValue = min(firstValue + channelCount, valueCount)
                    guard firstValue < lastValue else { continue }

                    var framePeak: Float = 0
                    for valueIndex in firstValue..<lastValue {
                        let amplitude = abs(values[valueIndex])
                        if amplitude.isFinite {
                            framePeak = max(framePeak, amplitude)
                        }
                    }
                    peaks[bin] = max(peaks[bin], framePeak)
                }
                processedFrames += frameCount
            }

            if reader.status == .failed {
                throw reader.error ?? ImageProcessing.ProcessingError(
                    message: "Couldn’t finish building the audio waveform."
                )
            }

            guard let maximumPeak = peaks.max(), maximumPeak > 0 else {
                return peaks
            }
            return peaks.map { peak in
                Float(pow(Double(peak / maximumPeak), 0.55))
            }
        }.value
    }
}

enum VideoFilmstrip {
    static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        return (0..<count).map { index in
            duration * (Double(index) + 0.5) / Double(count)
        }
    }

    static func time(at location: Double, width: Double, duration: Double) -> Double {
        guard location.isFinite,
              width.isFinite,
              width > 0,
              duration.isFinite,
              duration > 0 else {
            return 0
        }
        return min(max(location / width, 0), 1) * duration
    }

    static func clampedInTime(
        _ requestedTime: Double,
        outTime: Double,
        duration: Double
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let validOutTime = min(max(outTime, 0), duration)
        let minimumSelection = min(0.1, duration)
        return min(
            max(requestedTime.isFinite ? requestedTime : 0, 0),
            max(validOutTime - minimumSelection, 0)
        )
    }

    static func clampedOutTime(
        _ requestedTime: Double,
        inTime: Double,
        duration: Double
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let validInTime = min(max(inTime, 0), duration)
        let minimumSelection = min(0.1, duration)
        let minimumOutTime = min(validInTime + minimumSelection, duration)
        return min(
            max(requestedTime.isFinite ? requestedTime : duration, minimumOutTime),
            duration
        )
    }
}

private final class VideoAudioExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    var progress: Float {
        session.progress
    }

    func cancel() {
        session.cancelExport()
    }

    func export(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        session.exportAsynchronously {
            switch self.session.status {
            case .completed:
                completion(.success(()))
            case .cancelled:
                completion(.failure(CancellationError()))
            case .failed:
                completion(.failure(
                    self.session.error ?? ImageProcessing.ProcessingError(
                        message: "Couldn’t export this audio track."
                    )
                ))
            default:
                completion(.failure(ImageProcessing.ProcessingError(
                    message: "Couldn’t export this audio track."
                )))
            }
        }
    }
}

private final class TrimExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    var progress: Float {
        session.progress
    }

    func cancel() {
        session.cancelExport()
    }

    func export(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        session.exportAsynchronously {
            switch self.session.status {
            case .completed:
                completion(.success(()))
            case .cancelled:
                completion(.failure(CancellationError()))
            case .failed:
                completion(.failure(
                    self.session.error ?? ImageProcessing.ProcessingError(
                        message: "Couldn’t export this trim."
                    )
                ))
            default:
                completion(.failure(ImageProcessing.ProcessingError(
                    message: "Couldn’t export this trim."
                )))
            }
        }
    }
}

private final class VideoTransformExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    var progress: Float {
        session.progress
    }

    func cancel() {
        session.cancelExport()
    }

    func export(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        session.exportAsynchronously {
            switch self.session.status {
            case .completed:
                completion(.success(()))
            case .cancelled:
                completion(.failure(CancellationError()))
            case .failed:
                completion(.failure(
                    self.session.error ?? ImageProcessing.ProcessingError(
                        message: "Couldn’t export the transformed video."
                    )
                ))
            default:
                completion(.failure(ImageProcessing.ProcessingError(
                    message: "Couldn’t export the transformed video."
                )))
            }
        }
    }
}

private final class VideoMergeExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    var progress: Float {
        session.progress
    }

    func cancel() {
        session.cancelExport()
    }

    func export(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        session.exportAsynchronously {
            switch self.session.status {
            case .completed:
                completion(.success(()))
            case .cancelled:
                completion(.failure(CancellationError()))
            case .failed:
                completion(.failure(
                    self.session.error ?? ImageProcessing.ProcessingError(
                        message: "Couldn’t export the merged video."
                    )
                ))
            default:
                completion(.failure(ImageProcessing.ProcessingError(
                    message: "Couldn’t export the merged video."
                )))
            }
        }
    }
}
