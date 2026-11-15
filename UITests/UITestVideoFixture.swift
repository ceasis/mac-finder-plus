import AVFoundation
import CoreVideo
import Foundation

/// Generates a tiny four-second movie with a real audio track. No Downloads,
/// bundled user media, network assets, ffmpeg, or microphone access is required.
enum UITestVideoFixture {
    private struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func make(at destination: URL, workingFolder: URL) throws {
        let silentURL = workingFolder.appendingPathComponent("fixture-silent.mov")
        let audioURL = workingFolder.appendingPathComponent("fixture-audio.caf")
        try makeSilentVideo(at: silentURL)
        try makeAudio(at: audioURL)

        let video = AVURLAsset(url: silentURL)
        let audio = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
        guard let sourceVideo = video.tracks(withMediaType: .video).first,
              let sourceAudio = audio.tracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FixtureError(message: "Could not create test movie tracks")
        }
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw FixtureError(message: "Could not create test movie exporter")
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mov
        let complete = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { complete.signal() }
        guard complete.wait(timeout: .now() + 20) == .success,
              exporter.status == .completed else {
            exporter.cancelExport()
            throw FixtureError(message: exporter.error?.localizedDescription ?? "Test movie export timed out")
        }
    }

    private static func makeSilentVideo(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 120,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError(message: writer.error?.localizedDescription ?? "Test movie writer could not start")
        }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(15)
        for frame in 0..<120 {
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else {
                    writer.cancelWriting()
                    throw FixtureError(message: "Test movie writer stalled")
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw FixtureError(message: "Could not allocate test video frame")
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let bytes = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(bytes, Int32(40 + frame), CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw FixtureError(message: writer.error?.localizedDescription ?? "Could not append test video frame")
            }
        }
        input.markAsFinished()
        let complete = DispatchSemaphore(value: 0)
        writer.finishWriting { complete.signal() }
        guard complete.wait(timeout: .now() + 15) == .success,
              writer.status == .completed else {
            writer.cancelWriting()
            throw FixtureError(message: writer.error?.localizedDescription ?? "Test movie writer timed out")
        }
    }

    private static func makeAudio(at url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000),
              let samples = buffer.floatChannelData?[0] else {
            throw FixtureError(message: "Could not allocate test audio")
        }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 16_000) * 0.03)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
