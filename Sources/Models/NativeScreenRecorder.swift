@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
enum NativeScreenRecorder {
    private static var active: AsyncStream<RecordingEvent>.Continuation?

    static func stop() {
        active?.yield(.stop(CMClockGetTime(CMClockGetHostTimeClock()), streamAlreadyStopped: false))
    }

    static func record(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        destination: URL,
        duration: Int,
        includeMicrophone: Bool,
        onRecording: @escaping @MainActor () -> Void
    ) async throws {
        guard active == nil else { throw RecordingError.alreadyRecording }
        try Task.checkCancellation()
        let (events, signal) = AsyncStream<RecordingEvent>.makeStream()
        active = signal
        defer {
            signal.finish()
            active = nil
        }

        if includeMicrophone {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
            default: authorized = false
            }
            try Task.checkCancellation()
            guard authorized else { throw RecordingError.microphonePermission }
        }

        // Same volume for atomic, non-overwriting publication. Keep unfinished files hidden.
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".workbench-recording-\(UUID().uuidString)", isDirectory: true)
        let movie = staging.appendingPathComponent("Recording.mov")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }

        try configureVideo(configuration)
        configuration.capturesAudio = false
        if #available(macOS 15, *) {
            configuration.captureMicrophone = includeMicrophone
        }

        let sink = try RecordingSink(url: movie, configuration: configuration,
                                     includeMicrophone: includeMicrophone, signal: signal)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        let legacyMicrophone: LegacyRecordingMicrophone?
        if #available(macOS 15, *) {
            if includeMicrophone {
                try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
            }
            legacyMicrophone = nil
        } else {
            legacyMicrophone = try includeMicrophone ? LegacyRecordingMicrophone(sink: sink, signal: signal) : nil
        }

        var streamStarted = false
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await stream.startCapture()
                streamStarted = true
                try Task.checkCancellation()
                if let legacyMicrophone { try await legacyMicrophone.start() }

                let startTimeout = Task {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    signal.yield(.failed(RecordingError.noVideo))
                }
                var durationTimer: Task<Void, Never>?
                defer {
                    startTimeout.cancel()
                    durationTimer?.cancel()
                }

                var startedRecording = false
                var stopTime: CMTime?
                var streamAlreadyStopped = false
                for await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .started:
                        guard !startedRecording else { continue }
                        startedRecording = true
                        startTimeout.cancel()
                        if duration > 0 {
                            durationTimer = Task {
                                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                                signal.yield(.stop(CMClockGetTime(CMClockGetHostTimeClock()), streamAlreadyStopped: false))
                            }
                        }
                        onRecording()
                    case let .stop(time, alreadyStopped):
                        guard startedRecording else { throw CancellationError() }
                        stopTime = time
                        streamAlreadyStopped = alreadyStopped
                    case let .failed(error):
                        throw error
                    }
                    if stopTime != nil { break }
                }
                try Task.checkCancellation()
                guard let stopTime else { throw CancellationError() }

                // Finalize remaining output only after the stream is stopped; queued
                // callbacks are serialized with writer finalization on sink.queue.
                if !streamAlreadyStopped {
                    do {
                        try await stream.stopCapture()
                    } catch let error as SCStreamError where error.code == .userStopped || error.code == .attemptToStopStreamState {
                        // The system menu's stop can race a manual or timed Stop.
                    }
                }
                streamStarted = false
                if let legacyMicrophone { await legacyMicrophone.stop() }
                try await sink.finish(at: stopTime)
                try Task.checkCancellation()
            } onCancel: {
                signal.finish()
            }
        } catch {
            if streamStarted { try? await stream.stopCapture() }
            if let legacyMicrophone { await legacyMicrophone.stop() }
            await sink.cancel()
            throw error
        }

        try Task.checkCancellation()
        // FileManager.moveItem has a destination-exists check but does not guarantee
        // a concurrent creator will not race that check. Exclusive rename does.
        guard renamex_np(movie.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw RecordingError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func configureVideo(_ configuration: SCStreamConfiguration) throws {
        guard configuration.width >= 2, configuration.height >= 2 else {
            throw RecordingError.unsupportedVideo
        }
        // H.264 encoder limits vary; keep the configured capture aspect ratio.
        let scale = min(1, 4_096 / Double(max(configuration.width, configuration.height)))
        configuration.width = max(2, Int(Double(configuration.width) * scale) / 2 * 2)
        configuration.height = max(2, Int(Double(configuration.height) * scale) / 2 * 2)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    }
}

