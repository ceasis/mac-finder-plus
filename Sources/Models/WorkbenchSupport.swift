import AppKit
import Darwin
import Foundation

struct WorkbenchBuildInfo: Sendable {
    let appName: String
    let version: String
    let build: String
    let bundleID: String
    let macOSVersion: String
    let hardwareModel: String

    static var current: WorkbenchBuildInfo {
        let bundle = Bundle.main
        return WorkbenchBuildInfo(
            appName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "Workbench",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
            bundleID: bundle.bundleIdentifier ?? "com.qnsub.workbench.app",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: Self.hardwareModel()
        )
    }

    var displayVersion: String {
        "Version \(version) (\(build))"
    }

    var diagnosticsText: String {
        """
        \(appName) \(displayVersion)
        Bundle ID: \(bundleID)
        macOS: \(macOSVersion)
        Mac: \(hardwareModel)
        """
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown Mac"
        }

        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
            return "Unknown Mac"
        }
        return String(cString: model)
    }
}

enum WorkbenchLinks {
    static let supportEmail = "support@qnsub.com"

    static func supportEmailURL(
        subject: String = "Workbench Support",
        body: String = WorkbenchBuildInfo.current.diagnosticsText
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: "\(body)\n\nIssue:\n"),
        ]
        return components.url
    }
}

enum DeletionSafetySettings {
    static let confirmMoveToTrashKey = "deletion.confirmMoveToTrash"

    static var shouldConfirmMoveToTrash: Bool {
        if UserDefaults.standard.object(forKey: confirmMoveToTrashKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: confirmMoveToTrashKey)
    }
}

enum WorkbenchSupportActions {
    @MainActor
    static func openSupportEmail() {
        if let url = WorkbenchLinks.supportEmailURL() {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            WorkbenchBuildInfo.current.diagnosticsText,
            forType: .string
        )
    }

    @MainActor
    static func revealSupportFolder() {
        let root = WorkbenchDataBackup.supportRootDirectory
        if FileManager.default.fileExists(atPath: root.path) {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([root.deletingLastPathComponent()])
        }
    }
}

enum WorkbenchDataBackup {
    struct Manifest: Encodable, Sendable {
        let appName: String
        let version: String
        let build: String
        let bundleID: String
        let createdAt: Date
        let includedPaths: [String]
    }

    struct ImportResult: Sendable {
        let restoredSupportData: Bool
        let restoredPreferences: Bool
        let safetyBackupURL: URL?

        var summary: String {
            var parts: [String] = []
            if restoredSupportData { parts.append("data") }
            if restoredPreferences { parts.append("preferences") }
            let restored = parts.isEmpty ? "backup" : parts.joined(separator: " and ")
            if safetyBackupURL != nil {
                return "Restored \(restored); safety backup saved"
            }
            return "Restored \(restored)"
        }
    }

