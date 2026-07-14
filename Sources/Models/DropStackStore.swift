import AppKit
import Foundation
import Observation

struct DropStackItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var path: String
    var addedAt: Date

    init(url: URL, addedAt: Date = Date()) {
        let standardizedPath = url.standardizedFileURL.path
        self.id = standardizedPath
        self.path = standardizedPath
        self.addedAt = addedAt
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var name: String {
        url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var fileItem: FileItem? {
        PaneModel.itemIfReachable(id: path)
    }
}

@Observable
@MainActor
final class DropStackStore {
    static let shared = DropStackStore()

    private(set) var items: [DropStackItem] = []
    var selection = Set<DropStackItem.ID>()

    private let defaultsKey = "dropStack.paths"

    private init() {
        load()
    }

    var existingItems: [DropStackItem] {
        items.filter(\.exists)
    }

    var existingURLs: [URL] {
        existingItems.map(\.url)
    }

    var selectedURLs: [URL] {
        let selected = items.filter { selection.contains($0.id) && $0.exists }.map(\.url)
        return selected.isEmpty ? existingURLs : selected
    }

    var missingCount: Int {
        items.filter { !$0.exists }.count
    }

    func add(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }

        var seen = Set(items.map(\.id))
        var next = items
        for url in existing {
            let item = DropStackItem(url: url)
            guard !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            next.insert(item, at: 0)
        }
        items = next
        save()
    }

    func remove(_ ids: Set<DropStackItem.ID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    func remove(_ item: DropStackItem) {
        remove([item.id])
    }

    func removeMissing() {
        items.removeAll { !$0.exists }
        selection = selection.filter { id in
            items.contains { $0.id == id }
        }
        save()
    }

    func clear() {
        items = []
        selection = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([DropStackItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
