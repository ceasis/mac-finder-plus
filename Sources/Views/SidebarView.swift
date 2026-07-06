import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: URL?

    private struct Place: Identifiable {
        let name: String
        let icon: String
        let url: URL
        var id: URL { url }
    }

    private var places: [Place] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result = [Place(name: "Home", icon: "house", url: home)]
        let standard: [(String, String, FileManager.SearchPathDirectory)] = [
            ("Desktop", "menubar.dock.rectangle", .desktopDirectory),
            ("Documents", "doc", .documentDirectory),
            ("Downloads", "arrow.down.circle", .downloadsDirectory),
        ]
        for (name, icon, directory) in standard {
            if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
                result.append(Place(name: name, icon: icon, url: url))
            }
        }
        return result
    }

    var body: some View {
        List(selection: $selection) {
            Section("Places") {
                ForEach(places) { place in
                    Label(place.name, systemImage: place.icon)
                        .tag(place.url)
                }
            }
            let favorites = BookmarkStore.shared.grantedURLs
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "folder")
                            .tag(url)
                            .contextMenu {
                                Button("Remove from Favorites") {
                                    BookmarkStore.shared.remove(url)
                                }
                            }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Dropping a folder pins it as a favorite. Drops from Finder also
            // extend the sandbox to that folder, so save the bookmark right away.
            let folders = urls.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            guard !folders.isEmpty else { return false }
            for folder in folders {
                BookmarkStore.shared.save(folder)
            }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if let granted = BookmarkStore.shared.requestAccess(startingAt: nil) {
                    appState.activePane.navigate(to: granted)
                }
            } label: {
                Label("Add Folder…", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: selection) { _, url in
            guard let url else { return }
            appState.activePane.navigate(to: url)
        }
    }
}
