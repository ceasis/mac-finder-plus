import Foundation
import Observation

enum DiskSpaceContentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case documents
    case video
    case images
    case audio
    case archives
    case apps
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: "Documents"
        case .video: "Video"
        case .images: "Images"
        case .audio: "Audio"
        case .archives: "Archives"
        case .apps: "Apps"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .documents: "doc.text"
        case .video: "film"
        case .images: "photo"
        case .audio: "waveform"
        case .archives: "archivebox"
        case .apps: "app.badge"
        case .other: "square.stack.3d.up"
        }
    }
}

enum DiskSpaceDateBucket: String, CaseIterable, Identifiable, Sendable {
    case thisYear
    case lastYear
    case twoYearsAgo
    case older

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisYear: "This Year"
        case .lastYear: "Last Year"
        case .twoYearsAgo: "2 Years Ago"
        case .older: "3+ Years Ago"
        }
    }
}

struct DiskSpaceSizeThresholds: Sendable, Equatable {
    let smallMaximum: Int64
    let mediumMaximum: Int64
    let largeMaximum: Int64

    static let standard = DiskSpaceSizeThresholds(
        smallMaximum: 50 * 1_000_000,
        mediumMaximum: 250 * 1_000_000,
        largeMaximum: 1_000_000_000
    )
}

enum DiskSpaceSizeBucket: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small (<50 MB)"
        case .medium: "Medium (<250 MB)"
        case .large: "Large (<1 GB)"
        case .extraLarge: "Extra Large (1 GB+)"
        }
    }

    static func bucket(for bytes: Int64, thresholds: DiskSpaceSizeThresholds = .standard) -> Self {
        if bytes < thresholds.smallMaximum { return .small }
        if bytes < thresholds.mediumMaximum { return .medium }
        if bytes < thresholds.largeMaximum { return .large }
        return .extraLarge
    }
}

struct DiskSpaceSlice: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let bytes: Int64
    let itemCount: Int

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct DiskSpaceApplication: Codable, Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let bytes: Int64
    let fileCount: Int

    var id: String { path }
}

struct DiskSpaceDeletionCandidate: Codable, Identifiable, Hashable, Sendable {
    let path: String
    let kind: DiskSpaceContentKind
    let bytes: Int64
    let modified: Date
    let isDirectory: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var parentPath: String { url.deletingLastPathComponent().path }
    var isSystemItem: Bool { DiskSpaceSystemItem.isProtected(path) }
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum DiskSpaceSystemItem {
    private static let protectedRoots = [
        "/System",
        "/Library",
        "/usr",
        "/bin",
        "/sbin",
        "/private",
        "/var",
        "/etc",
    ]

    static func isProtected(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return protectedRoots.contains { root in
            normalized == root || normalized.hasPrefix("\(root)/")
        }
    }
}

struct DiskSpaceAnalysis: Codable, Sendable {
    let volumeName: String
    let volumePath: String
    let volumeCapacity: Int64?
    let availableCapacity: Int64?
    let typeSlices: [DiskSpaceSlice]
    let dateSlices: [DiskSpaceSlice]
    let sizeSlices: [DiskSpaceSlice]
    let applications: [DiskSpaceApplication]
    let deletionCandidates: [DiskSpaceContentKind: [DiskSpaceDeletionCandidate]]
    let scannedFileCount: Int

    var totalBytes: Int64 {
        typeSlices.reduce(0) { $0 + $1.bytes }
    }

    var totalBytesText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var usedCapacity: Int64? {
        guard let volumeCapacity, let availableCapacity else { return nil }
        return max(volumeCapacity - availableCapacity, 0)
    }

