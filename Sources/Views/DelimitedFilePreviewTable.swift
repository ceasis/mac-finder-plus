import AppKit
import SwiftUI

struct DelimitedFilePreviewView: View {
    let preview: DelimitedFilePreviewResult

    var body: some View {
        if preview.header.isEmpty && preview.rows.isEmpty {
            ContentUnavailableView(
                "No Table Data",
                systemImage: "tablecells",
                description: Text("The file has no complete rows to preview.")
            )
        } else {
            VStack(spacing: 0) {
                DelimitedFilePreviewTable(preview: preview)

                Divider()

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if preview.rows.isEmpty {
            parts.append("Showing header only")
        } else {
            let noun = preview.rows.count == 1 ? "row" : "rows"
            let qualifier = preview.limit == .rows(TextFilePreviewLoader.delimitedDataRowLimit)
                ? "first "
                : ""
            parts.append("Showing header and \(qualifier)\(preview.rows.count) data \(noun)")
        }

        if case let .bytes(count) = preview.limit {
            let size = ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
            parts.append("preview capped at \(size)")
        }
        if preview.columnsWereTruncated {
            parts.append("first \(TextFilePreviewLoader.delimitedColumnLimit) columns")
        }
        if preview.cellsWereTruncated {
            parts.append("long cells shortened")
        }
        return parts.joined(separator: " • ")
    }
}

private struct DelimitedFilePreviewTable: NSViewRepresentable {
    let preview: DelimitedFilePreviewResult

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.intercellSpacing = .zero
        tableView.rowHeight = 24
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = true
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.attach(tableView)
        context.coordinator.apply(preview)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(preview)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private weak var tableView: NSTableView?
        private var preview: DelimitedFilePreviewResult?

        func attach(_ tableView: NSTableView) {
            self.tableView = tableView
        }

        func apply(_ newPreview: DelimitedFilePreviewResult) {
            guard preview != newPreview, let tableView else { return }
            preview = newPreview

            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }
            for index in 0..<newPreview.columnCount {
                let identifier = NSUserInterfaceItemIdentifier("csv-column-\(index)")
                let column = NSTableColumn(identifier: identifier)
                column.title = headerTitle(at: index, in: newPreview)
                column.width = preferredWidth(at: index, in: newPreview)
                column.minWidth = 72
                column.maxWidth = 320
                column.resizingMask = .userResizingMask
                tableView.addTableColumn(column)
            }
            tableView.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            preview?.rows.count ?? 0
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let tableColumn,
                  let preview,
                  row < preview.rows.count,
                  let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn) else {
                return nil
            }

            let identifier = NSUserInterfaceItemIdentifier("csv-preview-cell")
            let textField: NSTextField
            if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
                textField = reusable
            } else {
                textField = NSTextField(labelWithString: "")
                textField.identifier = identifier
                textField.isSelectable = true
                textField.usesSingleLineMode = true
                textField.maximumNumberOfLines = 1
                textField.lineBreakMode = .byTruncatingTail
                textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            }

            let value = columnIndex < preview.rows[row].count
                ? preview.rows[row][columnIndex]
                : ""
            textField.stringValue = displayValue(value)
            textField.toolTip = displayValue(value)
            return textField
        }

        private func headerTitle(
            at index: Int,
            in preview: DelimitedFilePreviewResult
        ) -> String {
            guard index < preview.header.count, !preview.header[index].isEmpty else {
                return "Column \(index + 1)"
            }
            return displayValue(preview.header[index])
        }

        private func preferredWidth(
            at index: Int,
            in preview: DelimitedFilePreviewResult
        ) -> CGFloat {
            var values: [String] = []
            if index < preview.header.count {
                values.append(preview.header[index])
            }
            values.append(contentsOf: preview.rows.compactMap { row in
                index < row.count ? row[index] : nil
            })
            let longest = values.map { min(displayValue($0).count, 40) }.max() ?? 8
            return min(max(CGFloat(longest) * 7.2 + 24, 88), 320)
        }

        private func displayValue(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\r\n", with: " ↵ ")
                .replacingOccurrences(of: "\r", with: " ↵ ")
                .replacingOccurrences(of: "\n", with: " ↵ ")
        }
    }
}
