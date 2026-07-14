import Darwin
import Foundation

enum StarRatingFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all = "All Ratings"
    case unrated = "Unrated"
    case onePlus = "1 Star+"
    case twoPlus = "2 Stars+"
    case threePlus = "3 Stars+"
    case fourPlus = "4 Stars+"
    case five = "5 Stars"

    var id: String { rawValue }

    func matches(_ item: FileItem) -> Bool {
        switch self {
        case .all:
            true
        case .unrated:
            item.rating == 0
        case .onePlus:
            item.rating >= 1
        case .twoPlus:
            item.rating >= 2
        case .threePlus:
            item.rating >= 3
        case .fourPlus:
            item.rating >= 4
        case .five:
            item.rating == 5
        }
    }
}

enum FileRatingStore {
    private static let xattrName = "com.choloasis.panes.rating"
    private static let tagPrefix = "Workbench Rating "
    private static let legacyTagPrefix = "Panes Rating "

    static func rating(for url: URL, finderTags: [String]?) -> Int {
        if let xattrRating = xattrRating(for: url) {
            return xattrRating
        }
        return finderTags?.compactMap(rating(fromTag:)).first ?? 0
    }

    static func setRating(_ rating: Int, for url: URL) throws {
        let clamped = min(max(rating, 0), 5)
        try setXattrRating(clamped, for: url)
        try setFinderTagRating(clamped, for: url)
    }

    static func tagName(for rating: Int) -> String {
        "\(tagPrefix)\(rating)"
    }

    static func rating(fromTag tag: String) -> Int? {
        for prefix in [tagPrefix, legacyTagPrefix] where tag.hasPrefix(prefix) {
            let suffix = tag.dropFirst(prefix.count)
            if let value = Int(suffix), (1...5).contains(value) {
                return value
            }
        }
        return nil
    }

    private static func xattrRating(for url: URL) -> Int? {
        let length = getxattr(url.path, xattrName, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, xattrName, buffer.baseAddress, length, 0, 0)
        }
        guard read > 0 else { return nil }
        data.removeSubrange(read..<data.count)
        guard let string = String(data: data, encoding: .utf8),
              let value = Int(string),
              (0...5).contains(value) else {
            return nil
        }
        return value
    }

    private static func setXattrRating(_ rating: Int, for url: URL) throws {
        if rating == 0 {
            if removexattr(url.path, xattrName, 0) == -1, errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }

        let data = Data(String(rating).utf8)
        let result = data.withUnsafeBytes { buffer in
            setxattr(url.path, xattrName, buffer.baseAddress, data.count, 0, 0)
        }
        if result == -1 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func setFinderTagRating(_ rating: Int, for url: URL) throws {
        var tags = ((try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
            .filter { Self.rating(fromTag: $0) == nil }
        if rating > 0 {
            tags.append(tagName(for: rating))
        }
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
