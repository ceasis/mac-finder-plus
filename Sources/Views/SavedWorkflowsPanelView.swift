import SwiftUI

struct SavedWorkflowsPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = SavedWorkflowStore.shared
    @State private var draftName = ""
    @State private var draftSteps: [SavedWorkflowStep] = []

    private var selectedWorkflow: SavedWorkflow? {
        store.selectedWorkflow
    }

    private var canSaveDraft: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftSteps.isEmpty
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            panelHeader
            Divider()

            HSplitView {
                List(selection: $store.selectedWorkflowID) {
                    ForEach(store.workflows) { workflow in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workflow.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text("\(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .tag(workflow.id)
                    }
                }
                .frame(minWidth: 130, idealWidth: 160)

                workflowEditor
                    .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            actionBar
        }
        .onAppear {
            store.ensureSelection()
            loadSelectedWorkflow()
        }
        .onChange(of: store.selectedWorkflowID) { _, _ in
            loadSelectedWorkflow()
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text("Saved Workflows")
                    .font(.headline)
                Text("Run repeatable file recipes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            PanelIconButton(systemName: "sidebar.right", help: "Hide Workflows") {
                appState.hideSavedWorkflows()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var workflowEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Workflow name", text: $draftName)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Steps")
                            .font(.headline)
                        ForEach(SavedWorkflowStep.allCases) { step in
                            WorkflowStepToggle(
                                step: step,
                                isOn: Binding(
                                    get: { draftSteps.contains(step) },
                                    set: { isOn in
                                        toggle(step, isOn: isOn)
                                    }
                                )
                            )
                        }
                    }

                    if draftSteps.isEmpty {
                        Text("Choose at least one step. Steps run in the order shown here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Order: \(draftSteps.map(\.title).joined(separator: " → "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            AdaptiveActionBar {
                Button {
                    if let selectedWorkflow {
                        store.updateWorkflow(selectedWorkflow, name: draftName, steps: draftSteps)
                    } else {
                        store.addWorkflow(name: draftName, steps: draftSteps)
                    }
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .help(canSaveDraft ? "Save this workflow" : "Name the workflow and choose at least one step")
                .disabled(!canSaveDraft)

                Button {
                    draftName = "New Workflow"
                    draftSteps = [.copyPaths]
                    store.selectedWorkflowID = nil
                } label: {
                    Label("New", systemImage: "plus")
                }

                Button(role: .destructive) {
                    store.deleteSelectedWorkflow()
                    loadSelectedWorkflow()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help(store.selectedWorkflow == nil ? "Select a workflow first" : "Delete selected workflow")
                .disabled(store.selectedWorkflow == nil)
            } trailing: {
                Button("Defaults") {
                    store.resetDefaults()
                    loadSelectedWorkflow()
                }
            }

            HStack(spacing: 8) {
                Button {
                    appState.runSelectedWorkflow(source: .selection)
                } label: {
                    Label("Run Selection", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .help(appState.workflowRunUnavailableReason(source: .selection) ?? "Run workflow on the active selection")
                .disabled(!appState.canRunSelectedWorkflow(source: .selection))

                Button {
                    appState.runSelectedWorkflow(source: .dropStack)
                } label: {
                    Label("Run Drop Stack", systemImage: "tray.full")
                }
                .help(appState.workflowRunUnavailableReason(source: .dropStack) ?? "Run workflow on drop stack files")
                .disabled(!appState.canRunSelectedWorkflow(source: .dropStack))
            }
        }
        .padding(12)
    }

    private func loadSelectedWorkflow() {
        guard let workflow = store.selectedWorkflow else {
            draftName = ""
            draftSteps = []
            return
        }
        draftName = workflow.name
        draftSteps = workflow.steps
    }

    private func toggle(_ step: SavedWorkflowStep, isOn: Bool) {
        if isOn {
            guard !draftSteps.contains(step) else { return }
            draftSteps.append(step)
            draftSteps.sort { left, right in
                guard let leftIndex = SavedWorkflowStep.allCases.firstIndex(of: left),
                      let rightIndex = SavedWorkflowStep.allCases.firstIndex(of: right) else {
                    return false
                }
                return leftIndex < rightIndex
            }
        } else {
            draftSteps.removeAll { $0 == step }
        }
    }
}

private struct WorkflowStepToggle: View {
    let step: SavedWorkflowStep
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.callout)
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}
