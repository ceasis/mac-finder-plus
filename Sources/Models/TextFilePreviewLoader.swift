import Foundation

enum TextFilePreviewLimit: Equatable, Sendable {
    case bytes(Int)
    case rows(Int)
}

struct TextFilePreviewResult: Equatable, Sendable {
    let text: String
    let limit: TextFilePreviewLimit?
}

enum DelimitedFileSeparator: Sendable {
    case comma
    case tab

    fileprivate var byte: UInt8 {
        switch self {
        case .comma: 0x2C
        case .tab: 0x09
        }
    }

    fileprivate var character: Character {
        switch self {
        case .comma: ","
        case .tab: "\t"
        }
    }
}

struct DelimitedFilePreviewResult: Equatable, Sendable {
    let header: [String]
    let rows: [[String]]
    let limit: TextFilePreviewLimit?
    let columnsWereTruncated: Bool
    let cellsWereTruncated: Bool

    var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }
}

enum TextFilePreviewLoader {
    static let defaultByteCap = 1_000_000
    static let delimitedByteCap = 64 * 1_024
    static let delimitedDataRowLimit = 10
    static let delimitedColumnLimit = 100
    static let delimitedCellCharacterLimit = 1_000

    static func load(
        from url: URL,
        byteCap: Int = defaultByteCap
    ) async throws -> TextFilePreviewResult {
        let worker = Task.detached(priority: .utility) {
            try loadTextSynchronously(from: url, byteCap: byteCap)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func loadDelimited(
        from url: URL,
        separator: DelimitedFileSeparator,
        byteCap: Int = delimitedByteCap,
        dataRowLimit: Int = delimitedDataRowLimit
    ) async throws -> DelimitedFilePreviewResult {
        let worker = Task.detached(priority: .utility) {
            let safeDataRowLimit = max(dataRowLimit, 0)
            let rawPreview = try loadDelimitedTextSynchronously(
                from: url,
                byteCap: byteCap,
                recordLimit: safeDataRowLimit + 1,
                separator: separator
            )
            try Task.checkCancellation()

            let parsed = try parseDelimited(
                rawPreview.text,
                separator: separator.character,
                columnLimit: delimitedColumnLimit,
                cellCharacterLimit: delimitedCellCharacterLimit
            )
            guard var header = parsed.records.first else {
                return DelimitedFilePreviewResult(
                    header: [],
                    rows: [],
                    limit: rawPreview.limit,
                    columnsWereTruncated: parsed.columnsWereTruncated,
                    cellsWereTruncated: parsed.cellsWereTruncated
                )
            }
            if let first = header.first {
                header[0] = first.trimmingPrefix("\u{FEFF}")
            }

            let previewLimit: TextFilePreviewLimit?
            switch rawPreview.limit {
            case .rows:
                previewLimit = .rows(safeDataRowLimit)
            case let .bytes(count):
                previewLimit = .bytes(count)
            case nil:
                previewLimit = nil
            }

            return DelimitedFilePreviewResult(
                header: header,
                rows: Array(parsed.records.dropFirst().prefix(safeDataRowLimit)),
                limit: previewLimit,
                columnsWereTruncated: parsed.columnsWereTruncated,
                cellsWereTruncated: parsed.cellsWereTruncated
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func loadTextSynchronously(
        from url: URL,
        byteCap: Int
    ) throws -> TextFilePreviewResult {
        let safeByteCap = max(byteCap, 1)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try Task.checkCancellation()
        let data = try handle.read(upToCount: safeByteCap + 1) ?? Data()
        try Task.checkCancellation()
        let isTruncated = data.count > safeByteCap
        return TextFilePreviewResult(
            text: decode(Data(data.prefix(safeByteCap))),
            limit: isTruncated ? .bytes(safeByteCap) : nil
        )
    }

    private static func loadDelimitedTextSynchronously(
        from url: URL,
        byteCap: Int,
        recordLimit: Int,
        separator: DelimitedFileSeparator
    ) throws -> TextFilePreviewResult {
        let safeByteCap = max(byteCap, 1)
        let safeRecordLimit = max(recordLimit, 1)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Small chunks let ordinary files stop after a few KB. The bounded
        // result is parsed before crossing back to the main actor.
        let chunkSize = 8 * 1_024
        var accumulated = Data()
        var reachedEndOfFile = false

        while accumulated.count <= safeByteCap {
            try Task.checkCancellation()
            let remaining = safeByteCap + 1 - accumulated.count
            guard remaining > 0 else { break }
            let chunk = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
            if chunk.isEmpty {
                reachedEndOfFile = true
                break
            }
            accumulated.append(chunk)

            if let recordEnd = delimitedRecordEnd(
                in: accumulated,
                recordLimit: safeRecordLimit,
                separatorByte: separator.byte
            ) {
                var hasMoreContent = accumulated.count > recordEnd
                if !hasMoreContent {
                    let extra = try handle.read(upToCount: 1) ?? Data()
                    hasMoreContent = !extra.isEmpty
                }
                return TextFilePreviewResult(
                    text: decode(Data(accumulated.prefix(recordEnd))),
                    limit: hasMoreContent ? .rows(safeRecordLimit) : nil
                )
            }
        }

        try Task.checkCancellation()
        let isTruncated = !reachedEndOfFile && accumulated.count > safeByteCap
        let capped = Data(accumulated.prefix(safeByteCap))
        let previewData: Data
        if isTruncated {
            if let lastCompleteRecordEnd = lastDelimitedRecordEnd(
                in: capped,
                separatorByte: separator.byte
            ) {
                previewData = Data(capped.prefix(lastCompleteRecordEnd))
            } else {
                previewData = Data()
            }
        } else {
            previewData = capped
        }
        return TextFilePreviewResult(
            text: decode(previewData),
            limit: isTruncated ? .bytes(safeByteCap) : nil
        )
    }

    private static func delimitedRecordEnd(
        in data: Data,
        recordLimit: Int,
        separatorByte: UInt8
    ) -> Int? {
        recordBoundaries(in: data, separatorByte: separatorByte)
            .dropFirst(recordLimit - 1)
            .first
    }

    private static func lastDelimitedRecordEnd(
        in data: Data,
        separatorByte: UInt8
    ) -> Int? {
        recordBoundaries(in: data, separatorByte: separatorByte).last
    }

    /// Finds complete record boundaries while respecting quoted newlines.
    private static func recordBoundaries(
        in data: Data,
        separatorByte: UInt8
    ) -> [Int] {
        let bytes = [UInt8](data)
        var boundaries: [Int] = []
        var index = 0
        var insideQuotes = false
        var atFieldStart = true

        while index < bytes.count {
            let byte = bytes[index]
            if insideQuotes {
                if byte == 0x22 {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        index += 1
                    } else {
                        insideQuotes = false
                    }
                }
            } else if byte == 0x22, atFieldStart {
                insideQuotes = true
                atFieldStart = false
            } else if byte == separatorByte {
                atFieldStart = true
            } else if byte == 0x0A {
                boundaries.append(index + 1)
                atFieldStart = true
            } else if byte == 0x0D {
                guard index + 1 < bytes.count else { break }
                if bytes[index + 1] == 0x0A {
                    index += 1
                }
                boundaries.append(index + 1)
                atFieldStart = true
            } else {
                atFieldStart = false
            }
            index += 1
        }
        return boundaries
    }

    private static func parseDelimited(
        _ text: String,
        separator: Character,
        columnLimit: Int,
        cellCharacterLimit: Int
    ) throws -> (
        records: [[String]],
        columnsWereTruncated: Bool,
        cellsWereTruncated: Bool
    ) {
        let characters = Array(text)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var index = 0
        var insideQuotes = false
        var recordStarted = false
        var endedAtRecordBoundary = false
        var columnsWereTruncated = false
        var cellsWereTruncated = false

        func boundedField(_ value: String) -> String {
            guard value.count > cellCharacterLimit else { return value }
            cellsWereTruncated = true
            return String(value.prefix(cellCharacterLimit)) + "…"
        }

        func finishField() {
            if record.count < columnLimit {
                record.append(boundedField(field))
            } else {
                columnsWereTruncated = true
            }
            field = ""
        }

        func finishRecord() {
            finishField()
            records.append(record)
            record = []
            recordStarted = false
            endedAtRecordBoundary = true
        }

        while index < characters.count {
            try Task.checkCancellation()
            let character = characters[index]
            if insideQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        insideQuotes = false
                    }
                } else {
                    field.append(character)
                }
                recordStarted = true
                endedAtRecordBoundary = false
            } else if character == "\"", field.isEmpty {
                insideQuotes = true
                recordStarted = true
                endedAtRecordBoundary = false
            } else if character == separator {
                finishField()
                recordStarted = true
                endedAtRecordBoundary = false
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                finishRecord()
            } else {
                field.append(character)
                recordStarted = true
                endedAtRecordBoundary = false
            }
            index += 1
        }

        if recordStarted || !record.isEmpty || (!field.isEmpty && !endedAtRecordBoundary) {
            finishRecord()
        }

        return (records, columnsWereTruncated, cellsWereTruncated)
    }

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
