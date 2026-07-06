import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let pane = appState.activePane
        HStack(spacing: 4) {
            Text(
                pane.isDuplicateResultsActive
                    ? "\(pane.displayItems.count) duplicates"
                    : pane.isRecursiveSearchActive
                    ? "\(pane.displayItems.count) results"
                    : "\(pane.displayItems.count) items"
            )
            if !pane.selection.isEmpty {
                Text("· \(pane.selection.count) selected")
            }
            if pane.isSearching {
                Text("· searching…")
            }
            if let compareTitle = pane.compareTitle {
                Text("· \(compareTitle)")
            }
            if pane.isCalculatingFolderSizes {
                Text("· calculating sizes…")
            }
            if pane.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
            }
            if pane.isCalculatingFolderSizes {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
            }
            Spacer()
            if let free = pane.freeSpaceText {
                Text("\(free) available")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
