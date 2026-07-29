import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

/// Temporary diagnostics for the drag-to-folder path. Read with:
///   log show --predicate 'subsystem == "com.qnsub.workbench"' --last 10m --info
enum DragDropLog {
    private static let logger = Logger(subsystem: "com.qnsub.workbench", category: "dragdrop")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}

/// Builds one stable drag representation for every filesystem item. Creating an
/// `NSItemProvider(contentsOf:)` makes its primary representation depend on the
/// file's content type; SwiftUI can then omit the app's custom marker when it
/// bridges image, archive, audio, and video providers through a drop.
enum FileDragItemProvider {
    static func make(
        url: URL,
        suggestedName: String,
        sessionID: String,
        internalTypeIdentifier: String
    ) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = suggestedName
        provider.registerDataRepresentation(
            forTypeIdentifier: internalTypeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(sessionID.utf8), nil)
            return nil
        }
        return provider
    }

    static func containsInternalMarker(
        _ providers: [NSItemProvider],
        typeIdentifier: String
    ) -> Bool {
        providers.contains { provider in
            // The marker is an exact, app-owned type. UTType conformance checks
            // are unreliable here for several system content representations.
            provider.registeredTypeIdentifiers.contains(typeIdentifier)
        }
    }
}

extension View {
    func fileDragSource(_ item: FileItem, paneIndex: Int, appState: AppState) -> some View {
        onDrag {
            appState.fileDragProvider(for: item, paneIndex: paneIndex)
        }
    }

    func fileDropTarget(
        to destination: URL,
        paneIndex: Int,
        appState: AppState,
        isEnabled: Bool = true,
        showsIndicator: Bool = true,
        destinationResolver: ((CGPoint) -> URL?)? = nil,
        onTargetedDestinationChange: ((URL?) -> Void)? = nil
    ) -> some View {
        modifier(FileDropTargetModifier(
            destination: destination,
            paneIndex: paneIndex,
            appState: appState,
            isEnabled: isEnabled,
            showsIndicator: showsIndicator,
            destinationResolver: destinationResolver,
            onTargetedDestinationChange: onTargetedDestinationChange
        ))
    }

    func fileDropHoverAppearance(isTargeted: Bool, cornerRadius: CGFloat = 7) -> some View {
        modifier(FileDropHoverAppearanceModifier(
            isTargeted: isTargeted,
            cornerRadius: cornerRadius
        ))
    }
}

private struct FileDropHoverAppearanceModifier: ViewModifier {
    let isTargeted: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.16) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            isTargeted ? Color.accentColor.opacity(0.95) : Color.clear,
                            lineWidth: 2.5
                        )
                }
                .shadow(
                    color: isTargeted ? Color.accentColor.opacity(0.28) : Color.clear,
                    radius: 4
                )
                .padding(1)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: isTargeted)
        }
    }
}

private struct FileDropTargetModifier: ViewModifier {
    let destination: URL
    let paneIndex: Int
    let appState: AppState
    let isEnabled: Bool
    let showsIndicator: Bool
    let destinationResolver: ((CGPoint) -> URL?)?
    let onTargetedDestinationChange: ((URL?) -> Void)?
    @State private var isTargeted = false
    @State private var targetID = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .fileDropHoverAppearance(isTargeted: showsIndicator && isTargeted)
                .onDrop(
                    of: [AppState.internalFileDragType, .fileURL],
                    delegate: FileDropTargetDelegate(
                        destination: destination,
                        paneIndex: paneIndex,
                        appState: appState,
                        targetID: targetID,
                        isTargeted: $isTargeted,
                        destinationResolver: destinationResolver,
                        onTargetedDestinationChange: onTargetedDestinationChange
                    )
                )
                .onChange(of: isTargeted) { _, isTargeted in
                    appState.updateFileDropTarget(
                        id: targetID,
                        destination: destination,
                        isTargeted: isTargeted
                    )
                }
                .onDisappear {
                    appState.updateFileDropTarget(
                        id: targetID,
                        destination: destination,
                        isTargeted: false
                    )
                    onTargetedDestinationChange?(nil)
                }
        } else {
            content
        }
    }
}

