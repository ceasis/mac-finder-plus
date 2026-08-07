import Darwin
import Dispatch
import Foundation

/// Watches one visible browser directory for changes made outside Workbench.
/// Directory writes can arrive in bursts (downloads commonly create, extend,
/// and rename a temporary file), so callbacks are debounced before reloading.
@MainActor
final class DirectoryWatcher {
    private let debounce: Duration
    private let pollingInterval: Duration
    private let usesFileSystemEvents: Bool
    private let onChange: @MainActor () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var watchedURL: URL?
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var directoryStamp: DirectoryStamp?

    init(
        debounce: Duration = .milliseconds(250),
        pollingInterval: Duration = .seconds(1),
        usesFileSystemEvents: Bool = true,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.debounce = debounce
        self.pollingInterval = pollingInterval
        self.usesFileSystemEvents = usesFileSystemEvents
        self.onChange = onChange
    }

    func watch(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard watchedURL != standardizedURL else { return }

        stop()
        watchedURL = standardizedURL
        directoryStamp = Self.directoryStamp(for: standardizedURL)
        startPolling(standardizedURL)

        guard usesFileSystemEvents else { return }

        let descriptor = Darwin.open(standardizedURL.path, O_EVTONLY)
        // Polling remains active when the file descriptor cannot be opened.
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
        source.resume()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        source?.cancel()
        source = nil
        watchedURL = nil
        directoryStamp = nil
    }

    private func startPolling(_ url: URL) {
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, watchedURL == url {
                try? await Task.sleep(for: pollingInterval)
                guard !Task.isCancelled, watchedURL == url else { return }
                let latestStamp = await Task.detached(priority: .utility) {
                    Self.directoryStamp(for: url)
                }.value
                guard !Task.isCancelled, watchedURL == url else { return }
                if latestStamp != directoryStamp {
                    directoryStamp = latestStamp
                    scheduleRefresh(for: url)
                }
            }
        }
    }

    private func scheduleRefresh(for url: URL) {
        guard watchedURL == url else { return }

        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, watchedURL == url else { return }
            refreshTask = nil
            directoryStamp = Self.directoryStamp(for: url)
            onChange()
        }
    }

    nonisolated private static func directoryStamp(for url: URL) -> DirectoryStamp? {
        var info = stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        guard status == 0 else { return nil }
        return DirectoryStamp(
            modificationSeconds: info.st_mtimespec.tv_sec,
            modificationNanoseconds: info.st_mtimespec.tv_nsec,
            statusChangeSeconds: info.st_ctimespec.tv_sec,
            statusChangeNanoseconds: info.st_ctimespec.tv_nsec
        )
    }
}

private struct DirectoryStamp: Equatable, Sendable {
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let statusChangeSeconds: Int
    let statusChangeNanoseconds: Int
}
