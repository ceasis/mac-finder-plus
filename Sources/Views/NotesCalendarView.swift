import SwiftUI

/// Month calendar for the Notes panel. Badges each day that has notes and shows
/// whether those notes carry image or audio attachments. Tapping a day filters
/// the notes list to that day (tap again to clear).
struct NotesCalendarView: View {
    let store: NotesStore
    @Binding var selectedDay: Date?

    @State private var visibleMonth: Date = Date()

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        let markers = store.dayMarkers()
        VStack(spacing: 8) {
            header
            weekdayRow
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(gridDays, id: \.self) { day in
                    dayCell(day, marker: markers[calendar.startOfDay(for: day)])
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(monthTitle)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .help("Previous month")
            Button { visibleMonth = Date() } label: { Image(systemName: "circle.circle") }
                .buttonStyle(.plain)
                .help("Jump to this month")
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .help("Next month")
        }
        .font(.callout)
    }

    private var weekdayRow: some View {
        HStack(spacing: 2) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: Date, marker: NoteDayMarker?) -> some View {
        let inMonth = calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false

        return Button {
            toggle(day)
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption)
                    .fontWeight(isToday ? .bold : .regular)
                markerRow(marker)
                    .frame(height: 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14))
                }
            }
            .foregroundStyle(cellForeground(inMonth: inMonth, isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func markerRow(_ marker: NoteDayMarker?) -> some View {
        if let marker, marker.hasNote {
            HStack(spacing: 2) {
                if marker.hasImage {
                    Image(systemName: "photo.fill")
                }
                if marker.hasAudio {
                    Image(systemName: "waveform")
                }
                if !marker.hasImage && !marker.hasAudio {
                    Circle().frame(width: 4, height: 4)
                }
            }
            .font(.system(size: 7))
        } else {
            Color.clear
        }
    }

    private func cellForeground(inMonth: Bool, isSelected: Bool) -> Color {
        if isSelected { return .white }
        return inMonth ? .primary : .secondary.opacity(0.5)
    }

    // MARK: - Logic

    private func toggle(_ day: Date) {
        if let selectedDay, calendar.isDate(selectedDay, inSameDayAs: day) {
            self.selectedDay = nil
        } else {
            selectedDay = calendar.startOfDay(for: day)
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = next
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: visibleMonth)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// 42 days (6 weeks) covering the visible month, padded with the tail of the
    /// previous month and head of the next so the grid is always full.
    private var gridDays: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else {
            return []
        }
        let firstOfMonth = monthInterval.start
        let weekdayOffset = (calendar.component(.weekday, from: firstOfMonth) - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -weekdayOffset, to: firstOfMonth) else {
            return []
        }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
