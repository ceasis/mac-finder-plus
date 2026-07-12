import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Reads and requests the OS privacy permissions Workbench needs, plus opens the
/// relevant System Settings panes when the user has to grant them by hand.
/// Screen recording and microphone are TCC-gated; once denied, macOS will not
/// re-prompt, so the fallback is always "open System Settings".
@Observable
@MainActor
final class PermissionsManager {
    enum Status {
        case granted
        case denied
        case notDetermined
    }

    private let screenRecordingPromptedKey = "permissions.screenRecordingPrompted"

    private(set) var screenRecording: Status = .notDetermined
    private(set) var microphone: Status = .notDetermined
    private(set) var camera: Status = .notDetermined

    var hasGrantedFolderAccess: Bool {
        !BookmarkStore.shared.grantedURLs.isEmpty
    }

    func refresh() {
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .granted
        } else if UserDefaults.standard.bool(forKey: screenRecordingPromptedKey) {
            screenRecording = .denied
        } else {
            screenRecording = .notDetermined
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied, .restricted: microphone = .denied
        default: microphone = .notDetermined
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = .granted
        case .denied, .restricted: camera = .denied
        default: camera = .notDetermined
        }
    }

    /// Triggers the one-time system prompt. If the user has already decided,
    /// this returns immediately with the standing answer.
    func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: screenRecordingPromptedKey)
        let granted = CGRequestScreenCaptureAccess()
        screenRecording = granted ? .granted : .denied
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
    }

    func requestCamera() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        camera = granted ? .granted : .denied
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