    static var supportRootDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Panes", isDirectory: true)
    }

    static var preferencesFile: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.qnsub.workbench.app"
        let base = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleID).plist")
    }

    static func suggestedFilename() -> String {
        let info = WorkbenchBuildInfo.current
        let date = BackupDateFormatter.filenameFormatter.string(from: Date())
        return "Workbench Backup \(info.version)-\(info.build) \(date).zip"
    }

    static func suggestedPreImportFilename() -> String {
        let date = BackupDateFormatter.filenameFormatter.string(from: Date())
        return "Workbench Pre-Import Backup \(date).zip"
    }

    static func export(to destination: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try createBackup(at: destination)
        }.value
    }

    static func importBackup(from source: URL) async throws -> ImportResult {
        try await Task.detached(priority: .userInitiated) {
            try restoreBackup(from: source)
        }.value
    }

    private static func createBackup(at destination: URL) throws -> URL {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("WorkbenchBackup-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = tempRoot.appendingPathComponent("Workbench Backup", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        var includedPaths: [String] = []
        if fm.fileExists(atPath: supportRootDirectory.path) {
            let supportDestination = packageRoot.appendingPathComponent("Application Support", isDirectory: true)
            try fm.createDirectory(at: supportDestination, withIntermediateDirectories: true)
            try fm.copyItem(
                at: supportRootDirectory,
                to: supportDestination.appendingPathComponent("Panes", isDirectory: true)
            )
            includedPaths.append(supportRootDirectory.path)
        }

        if fm.fileExists(atPath: preferencesFile.path) {
            let prefsDestination = packageRoot.appendingPathComponent("Preferences", isDirectory: true)
            try fm.createDirectory(at: prefsDestination, withIntermediateDirectories: true)
            try fm.copyItem(
                at: preferencesFile,
                to: prefsDestination.appendingPathComponent(preferencesFile.lastPathComponent)
            )
            includedPaths.append(preferencesFile.path)
        }

        let info = WorkbenchBuildInfo.current
        let manifest = Manifest(
            appName: info.appName,
            version: info.version,
            build: info.build,
            bundleID: info.bundleID,
            createdAt: Date(),
            includedPaths: includedPaths
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: packageRoot.appendingPathComponent("manifest.json"), options: [.atomic])

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempRoot
        process.arguments = ["-q", "-r", "-X", destination.path, "Workbench Backup"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkbenchBackupError.exportFailed(detail)
        }

        return destination
    }

    private static func restoreBackup(from source: URL) throws -> ImportResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw WorkbenchBackupError.importFailed("The selected backup file no longer exists.")
        }

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("WorkbenchRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        try unzip(source, to: tempRoot)
        let backupRoot = try locateBackupRoot(in: tempRoot)
        let importedSupportRoot = backupRoot
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Panes", isDirectory: true)
        let importedPreferences = try locatePreferencesFile(in: backupRoot)

        let hasSupportData = fm.fileExists(atPath: importedSupportRoot.path)
        guard hasSupportData || importedPreferences != nil else {
            throw WorkbenchBackupError.invalidBackup
        }

        let safetyBackupURL = try createSafetyBackupIfNeeded()

        if hasSupportData {
            try fm.createDirectory(
                at: supportRootDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: supportRootDirectory.path) {
                try fm.removeItem(at: supportRootDirectory)
            }
            try fm.copyItem(at: importedSupportRoot, to: supportRootDirectory)
        }

        if let importedPreferences {
            try fm.createDirectory(
                at: preferencesFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: preferencesFile.path) {
                try fm.removeItem(at: preferencesFile)
            }
            try fm.copyItem(at: importedPreferences, to: preferencesFile)
        }

        return ImportResult(
            restoredSupportData: hasSupportData,
            restoredPreferences: importedPreferences != nil,
            safetyBackupURL: safetyBackupURL
        )
    }

    private static func createSafetyBackupIfNeeded() throws -> URL? {
        let fm = FileManager.default
        let hasExistingData = fm.fileExists(atPath: supportRootDirectory.path)
            || fm.fileExists(atPath: preferencesFile.path)
        guard hasExistingData else { return nil }

        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let backupDirectory = base.appendingPathComponent("Workbench Backups", isDirectory: true)
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let destination = uniqueDestination(
            for: backupDirectory.appendingPathComponent(suggestedPreImportFilename())
        )
        return try createBackup(at: destination)
    }

    private static func locateBackupRoot(in extractedRoot: URL) throws -> URL {
        let fm = FileManager.default
        let expected = extractedRoot.appendingPathComponent("Workbench Backup", isDirectory: true)
        if fm.fileExists(atPath: expected.appendingPathComponent("manifest.json").path) {
            return expected
        }

        if let enumerator = fm.enumerator(
            at: extractedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent == "manifest.json" {
                return url.deletingLastPathComponent()
            }
        }

        let supportRoots = [
            extractedRoot.appendingPathComponent("Application Support/Panes", isDirectory: true),
            extractedRoot.appendingPathComponent("Panes", isDirectory: true),
        ]
        if supportRoots.contains(where: { fm.fileExists(atPath: $0.path) }) {
            return extractedRoot
        }

        throw WorkbenchBackupError.invalidBackup
    }

    private static func locatePreferencesFile(in backupRoot: URL) throws -> URL? {
        let prefsDirectory = backupRoot.appendingPathComponent("Preferences", isDirectory: true)
        guard FileManager.default.fileExists(atPath: prefsDirectory.path) else { return nil }

        let candidates = try FileManager.default.contentsOfDirectory(
            at: prefsDirectory,
            includingPropertiesForKeys: nil
        )
        let preferredName = preferencesFile.lastPathComponent
        return candidates.first { $0.lastPathComponent == preferredName }
            ?? candidates.first { $0.pathExtension == "plist" }
    }

    private static func unzip(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", source.path, "-d", destination.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkbenchBackupError.importFailed(detail)
        }
    }

    private static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}

enum WorkbenchBackupError: LocalizedError {
    case exportFailed(String?)
    case importFailed(String?)
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .exportFailed(let detail):
            if let detail, !detail.isEmpty {
                return "Couldn’t export Workbench data: \(detail)"
            }
            return "Couldn’t export Workbench data."
        case .importFailed(let detail):
            if let detail, !detail.isEmpty {
                return "Couldn’t import Workbench data: \(detail)"
            }
            return "Couldn’t import Workbench data."
        case .invalidBackup:
            return "That ZIP does not look like a Workbench backup."
        }
    }
}

