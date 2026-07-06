import AppKit
import Foundation

enum ScreenshotCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case interactive
    case selection
    case window
    case appWindow
    case fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interactive: "Area / Window"
        case .selection: "Area"
        case .window: "Window"
        case .appWindow: "Panes Window"
        case .fullScreen: "Screen"
        }
    }

    var systemImage: String {
        switch self {
        case .interactive: "viewfinder"
        case .selection: "crop"
        case .window: "macwindow"
        case .appWindow: "rectangle.inset.filled"
        case .fullScreen: "display"
        }
    }

    var supportsCursor: Bool {
        self == .fullScreen
    }

    var supportsShadow: Bool {
        switch self {
        case .interactive, .window, .appWindow:
            true
        case .selection, .fullScreen:
            false
        }
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
    var mode: ScreenshotCaptureMode
    var format: ScreenshotFormat
    var delay: Int
    var includeCursor: Bool
    var includeWindowShadow: Bool
    var saveToActiveFolder: Bool
    var copyToClipboard: Bool
    var openInPreview: Bool
    var playSound: Bool
}

struct ScreenshotCaptureResult: Sendable {
    let savedURL: URL?
}

enum ScreenshotCapture {
    static func capture(
        options: ScreenshotOptions,
        destinationFolder: URL,
        appWindowNumber: Int?
    ) async throws -> ScreenshotCaptureResult {
        let destination = options.saveToActiveFolder
            ? uniqueDestination(in: destinationFolder, format: options.format)
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

    private static func runScreencapture(
        options: ScreenshotOptions,
        destination: URL?,
        appWindowNumber: Int?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            var arguments: [String] = ["-d", "-t", options.format.rawValue]
            if !options.playSound {
                arguments.append("-x")
            }
            if options.delay > 0 {
                arguments += ["-T", "\(options.delay)"]
            }

            switch options.mode {
            case .interactive:
                arguments += ["-i", "-J", "selection"]
                if !options.includeWindowShadow {
                    arguments.append("-o")
                }
            case .selection:
                arguments += ["-i", "-s"]
            case .window:
                arguments += ["-i", "-w"]
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

    private static func uniqueDestination(in folder: URL, format: ScreenshotFormat) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(formatter.string(from: Date())).\(format.fileExtension)"
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
            "No visible Panes window was available to capture."
        case let .failed(detail):
            detail.isEmpty ? "Screenshot failed." : detail
        }
    }
}
