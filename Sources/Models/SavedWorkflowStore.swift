import Foundation
import Observation

enum SavedWorkflowRunSource: String, CaseIterable, Identifiable {
    case selection
    case dropStack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: "Selection"
        case .dropStack: "Drop Stack"
        }
    }

    var systemImage: String {
        switch self {
        case .selection: "checkmark.circle"
        case .dropStack: "tray.full"
        }
    }
}

enum SavedWorkflowStep: String, CaseIterable, Codable, Identifiable, Sendable {
    case optimizeImages
    case createThumbnails
    case grayscaleImages
    case contactSheetPDF
    case copyPaths
    case copyNames
    case createSnippets
    case rateThreeStars
    case rateFiveStars
    case copyToOtherPane
    case moveToOtherPane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optimizeImages: "Optimize Images"
        case .createThumbnails: "Create 512px Thumbnails"
        case .grayscaleImages: "Convert to Grayscale"
        case .contactSheetPDF: "Export Contact Sheet PDF"
        case .copyPaths: "Copy Paths"
        case .copyNames: "Copy Names"
        case .createSnippets: "Create Snippets"
        case .rateThreeStars: "Rate 3 Stars"
        case .rateFiveStars: "Rate 5 Stars"
        case .copyToOtherPane: "Copy to Other Pane"
        case .moveToOtherPane: "Move to Other Pane"
        }
    }

    var detail: String {
        switch self {
        case .optimizeImages: "Writes optimized image copies beside the originals."
        case .createThumbnails: "Writes 512px thumbnail copies beside the originals."
        case .grayscaleImages: "Writes grayscale image copies beside the originals."
        case .contactSheetPDF: "Creates one contact sheet from image files."
        case .copyPaths: "Copies full paths to the clipboard history."
        case .copyNames: "Copies file names to the clipboard history."
        case .createSnippets: "Stores non-folder files in Snippets."
        case .rateThreeStars: "Applies a 3-star Finder-compatible rating."
        case .rateFiveStars: "Applies a 5-star Finder-compatible rating."
        case .copyToOtherPane: "Copies files into the inactive pane."
        case .moveToOtherPane: "Moves files into the inactive pane with undo support."
        }
    }

    var systemImage: String {
        switch self {
        case .optimizeImages: "wand.and.stars"
        case .createThumbnails: "photo.on.rectangle"
        case .grayscaleImages: "circle.lefthalf.filled"
        case .contactSheetPDF: "square.grid.3x3"
        case .copyPaths: "point.topleft.down.curvedto.point.bottomright.up"
        case .copyNames: "textformat"
        case .createSnippets: "text.quote"
        case .rateThreeStars, .rateFiveStars: "star.fill"
        case .copyToOtherPane: "doc.on.doc"
        case .moveToOtherPane: "arrow.right.doc.on.clipboard"
        }
    }

    var requiresDualPane: Bool {
        switch self {
        case .copyToOtherPane, .moveToOtherPane:
            true
        default:
            false
        }
    }
}

struct SavedWorkflow: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var steps: [SavedWorkflowStep]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        steps: [SavedWorkflowStep],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var stepSummary: String {
        guard !steps.isEmpty else { return "No steps" }
        return steps.map(\.title).joined(separator: " → ")
    }
}

@Observable
@MainActor
final class SavedWorkflowStore {
    static let shared = SavedWorkflowStore()

    private(set) var workflows: [SavedWorkflow] = []
    var selectedWorkflowID: SavedWorkflow.ID?

    private let defaultsKey = "savedWorkflows.v1"

    private init() {
        load()
    }

    var selectedWorkflow: SavedWorkflow? {
        guard let selectedWorkflowID else { return nil }
        return workflows.first { $0.id == selectedWorkflowID }
    }

    func ensureSelection() {
        if let selectedWorkflowID, workflows.contains(where: { $0.id == selectedWorkflowID }) {
            return
        }
        selectedWorkflowID = workflows.first?.id
    }

    func addWorkflow(name: String, steps: [SavedWorkflowStep]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !steps.isEmpty else { return }
        let workflow = SavedWorkflow(name: trimmed, steps: steps)
        workflows.insert(workflow, at: 0)
        selectedWorkflowID = workflow.id
        save()
    }

    func updateWorkflow(_ workflow: SavedWorkflow, name: String, steps: [SavedWorkflowStep]) {
        guard let index = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !steps.isEmpty else { return }
        workflows[index].name = trimmed
        workflows[index].steps = steps
        workflows[index].updatedAt = Date()
        save()
    }

    func deleteSelectedWorkflow() {
        guard let selectedWorkflowID,
              let index = workflows.firstIndex(where: { $0.id == selectedWorkflowID }) else {
            return
        }
        workflows.remove(at: index)
        self.selectedWorkflowID = workflows.first?.id
        save()
    }

    func resetDefaults() {
        workflows = Self.defaultWorkflows
        selectedWorkflowID = workflows.first?.id
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedWorkflow].self, from: data),
           !decoded.isEmpty {
            workflows = decoded
        } else {
            workflows = Self.defaultWorkflows
        }
        selectedWorkflowID = workflows.first?.id
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(workflows) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static let defaultWorkflows: [SavedWorkflow] = [
        SavedWorkflow(
            name: "Social Image Prep",
            steps: [.optimizeImages, .createThumbnails, .copyNames]
        ),
        SavedWorkflow(
            name: "Client Contact Sheet",
            steps: [.rateFiveStars, .contactSheetPDF, .copyPaths]
        ),
        SavedWorkflow(
            name: "Hand Off to Other Pane",
            steps: [.copyToOtherPane]
        ),
    ]
}