private enum RecordingEvent: Sendable {
    case started
    case stop(CMTime, streamAlreadyStopped: Bool)
    case failed(any Error)
}

private enum RecordingError: LocalizedError {
    case alreadyRecording, microphonePermission, noMicrophone, noVideo, noAudio
    case unsupportedVideo, unsupportedAudio, writeFailed, destinationExists

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Stop the current screen recording before starting another."
        case .microphonePermission: "Allow microphone access for Workbench in System Settings, or turn off the microphone for this recording."
        case .noMicrophone: "No microphone was available for this screen recording."
        case .noVideo: "No video frames were received. Make sure the screen or window is still available."
        case .noAudio: "No microphone audio was received. Check the input device, or record without the microphone."
        case .unsupportedVideo: "The screen recording’s video configuration is not supported."
        case .unsupportedAudio: "The screen recording’s microphone configuration is not supported."
        case .writeFailed: "Workbench couldn’t finish writing the screen recording."
        case .destinationExists: "A file with this recording name already exists. The existing file was not changed."
        }
    }
}

/// Framework callbacks and every mutation of AVAssetWriter are serialized on queue.
private final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.qnsub.workbench.screen-recording.samples", qos: .userInitiated)

    private let signal: AsyncStream<RecordingEvent>.Continuation
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private var firstVideoTime = CMTime.invalid
    private var lastVideo: CMSampleBuffer?
    private var lastAudioTime = CMTime.invalid
    private var failure: (any Error)?
    private var acceptingSamples = true

    init(url: URL, configuration: SCStreamConfiguration, includeMicrophone: Bool,
         signal: AsyncStream<RecordingEvent>.Continuation) throws {
        self.signal = signal
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(40_000_000, max(600_000, configuration.width * configuration.height * 3)),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecordingError.unsupportedVideo
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecordingError.unsupportedVideo }
        writer.add(video)

        if includeMicrophone {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw RecordingError.unsupportedAudio
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError.unsupportedAudio }
            writer.add(input)
            audio = input
        } else {
            audio = nil
        }
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        if let streamError = error as? SCStreamError, streamError.code == .userStopped {
            signal.yield(.stop(CMClockGetTime(CMClockGetHostTimeClock()), streamAlreadyStopped: true))
            return
        }
        signal.yield(.failed(error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard acceptingSamples, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus),
                  status == .complete || status == .started,
                  sampleBuffer.imageBuffer != nil else { return }
            appendVideo(sampleBuffer, clock: stream.synchronizationClock)
        } else if #available(macOS 15, *), type == .microphone {
            appendAudio(sampleBuffer, clock: stream.synchronizationClock)
        }
    }

    func appendAudio(_ buffer: CMSampleBuffer, clock: CMClock?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard acceptingSamples, let audio, firstVideoTime.isNumeric,
              audio.isReadyForMoreMediaData,
              let sample = Self.onHostClock(buffer, clock: clock),
              sample.presentationTimeStamp >= firstVideoTime,
              !lastAudioTime.isNumeric || sample.presentationTimeStamp > lastAudioTime else { return }
        guard audio.append(sample) else { fail(writer.error ?? RecordingError.writeFailed); return }
        lastAudioTime = sample.presentationTimeStamp
    }

    private func appendVideo(_ buffer: CMSampleBuffer, clock: CMClock?) {
        guard let sample = Self.onHostClock(buffer, clock: clock) else { return }
        let time = sample.presentationTimeStamp
        let isFirst = !firstVideoTime.isNumeric
        if isFirst {
            guard writer.startWriting() else { fail(writer.error ?? RecordingError.writeFailed); return }
            writer.startSession(atSourceTime: time)
            firstVideoTime = time
        }
        guard video.isReadyForMoreMediaData,
              lastVideo.map({ $0.presentationTimeStamp < time }) ?? true else { return }
        guard video.append(sample) else { fail(writer.error ?? RecordingError.writeFailed); return }
        if lastVideo == nil { signal.yield(.started) }
        lastVideo = sample
    }

    func finish(at stopTime: CMTime) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            queue.async {
                self.acceptingSamples = false
                if let failure = self.failure { result.resume(throwing: failure); return }
                guard let finalFrame = self.lastVideo else { result.resume(throwing: RecordingError.noVideo); return }
                guard self.audio == nil || self.lastAudioTime.isNumeric else {
                    result.resume(throwing: RecordingError.noAudio)
                    return
                }
                guard self.writer.status == .writing else {
                    result.resume(throwing: self.writer.error ?? RecordingError.writeFailed)
                    return
                }

                let frameDuration = CMTime(value: 1, timescale: 30)
                let endTime = max(stopTime, finalFrame.presentationTimeStamp + frameDuration)
                let holdTime = endTime - frameDuration
                // ScreenCaptureKit emits only changed frames. Hold the final frame
                // through the endpoint even when the desktop was completely still.
                if holdTime > finalFrame.presentationTimeStamp, self.video.isReadyForMoreMediaData,
                   let hold = Self.shift(finalFrame, by: holdTime - finalFrame.presentationTimeStamp) {
                    guard self.video.append(hold) else {
                        result.resume(throwing: self.writer.error ?? RecordingError.writeFailed)
                        return
                    }
                }
                self.writer.endSession(atSourceTime: endTime)
                self.video.markAsFinished()
                self.audio?.markAsFinished()
                self.writer.finishWriting {
                    self.queue.async {
                        if self.writer.status == .completed {
                            result.resume()
                        } else {
                            result.resume(throwing: self.writer.error ?? RecordingError.writeFailed)
                        }
                    }
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { (result: CheckedContinuation<Void, Never>) in
            queue.async {
                self.acceptingSamples = false
                if self.writer.status == .writing { self.writer.cancelWriting() }
                result.resume()
            }
        }
    }

    private func fail(_ error: any Error) {
        acceptingSamples = false
        failure = error
        signal.yield(.failed(error))
    }

    private static func onHostClock(_ sample: CMSampleBuffer, clock: CMClock?) -> CMSampleBuffer? {
        let timestamp = sample.presentationTimeStamp
        guard timestamp.isNumeric else { return nil }
        guard let clock else { return sample }
        let hostTime = CMSyncConvertTime(timestamp, from: clock, to: CMClockGetHostTimeClock())
        guard hostTime.isNumeric else { return nil }
        return hostTime == timestamp ? sample : shift(sample, by: hostTime - timestamp)
    }

    private static func shift(_ sample: CMSampleBuffer, by delta: CMTime) -> CMSampleBuffer? {
        guard var timing = try? sample.sampleTimingInfos() else { return nil }
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isNumeric { timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + delta }
            if timing[index].decodeTimeStamp.isNumeric { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + delta }
        }
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                    sampleTimingEntryCount: timing.count,
                                                    sampleTimingArray: timing, sampleBufferOut: &output) == noErr else { return nil }
        return output
    }
}

/// On macOS 14 ScreenCaptureKit has no microphone output. Capture the mic via
/// AVFoundation and use its synchronization clock to align it with screen frames.
private final class LegacyRecordingMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.qnsub.workbench.screen-recording.microphone", qos: .userInitiated)
    private let sink: RecordingSink
    private var errorObserver: NSObjectProtocol?

    init(sink: RecordingSink, signal: AsyncStream<RecordingEvent>.Continuation) throws {
        self.sink = sink
        super.init()
        guard let device = AVCaptureDevice.default(for: .audio) else { throw RecordingError.noMicrophone }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { throw RecordingError.unsupportedAudio }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: sink.queue)
        errorObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError,
                                                                object: session, queue: nil) { notification in
            signal.yield(.failed(notification.userInfo?[AVCaptureSessionErrorKey] as? any Error ?? RecordingError.noMicrophone))
        }
    }

    deinit { if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) } }

    func start() async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            queue.async {
                self.session.startRunning()
                if self.session.isRunning { result.resume() }
                else { result.resume(throwing: RecordingError.noMicrophone) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (result: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                result.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sink.appendAudio(sampleBuffer, clock: session.synchronizationClock)
    }
}
