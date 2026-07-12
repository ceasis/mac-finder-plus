import AppKit
import Foundation

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

enum ScreenshotCapture {
    static func capture(
        options: ScreenshotOptions,
        destinationFolder: URL,
        appWindowNumber: Int?
    ) async throws -> ScreenshotCaptureResult {
        let destination = options.saveToActiveFolder
            ? uniqueDestination(in: destinationFolder, options: options)
            : nil
        try await runScreencapture(
            options: options,
            destination: destination,
            appWindowNumber: appWindowNumber
        )

        if options.copyToClipboard, let destination {
            await copyToClipboard(destination)
        }

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

    private static func runScreencapture(
        options: ScreenshotOptions,
        destination: URL?,
        appWindowNumber: Int?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            var arguments: [String] = ["-d"]
            switch options.kind {
            case .screenshot:
                arguments += ["-t", options.format.rawValue]
            case .recording:
                arguments.append("-v")
                if options.recordingDuration > 0 {
                    arguments += ["-V", "\(options.recordingDuration)"]
                }
                if options.includeMicrophone {
                    arguments.append("-g")
                }
                if options.showClicks {
                    arguments.append("-k")
                }
            }

            if !options.playSound {
                arguments.append("-x")
            }
            if options.delay > 0 {
                arguments += ["-T", "\(options.delay)"]
            }

            switch options.mode {
            case .interactive:
                arguments += ["-i", "-J", options.kind == .recording ? "video" : "selection"]
                if options.kind == .recording {
                    arguments.append("-U")
                }
                if !options.includeWindowShadow {
                    arguments.append("-o")
                }
            case .selection:
                arguments += ["-i", "-s"]
                if options.kind == .recording {
                    arguments += ["-J", "video", "-U"]
                }
            case .window:
                arguments += ["-i", "-w"]
                if options.kind == .recording {
                    arguments += ["-J", "video", "-U"]
                }
                if !options.includeWindowShadow {
                    arguments.append("-o")
                }
            case .applicationWindow:
                guard let selectedWindowNumber = options.selectedWindowNumber else {
                    throw ScreenshotCaptureError.noWindow
                }
                arguments += ["-l", "\(selectedWindowNumber)"]
                if !options.includeWindowShadow {
                    arguments.append("-o")
                }
            case .appWindow:
                guard let appWindowNumber else {
                    throw ScreenshotCaptureError.noWindow
                }
                arguments += ["-l", "\(appWindowNumber)"]
                if !options.includeWindowShadow {
                    arguments.append("-o")
                }
            case .fullScreen:
                arguments.append("-m")
                if options.includeCursor {
                    arguments.append("-C")
                }
            }

            if options.copyToClipboard, destination == nil {
                arguments.append("-c")
            }
            if options.openInPreview, destination != nil {
                arguments.append("-P")
            }
            if let destination {
                arguments.append(destination.path)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let error = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let detail = [output, error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            if process.terminationStatus != 0 {
                if destination?.hasReachableFile == false || detail.isEmpty {
                    throw CancellationError()
                }
                throw ScreenshotCaptureError.failed(detail)
            }
            if let destination, !destination.hasReachableFile {
                throw CancellationError()
            }
        }.value
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

    @MainActor
    private static func copyToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image, url as NSURL])
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
    }
}

private extension URL {
    var hasReachableFile: Bool {
        (try? resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

private enum ScreenshotCaptureError: LocalizedError {
    case noWindow
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noWindow:
            "No visible Workbench window was available to capture."
        case let .failed(detail):
            detail.isEmpty ? "Screenshot failed." : detail
        }
    }
}
