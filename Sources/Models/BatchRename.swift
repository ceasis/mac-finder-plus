import Foundation

struct BatchRenameOptions: Equatable {
    var pattern = "Untitled-{seq}"
    var dateFormat = "yyyyMMdd"
    var sequenceStart = 1
    var sequencePadding = 3
    var preservesExtension = true
}

struct BatchRenamePreviewItem: Identifiable, Equatable {
    let id: FileItem.ID
    let originalName: String
    let newName: String
    let warning: String?
}

enum BatchRenameEngine {
    static func previews(
        for items: [FileItem],
        options: BatchRenameOptions
    ) async -> [BatchRenamePreviewItem] {
        let names = await renderedNames(for: items, options: options)
        var seenNames = Set<String>()
        return zip(items, names).map { item, newName in
            let lowercased = newName.lowercased()
            let proposedURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            let warning: String?
            if item.name == newName {
                warning = "No change"
            } else if seenNames.contains(lowercased) {
                warning = "Duplicate in batch"
            } else if FileManager.default.fileExists(atPath: proposedURL.path),
                      proposedURL.standardizedFileURL != item.url.standardizedFileURL {
                warning = "Name exists"
            } else {
                warning = nil
            }
            seenNames.insert(lowercased)
            return BatchRenamePreviewItem(
                id: item.id,
                originalName: item.name,
                newName: newName,
                warning: warning
            )
        }
    }

    static func rename(
        _ items: [FileItem],
        options: BatchRenameOptions
    ) async throws -> [FileMoveRecord] {
        let names = await renderedNames(for: items, options: options)
        var records: [FileMoveRecord] = []
        for (item, newName) in zip(items, names) {
            try Task.checkCancellation()
            let proposed = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            guard proposed.standardizedFileURL != item.url.standardizedFileURL else { continue }
            let destination = FileOperations.uniqueDestination(for: proposed)
            try FileManager.default.moveItem(at: item.url, to: destination)
            records.append(FileMoveRecord(source: item.url, destination: destination))
        }
        return records
    }

    private static func renderedNames(
        for items: [FileItem],
        options: BatchRenameOptions
    ) async -> [String] {
        var names: [String] = []
        names.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let sequence = options.sequenceStart + offset
            let captureDate = await MediaMetadataReader.captureDate(for: item.url) ?? item.modified
            names.append(renderedName(
                for: item,
                sequence: sequence,
                captureDate: captureDate,
                options: options
            ))
        }
        return names
    }

    private static func renderedName(
        for item: FileItem,
        sequence: Int,
        captureDate: Date,
        options: BatchRenameOptions
    ) -> String {
        let originalExtension = item.url.pathExtension
        let originalBaseName = item.url.deletingPathExtension().lastPathComponent
        let formattedDate = dateFormatter(format: options.dateFormat).string(from: captureDate)
        let sequenceText = String(format: "%0*d", max(options.sequencePadding, 1), sequence)
        var output = options.pattern
            .replacingOccurrences(of: "{name}", with: originalBaseName)
            .replacingOccurrences(of: "{date}", with: formattedDate)
            .replacingOccurrences(of: "{seq}", with: sequenceText)
            .replacingOccurrences(of: "{ext}", with: originalExtension)

        output = sanitizedFileName(output)
        if options.preservesExtension,
           !originalExtension.isEmpty,
           !options.pattern.localizedCaseInsensitiveContains("{ext}") {
            output += ".\(originalExtension)"
        }
        return output
    }

    private static func dateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "yyyyMMdd"
            : format
        return formatter
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let replaced = name
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return replaced.isEmpty ? "Untitled" : replaced
    }
}
