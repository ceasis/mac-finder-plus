import Foundation
import Observation

@Observable
@MainActor
final class CleanupStore {
    static let shared = CleanupStore()

    var scanScope: CleanupScanScope = .home
    var categories: [CleanupCategorySummary] = []
    var selectedSuggestionIDs = Set<String>()
    var isScanning = false
    var scanProgress: Double = 0
    var scanDetail = ""
    var lastError: String?
    var lastScannedAt: Date?

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    private init() {}

    var totalSuggestionCount: Int {
        categories.reduce(0) { $0 + $1.suggestions.count }
    }

    var totalReclaimableBytes: Int64 {
        categories.reduce(0) { $0 + $1.totalBytes }
    }

    var totalReclaimableText: String {
        ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)
    }

    var selectedSuggestions: [CleanupSuggestion] {
        categories
            .flatMap(\.suggestions)
            .filter { selectedSuggestionIDs.contains($0.id) }
    }

    func startScan(activeFolder: URL?) {
        guard !isScanning else { return }
        guard let root = scanScope.rootURL(activeFolder: activeFolder) else {
            lastError = scanScope == .activeFolder
                ? "Open a folder in the active pane to scan it."
                : "Could not resolve the scan location."
            return
        }

        lastError = nil
        isScanning = true
        scanProgress = 0
        scanDetail = "Starting scan…"
        categories = []
        selectedSuggestionIDs.removeAll()

        let scope = scanScope
        scanTask = Task {
            do {
                let options = CleanupScanOptions(root: root)
                let results = try await CleanupEngine.scan(options: options) { progress, detail in
                    await MainActor.run {
                        self.scanProgress = progress
                        self.scanDetail = detail
                    }
                }
                guard !Task.isCancelled else { return }
                categories = results
                lastScannedAt = Date()
                scanDetail = results.isEmpty
                    ? "No cleanup suggestions found."
                    : "Found \(totalSuggestionCount) suggestions (\(totalReclaimableText))."
            } catch is CancellationError {
                scanDetail = "Scan cancelled."
            } catch {
                lastError = error.localizedDescription
                scanDetail = "Scan failed."
            }
            isScanning = false
            scanTask = nil
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanDetail = "Scan cancelled."
    }

    func toggleSelection(for suggestion: CleanupSuggestion) {
        if selectedSuggestionIDs.contains(suggestion.id) {
            selectedSuggestionIDs.remove(suggestion.id)
        } else {
            selectedSuggestionIDs.insert(suggestion.id)
        }
    }

    func setSelection(for suggestions: [CleanupSuggestion], selected: Bool) {
        let ids = Set(suggestions.map(\.id))
        if selected {
            selectedSuggestionIDs.formUnion(ids)
        } else {
            selectedSuggestionIDs.subtract(ids)
        }
    }

    func selectAll() {
        selectedSuggestionIDs = Set(categories.flatMap(\.suggestions).map(\.id))
    }

    func clearSelection() {
        selectedSuggestionIDs.removeAll()
    }

    func removeSuggestions(withIDs ids: Set<String>) {
        guard !ids.isEmpty else { return }
        categories = categories.map { category in
            var updated = category
            updated.suggestions.removeAll { ids.contains($0.id) }
            return updated
        }
        .filter { !$0.suggestions.isEmpty }
        selectedSuggestionIDs.subtract(ids)
    }
}
