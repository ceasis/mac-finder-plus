import AVFoundation
import Foundation

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
