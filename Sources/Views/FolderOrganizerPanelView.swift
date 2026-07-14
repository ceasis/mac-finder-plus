import AppKit
import SwiftUI

struct FolderOrganizerPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = FolderOrganizerStore.shared

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        .background(.bar)
        .alert("Organize Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Organize", systemImage: "folder.badge.gearshape")
                .font(.headline)

            Spacer()

            if store.isPlanning {
                PanelIconButton(systemName: "stop.circle", help: "Stop planning") {
                    store.cancelPlanning()
                }
            } else {
                PanelIconButton(systemName: "arrow.clockwise", help: "Plan again") {
                    store.plan(
                        activeFolder: appState.activePane.currentURL,
                        includeHidden: appState.showHidden
                    )
                }
            }

            PanelIconButton(systemName: "xmark", help: "Hide Organize") {
                appState.hideOrganizeTool()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var controls: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Folder", selection: $store.targetScope) {
                ForEach(CleanupScanScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isPlanning || store.isApplying)

            Picker("Mode", selection: $store.mode) {
                ForEach(FolderOrganizeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isPlanning || store.isApplying)

            Text(store.mode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if store.isPlanning {
                ProgressView()
                    .controlSize(.small)
                Text(store.planDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !store.planDetail.isEmpty {
                Text(store.planDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                Text("Sort loose files in the selected folder into subfolders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                store.plan(
                    activeFolder: appState.activePane.currentURL,
                    includeHidden: appState.showHidden
                )
            } label: {
                Label(store.isPlanning ? "Planning…" : "Preview Plan", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(store.isPlanning || store.isApplying)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if store.groups.isEmpty && !store.isPlanning {
            ContentUnavailableView(
                "No Plan Yet",
                systemImage: "folder.badge.gearshape",
                description: Text("Choose a folder and mode, then preview how files will be grouped.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            OrganizePlanRow(item: item) {
                                reveal(item)
                            }
                        }
                    } header: {
                        OrganizeGroupHeader(group: group)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerContent
            VStack(alignment: .leading, spacing: 8) {
                Text(footerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    footerButtons
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footerContent: some View {
        HStack(spacing: 8) {
            Text(footerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            footerButtons
        }
    }

    private var footerButtons: some View {
        Group {
            Button("Reveal") {
                revealAll()
            }
            .disabled(store.allPlanItems.isEmpty)

            Button("Organize") {
                appState.applyOrganizePlan(store.allPlanItems) {
                    store.clearPlan()
                }
            }
            .disabled(store.allPlanItems.isEmpty || store.isApplying)
        }
    }

    private var footerSummary: String {
        guard store.totalItemCount > 0 else { return "No files to move" }
        return "\(store.totalItemCount) files · \(store.totalBytesText)"
    }

    private func reveal(_ item: OrganizePlanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func revealAll() {
        let urls = store.allPlanItems.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}

private struct OrganizeGroupHeader: View {
    let group: OrganizeGroupSummary

    var body: some View {
        HStack(spacing: 6) {
            Label(group.folderName, systemImage: "folder")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Text("\(group.items.count) · \(group.totalBytesText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OrganizePlanRow: View {
    let item: OrganizePlanItem
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.body)
                .lineLimit(1)
            Text("→ \(item.destinationFolder)/")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.sizeText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contextMenu {
            Button("Reveal in Finder") { onReveal() }
        }
    }
}
