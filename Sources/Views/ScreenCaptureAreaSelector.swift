import AppKit
import CoreGraphics

/// A short-lived selection overlay, not part of the capture itself. Each
/// display has a window so a drag is clipped to the display where it began.
@MainActor
enum ScreenCaptureAreaSelector {
    private static var isSelecting = false

    /// The user chose the separate window picker instead of drawing a region.
    struct SwitchToWindow: Error {}

    /// Returns global Quartz coordinates (top-left origin, logical points).
    static func select(allowWindowSwitch: Bool = false) async throws -> CGRect {
        try Task.checkCancellation()
        guard !isSelecting else { throw SelectionError.alreadySelecting }
        isSelecting = true
        defer { isSelecting = false }

        let session = AreaSelectionSession(allowWindowSwitch: allowWindowSwitch)
        let rectangle = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                session.present(continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in session.cancel() }
        }
        try Task.checkCancellation()
        return rectangle
    }

    fileprivate enum SelectionError: LocalizedError {
        case alreadySelecting
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .alreadySelecting: "An area selection is already open."
            case .noDisplay: "No display is available for area capture."
            }
        }
    }
}

enum ScreenCaptureAreaGeometry {
    /// The view is flipped, so both spaces are top-left logical coordinates.
    /// Retina backing pixels are applied later by the capture configuration.
    static func quartzRectangle(_ selection: CGRect, in view: CGRect, on display: CGRect) -> CGRect? {
        guard view.width > 0, view.height > 0, display.width > 0, display.height > 0 else { return nil }
        let clipped = selection.standardized.intersection(view)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        let xScale = display.width / view.width
        let yScale = display.height / view.height
        return CGRect(
            x: display.minX + (clipped.minX - view.minX) * xScale,
            y: display.minY + (clipped.minY - view.minY) * yScale,
            width: clipped.width * xScale,
            height: clipped.height * yScale
        ).intersection(display)
    }
}

@MainActor
private final class AreaSelectionSession: NSObject {
    private let allowWindowSwitch: Bool
    private var continuation: CheckedContinuation<CGRect, any Error>?
    private var windows: [AreaSelectionWindow] = []
    private weak var previousKeyWindow: NSWindow?

    init(allowWindowSwitch: Bool) {
        self.allowWindowSwitch = allowWindowSwitch
    }

    func present(continuation: CheckedContinuation<CGRect, any Error>) {
        self.continuation = continuation
        previousKeyWindow = NSApp.keyWindow
        windows = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(id.uint32Value))
            guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }

            let window = AreaSelectionWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isRestorable = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.setFrame(screen.frame, display: false)
            let view = AreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onSelection = { [weak self, weak view] region in
                guard let view,
                      let bounds = ScreenCaptureAreaGeometry.quartzRectangle(region, in: view.bounds, on: displayBounds)
                else { return }
                self?.finish(.success(bounds))
            }
            view.onCancel = { [weak self] in self?.cancel() }
            if allowWindowSwitch {
                view.onSwitchToWindow = { [weak self] in self?.finish(.failure(ScreenCaptureAreaSelector.SwitchToWindow())) }
            }
            window.contentView = view
            window.initialFirstResponder = view
            return window
        }

        guard !windows.isEmpty else {
            finish(.failure(ScreenCaptureAreaSelector.SelectionError.noDisplay))
            return
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(environmentChanged(_:)), name: NSApplication.didResignActiveNotification, object: NSApp)
        center.addObserver(self, selector: #selector(environmentChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        NSApp.activate()
        for window in windows {
            window.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let initialWindow = windows.first(where: { $0.frame.contains(mouse) }) ?? windows[0]
        initialWindow.makeKey()
        initialWindow.makeFirstResponder(initialWindow.contentView)
    }

    @objc private func environmentChanged(_ notification: Notification) {
        cancel()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<CGRect, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        NotificationCenter.default.removeObserver(self)
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        if NSApp.isActive, let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
        }
        continuation.resume(with: result)
    }
}

private final class AreaSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class AreaSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onSwitchToWindow: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        start = point
        current = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard start != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        let selected = selection
        start = nil
        current = nil
        needsDisplay = true
        if let selected { onSelection?(selected) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?() // Escape
        case 49: onSwitchToWindow?() // Space
        default: break
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        let rectangle = CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(start.x - current.x), height: abs(start.y - current.y)
        ).intersection(bounds)
        return rectangle.isNull || rectangle.isEmpty ? nil : rectangle
    }

    override func draw(_ dirtyRect: NSRect) {
        let mask = NSBezierPath(rect: bounds)
        mask.windingRule = .evenOdd
        if let selection { mask.appendRect(selection) }
        NSColor.black.withAlphaComponent(0.36).setFill()
        mask.fill()

        if let selection {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1
            outline.stroke()
        }

        if start == nil {
            let hint = NSAttributedString(
                string: onSwitchToWindow == nil
                    ? "Drag to capture an area  ·  Esc to close"
                    : "Drag to capture an area  ·  Space for a window  ·  Esc to close",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
            )
            let size = hint.size()
            let origin = CGPoint(x: (bounds.width - size.width) / 2, y: 48)
            let background = CGRect(origin: origin, size: size).insetBy(dx: -14, dy: -8)
            NSColor.black.withAlphaComponent(0.76).setFill()
            NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
            hint.draw(at: origin)
        }
    }
}