private struct FileDropTargetDelegate: DropDelegate {
    let destination: URL
    let paneIndex: Int
    let appState: AppState
    let targetID: UUID
    @Binding var isTargeted: Bool
    let destinationResolver: ((CGPoint) -> URL?)?
    let onTargetedDestinationChange: ((URL?) -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [AppState.internalFileDragType, .fileURL]).isEmpty
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        onTargetedDestinationChange?(targetedDestination(at: info.location))
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        onTargetedDestinationChange?(nil)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onTargetedDestinationChange?(targetedDestination(at: info.location))
        let providers = info.itemProviders(
            for: [AppState.internalFileDragType, .fileURL]
        )
        let isInternal = appState.hasCurrentFileDragSession
            && FileDragItemProvider.containsInternalMarker(
                providers,
                typeIdentifier: AppState.internalFileDragType.identifier
            )
        return DropProposal(operation: FileDropOperationPolicy.shouldMove(
            isInternalDrag: isInternal,
            modifiers: NSEvent.modifierFlags
        ) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        onTargetedDestinationChange?(nil)
        let providers = info.itemProviders(for: [AppState.internalFileDragType, .fileURL])
        guard !providers.isEmpty else { return false }
        return handleDrop(providers, at: info.location)
    }

    private func handleDrop(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        let resolvedDestination = resolvedDestination(at: point)
        let hasInternalMarker = FileDragItemProvider.containsInternalMarker(
            providers,
            typeIdentifier: AppState.internalFileDragType.identifier
        )
        let isInternal = hasInternalMarker && appState.hasCurrentFileDragSession
        let providerTypes = Set(providers.flatMap(\.registeredTypeIdentifiers)).sorted()
        DragDropLog.log(
            "HANDLE_DROP providers=\(providers.count) internal=\(isInternal) "
                + "marker=\(hasInternalMarker) types=\(providerTypes) "
                + "target=\(destination.lastPathComponent) "
                + "resolver=\(destinationResolver == nil ? "none" : resolvedDestination.lastPathComponent) "
                + "final=\(resolvedDestination.lastPathComponent) "
                + "hasSession=\(appState.hasCurrentFileDragSession)"
        )
        if isInternal {
            return appState.dropCurrentFileDrag(
                to: resolvedDestination,
                paneIndex: paneIndex
            )
        }

        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let collector = FileDropURLCollector()
        let group = DispatchGroup()
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                if let url = FileDropPayload.fileURL(from: item) {
                    collector.insert(url.standardizedFileURL, at: index)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let urls = collector.urls
            guard !urls.isEmpty else {
                appState.lastError = "No usable files were dropped."
                return
            }
            _ = appState.drop(
                urls,
                to: resolvedDestination,
                paneIndex: paneIndex
            )
        }
        return true
    }

    private func resolvedDestination(at point: CGPoint) -> URL {
        if let destinationResolver {
            // A resolver owns the whole drop surface and is authoritative for
            // the pointer's final location. Mixing its answer with transient
            // nested onDrop state can redirect a folder drop to its parent.
            return destinationResolver(point) ?? destination
        }
        return appState.preferredFileDropDestination(fallback: destination)
    }

    private func targetedDestination(at point: CGPoint) -> URL {
        destinationResolver?(point) ?? destination
    }
}

enum FileDropDestinationPolicy {
    static func preferredDestination(fallback: URL, activeDestinations: [URL]) -> URL {
        let fallback = fallback.standardizedFileURL
        return activeDestinations
            .map(\.standardizedFileURL)
            .filter { isSameOrDescendant($0, of: fallback) }
            .max { pathDepth($0) < pathDepth($1) }
            ?? fallback
    }

    private static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let ancestorComponents = ancestor.pathComponents
        guard candidateComponents.count >= ancestorComponents.count else { return false }
        return candidateComponents.prefix(ancestorComponents.count).elementsEqual(ancestorComponents)
    }

    private static func pathDepth(_ url: URL) -> Int {
        url.pathComponents.count
    }
}

enum FileDropHighlightPolicy {
    static func visibleFolder(destination: URL?, folders: [URL]) -> URL? {
        guard let destination else { return nil }
        let standardizedDestination = destination.standardizedFileURL
        return folders.first {
            $0.standardizedFileURL == standardizedDestination
        }
    }
}

enum FileDropPayload {
    nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let value = item as? URL {
            url = value
        } else if let value = item as? NSURL {
            url = value as URL
        } else if let value = item as? String {
            url = URL(string: value)
        } else if let value = item as? NSString {
            url = URL(string: value as String)
        } else {
            url = nil
        }
        return url?.isFileURL == true ? url : nil
    }
}

private final class FileDropURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: URL] = [:]

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return entries.sorted { $0.key < $1.key }.map(\.value)
    }

    func insert(_ url: URL, at index: Int) {
        lock.lock()
        entries[index] = url
        lock.unlock()
    }
}
