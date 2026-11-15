import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
struct ScreenCaptureTarget {
    let filter: SCContentFilter
    var sourceRect: CGRect?

    static func resolve(_ mode: ScreenshotCaptureMode, selectedWindow: Int?, workbenchWindow: Int?) async throws -> Self {
        try Task.checkCancellation()
        switch mode {
        case .window:
            return Self(filter: try await ScreenCaptureWindowPicker().pick())
        case .selection, .interactive:
            do {
                let rect = try await ScreenCaptureAreaSelector.select(allowWindowSwitch: mode == .interactive)
                return try await display(area: rect)
            } catch is ScreenCaptureAreaSelector.SwitchToWindow {
                return Self(filter: try await ScreenCaptureWindowPicker().pick())
            }
        case .fullScreen:
            return try await display(area: nil)
        case .applicationWindow, .appWindow:
            let number = mode == .appWindow ? workbenchWindow : selectedWindow
            guard let number else { throw ScreenshotCaptureError.noWindow }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { Int($0.windowID) == number }) else {
                throw ScreenshotCaptureError.noWindow
            }
            return Self(filter: SCContentFilter(desktopIndependentWindow: window))
        }
    }

    private static func display(area: CGRect?) async throws -> Self {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display: SCDisplay
        let sourceRect: CGRect?
        if let area {
            // sourceRect is in the selected display's logical points, not global points or pixels.
            guard let candidate = content.displays.max(by: {
                overlap($0.frame, area) < overlap($1.frame, area)
            }), overlap(candidate.frame, area) > 0 else { throw ScreenshotCaptureError.invalidArea }
            display = candidate
            let clipped = area.intersection(display.frame)
            sourceRect = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        } else {
            guard let main = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw ScreenshotCaptureError.noDisplay
            }
            display = main
            sourceRect = nil
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        return Self(filter: filter, sourceRect: sourceRect)
    }

    private static func overlap(_ display: CGRect, _ area: CGRect) -> CGFloat {
        let overlap = display.intersection(area)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    func configuration(for options: ScreenshotOptions) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let size = (sourceRect ?? filter.contentRect).size
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let maxDimension: CGFloat = options.kind == .recording ? 4_096 : .greatestFiniteMagnitude
        let ratio = min(scale, maxDimension / max(size.width, size.height, 1))
        let width = max(2, Int((size.width * ratio).rounded()))
        let height = max(2, Int((size.height * ratio).rounded()))
        config.width = options.kind == .recording ? width - width % 2 : width
        config.height = options.kind == .recording ? height - height % 2 : height
        if let sourceRect { config.sourceRect = sourceRect }
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = options.includeCursor
        config.ignoreShadowsSingleWindow = !options.includeWindowShadow
        if #available(macOS 15, *) {
            config.showMouseClicks = options.kind == .recording && options.showClicks
        }
        return config
    }
}

// Only the interactive Window mode uses the system picker; known window IDs come
// from the app selector and shareable-content enumeration.
@MainActor
private final class ScreenCaptureWindowPicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter, any Error>?

    func pick() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        let previousConfiguration = picker.defaultConfiguration
        let wasActive = picker.isActive
        defer {
            picker.remove(self)
            picker.defaultConfiguration = previousConfiguration
            picker.isActive = wasActive
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = [.singleWindow]
                configuration.allowsChangingSelectedContent = false
                picker.defaultConfiguration = configuration
                picker.add(self)
                picker.isActive = true
                picker.present(using: .window)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor in finish(.success(filter)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor in finish(.failure(CancellationError())) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in finish(.failure(error)) }
    }

    private func finish(_ result: Result<SCContentFilter, any Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
