import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
@preconcurrency import UserNotifications

enum WorkbenchPermission: String, CaseIterable, Identifiable {
    case folderAccess
    case screenRecording
    case microphone
    case camera
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folderAccess: "Files & Folders"
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .notifications: "Notifications"
        }
    }

    var detail: String {
        switch self {
        case .folderAccess:
            "Lets Workbench browse, remember, and organize folders you choose."
        case .screenRecording:
            "Used by Screenshot and Screen Recording to capture content from your display."
        case .microphone:
            "Used for Voice Recorder, narrated screen recordings, and audio notes."
        case .camera:
            "Used only when you record a video journal in Notes."
        case .notifications:
            "Used to alert you when a Calendar reminder is due."
        }
    }

    var systemImage: String {
        switch self {
        case .folderAccess: "folder.badge.plus"
        case .screenRecording: "record.circle"
        case .microphone: "mic"
        case .camera: "video"
        case .notifications: "bell.badge"
        }
    }
}

/// Reads and requests the OS privacy permissions Workbench needs, plus opens the
/// relevant System Settings panes when the user has to grant them by hand.
/// Once a TCC permission is denied, macOS will not re-prompt, so the fallback
/// is always "open System Settings".
@Observable
@MainActor
final class PermissionsManager {
    enum Status: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
    }

    private let screenRecordingPromptedKey = "permissions.screenRecordingPrompted"

    private(set) var screenRecording: Status = .notDetermined
    private(set) var microphone: Status = .notDetermined
    private(set) var camera: Status = .notDetermined
    private(set) var notifications: Status = .notDetermined
    private(set) var folderAccess: Status = .notDetermined

    var hasGrantedFolderAccess: Bool {
        folderAccess == .granted
    }

    func refresh() {
        folderAccess = BookmarkStore.shared.grantedURLs.isEmpty ? .notDetermined : .granted

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

    func refreshAll() async {
        refresh()
        await refreshNotificationStatus()
    }

    func status(for permission: WorkbenchPermission) -> Status {
        switch permission {
        case .folderAccess: folderAccess
        case .screenRecording: screenRecording
        case .microphone: microphone
        case .camera: camera
        case .notifications: notifications
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

    func requestNotifications() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        } catch {
            // The authoritative state still comes from notificationSettings().
        }
        await refreshNotificationStatus()
    }

    @discardableResult
    func requestFolderAccess(startingAt url: URL?) -> URL? {
        let grantedURL = BookmarkStore.shared.requestAccess(startingAt: url)
        refresh()
        return grantedURL
    }

    func request(_ permission: WorkbenchPermission, folderStartingAt url: URL? = nil) async {
        switch permission {
        case .folderAccess:
            requestFolderAccess(startingAt: url)
        case .screenRecording:
            requestScreenRecording()
        case .microphone:
            await requestMicrophone()
        case .camera:
            await requestCamera()
        case .notifications:
            await requestNotifications()
        }
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

    func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    func openSettings(for permission: WorkbenchPermission) {
        switch permission {
        case .folderAccess:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        case .screenRecording:
            openScreenRecordingSettings()
        case .microphone:
            openMicrophoneSettings()
        case .camera:
            openCameraSettings()
        case .notifications:
            openNotificationSettings()
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notifications = .granted
        case .denied:
            notifications = .denied
        case .notDetermined:
            notifications = .notDetermined
        @unknown default:
            notifications = .notDetermined
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
