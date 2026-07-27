import Darwin
import Dispatch
import Foundation

/// Watches one visible browser directory for changes made outside Workbench.
/// Directory writes can arrive in bursts (downloads commonly create, extend,
/// and rename a temporary file), so callbacks are debounced before reloading.
@MainActor
final class DirectoryWatcher {
    private let debounce: Duration
    private let onChange: @MainActor () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var watchedURL: URL?
    private var refreshTask: Task<Void, Never>?

    init(
        debounce: Duration = .milliseconds(250),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.debounce = debounce
        self.onChange = onChange
    }

    func watch(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard watchedURL != standardizedURL else { return }

        stop()

        let descriptor = Darwin.open(standardizedURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh(for: standardizedURL)
            }
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }

        self.source = source
        watchedURL = standardizedURL
        source.resume()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        source?.cancel()
        source = nil
        watchedURL = nil
    }

    private func scheduleRefresh(for url: URL) {
        guard watchedURL == url else { return }

        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, watchedURL == url else { return }
            refreshTask = nil
            onChange()
        }
    }
}
