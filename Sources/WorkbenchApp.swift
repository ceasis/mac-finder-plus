import AppKit
import SwiftUI

@main
struct WorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchAppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 780, minHeight: 480)
                .background(WindowTitleHider())
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            AppCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

private struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        WorkbenchWindowStateRestorer.shared.configure(window)
    }
}

@MainActor
private final class WorkbenchWindowStateRestorer {
    static let shared = WorkbenchWindowStateRestorer()

    private let normalFrameKey = "mainWindow.normalFrame"
    private let isZoomedKey = "mainWindow.isZoomed"
    private let isFullScreenKey = "mainWindow.isFullScreen"
    private let minimumSize = NSSize(width: 780, height: 480)

    private var observedWindowIDs = Set<ObjectIdentifier>()
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private weak var latestWindow: NSWindow?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveLatestWindow()
            }
        }
    }

    func configure(_ window: NSWindow) {
        latestWindow = window

        let id = ObjectIdentifier(window)
        guard !observedWindowIDs.contains(id) else { return }
        observedWindowIDs.insert(id)

        if UserDefaults.standard.string(forKey: normalFrameKey) == nil {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: normalFrameKey)
        }

        restore(window)
        observe(window)
    }

    private func restore(_ window: NSWindow) {
        if let savedFrame = savedNormalFrame() {
            window.setFrame(constrainedFrame(savedFrame), display: true, animate: false)
        }

        let shouldRestoreFullScreen = UserDefaults.standard.bool(forKey: isFullScreenKey)
        let shouldRestoreZoomed = UserDefaults.standard.bool(forKey: isZoomedKey)

        if shouldRestoreFullScreen {
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                if !window.styleMask.contains(.fullScreen) {
                    self.withoutWindowAnimation(window) {
                        window.toggleFullScreen(nil)
                    }
                }
            }
        } else if shouldRestoreZoomed, !window.isZoomed {
            withoutWindowAnimation(window) {
                window.zoom(nil)
            }
        }
    }

    private func withoutWindowAnimation(_ window: NSWindow, updates: () -> Void) {
        let previousAnimationBehavior = window.animationBehavior
        window.animationBehavior = .none

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            updates()
        }

        window.animationBehavior = previousAnimationBehavior
    }

    private func observe(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        let notificationCenter = NotificationCenter.default
        let observedNotifications: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didDeminiaturizeNotification,
        ]

        var tokens = observedNotifications.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let window else { return }
                    self?.persist(window)
                }
            }
        }

        tokens.append(notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                if let window {
                    self?.persist(window)
                }
                self?.removeObservers(for: id)
            }
        })

        observers[id] = tokens
    }

    private func removeObservers(for id: ObjectIdentifier) {
        guard let tokens = observers.removeValue(forKey: id) else { return }
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        observedWindowIDs.remove(id)
    }

    private func saveLatestWindow() {
        guard let latestWindow else { return }
        persist(latestWindow)
    }

    private func persist(_ window: NSWindow) {
        let isFullScreen = window.styleMask.contains(.fullScreen)
        UserDefaults.standard.set(isFullScreen, forKey: isFullScreenKey)
        UserDefaults.standard.set(window.isZoomed, forKey: isZoomedKey)

        guard !isFullScreen, !window.isZoomed, !window.isMiniaturized else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: normalFrameKey)
    }

    private func savedNormalFrame() -> NSRect? {
        guard let frameString = UserDefaults.standard.string(forKey: normalFrameKey) else {
            return nil
        }
        let frame = NSRectFromString(frameString)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    private func constrainedFrame(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else {
            return frame
        }

        let visibleFrame = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let minimumWidth = min(minimumSize.width, visibleFrame.width)
        let minimumHeight = min(minimumSize.height, visibleFrame.height)
        let size = NSSize(
            width: min(max(frame.width, minimumWidth), visibleFrame.width),
            height: min(max(frame.height, minimumHeight), visibleFrame.height)
        )
        var origin = frame.origin

        if origin.x < visibleFrame.minX {
            origin.x = visibleFrame.minX
        }
        if origin.y < visibleFrame.minY {
            origin.y = visibleFrame.minY
        }
        if origin.x + size.width > visibleFrame.maxX {
            origin.x = visibleFrame.maxX - size.width
        }
        if origin.y + size.height > visibleFrame.maxY {
            origin.y = visibleFrame.maxY - size.height
        }

        return NSRect(origin: origin, size: size)
    }
}
