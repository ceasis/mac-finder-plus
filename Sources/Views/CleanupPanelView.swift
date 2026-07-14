import AppKit
import SwiftUI

struct CleanupPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = CleanupStore.shared

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            scopeControls
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        .background(.bar)
        .alert("Clean Up Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Clean Up", systemImage: "sparkles")
                .font(.headline)

            Spacer()

            if store.isScanning {
                PanelIconButton(systemName: "stop.circle", help: "Stop scan") {
                    store.cancelScan()
                }
            } else {
                PanelIconButton(systemName: "arrow.clockwise", help: "Scan again") {
                    store.startScan(activeFolder: appState.activePane.currentURL)
                }
            }

            PanelIconButton(systemName: "xmark", help: "Hide Clean Up") {
                appState.hideCleanupTool()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var scopeControls: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Scan", selection: $store.scanScope) {
                ForEach(CleanupScanScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isScanning)

            if store.isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: store.scanProgress)
                    Text(store.scanDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if let scannedAt = store.lastScannedAt {
                Text(store.scanDetail.isEmpty
                    ? "Last scan \(scannedAt.formatted(date: .abbreviated, time: .shortened))"
                    : store.scanDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                Text("Scan for large files, stale downloads, empty folders, and more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                store.startScan(activeFolder: appState.activePane.currentURL)
            } label: {
                Label(store.isScanning ? "Scanning…" : "Scan Now", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(store.isScanning)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if store.categories.isEmpty && !store.isScanning {
            ContentUnavailableView(
                "No Suggestions Yet",
                systemImage: "sparkles",
                description: Text("Choose a location and run a scan to see cleanup ideas.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.categories) { category in
                    Section {
                        ForEach(category.suggestions) { suggestion in
                            CleanupSuggestionRow(
                                suggestion: suggestion,
                                isSelected: store.selectedSuggestionIDs.contains(suggestion.id)
                            ) {
                                store.toggleSelection(for: suggestion)
                            } primaryAction: {
                                reveal(suggestion)
                            }
                        }
                    } header: {
                        CleanupCategoryHeader(
                            category: category,
                            selectedCount: selectedCount(in: category),
                            onSelectAll: {
                                store.setSelection(for: category.suggestions, selected: true)
                            },
                            onClear: {
                                store.setSelection(for: category.suggestions, selected: false)
                            }
                        )
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
                Text(selectionSummary)
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
            Text(selectionSummary)
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
                revealSelected()
            }
            .disabled(store.selectedSuggestions.isEmpty)

            Button("Trash") {
                trashSelected()
            }
            .disabled(store.selectedSuggestions.isEmpty)
        }
    }

    private var selectionSummary: String {
        let selected = store.selectedSuggestions
        guard !selected.isEmpty else {
            return store.totalSuggestionCount == 0
                ? "No items"
                : "\(store.totalSuggestionCount) suggestions"
        }
        let bytes = selected.reduce(Int64(0)) { $0 + max($1.size, 0) }
        let sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(selected.count) selected · \(sizeText)"
    }

    private func selectedCount(in category: CleanupCategorySummary) -> Int {
        category.suggestions.filter { store.selectedSuggestionIDs.contains($0.id) }.count
    }

    private func reveal(_ suggestion: CleanupSuggestion) {
        NSWorkspace.shared.activateFileViewerSelecting([suggestion.url])
    }

    private func revealSelected() {
        let urls = store.selectedSuggestions.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func trashSelected() {
        let suggestions = store.selectedSuggestions
        guard !suggestions.isEmpty else { return }
        let ids = Set(suggestions.map(\.id))
        appState.trashCleanupSuggestions(suggestions) {
            store.removeSuggestions(withIDs: ids)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}

private struct CleanupCategoryHeader: View {
    let category: CleanupCategorySummary
    let selectedCount: Int
    let onSelectAll: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(category.kind.title, systemImage: category.kind.systemImage)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Text(category.totalBytesText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Menu {
                Button("Select All") { onSelectAll() }
                Button("Clear Selection") { onClear() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
        }
        .help(category.kind.detail)
        .overlay(alignment: .bottomLeading) {
            if selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(y: 14)
            }
        }
    }
}

private struct CleanupSuggestionRow: View {
    let suggestion: CleanupSuggestion
    let isSelected: Bool
    let onToggle: () -> Void
    let primaryAction: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.body)
                        .lineLimit(1)
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(suggestion.sizeText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") { primaryAction() }
            Button(isSelected ? "Deselect" : "Select") { onToggle() }
        }
    }
}
