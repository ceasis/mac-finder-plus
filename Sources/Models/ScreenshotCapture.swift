import AppKit
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureKind: String, CaseIterable, Identifiable, Sendable {
    case screenshot
    case recording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .recording: "Recording"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshot: "camera.viewfinder"
        case .recording: "record.circle"
        }
    }
}

enum ScreenshotCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case interactive
    case selection
    case window
    case applicationWindow
    case appWindow
    case fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interactive: "Area / Window"
        case .selection: "Area"
        case .window: "Window"
        case .applicationWindow: "App Window"
        case .appWindow: "Workbench Window"
        case .fullScreen: "Screen"
        }
    }

    var systemImage: String {
        switch self {
        case .interactive: "viewfinder"
        case .selection: "crop"
        case .window: "macwindow"
        case .applicationWindow: "app.connected.to.app.below.fill"
        case .appWindow: "rectangle.inset.filled"
        case .fullScreen: "display"
        }
    }

    func supportsCursor(for kind: CaptureKind) -> Bool {
        switch kind {
        case .screenshot:
            return self == .fullScreen
        case .recording:
            return self == .fullScreen || self == .appWindow || self == .applicationWindow
        }
    }

    func supportsShadow(for kind: CaptureKind) -> Bool {
        guard kind == .screenshot else { return false }
        switch self {
        case .interactive, .window, .applicationWindow, .appWindow:
            return true
        case .selection, .fullScreen:
            return false
        }
    }

    var needsAppWindowSelection: Bool {
        return self == .applicationWindow
    }
}

enum ScreenshotFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpg
    case tiff
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpg: "JPEG"
        case .tiff: "TIFF"
        case .pdf: "PDF"
        }
    }

    var fileExtension: String { rawValue }
}

struct ScreenshotOptions: Equatable, Sendable {
    var kind: CaptureKind
    var mode: ScreenshotCaptureMode
    var format: ScreenshotFormat
    var delay: Int
    var recordingDuration: Int
    var includeCursor: Bool
    var includeWindowShadow: Bool
    var includeMicrophone: Bool
    var showClicks: Bool
    var saveToActiveFolder: Bool
    var copyToClipboard: Bool
    var openInPreview: Bool
    var playSound: Bool
    var selectedWindowNumber: Int?
    var selectedWindowTitle: String?
}

struct ScreenshotCaptureResult: Sendable {
    let savedURL: URL?
}

struct ScreenCaptureWindowTarget: Identifiable, Hashable, Sendable {
    let id: Int
    let ownerName: String
    let windowName: String
    let width: Int
    let height: Int

    var title: String {
        let trimmed = windowName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ownerName : "\(ownerName) — \(trimmed)"
    }

    var subtitle: String {
        "\(width) × \(height)"
    }
}

@MainActor
enum ScreenshotCapture {
    static func capture(
        options: ScreenshotOptions,
        destinationFolder: URL,
        appWindowNumber: Int?,
        onRecording: @escaping @MainActor () -> Void = {}
    ) async throws -> ScreenshotCaptureResult {
        let target = try await ScreenCaptureTarget.resolve(options.mode, selectedWindow: options.selectedWindowNumber,
                                                           workbenchWindow: appWindowNumber)
        // Start the countdown after an interactive selection, when the user can use it to prepare.
        try await Task.sleep(for: .milliseconds(options.delay > 0 ? options.delay * 1_000 : 180))
        let configuration = target.configuration(for: options)
        let destination = options.kind == .recording || options.saveToActiveFolder
            ? uniqueDestination(in: destinationFolder, options: options) : nil

        switch options.kind {
        case .recording:
            guard let destination else { throw ScreenshotCaptureError.noOutput }
            try await NativeScreenRecorder.record(filter: target.filter, configuration: configuration,
                                                  destination: destination, duration: options.recordingDuration,
                                                  includeMicrophone: options.includeMicrophone, onRecording: onRecording)
        case .screenshot:
            guard destination != nil || options.copyToClipboard else { throw ScreenshotCaptureError.noOutput }
            let image = try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: configuration)
            try Task.checkCancellation()
            if let destination {
                // Encode before touching the destination and never replace an existing file.
                let data = try ScreenshotImageEncoder.encode(image, as: options.format)
                try data.write(to: destination, options: .withoutOverwriting)
            }
            if options.copyToClipboard {
                let pasteboard = NSPasteboard.general
                let image = NSImage(cgImage: image, size: .zero)
                pasteboard.clearContents()
                if let destination {
                    pasteboard.writeObjects([image, destination as NSURL])
                } else {
                    pasteboard.writeObjects([image])
                }
            }
        }
        if options.playSound { NSSound(named: "Tink")?.play() }
        if options.openInPreview, let destination { openCapture(destination, kind: options.kind) }
        return ScreenshotCaptureResult(savedURL: destination)
    }

    @MainActor
    static func keyWindowNumber() -> Int? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.windows
        return candidates
            .compactMap { $0 }
            .first { window in
                window.isVisible && !window.isMiniaturized && window.windowNumber > 0
            }?
            .windowNumber
    }

    static func availableWindowTargets() -> [ScreenCaptureWindowTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return infoList.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { return nil }

            let width = Int(bounds["Width"] as? Double ?? 0)
            let height = Int(bounds["Height"] as? Double ?? 0)
            guard width >= 80, height >= 60 else { return nil }

            let windowName = info[kCGWindowName as String] as? String ?? ""
            return ScreenCaptureWindowTarget(
                id: windowNumber,
                ownerName: ownerName,
                windowName: windowName,
                width: width,
                height: height
            )
        }
        .sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func uniqueDestination(in folder: URL, options: ScreenshotOptions) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let prefix = options.kind == .recording ? "Screen Recording" : "Screenshot"
        let fileExtension = options.kind == .recording ? "mov" : options.format.fileExtension
        let name = "\(prefix) \(formatter.string(from: Date())).\(fileExtension)"
        return FileOperations.uniqueDestination(for: folder.appendingPathComponent(name))
    }

    private static func openCapture(_ url: URL, kind: CaptureKind) {
        let workspace = NSWorkspace.shared
        let bundleID = kind == .recording ? "com.apple.QuickTimePlayerX" : "com.apple.Preview"
        if let application = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            workspace.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(url)
        }
    }
}

enum ScreenshotImageEncoder {
    static func encode(_ image: CGImage, as format: ScreenshotFormat) throws -> Data {
        let output = NSMutableData()
        if format == .pdf {
            var bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let consumer = CGDataConsumer(data: output as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
                throw ScreenshotCaptureError.encodingFailed
            }
            context.beginPDFPage(nil)
            context.draw(image, in: bounds)
            context.endPDFPage()
            context.closePDF()
        } else {
            let type: UTType = format == .png ? .png : (format == .jpg ? .jpeg : .tiff)
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
                throw ScreenshotCaptureError.encodingFailed
            }
            let properties = format == .jpg ? [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary : nil
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else { throw ScreenshotCaptureError.encodingFailed }
        }
        return output as Data
    }
}

enum ScreenshotCaptureError: LocalizedError {
    case noWindow, noDisplay, invalidArea, noOutput, encodingFailed

    var errorDescription: String? {
        switch self {
        case .noWindow: "The selected window is no longer available to capture."
        case .noDisplay: "No screen was available to capture."
        case .invalidArea: "Select an area within one screen."
        case .noOutput: "Choose where to save or copy the capture."
        case .encodingFailed: "Workbench couldn’t encode the screenshot in the selected format."
        }
    }
}
