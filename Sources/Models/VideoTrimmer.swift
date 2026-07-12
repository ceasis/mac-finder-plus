import AVFoundation
import CoreGraphics
import Foundation
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

struct VideoMergeLayout {
    let transform: CGAffineTransform
    let contentSize: CGSize
}

enum VideoMerger {
    private struct PreparedClip {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
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
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else {
                throw ImageProcessing.ProcessingError(
                    message: "“\(url.lastPathComponent)” has no usable video duration."
                )
            }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw ImageProcessing.ProcessingError(
                    message: "“\(url.lastPathComponent)” has no video track to merge."
                )
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            clips.append(PreparedClip(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: audioTracks.first,
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
        let hasAudio = clips.contains { $0.audioTrack != nil }
        let compositionAudioTrack = hasAudio ? composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) : nil
        guard !hasAudio || compositionAudioTrack != nil else {
            throw ImageProcessing.ProcessingError(message: "Couldn’t prepare the merged audio track.")
        }

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var cursor = CMTime.zero
        for clip in clips {
            try Task.checkCancellation()
            let timeRange = CMTimeRange(start: .zero, duration: clip.duration)
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ImageProcessing.ProcessingError(message: "Couldn’t prepare a merged video track.")
            }
            try compositionVideoTrack.insertTimeRange(timeRange, of: clip.videoTrack, at: cursor)

            if let audioTrack = clip.audioTrack,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: cursor)
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
    static func exportLossless(
        url: URL,
        inTime: Double,
        outTime: Double,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard outTime > inTime else {
            throw ImageProcessing.ProcessingError(message: "Trim out point must be after the in point.")
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” can’t be exported without re-encoding."
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
