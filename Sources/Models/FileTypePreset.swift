import Foundation
import UniformTypeIdentifiers

/// Quick file-type scopes used by both the browse filter and recursive search.
enum FileTypePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case all = "All"
    case images = "Images"
    case videos = "Videos"
    case audio = "Audio"
    case documents = "Documents"
    case archives = "Archives"
    case folders = "Folders"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .images: "photo"
        case .videos: "film"
        case .audio: "music.note"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .folders: "folder"
        }
    }

    func matches(_ item: FileItem) -> Bool {
        switch self {
        case .all:
            return true
        case .folders:
            return item.isDirectory
        case .images:
            return item.isImage
        case .videos:
            guard let type = item.contentType else { return false }
            return type.conforms(to: .movie) || type.conforms(to: .video)
        case .audio:
            return item.contentType?.conforms(to: .audio) == true
        case .archives:
            return item.contentType?.conforms(to: .archive) == true
        case .documents:
            guard !item.isDirectory, let type = item.contentType else { return false }
            let documentTypes: [UTType] = [.text, .pdf, .rtf, .spreadsheet, .presentation]
            return documentTypes.contains { type.conforms(to: $0) }
        }
    }
}
