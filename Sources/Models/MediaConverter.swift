import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MediaConversionOptions: Equatable {
    var imageFormat: MediaImageOutputFormat = .jpeg
    var videoCodec: MediaVideoOutputCodec = .h264
}

enum MediaImageOutputFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"

    var id: String { rawValue }
    var type: UTType { .jpeg }
    var filenameExtension: String { "jpg" }
}

enum MediaVideoOutputCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"

    var id: String { rawValue }
    var filenameExtension: String { "mp4" }

    var preferredPreset: String {
        switch self {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        }
    }
}

enum MediaConverter {
    static func canConvert(_ item: FileItem) -> Bool {
        item.isImage || item.isVideoMedia
    }

    @discardableResult
    static func convert(
        _ item: FileItem,
        options: MediaConversionOptions,
        progress: @escaping (Double) async -> Void = { _ in }
    ) async throws -> URL {
        if item.isImage {
            let output = try convertImage(item.url, format: options.imageFormat)
            await progress(1)
            return output
        }
        if item.isPlayableMedia {
            return try await convertVideo(item.url, codec: options.videoCodec, progress: progress)
        }
        throw ImageProcessing.ProcessingError(
            message: "“\(item.name)” is not an image or video file Panes can convert."
        )
    }

    private static func convertImage(
        _ url: URL,
        format: MediaImageOutputFormat
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” is not a readable image."
            )
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-converted.\(format.filenameExtension)")
        let destination = FileOperations.uniqueDestination(for: candidate)
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            format.type.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessing.ProcessingError(
                message: "Couldn’t create “\(destination.lastPathComponent)”."
            )
        }

        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw ImageProcessing.ProcessingError(
                message: "Couldn’t save “\(destination.lastPathComponent)”."
            )
        }
        return destination
    }

    private static func convertVideo(
        _ url: URL,
        codec: MediaVideoOutputCodec,
        progress: @escaping (Double) async -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = exportSession(for: asset, codec: codec) else {
            throw ImageProcessing.ProcessingError(
                message: "“\(url.lastPathComponent)” can’t be exported with \(codec.rawValue)."
            )
        }
        let exportBox = ExportSessionBox(export)

        let baseName = url.deletingPathExtension().lastPathComponent
        let candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(codec.rawValue)-converted.\(codec.filenameExtension)")
        let destination = FileOperations.uniqueDestination(for: candidate)
        export.outputURL = destination
        export.outputFileType = supportedOutputType(for: export) ?? .mp4
        export.shouldOptimizeForNetworkUse = true

        let progressTask = Task {
            while !Task.isCancelled {
                await progress(Double(exportBox.progress))
                try? await Task.sleep(for: .milliseconds(250))
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
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func exportSession(
        for asset: AVAsset,
        codec: MediaVideoOutputCodec
    ) -> AVAssetExportSession? {
        let presets = [
            codec.preferredPreset,
            AVAssetExportPresetHighestQuality,
            AVAssetExportPresetMediumQuality,
            AVAssetExportPresetPassthrough,
        ]
        for preset in presets {
            if let session = AVAssetExportSession(asset: asset, presetName: preset) {
                return session
            }
        }
        return nil
    }

    private static func supportedOutputType(for export: AVAssetExportSession) -> AVFileType? {
        if export.supportedFileTypes.contains(.mp4) {
            return .mp4
        }
        return export.supportedFileTypes.first
    }
}

private final class ExportSessionBox: @unchecked Sendable {
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
                        message: "Couldn’t export this file."
                    )
                ))
            default:
                completion(.failure(ImageProcessing.ProcessingError(
                    message: "Couldn’t export this file."
                )))
            }
        }
    }
}
