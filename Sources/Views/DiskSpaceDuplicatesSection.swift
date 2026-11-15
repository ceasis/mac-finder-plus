import SwiftUI

struct DiskSpaceDuplicatesSection: View {
    @Environment(AppState.self) private var appState
    let analysis: DiskSpaceAnalysis
    let isBusy: Bool
    let reveal: (DiskSpaceDuplicateFile) -> Void

    @State private var expandedGroupIDs: Set<String> = []
    @State private var lastActivityID: UUID?
    @State private var completionMessage = ""
    @State private var isUndoing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Duplicates", systemImage: "doc.on.doc").font(.headline)
                Spacer(minLength: 8)
                Text("Exact content matches").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                metric("Potential Savings", analysis.duplicatePotentialSavingsText)
                metric("Groups", analysis.duplicateGroupCount.formatted())
                metric("Files", analysis.duplicateFileCount.formatted())
            }
            if !completionMessage.isEmpty {
                HStack {
                    Text(completionMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let id = lastActivityID, appState.canUndoActivity(id) {
                        Button {
                            isUndoing = true
                            completionMessage = "Restoring copies…"
                            appState.undoActivity(id) { succeeded in
                                isUndoing = false
                                completionMessage = succeeded
                                    ? "Copies restored. Analyze again to refresh this snapshot."
                                    : "Could not restore all copies. Check Activity History, then retry Undo."
                            }
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isBusy || isUndoing)
                        .help("Restore the copies moved to Trash; analyze again to refresh this snapshot")
                    }
                }
            }
            Divider()
            if analysis.duplicateGroups.isEmpty {
                ContentUnavailableView(
                    "No Duplicate Savings Found", systemImage: "doc.on.doc",
                    description: Text("Workbench checks exact file matches 100 KB and larger.")
                )
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(analysis.duplicateGroups) { group in
                        DiskSpaceDuplicateReviewRow(
                            group: group,
                            isExpanded: expandedGroupIDs.contains(group.id),
                            isBusy: isBusy || isUndoing,
                            toggleExpansion: {
                                if !expandedGroupIDs.insert(group.id).inserted { expandedGroupIDs.remove(group.id) }
                            },
                            reveal: reveal,
                            trash: { selection in
                                appState.trashDiskSpaceDuplicates(
                                    group: group, keeperPath: selection.keeperPath,
                                    selectedPaths: selection.selectedPaths
                                ) { id, paths in
                                    lastActivityID = id
                                    completionMessage = paths.isEmpty
                                        ? "No copies moved. Check Activity History for details."
                                        : "\(paths.count) copies moved to Trash. Disk space is freed only after Trash is emptied."
                                }
                            }
                        )
                        Divider()
                    }
                }
            }
            Text("Review each group, choose the copy to keep, then select extras to trash. System files are protected. Savings are estimates; disk usage is a snapshot.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.16), lineWidth: 1) }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.body.weight(.semibold)).lineLimit(1)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct DiskSpaceDuplicateReviewRow: View {
    let group: DiskSpaceDuplicateGroup
    let isExpanded: Bool
    let isBusy: Bool
    let toggleExpansion: () -> Void
    let reveal: (DiskSpaceDuplicateFile) -> Void
    let trash: (DiskSpaceDuplicateSelection) -> Void
    @State private var selection: DiskSpaceDuplicateSelection

    init(group: DiskSpaceDuplicateGroup, isExpanded: Bool, isBusy: Bool,
         toggleExpansion: @escaping () -> Void,
         reveal: @escaping (DiskSpaceDuplicateFile) -> Void,
         trash: @escaping (DiskSpaceDuplicateSelection) -> Void) {
        self.group = group
        self.isExpanded = isExpanded
        self.isBusy = isBusy
        self.toggleExpansion = toggleExpansion
        self.reveal = reveal
        self.trash = trash
        _selection = State(initialValue: DiskSpaceDuplicateSelection(group: group))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggleExpansion) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12)
                    Image(systemName: "doc.on.doc.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.representativeName).font(.subheadline.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(group.fileCount) copies · \(group.duplicateSizeText) each · Review copies")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(group.potentialSavingsText).font(.subheadline.monospacedDigit())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(group.files) { file in
                    fileRow(file)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { selectionButtons; Spacer(minLength: 8); trashButton }
                    VStack(alignment: .leading, spacing: 8) { selectionButtons; trashButton }
                }
                Text("The kept copy and selected copies are rechecked before moving. Restore them with Undo or Activity History.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .onChange(of: group.files.map(\.path)) { _, _ in selection = DiskSpaceDuplicateSelection(group: group) }
    }

    private func fileRow(_ file: DiskSpaceDuplicateFile) -> some View {
        HStack(spacing: 8) {
            Button { selection.keep(file.path, in: group) } label: {
                Image(systemName: selection.keeperPath == file.path ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.keeperPath == file.path ? Color.green : Color.secondary)
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.plain).disabled(isBusy)
            .accessibilityLabel("Keep \(file.path)")
            .help(selection.keeperPath == file.path ? "This copy will be kept" : "Keep this copy instead")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if selection.keeperPath == file.path { Text("Keep").font(.caption2.weight(.semibold)).foregroundStyle(.green) }
                    if file.isSystemItem { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("System file — protected") }
                }
                Text(file.parentPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading).help(file.path)

            Toggle("Trash", isOn: Binding(
                get: { selection.selectedPaths.contains(file.path) },
                set: { selection.select(file.path, selected: $0, in: group) }
            ))
            .toggleStyle(.checkbox).font(.caption)
            .disabled(isBusy || selection.keeperPath == file.path || file.isSystemItem)
            .accessibilityLabel("Select \(file.path) for Trash")

            Button { reveal(file) } label: { Image(systemName: "finder") }
                .buttonStyle(.bordered).controlSize(.small).help("Reveal \(file.name) in Finder")
        }
    }

    private var selectionButtons: some View {
        HStack(spacing: 10) {
            Button("Select Extras") { selection.selectExtras(in: group) }
            Button("Clear") { selection.clear() }.disabled(selection.selectedPaths.isEmpty)
        }
        .controlSize(.small).disabled(isBusy)
    }

    private var trashButton: some View {
        Button(role: .destructive) { trash(selection) } label: {
            Label("Trash Selected (\(selection.selectedPaths.count))", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(isBusy || selection.selectedPaths.isEmpty)
    }
}
