import AppKit
import Foundation
import Observation

/// Persists bookmarks for folders the user has pinned as favorites so they
/// survive relaunches (and folder moves/renames). Workbench ships without the App
/// Sandbox, so these are plain bookmarks — no security scope is needed; the app
/// reads any path the user's account can, subject to the usual macOS TCC
/// prompts for protected folders (Desktop, Documents, Downloads, volumes).
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
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            grantedURLs.append(url)
            if isStale, let fresh = try? url.bookmarkData() {
                kept.append(fresh)
            } else {
                kept.append(data)
            }
        }
        UserDefaults.standard.set(kept, forKey: defaultsKey)
    }

    func save(_ url: URL) {
        guard !grantedURLs.contains(url),
              let data = try? url.bookmarkData() else { return }
        var saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        saved.append(data)
        UserDefaults.standard.set(saved, forKey: defaultsKey)
        grantedURLs.append(url)
    }

    func remove(_ url: URL) {
        guard let index = grantedURLs.firstIndex(of: url) else { return }
        grantedURLs.remove(at: index)
        var saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        if saved.indices.contains(index) { saved.remove(at: index) }
        UserDefaults.standard.set(saved, forKey: defaultsKey)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        grantedURLs.moveItems(fromOffsets: source, toOffset: destination)
        persistAll()
    }

    /// Inserts a favorite at a specific position (used by drag-to-reorder /
    /// drag-to-insert in the sidebar). If the URL is already a favorite it moves
    /// to the new position instead of duplicating.
    func insert(_ url: URL, at index: Int) {
        if let existing = grantedURLs.firstIndex(of: url) {
            grantedURLs.remove(at: existing)
        }
        let clamped = min(max(index, 0), grantedURLs.count)
        grantedURLs.insert(url, at: clamped)
        persistAll()
    }

    private func persistAll() {
        let data = grantedURLs.compactMap { try? $0.bookmarkData() }
        UserDefaults.standard.set(data, forKey: defaultsKey)
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
        panel.message = "Workbench needs your permission to browse this folder."
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        save(chosen)
        return chosen
    }
}

private extension Array {
    mutating func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { self[$0] }
        for index in source.sorted(by: >) {
            remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        insert(
            contentsOf: moving,
            at: Swift.min(Swift.max(adjustedDestination, 0), count)
        )
    }
}
