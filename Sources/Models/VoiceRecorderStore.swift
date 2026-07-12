import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class VoiceRecorderStore {
    static let shared = VoiceRecorderStore()

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var destinationURL: URL?
    private(set) var lastSavedURL: URL?
    private(set) var lastError: String?
    private(set) var inputLevel = 0.0

    @ObservationIgnored private var audioRecorder: AVAudioRecorder?
    @ObservationIgnored private var meterTimer: Timer?

    private init() {}

    func startRecording(in folder: URL) {
        Task {
            do {
                guard try await requestMicrophoneAccess() else {
                    throw VoiceRecorderError.microphoneDenied
                }
                if isRecording {
                    _ = stopRecording()
                }

                let destination = FileOperations.uniqueDestination(
                    for: folder.appendingPathComponent("Voice Recording \(Self.recordingDateString()).m4a")
                )
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let recorder = try AVAudioRecorder(url: destination, settings: settings)
                recorder.isMeteringEnabled = true
                recorder.prepareToRecord()
                guard recorder.record() else {
                    throw VoiceRecorderError.recordingFailed
                }

                audioRecorder = recorder
                isRecording = true
                startedAt = Date()
                destinationURL = destination
                lastSavedURL = nil
                lastError = nil
                startMetering()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func stopRecording() -> URL? {
        guard let recorder = audioRecorder,
              let destinationURL else {
            return nil
        }

        recorder.stop()
        clearRecordingState()
        lastSavedURL = destinationURL
        return destinationURL
    }

    func cancelRecording() {
        let url = destinationURL
        audioRecorder?.stop()
        clearRecordingState()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func clearError() {
        lastError = nil
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMeter()
            }
        }
    }

    private func updateMeter() {
        guard let audioRecorder, isRecording else {
            inputLevel = 0
            return
        }
        audioRecorder.updateMeters()
        let power = audioRecorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (Double(power) + 60) / 60))
        inputLevel = pow(normalized, 1.6)
    }

    private func clearRecordingState() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioRecorder = nil
        isRecording = false
        startedAt = nil
        destinationURL = nil
        inputLevel = 0
    }

    private func requestMicrophoneAccess() async throws -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func recordingDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}

private enum VoiceRecorderError: LocalizedError {
    case microphoneDenied
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required to record audio."
        case .recordingFailed:
            "Voice recording could not be started."
        }
    }
}
