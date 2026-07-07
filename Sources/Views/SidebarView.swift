import SwiftUI
import UniformTypeIdentifiers

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
                        Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc")
                            .tag(url)
                            .contextMenu {
                                Button("Remove from Favorites") {
                                    BookmarkStore.shared.remove(url)
                                }
                            }
                    }
                    // Drop a folder or file between rows to insert it there;
                    // SwiftUI draws the blue insertion line automatically.
                    .onInsert(of: [UTType.fileURL]) { index, providers in
                        insertFavorites(at: index, providers: providers)
                    }
                }
            }

            Section("Tools") {
                SidebarToolButton(
                    title: "Organize",
                    systemImage: "folder.badge.gearshape",
                    help: "Sort files in a folder into subfolders"
                ) {
                    appState.showOrganizeTool()
                }

                SidebarToolButton(
                    title: "Clean Up",
                    systemImage: "sparkles",
                    help: "Find large, old, and unused files"
                ) {
                    appState.showCleanupTool()
                }

                SidebarToolButton(
                    title: "Clipboard History",
                    systemImage: "clipboard",
                    help: "Open clipboard history"
                ) {
                    appState.showClipboardHistory()
                }

                SidebarToolButton(
                    title: "Notes",
                    systemImage: "note.text",
                    help: "Open notes"
                ) {
                    appState.showNotes()
                }

                SidebarToolButton(
                    title: "Screenshot",
                    systemImage: "camera.viewfinder",
                    help: "Capture a screenshot"
                ) {
                    appState.beginScreenshotCapture()
                }

                SidebarToolButton(
                    title: "Screen Recording",
                    systemImage: "record.circle",
                    help: "Record the screen"
                ) {
                    appState.beginScreenRecording()
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
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    appState.showNewFolderPrompt = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New folder in the active pane (⇧⌘N)")

                Button {
                    if let granted = BookmarkStore.shared.requestAccess(
                        startingAt: appState.activePane.currentURL
                    ) {
                        selection = granted
                        appState.activePane.navigate(to: granted)
                    }
                } label: {
                    Label("Pin to Favorites…", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a folder to the sidebar favorites")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: selection) { _, url in
            guard let url else { return }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && !isDirectory.boolValue {
                // File favorite: reveal it inside its enclosing folder.
                appState.activePane.navigate(to: url.deletingLastPathComponent())
            } else {
                appState.activePane.navigate(to: url)
            }
        }
    }

    private func insertFavorites(at index: Int, providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    ?? (item as? URL)
                guard let resolved = url else { return }
                Task { @MainActor in
                    BookmarkStore.shared.insert(resolved, at: index)
                }
            }
        }
    }
}

private struct SidebarToolButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(help)
    }
}
