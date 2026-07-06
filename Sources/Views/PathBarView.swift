import SwiftUI

/// Back/forward/up controls, clickable breadcrumbs, and the per-pane search field.
struct PathBarView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: PaneModel
    let isActive: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("Back (⌘[)")

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .help("Forward (⌘])")

            Button {
                model.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!model.canGoUp)
            .help("Enclosing Folder (⌘↑)")

            Divider().frame(height: 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(breadcrumbs, id: \.self) { crumb in
                        Button {
                            model.navigate(to: crumb)
                        } label: {
                            Text(displayName(for: crumb))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            crumb == model.currentURL ? .primary : .secondary
                        )
                        if crumb != breadcrumbs.last {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)

            if let title = model.duplicateResultsTitle {
                HStack(spacing: 4) {
                    Label(title, systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    Button {
                        model.clearDuplicateResults()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear duplicate results")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            if let title = model.compareTitle {
                HStack(spacing: 4) {
                    Label(title, systemImage: "rectangle.split.2x1")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    Button {
                        model.clearCompare()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear folder compare")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            Spacer(minLength: 8)

            Picker("View", selection: $model.viewMode) {
                ForEach(PaneViewMode.allCases) { mode in
                    Image(systemName: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("List or icon view (⌘1 / ⌘2)")

            HStack(spacing: 4) {
                Menu {
                    Picker("Type", selection: $model.typePreset) {
                        ForEach(FileTypePreset.allCases) { preset in
                            Label(preset.rawValue, systemImage: preset.systemImage)
                                .tag(preset)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("Rating", selection: $model.ratingFilter) {
                        ForEach(StarRatingFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Include Subfolders", isOn: $model.searchSubfolders)
                } label: {
                    Image(systemName: filtersActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(filtersActive ? Color.accentColor : Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("File type preset and search scope")

                TextField(model.searchSubfolders ? "Search" : "Filter", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand {
                        model.filterText = ""
                        searchFocused = false
                    }

                if model.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                } else if !model.filterText.isEmpty {
                    Button {
                        model.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(width: 195)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: appState.searchFocusTick) { _, _ in
            if isActive { searchFocused = true }
        }
    }

    private var filtersActive: Bool {
        model.typePreset != .all || model.ratingFilter != .all || model.searchSubfolders
    }

    private var breadcrumbs: [URL] {
        var chain: [URL] = []
        var url = model.currentURL.standardizedFileURL
        while true {
            chain.append(url)
            if url.path == "/" { break }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path { break }
            url = parent
        }
        return chain.reversed()
    }

    private func displayName(for url: URL) -> String {
        url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }
}
