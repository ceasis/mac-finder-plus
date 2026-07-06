import AppKit
import Foundation
import Observation

/// Persists security-scoped bookmarks for folders the user has granted access to.
/// This is what lets a sandboxed Mac App Store build keep access across launches.
@Observable
@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore()

    private let defaultsKey = "grantedBookmarks"
    private(set) var grantedURLs: [URL] = []

    /// Resolve all saved bookmarks and begin accessing them. Call once at launch.
    func restoreAll() {
        let saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var kept: [Data] = []
        for data in saved {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            grantedURLs.append(url)
            if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                kept.append(fresh)
            } else {
                kept.append(data)
            }
        }
        UserDefaults.standard.set(kept, forKey: defaultsKey)
    }

    func save(_ url: URL) {
        guard !grantedURLs.contains(url),
              let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        var saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: defaultsKey)
        _ = url.startAccessingSecurityScopedResource()
        grantedURLs.append(url)
    }

    func remove(_ url: URL) {
        guard let index = grantedURLs.firstIndex(of: url) else { return }
        url.stopAccessingSecurityScopedResource()
        grantedURLs.remove(at: index)
        var saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        if saved.indices.contains(index) { saved.remove(at: index) }
        UserDefaults.standard.set(saved, forKey: defaultsKey)
    }

    /// Shows an open panel asking the user to grant access to a folder,
    /// then bookmarks whatever they picked. Returns the granted URL.
    @discardableResult
    func requestAccess(startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = "Grant Access"
        panel.message = "Panes needs your permission to browse this folder."
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        save(chosen)
        return chosen
    }
}
