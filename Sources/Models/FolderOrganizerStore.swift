import Foundation
import Observation

@Observable
@MainActor
final class FolderOrganizerStore {
    static let shared = FolderOrganizerStore()

    var targetScope: CleanupScanScope = .activeFolder
    var mode: FolderOrganizeMode = .byType
    var groups: [OrganizeGroupSummary] = []
    var isPlanning = false
    var isApplying = false
    var planDetail = ""
    var lastError: String?
    var lastPlannedAt: Date?
    var plannedFolder: URL?

    @ObservationIgnored private var planTask: Task<Void, Never>?

    private init() {}

    var totalItemCount: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    var totalBytes: Int64 {
        groups.reduce(0) { $0 + $1.totalBytes }
    }

    var totalBytesText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var allPlanItems: [OrganizePlanItem] {
        groups.flatMap(\.items)
    }

    func plan(activeFolder: URL?, includeHidden: Bool) {
        guard !isPlanning else { return }
        guard let folder = targetScope.rootURL(activeFolder: activeFolder) else {
            lastError = targetScope == .activeFolder
                ? "Open a folder in the active pane to organize it."
                : "Could not resolve the folder to organize."
            return
        }

        lastError = nil
        isPlanning = true
        planDetail = "Planning organization…"
        groups = []
        plannedFolder = folder

        let selectedMode = mode
        let selectedScope = targetScope
        planTask = Task {
            do {
                let results = try await FolderOrganizerEngine.plan(
                    in: folder,
                    mode: selectedMode,
                    includeHidden: includeHidden
                )
                guard !Task.isCancelled else { return }
                groups = results
                lastPlannedAt = Date()
                plannedFolder = folder
                if results.isEmpty {
                    planDetail = "Nothing to organize in \(selectedScope.rawValue)."
                } else {
                    planDetail = "\(totalItemCount) files into \(results.count) folders (\(totalBytesText))."
                }
            } catch is CancellationError {
                planDetail = "Planning cancelled."
            } catch {
                lastError = error.localizedDescription
                planDetail = "Could not plan organization."
            }
            isPlanning = false
            planTask = nil
        }
    }

    func cancelPlanning() {
        planTask?.cancel()
        planTask = nil
        isPlanning = false
        planDetail = "Planning cancelled."
    }

    func clearPlan() {
        groups = []
        planDetail = ""
        plannedFolder = nil
        lastPlannedAt = nil
    }
}