    var applicationSlices: [DiskSpaceSlice] {
        let maximumVisibleApps = 6
        let visibleApps = applications.prefix(maximumVisibleApps)
        var slices = visibleApps.map {
            DiskSpaceSlice(
                id: $0.path,
                title: $0.name,
                bytes: $0.bytes,
                itemCount: $0.fileCount
            )
        }
        let remaining = applications.dropFirst(maximumVisibleApps)
        let remainingBytes = remaining.reduce(Int64(0)) { $0 + $1.bytes }
        if remainingBytes > 0 {
            slices.append(
                DiskSpaceSlice(
                    id: "other-applications",
                    title: "Other Apps",
                    bytes: remainingBytes,
                    itemCount: remaining.count
                )
            )
        }
        return slices
    }

    func deletionCandidates(for kind: DiskSpaceContentKind) -> [DiskSpaceDeletionCandidate] {
        deletionCandidates[kind] ?? []
    }
}

struct DiskSpaceAnalysisSnapshot: Codable, Sendable {
    let analysis: DiskSpaceAnalysis
    let completedAt: Date
}

struct DiskSpaceScanProgress: Sendable {
    let filesScanned: Int
    let bytesFound: Int64

    var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: bytesFound, countStyle: .file)
        return "Scanned \(filesScanned.formatted()) files · \(size) found"
    }
}

struct DiskSpaceScanOptions: Sendable {
    let root: URL
    var sizeThresholds: DiskSpaceSizeThresholds = .standard
}

