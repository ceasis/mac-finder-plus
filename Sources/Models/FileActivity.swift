import Foundation

enum FileConflictPolicy: String, CaseIterable, Identifiable {
    case keepBoth
    case replace
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepBoth: "Keep Both"
        case .replace: "Replace"
        case .skip: "Skip"
        }
    }
}

enum FileActivityStatus: Equatable {
    case queued
    case running
    case paused
    case completed
    case cancelled
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            return true
        case .queued, .running, .paused:
            return false
        }
    }
}

struct FileActivity: Identifiable, Equatable {
    let id: UUID
    var title: String
    var detail: String
    var bytesCompleted: Int64
    var bytesTotal: Int64
    var status: FileActivityStatus
    var startedAt: Date
    var finishedAt: Date?
    var conflictPolicy: FileConflictPolicy
    var supportsConflictPolicy: Bool
    var progressDetail: String?

    var progress: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(max(Double(bytesCompleted) / Double(bytesTotal), 0), 1)
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    var speedText: String? {
        guard bytesCompleted > 0 else { return nil }
        let end = finishedAt ?? Date()
        let elapsed = max(end.timeIntervalSince(startedAt), 0.1)
        let bytesPerSecond = Int64(Double(bytesCompleted) / elapsed)
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
    }
}

struct FileMoveRecord: Equatable {
    let source: URL
    let destination: URL
}

struct FileTrashRecord: Equatable {
    let originalURL: URL
    let trashedURL: URL
}

enum FileUndoAction: Equatable {
    case moveBack(title: String, records: [FileMoveRecord])
    case putBack(title: String, records: [FileTrashRecord])

    var title: String {
        switch self {
        case let .moveBack(title, _), let .putBack(title, _):
            return title
        }
    }
}