struct WorkbenchActivityDiagnostic: Encodable, Sendable {
    let title: String
    let detail: String
    let status: String
    let startedAt: Date
    let finishedAt: Date?
    let progressDetail: String?

    @MainActor
    init(activity: FileActivity) {
        title = activity.title
        detail = activity.detail
        startedAt = activity.startedAt
        finishedAt = activity.finishedAt
        progressDetail = activity.progressDetail
        switch activity.status {
        case .queued:
            status = "queued"
        case .running:
            status = "running"
        case .paused:
            status = "paused"
        case .completed:
            status = "completed"
        case .cancelled:
            status = "cancelled"
        case .failed(let message):
            status = "failed: \(message)"
        }
    }
}

enum WorkbenchDiagnostics {
    struct Manifest: Encodable, Sendable {
        let appName: String
        let version: String
        let build: String
        let bundleID: String
        let createdAt: Date
        let includedFiles: [String]
    }

    static func suggestedFilename() -> String {
        let date = BackupDateFormatter.filenameFormatter.string(from: Date())
        return "Workbench Diagnostics \(date).zip"
    }

    static func export(
        to destination: URL,
        activities: [WorkbenchActivityDiagnostic]
    ) async throws -> URL {
        let info = WorkbenchBuildInfo.current
        return try await Task.detached(priority: .userInitiated) {
            try createDiagnostics(at: destination, info: info, activities: activities)
        }.value
    }

    private static func createDiagnostics(
        at destination: URL,
        info: WorkbenchBuildInfo,
        activities: [WorkbenchActivityDiagnostic]
    ) throws -> URL {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("WorkbenchDiagnostics-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = tempRoot.appendingPathComponent("Workbench Diagnostics", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        var includedFiles: [String] = []

        let diagnosticsURL = packageRoot.appendingPathComponent("diagnostics.txt")
        try info.diagnosticsText.write(to: diagnosticsURL, atomically: true, encoding: .utf8)
        includedFiles.append(diagnosticsURL.lastPathComponent)

        let activityURL = packageRoot.appendingPathComponent("activity-history.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(activities).write(to: activityURL, options: [.atomic])
        includedFiles.append(activityURL.lastPathComponent)

        let logURL = packageRoot.appendingPathComponent("recent-workbench-log.txt")
        if writeRecentLog(to: logURL) {
            includedFiles.append(logURL.lastPathComponent)
        }

        let crashDirectory = packageRoot.appendingPathComponent("Crash Reports", isDirectory: true)
        let crashCount = try copyRecentCrashReports(to: crashDirectory)
        if crashCount > 0 {
            includedFiles.append("Crash Reports (\(crashCount))")
        }

        let manifest = Manifest(
            appName: info.appName,
            version: info.version,
            build: info.build,
            bundleID: info.bundleID,
            createdAt: Date(),
            includedFiles: includedFiles
        )
        try encoder.encode(manifest)
            .write(to: packageRoot.appendingPathComponent("manifest.json"), options: [.atomic])

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempRoot
        process.arguments = ["-q", "-r", "-X", destination.path, "Workbench Diagnostics"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkbenchDiagnosticsError.exportFailed(detail)
        }

        return destination
    }

    private static func writeRecentLog(to destination: URL) -> Bool {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else { return false }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--last", "1h",
            "--style", "compact",
            "--predicate", "process == \"Workbench\"",
        ]
        process.standardOutput = handle
        process.standardError = nil

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func copyRecentCrashReports(to destination: URL) throws -> Int {
        let fm = FileManager.default
        let reportsDirectory = fm.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        guard let reportsDirectory,
              fm.fileExists(atPath: reportsDirectory.path) else {
            return 0
        }

        let reports = try fm.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.lastPathComponent.hasPrefix("Workbench_")
                && ["crash", "ips"].contains(url.pathExtension)
        }
        .sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        .prefix(5)

        guard !reports.isEmpty else { return 0 }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for report in reports {
            try fm.copyItem(at: report, to: destination.appendingPathComponent(report.lastPathComponent))
        }
        return reports.count
    }
}

enum WorkbenchDiagnosticsError: LocalizedError {
    case exportFailed(String?)

    var errorDescription: String? {
        switch self {
        case .exportFailed(let detail):
            if let detail, !detail.isEmpty {
                return "Couldn’t export diagnostics: \(detail)"
            }
            return "Couldn’t export diagnostics."
        }
    }
}

private enum BackupDateFormatter {
    static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()
}
