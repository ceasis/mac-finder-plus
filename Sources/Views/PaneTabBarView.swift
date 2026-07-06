import SwiftUI

struct PaneTabBarView: View {
    let model: PaneModel
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(model.tabs) { tab in
                        tabView(tab)
                    }
                }
                .padding(.leading, 6)
            }
            .defaultScrollAnchor(.trailing)

            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .padding(.trailing, 6)
        }
        .font(.caption)
        .frame(height: 28)
        .background(.bar)
    }

    private func tabView(_ tab: PaneTab) -> some View {
        let selected = tab.id == model.activeTabID
        return HStack(spacing: 4) {
            Button {
                model.selectTab(tab.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 130, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.tabs.count > 1 {
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, model.tabs.count > 1 ? 4 : 7)
        .padding(.vertical, 4)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background(
            selected ? Color.accentColor.opacity(isActive ? 0.18 : 0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    selected
                        ? Color.accentColor.opacity(0.35)
                        : Color(nsColor: .separatorColor).opacity(0.45)
                )
        }
        .contextMenu {
            Button("New Tab") { model.newTab() }
            Button("Close Tab") { model.closeTab(tab.id) }
                .disabled(model.tabs.count <= 1)
            Divider()
            Button("Show Tab") { model.selectTab(tab.id) }
        }
    }
}
