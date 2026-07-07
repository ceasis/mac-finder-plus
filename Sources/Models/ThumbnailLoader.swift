import AppKit
import QuickLookThumbnailing

/// Generates and caches Quick Look thumbnails for the icon grid.
/// Cache keys include the modification date so edited files refresh.
enum ThumbnailLoader {
    // NSCache is internally thread-safe; safe as shared concurrency state.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for item: FileItem, pixelSize: CGFloat) async -> NSImage? {
        let key = "\(item.url.path)|\(item.modified.timeIntervalSince1970)|\(Int(pixelSize))"
            as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: 2,
            representationTypes: .all
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}
