import Foundation

enum FolderCompareMarker: String, Sendable {
    case onlyHere
    case newerHere
    case olderHere
    case different

    var title: String {
        switch self {
        case .onlyHere: "Only here"
        case .newerHere: "Newer"
        case .olderHere: "Older"
        case .different: "Different"
        }
    }

    var canSyncFromHere: Bool {
        switch self {
        case .onlyHere, .newerHere, .different:
            true
        case .olderHere:
            false
        }
    }
}

enum FolderSyncDirection {
    case leftToRight
    case rightToLeft

    var title: String {
        switch self {
        case .leftToRight: "Left to Right"
        case .rightToLeft: "Right to Left"
        }
    }
}

struct FolderCompareSummary: Sendable {
    var onlyLeft = 0
    var onlyRight = 0
    var newerLeft = 0
    var newerRight = 0
    var different = 0

    var differenceCount: Int {
        onlyLeft + onlyRight + newerLeft + newerRight + different
    }

    var title: String {
        differenceCount == 1 ? "1 difference" : "\(differenceCount) differences"
    }
}

struct FolderCompareResult: Sendable {
    let leftMarkers: [FileItem.ID: FolderCompareMarker]
    let rightMarkers: [FileItem.ID: FolderCompareMarker]
    let leftToRightSources: [URL]
    let rightToLeftSources: [URL]
    let summary: FolderCompareSummary
}

enum FolderCompare {
    private static let dateTolerance: TimeInterval = 1

    static func compare(
        leftFolder: URL,
        rightFolder: URL,
        includeHidden: Bool,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> FolderCompareResult {
        try await Task.detached(priority: .userInitiated) {
            let leftItems = try list(folder: leftFolder, includeHidden: includeHidden)
            let rightItems = try list(folder: rightFolder, includeHidden: includeHidden)
            let leftByName = Dictionary(uniqueKeysWithValues: leftItems.map { ($0.name, $0) })
            let rightByName = Dictionary(uniqueKeysWithValues: rightItems.map { ($0.name, $0) })
            let names = Set(leftByName.keys).union(rightByName.keys).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }

            var leftMarkers: [FileItem.ID: FolderCompareMarker] = [:]
            var rightMarkers: [FileItem.ID: FolderCompareMarker] = [:]
            var leftToRightSources: [URL] = []
            var rightToLeftSources: [URL] = []
            var summary = FolderCompareSummary()

            let total = max(names.count, 1)
            for (index, name) in names.enumerated() {
                try Task.checkCancellation()
                await progress(Double(index) / Double(total), name)
                let left = leftByName[name]
                let right = rightByName[name]

                switch (left, right) {
                case let (left?, nil):
                    leftMarkers[left.id] = .onlyHere
                    leftToRightSources.append(left.url)
                    summary.onlyLeft += 1
                case let (nil, right?):
                    rightMarkers[right.id] = .onlyHere
                    rightToLeftSources.append(right.url)
                    summary.onlyRight += 1
                case let (left?, right?):
                    let comparison = try compare(left: left, right: right)
                    switch comparison {
                    case .same:
                        break
                    case .leftNewer:
                        leftMarkers[left.id] = .newerHere
                        rightMarkers[right.id] = .olderHere
                        leftToRightSources.append(left.url)
                        summary.newerLeft += 1
                    case .rightNewer:
                        leftMarkers[left.id] = .olderHere
                        rightMarkers[right.id] = .newerHere
                        rightToLeftSources.append(right.url)
                        summary.newerRight += 1
                    case .different:
                        leftMarkers[left.id] = .different
                        rightMarkers[right.id] = .different
                        leftToRightSources.append(left.url)
                        rightToLeftSources.append(right.url)
                        summary.different += 1
                    }
                case (nil, nil):
                    break
                }
            }

            await progress(1, summary.title)
            return FolderCompareResult(
                leftMarkers: leftMarkers,
                rightMarkers: rightMarkers,
                leftToRightSources: leftToRightSources,
                rightToLeftSources: rightToLeftSources,
                summary: summary
            )
        }.value
    }

    private enum ItemComparison {
        case same
        case leftNewer
        case rightNewer
        case different
    }

    private struct Signature {
        var size: Int64
        var itemCount: Int
        var modified: Date
    }

    private static func compare(left: FileItem, right: FileItem) throws -> ItemComparison {
        guard left.isDirectory == right.isDirectory else {
            return .different
        }

        let leftSignature = try signature(for: left)
        let rightSignature = try signature(for: right)
        if leftSignature.size == rightSignature.size,
           leftSignature.itemCount == rightSignature.itemCount,
           abs(leftSignature.modified.timeIntervalSince(rightSignature.modified)) <= dateTolerance {
            return .same
        }

        if leftSignature.modified.timeIntervalSince(rightSignature.modified) > dateTolerance {
            return .leftNewer
        }
        if rightSignature.modified.timeIntervalSince(leftSignature.modified) > dateTolerance {
            return .rightNewer
        }
        return .different
    }

    private static func signature(for item: FileItem) throws -> Signature {
        if !item.isDirectory {
            return Signature(
                size: item.size,
                itemCount: 1,
                modified: item.modified
            )
        }

        var size: Int64 = 0
        var count = 0
        var latest = item.modified
        let enumerator = FileManager.default.enumerator(
            at: item.url,
            includingPropertiesForKeys: [
                .fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey,
            ],
            options: [.skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
            )
            if let modified = values?.contentModificationDate, modified > latest {
                latest = modified
            }
            if values?.isDirectory == true {
                count += 1
            } else if values?.isRegularFile == true {
                count += 1
                size += Int64(values?.fileSize ?? 0)
            }
        }

        return Signature(size: size, itemCount: count, modified: latest)
    }

    private static func list(folder: URL, includeHidden: Bool) throws -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: options
        )
        return urls.map { FileItem.make(url: $0) }
    }
}
