import AppKit
import SwiftUI

@main
struct WorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchAppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let fixture = WorkbenchUITestConfiguration.current {
                WorkbenchUIRegressionView(fixture: fixture, appState: appState)
            } else if WorkbenchUITestConfiguration.isRequested {
                ContentUnavailableView(
                    "Invalid UI Test Fixture",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The test runner must provide a marked disposable directory in an approved temporary location.")
                )
                .frame(width: 680, height: 360)
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            if !WorkbenchUITestConfiguration.isRequested {
                WorkbenchAppInfoCommands(appState: appState)
                AppCommands(appState: appState)
                CalendarCommands(appState: appState)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }

        Window("Review App Permissions", id: PermissionsReviewView.windowID) {
            PermissionsReviewView()
                .environment(appState)
        }
        .defaultSize(width: 700, height: 660)
        .windowResizability(.contentSize)
    }

    private var mainContent: some View {
        ContentView()
            .environment(appState)
            .frame(minWidth: 780, minHeight: 480)
            .background(WindowTitleHider())
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
final class WorkbenchWindowPersistenceScheduler {
    private let delay: Duration
    private var pendingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(delay: Duration) {
        self.delay = delay
    }

    func schedule(for id: ObjectIdentifier, operation: @escaping @MainActor () -> Void) {
        cancel(for: id)
        pendingTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            pendingTasks[id] = nil
            operation()
        }
    }

    func cancel(for id: ObjectIdentifier) {
        pendingTasks.removeValue(forKey: id)?.cancel()
    }
}

@MainActor
private final class WorkbenchWindowStateRestorer {
    static let shared = WorkbenchWindowStateRestorer()

    private let normalFrameKey = "mainWindow.normalFrame"
    private let isZoomedKey = "mainWindow.isZoomed"
    private let isFullScreenKey = "mainWindow.isFullScreen"
    private let minimumSize = NSSize(width: 780, height: 480)
    private let defaults: UserDefaults
    private let persistenceScheduler: WorkbenchWindowPersistenceScheduler

    private var observedWindowIDs = Set<ObjectIdentifier>()
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private weak var latestWindow: NSWindow?
    private var terminationObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        persistenceDelay: Duration = .milliseconds(200)
    ) {
        self.defaults = defaults
        persistenceScheduler = WorkbenchWindowPersistenceScheduler(delay: persistenceDelay)
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

        if defaults.string(forKey: normalFrameKey) == nil {
            defaults.set(NSStringFromRect(window.frame), forKey: normalFrameKey)
        }

        restore(window)
        observe(window)
    }

    private func restore(_ window: NSWindow) {
        if let savedFrame = savedNormalFrame() {
            window.setFrame(constrainedFrame(savedFrame), display: true, animate: false)
        }

        let shouldRestoreFullScreen = defaults.bool(forKey: isFullScreenKey)
        let shouldRestoreZoomed = defaults.bool(forKey: isZoomedKey)

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
        let deferredNotifications: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
        ]
        let immediateNotifications: [Notification.Name] = [
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didDeminiaturizeNotification,
        ]

        var tokens = deferredNotifications.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let window else { return }
                    self?.schedulePersistence(for: window)
                }
            }
        }

        tokens.append(contentsOf: immediateNotifications.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let window else { return }
                    self?.persistImmediately(window)
                }
            }
        })

        tokens.append(notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                if let window {
                    self?.persistImmediately(window)
                }
                self?.removeObservers(for: id)
            }
        })

        observers[id] = tokens
    }

    private func schedulePersistence(for window: NSWindow) {
        let id = ObjectIdentifier(window)
        persistenceScheduler.schedule(for: id) { [weak self, weak window] in
            guard let self, let window else { return }
            self.persist(window)
        }
    }

    private func persistImmediately(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        persistenceScheduler.cancel(for: id)
        persist(window)
    }

    private func removeObservers(for id: ObjectIdentifier) {
        persistenceScheduler.cancel(for: id)
        guard let tokens = observers.removeValue(forKey: id) else { return }
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        observedWindowIDs.remove(id)
    }

    private func saveLatestWindow() {
        guard let latestWindow else { return }
        persistImmediately(latestWindow)
    }

    private func persist(_ window: NSWindow) {
        let isFullScreen = window.styleMask.contains(.fullScreen)
        setIfChanged(isFullScreen, forKey: isFullScreenKey)
        setIfChanged(window.isZoomed, forKey: isZoomedKey)

        guard !isFullScreen, !window.isZoomed, !window.isMiniaturized else { return }
        setIfChanged(NSStringFromRect(window.frame), forKey: normalFrameKey)
    }

    private func setIfChanged(_ value: Bool, forKey key: String) {
        guard defaults.object(forKey: key) as? Bool != value else { return }
        defaults.set(value, forKey: key)
    }

    private func setIfChanged(_ value: String, forKey key: String) {
        guard defaults.string(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
    }

    private func savedNormalFrame() -> NSRect? {
        guard let frameString = defaults.string(forKey: normalFrameKey) else {
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
