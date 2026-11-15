import Foundation

/// Build-time identification is separate from the public release version. This
/// resource is generated in the app bundle before signing, never at launch.
struct WorkbenchBuildMetadata: Codable, Equatable, Sendable {
    let identifier: String
    let builtAt: String
    let revision: String
    let hasUncommittedChanges: Bool
    let configuration: String

    static func load(from bundle: Bundle) -> WorkbenchBuildMetadata? {
        guard let url = bundle.url(forResource: "WorkbenchBuildMetadata", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    static func decode(_ data: Data) throws -> WorkbenchBuildMetadata {
        try PropertyListDecoder().decode(Self.self, from: data)
    }

    var date: Date? {
        ISO8601DateFormatter().date(from: builtAt)
    }

    var dateText: String {
        guard let date else { return builtAt }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    var sourceText: String {
        hasUncommittedChanges ? "\(revision) · modified sources" : revision
    }
}
