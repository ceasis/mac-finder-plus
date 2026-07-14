import SwiftUI

struct AdvancedSearchPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = AdvancedSearchStore.shared
    @State private var saveName = ""

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            panelHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    querySection(store: store)
                    filterSection(store: store)
                    savedSearchSection(store: store)
                    resultsSection(store: store)
                }
                .padding(14)
            }

            Divider()
            actionBar
        }
        .onChange(of: store.lastError) { _, error in
            if let error {
                appState.lastError = error
                store.lastError = nil
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced Search")
                    .font(.headline)
                Text(store.progressDetail.isEmpty ? "Build precise file searches" : store.progressDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            PanelIconButton(systemName: "sidebar.right", help: "Hide Advanced Search") {
                appState.hideAdvancedSearch()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func querySection(store: AdvancedSearchStore) -> some View {
        @Bindable var store = store

        return VStack(alignment: .leading, spacing: 9) {
            Text("Query")
                .font(.headline)

            TextField("Name, contents, tag, or archive entry", text: $store.options.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(runSearch)

            HStack {
                Picker("Match", selection: $store.options.matchMode) {
                    ForEach(AdvancedSearchMatchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Toggle("Case Sensitive", isOn: $store.options.caseSensitive)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Toggle("Contents", isOn: $store.options.searchContents)
                    Toggle("Archives", isOn: $store.options.searchArchives)
                }
                GridRow {
                    Toggle("Subfolders", isOn: $store.options.includeSubfolders)
                    Toggle("Hidden", isOn: $store.options.includeHidden)
                }
            }
            .toggleStyle(.checkbox)

            TextField("Finder tag contains", text: $store.options.tagQuery)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func filterSection(store: AdvancedSearchStore) -> some View {
        @Bindable var store = store

        return VStack(alignment: .leading, spacing: 9) {
            Text("Filters")
                .font(.headline)

            Picker("Scope", selection: $store.options.scope) {
                ForEach(AdvancedSearchScope.allCases) { scope in
                    Label(scope.rawValue, systemImage: scope.systemImage).tag(scope)
                }
            }

            Picker("Type", selection: $store.options.typePreset) {
                ForEach(FileTypePreset.allCases) { preset in
                    Label(preset.rawValue, systemImage: preset.systemImage).tag(preset)
                }
            }

            Picker("Kind", selection: $store.options.itemKindFilter) {
                ForEach(ItemKindFilter.allCases) { filter in
                    Text(filter.helpText).tag(filter)
                }
            }

            Picker("Rating", selection: $store.options.ratingFilter) {
                ForEach(StarRatingFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }

            Picker("Modified", selection: $store.options.modifiedDateFilter) {
                ForEach(ModifiedDateFilter.allCases) { filter in
                    Text(filter.helpText).tag(filter)
                }
            }

            Picker("Size", selection: $store.options.fileSizeFilter) {
                ForEach(FileSizeFilter.allCases) { filter in
                    Text(filter.helpText).tag(filter)
                }
            }
        }
    }

    private func savedSearchSection(store: AdvancedSearchStore) -> some View {
        @Bindable var store = store

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Saved Searches")
                    .font(.headline)
                Spacer()
                if !store.savedSearches.isEmpty {
                    Menu {
                        ForEach(store.savedSearches) { saved in
                            Button(saved.name) {
                                store.applySavedSearch(saved)
                            }
                        }
                    } label: {
                        Label("Load", systemImage: "folder")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }

            HStack(spacing: 8) {
                TextField("Save current search as", text: $saveName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    store.saveCurrentSearch(named: saveName)
                    saveName = ""
                }
                .disabled(saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.options.hasSearchCriteria)
            }

            if let selected = store.savedSearches.first(where: { $0.id == store.selectedSavedSearchID }) {
                HStack {
                    Label(selected.name, systemImage: "bookmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete") {
                        store.deleteSavedSearch(selected)
                    }
                }
            }
        }
    }

    private func resultsSection(store: AdvancedSearchStore) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Results")
                    .font(.headline)
                Spacer()
                Text("\(store.results.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if store.isSearching {
                ProgressView(store.progressDetail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if store.results.isEmpty {
                if store.hasRunSearch {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("Broaden the query or remove a filter.")
                    )
                    .frame(height: 150)
                } else {
                    ContentUnavailableView(
                        "Ready to Search",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Add a query or filter to search the selected scope.")
                    )
                    .frame(height: 150)
                }
            } else {
                SearchResultList(
                    results: store.results,
                    selectedResultID: Binding(
                        get: { store.selectedResultID },
                        set: { store.selectedResultID = $0 }
                    )
                )
                .frame(minHeight: 220)
            }
        }
    }

    private var actionBar: some View {
        AdaptiveActionBar {
            Button {
                runSearch()
            } label: {
                if store.isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canRunSearch)
            .help(store.options.hasSearchCriteria ? "Run advanced search" : "Add a query or filter first")

            Button("Cancel") {
                store.cancel()
            }
            .disabled(!store.isSearching)

            Button("Reset") {
                store.resetOptions()
                saveName = ""
            }
            .disabled(store.isSearching)

            Button("Clear") {
                store.clearResults()
            }
            .disabled(store.results.isEmpty && !store.hasRunSearch)
        } trailing: {
            Button {
                openSelectedResult()
            } label: {
                Label("Open", systemImage: "arrow.down.right.square")
            }
            .disabled(store.selectedResult == nil)

            Button {
                appState.publishAdvancedSearchResultsToActivePane()
            } label: {
                Label("Show in Pane", systemImage: "list.bullet.rectangle")
            }
            .disabled(store.results.isEmpty)
        }
        .padding(12)
    }

    private func openSelectedResult() {
        guard let item = store.selectedResult?.item else { return }
        if item.isDirectory {
            appState.activePane.navigate(to: item.url)
        } else {
            appState.activePane.navigate(to: item.url.deletingLastPathComponent())
            appState.activePane.selection = [item.id]
        }
    }

    private func runSearch() {
        guard store.canRunSearch else { return }
        store.run(activeFolder: appState.activePane.currentURL)
    }
}

private struct SearchResultList: View {
    let results: [AdvancedSearchResult]
    @Binding var selectedResultID: AdvancedSearchResult.ID?

    var body: some View {
        List(selection: $selectedResultID) {
            ForEach(results) { result in
                SearchResultRow(result: result)
                    .tag(result.id)
            }
        }
        .listStyle(.inset)
    }
}

private struct SearchResultRow: View {
    let result: AdvancedSearchResult

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: result.item.icon)
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.item.name)
                    .lineLimit(1)
                Text(result.matchDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(result.item.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(result.item.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