enum DiskSpaceAnalyzerEngine {
    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "png", "raw", "tif", "tiff", "webp",
    ]
    private static let videoExtensions: Set<String> = [
        "3gp", "avi", "flv", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm", "wmv",
    ]
    private static let audioExtensions: Set<String> = [
        "aac", "aiff", "alac", "flac", "m4a", "mp3", "ogg", "opus", "wav",
    ]
    private static let archiveExtensions: Set<String> = [
        "7z", "bz2", "dmg", "gz", "iso", "rar", "tar", "tbz", "tgz", "txz", "xz", "zip",
    ]
    private static let documentExtensions: Set<String> = [
        "csv", "doc", "docx", "epub", "key", "md", "numbers", "odt", "pages", "pdf", "ppt", "pptx",
        "rtf", "rtfd", "tex", "txt", "xls", "xlsx", "yaml", "yml",
    ]

    static func volumeRoot(for location: URL) -> URL {
        guard let volumePath = volumePath(for: location) else {
            return location.standardizedFileURL
        }
        return URL(fileURLWithPath: volumePath, isDirectory: true).standardizedFileURL
    }

    static func analyze(
        options: DiskSpaceScanOptions,
        progress: @escaping @Sendable (DiskSpaceScanProgress) async -> Void = { _ in }
    ) async throws -> DiskSpaceAnalysis {
        try await Task.detached(priority: .userInitiated) {
            try await analyzeDetached(options: options, progress: progress)
        }.value
    }

    private static func analyzeDetached(
        options: DiskSpaceScanOptions,
        progress: @escaping @Sendable (DiskSpaceScanProgress) async -> Void
    ) async throws -> DiskSpaceAnalysis {
        let root = options.root.standardizedFileURL
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .volumeURLKey,
        ]
        let volumeKeys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeURLKey,
        ]
        let volumeValues = try? root.resourceValues(forKeys: volumeKeys)
        let rootVolumePath = volumePath(for: root)
        let volumeName = volumeValues?.volumeLocalizedName
            ?? (root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
        let totalCapacity = volumeValues?.volumeTotalCapacity.map { Int64($0) }
        let availableCapacity = volumeValues?.volumeAvailableCapacityForImportantUsage.map { Int64($0) }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw DiskSpaceAnalyzerError.unreadableVolume(root.path)
        }

        var accumulator = DiskSpaceAccumulator(
            thresholds: options.sizeThresholds,
            now: Date(),
            calendar: Calendar.current
        )

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let isDirectory = values?.isDirectory ?? false

            if let rootVolumePath,
               let itemVolumePath = volumePath(for: url),
               itemVolumePath != rootVolumePath {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            if values?.isSymbolicLink == true {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            if isDirectory {
                guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                enumerator.skipDescendants()
                let application = try applicationUsage(
                    at: url,
                    resourceKeys: resourceKeys,
                    rootVolumePath: rootVolumePath
                )
                accumulator.addApplication(
                    at: url,
                    bytes: application.bytes,
                    fileCount: application.fileCount,
                    modified: values?.contentModificationDate ?? .distantPast
                )
            } else {
                accumulator.addFile(
                    at: url,
                    bytes: allocatedSize(from: values),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }

            if accumulator.scannedFileCount.isMultiple(of: 750) {
                await progress(
                    DiskSpaceScanProgress(
                        filesScanned: accumulator.scannedFileCount,
                        bytesFound: accumulator.totalBytes
                    )
                )
            }
        }

        let finalProgress = DiskSpaceScanProgress(
            filesScanned: accumulator.scannedFileCount,
            bytesFound: accumulator.totalBytes
        )
        await progress(finalProgress)
        return accumulator.analysis(
            volumeName: volumeName,
            volumePath: root.path,
            volumeCapacity: totalCapacity,
            availableCapacity: availableCapacity
        )
    }

    private static func applicationUsage(
        at url: URL,
        resourceKeys: Set<URLResourceKey>,
        rootVolumePath: String?
    ) throws -> (bytes: Int64, fileCount: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0)
        }

        var bytes: Int64 = 0
        var fileCount = 0
        while let nestedURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? nestedURL.resourceValues(forKeys: resourceKeys)
            let isDirectory = values?.isDirectory ?? false
            if let rootVolumePath,
               let itemVolumePath = volumePath(for: nestedURL),
               itemVolumePath != rootVolumePath {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if values?.isSymbolicLink == true {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard !isDirectory else { continue }
            bytes += allocatedSize(from: values)
            fileCount += 1
        }
        return (bytes, fileCount)
    }

    private static func allocatedSize(from values: URLResourceValues?) -> Int64 {
        Int64(values?.fileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private static func volumePath(for url: URL) -> String? {
        let values = try? (url as NSURL).resourceValues(forKeys: [.volumeURLKey])
        return (values?[.volumeURLKey] as? URL)?.standardizedFileURL.path
    }

    fileprivate static func contentKind(for url: URL) -> DiskSpaceContentKind {
        let fileExtension = url.pathExtension.lowercased()
        if imageExtensions.contains(fileExtension) { return .images }
        if videoExtensions.contains(fileExtension) { return .video }
        if audioExtensions.contains(fileExtension) { return .audio }
        if archiveExtensions.contains(fileExtension) { return .archives }
        if documentExtensions.contains(fileExtension) { return .documents }
        return .other
    }
}

private struct DiskSpaceAccumulator {
    private static let deletionCandidateLimit = 50

    let thresholds: DiskSpaceSizeThresholds
    let now: Date
    let calendar: Calendar
    var typeBytes = Dictionary(uniqueKeysWithValues: DiskSpaceContentKind.allCases.map { ($0, Int64(0)) })
    var typeCounts = Dictionary(uniqueKeysWithValues: DiskSpaceContentKind.allCases.map { ($0, 0) })
    var dateBytes = Dictionary(uniqueKeysWithValues: DiskSpaceDateBucket.allCases.map { ($0, Int64(0)) })
    var dateCounts = Dictionary(uniqueKeysWithValues: DiskSpaceDateBucket.allCases.map { ($0, 0) })
    var sizeBytes = Dictionary(uniqueKeysWithValues: DiskSpaceSizeBucket.allCases.map { ($0, Int64(0)) })
    var sizeCounts = Dictionary(uniqueKeysWithValues: DiskSpaceSizeBucket.allCases.map { ($0, 0) })
    var applications: [String: DiskSpaceApplication] = [:]
    var deletionCandidates = Dictionary(
        uniqueKeysWithValues: DiskSpaceContentKind.allCases.map { ($0, [DiskSpaceDeletionCandidate]()) }
    )
    var scannedFileCount = 0
    var totalBytes: Int64 = 0

    mutating func addFile(at url: URL, bytes: Int64, modified: Date) {
        let size = max(bytes, 0)
        let kind = DiskSpaceAnalyzerEngine.contentKind(for: url)
        add(size: size, kind: kind, modified: modified)
        addDeletionCandidate(
            DiskSpaceDeletionCandidate(
                path: url.path,
                kind: kind,
                bytes: size,
                modified: modified,
                isDirectory: false
            )
        )
    }

    mutating func addApplication(at url: URL, bytes: Int64, fileCount: Int, modified: Date) {
        let size = max(bytes, 0)
        add(size: size, kind: .apps, modified: modified, fileCount: max(fileCount, 1))
        applications[url.path] = DiskSpaceApplication(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            bytes: size,
            fileCount: fileCount
        )
        addDeletionCandidate(
            DiskSpaceDeletionCandidate(
                path: url.path,
                kind: .apps,
                bytes: size,
                modified: modified,
                isDirectory: true
            )
        )
    }

    func analysis(
        volumeName: String,
        volumePath: String,
        volumeCapacity: Int64?,
        availableCapacity: Int64?
    ) -> DiskSpaceAnalysis {
        DiskSpaceAnalysis(
            volumeName: volumeName,
            volumePath: volumePath,
            volumeCapacity: volumeCapacity,
            availableCapacity: availableCapacity,
            typeSlices: DiskSpaceContentKind.allCases.map {
                DiskSpaceSlice(
                    id: $0.rawValue,
                    title: $0.title,
                    bytes: typeBytes[$0] ?? 0,
                    itemCount: typeCounts[$0] ?? 0
                )
            },
            dateSlices: DiskSpaceDateBucket.allCases.map {
                DiskSpaceSlice(
                    id: $0.rawValue,
                    title: $0.title,
                    bytes: dateBytes[$0] ?? 0,
                    itemCount: dateCounts[$0] ?? 0
                )
            },
            sizeSlices: DiskSpaceSizeBucket.allCases.map {
                DiskSpaceSlice(
                    id: $0.rawValue,
                    title: $0.title,
                    bytes: sizeBytes[$0] ?? 0,
                    itemCount: sizeCounts[$0] ?? 0
                )
            },
            applications: applications.values.sorted { $0.bytes > $1.bytes },
            deletionCandidates: deletionCandidates,
            scannedFileCount: scannedFileCount
        )
    }

    private mutating func addDeletionCandidate(_ candidate: DiskSpaceDeletionCandidate) {
        guard candidate.bytes > 0 else { return }
        var candidates = deletionCandidates[candidate.kind, default: []]

        if candidates.count < Self.deletionCandidateLimit {
            candidates.append(candidate)
        } else if let smallest = candidates.last, ranksBefore(candidate, smallest) {
            candidates.removeLast()
            candidates.append(candidate)
        } else {
            return
        }

        candidates.sort(by: ranksBefore)
        deletionCandidates[candidate.kind] = candidates
    }

    private func ranksBefore(_ lhs: DiskSpaceDeletionCandidate, _ rhs: DiskSpaceDeletionCandidate) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private mutating func add(
        size: Int64,
        kind: DiskSpaceContentKind,
        modified: Date,
        fileCount: Int = 1
    ) {
        typeBytes[kind, default: 0] += size
        typeCounts[kind, default: 0] += fileCount
        let dateBucket = bucket(for: modified)
        dateBytes[dateBucket, default: 0] += size
        dateCounts[dateBucket, default: 0] += fileCount
        let sizeBucket = DiskSpaceSizeBucket.bucket(for: size, thresholds: thresholds)
        sizeBytes[sizeBucket, default: 0] += size
        sizeCounts[sizeBucket, default: 0] += fileCount
        scannedFileCount += fileCount
        totalBytes += size
    }

    private func bucket(for modified: Date) -> DiskSpaceDateBucket {
        let currentYear = calendar.component(.year, from: now)
        let modifiedYear = calendar.component(.year, from: modified)
        switch currentYear - modifiedYear {
        case ...0: return .thisYear
        case 1: return .lastYear
        case 2: return .twoYearsAgo
        default: return .older
        }
    }
}

private enum DiskSpaceAnalyzerError: LocalizedError {
    case unreadableVolume(String)

    var errorDescription: String? {
        switch self {
        case .unreadableVolume(let path): "Workbench couldn’t read \(path)."
        }
    }
}

@Observable
@MainActor
final class DiskSpaceAnalyzerStore {
    static let shared = DiskSpaceAnalyzerStore()

    var analysis: DiskSpaceAnalysis?
    var isScanning = false
    var scanDetail = ""
    var lastError: String?
    var lastScannedAt: Date?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var activeScanID: UUID?
    @ObservationIgnored private let snapshotFile: URL

    private init() {
        snapshotFile = Self.defaultSnapshotFile
        restoreSnapshot()
    }

    func startScan(containing location: URL, force: Bool = false) {
        guard !isScanning else { return }
        let root = DiskSpaceAnalyzerEngine.volumeRoot(for: location)
        if !force, analysis?.volumePath == root.path { return }

        lastError = nil
        isScanning = true
        scanDetail = "Starting disk scan…"
        let options = DiskSpaceScanOptions(root: root)
        let scanID = UUID()
        activeScanID = scanID
        scanTask = Task {
            defer {
                if activeScanID == scanID {
                    isScanning = false
                    scanTask = nil
                    activeScanID = nil
                }
            }
            do {
                let result = try await DiskSpaceAnalyzerEngine.analyze(options: options) { [scanID] progress in
                    await MainActor.run {
                        let store = DiskSpaceAnalyzerStore.shared
                        guard store.activeScanID == scanID else { return }
                        store.scanDetail = progress.detail
                    }
                }
                guard !Task.isCancelled, activeScanID == scanID else { return }
                analysis = result
                lastScannedAt = Date()
                scanDetail = "Analyzed \(result.scannedFileCount.formatted()) files · \(result.totalBytesText)"
                saveSnapshot()
            } catch is CancellationError {
                guard activeScanID == scanID else { return }
                scanDetail = "Disk scan cancelled."
            } catch {
                guard activeScanID == scanID else { return }
                lastError = error.localizedDescription
                scanDetail = "Disk scan failed."
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        activeScanID = nil
        isScanning = false
        scanDetail = "Disk scan cancelled."
    }

    private func restoreSnapshot() {
        guard FileManager.default.fileExists(atPath: snapshotFile.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(
                DiskSpaceAnalysisSnapshot.self,
                from: Data(contentsOf: snapshotFile)
            )
            analysis = snapshot.analysis
            lastScannedAt = snapshot.completedAt
            scanDetail = "Saved analysis · \(snapshot.analysis.scannedFileCount.formatted()) files · \(snapshot.analysis.totalBytesText)"
        } catch {
            try? FileManager.default.removeItem(at: snapshotFile)
        }
    }

    private func saveSnapshot() {
        guard let analysis, let lastScannedAt else { return }
        do {
            try FileManager.default.createDirectory(
                at: snapshotFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snapshot = DiskSpaceAnalysisSnapshot(analysis: analysis, completedAt: lastScannedAt)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: snapshotFile, options: [.atomic])
        } catch {
            lastError = "The disk analysis finished, but Workbench couldn’t save it for next time."
        }
    }

    private static var defaultSnapshotFile: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Panes/DiskSpace", isDirectory: true)
            .appendingPathComponent("latest-analysis.json")
    }
}
