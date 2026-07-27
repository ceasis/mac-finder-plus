import Foundation
import Observation
@preconcurrency import UserNotifications

enum CalendarToolPeriod: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

enum CalendarToolDateMath {
    static func date(
        byMoving period: CalendarToolPeriod,
        offset: Int,
        from date: Date,
        calendar: Calendar = .current
    ) -> Date {
        calendar.date(byAdding: period.calendarComponent, value: offset, to: date) ?? date
    }

    static func weekDates(
        containing date: Date,
        numberOfWeeks: Int = 1,
        calendar: Calendar = .current
    ) -> [Date] {
        weekRows(
            containing: date,
            numberOfWeeks: numberOfWeeks,
            calendar: calendar
        ).flatMap { $0 }
    }

    static func weekRows(
        containing date: Date,
        numberOfWeeks: Int = 1,
        calendar: Calendar = .current
    ) -> [[Date]] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        let weekCount = min(max(numberOfWeeks, 1), 10)
        return (0..<weekCount).map { weekOffset in
            (0..<7).compactMap { dayOffset in
                calendar.date(
                    byAdding: .day,
                    value: (weekOffset * 7) + dayOffset,
                    to: interval.start
                )
            }
        }
    }

    static func startsInDifferentMonth(
        _ week: [Date],
        than previousWeek: [Date],
        calendar: Calendar = .current
    ) -> Bool {
        guard let start = week.first, let previousStart = previousWeek.first else { return false }
        return !calendar.isDate(start, equalTo: previousStart, toGranularity: .month)
    }

    static func monthGrid(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let firstWeekdayOffset = (
            calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7
        ) % 7
        guard let gridStart = calendar.date(
            byAdding: .day,
            value: -firstWeekdayOffset,
            to: month.start
        ) else { return [] }

        return (0..<42).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: gridStart)
        }
    }

    static func months(inYearContaining date: Date, calendar: Calendar = .current) -> [Date] {
        guard let year = calendar.dateInterval(of: .year, for: date) else { return [] }
        return (0..<12).compactMap { monthOffset in
            calendar.date(byAdding: .month, value: monthOffset, to: year.start)
        }
    }
}

struct CalendarToolDateRange: Codable, Equatable, Sendable {
    let startDate: Date
    let endDate: Date

    init(startDate: Date, endDate: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        if start <= end {
            self.startDate = start
            self.endDate = end
        } else {
            self.startDate = end
            self.endDate = start
        }
    }

    init(single date: Date, calendar: Calendar = .current) {
        self.init(startDate: date, endDate: date, calendar: calendar)
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= startDate && day <= endDate
    }

    func overlaps(_ other: CalendarToolDateRange) -> Bool {
        startDate <= other.endDate && other.startDate <= endDate
    }

    func dayCount(calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.day], from: startDate, to: endDate)
        return max((components.day ?? 0) + 1, 1)
    }
}

enum CalendarToolReminderLeadUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    static let defaultValueUnit: CalendarToolReminderLeadUnit = .days

    case hours
    case days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hours: "Hours"
        case .days: "Days"
        }
    }

    func label(for value: Int) -> String {
        let clamped = CalendarToolReminderLeadTime.clampedValue(value)
        switch self {
        case .hours:
            return clamped == 1 ? "1 hour before" : "\(clamped) hours before"
        case .days:
            return clamped == 1 ? "1 day before" : "\(clamped) days before"
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .hours: .hour
        case .days: .day
        }
    }
}

struct CalendarToolReminderLeadTime: Codable, Equatable, Sendable {
    static let allowedRange = 1...365
    static let defaultValue = CalendarToolReminderLeadTime(value: 1, unit: .days)

    var value: Int
    var unit: CalendarToolReminderLeadUnit

    init(value: Int, unit: CalendarToolReminderLeadUnit) {
        self.value = Self.clampedValue(value)
        self.unit = unit
    }

    var label: String {
        unit.label(for: value)
    }

    func triggerDate(for range: CalendarToolDateRange, calendar: Calendar = .current) -> Date? {
        calendar.date(
            byAdding: unit.calendarComponent,
            value: -Self.clampedValue(value),
            to: range.startDate
        )
    }

    static func clampedValue(_ value: Int) -> Int {
        min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }
}

struct CalendarToolReminder: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var range: CalendarToolDateRange
    var notificationLeadTime: CalendarToolReminderLeadTime
    let createdAt: Date

    var notificationIdentifier: String {
        "calendarTool.reminder.\(id.uuidString)"
    }

    init(
        id: UUID = UUID(),
        title: String,
        range: CalendarToolDateRange,
        notificationLeadTime: CalendarToolReminderLeadTime = .defaultValue,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.range = range
        self.notificationLeadTime = notificationLeadTime
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case range
        case notificationLeadTime
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        range = try container.decode(CalendarToolDateRange.self, forKey: .range)
        notificationLeadTime = try container.decodeIfPresent(
            CalendarToolReminderLeadTime.self,
            forKey: .notificationLeadTime
        ) ?? .defaultValue
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

protocol CalendarToolReminderNotificationScheduling: AnyObject {
    func schedule(_ reminder: CalendarToolReminder, calendar: Calendar, now: Date)
    func cancel(_ reminder: CalendarToolReminder)
}

final class CalendarToolUserNotificationScheduler: CalendarToolReminderNotificationScheduling {
    static let shared = CalendarToolUserNotificationScheduler()

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func schedule(_ reminder: CalendarToolReminder, calendar: Calendar = .current, now: Date = .now) {
        guard let triggerDate = reminder.notificationLeadTime.triggerDate(
            for: reminder.range,
            calendar: calendar
        ), triggerDate > now else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.subtitle = "Calendar reminder"
        content.body = Self.notificationBody(for: reminder)
        content.sound = .default

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.notificationIdentifier,
            content: content,
            trigger: trigger
        )

        center.removePendingNotificationRequests(withIdentifiers: [reminder.notificationIdentifier])
        Task { [center] in
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
                try await center.add(request)
            } catch {
                // Keep reminders usable even if notification permission is denied or scheduling fails.
            }
        }
    }

    func cancel(_ reminder: CalendarToolReminder) {
        center.removePendingNotificationRequests(withIdentifiers: [reminder.notificationIdentifier])
    }

    private static func notificationBody(for reminder: CalendarToolReminder) -> String {
        if reminder.range.startDate == reminder.range.endDate {
            let date = reminder.range.startDate.formatted(date: .long, time: .omitted)
            return "\(date) • \(reminder.notificationLeadTime.label)"
        }

        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: reminder.range.startDate, to: reminder.range.endDate)) • \(reminder.notificationLeadTime.label)"
    }
}

@Observable
@MainActor
final class CalendarToolReminderStore {
    static let shared = CalendarToolReminderStore()

    private enum Key {
        static let reminders = "calendarTool.reminders"
    }

    private(set) var reminders: [CalendarToolReminder]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notificationScheduler: CalendarToolReminderNotificationScheduling

    init(
        defaults: UserDefaults = .standard,
        notificationScheduler: CalendarToolReminderNotificationScheduling = CalendarToolUserNotificationScheduler.shared
    ) {
        self.defaults = defaults
        self.notificationScheduler = notificationScheduler
        reminders = Self.load(from: defaults)
    }

    @discardableResult
    func add(
        title: String,
        range: CalendarToolDateRange,
        notificationLeadTime: CalendarToolReminderLeadTime = .defaultValue,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> CalendarToolReminder {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let reminder = CalendarToolReminder(
            title: trimmed.isEmpty ? "Reminder" : trimmed,
            range: range,
            notificationLeadTime: notificationLeadTime,
            createdAt: now
        )
        reminders.append(reminder)
        reminders.sort {
            if $0.range.startDate == $1.range.startDate {
                return $0.createdAt < $1.createdAt
            }
            return $0.range.startDate < $1.range.startDate
        }
        persist()
        notificationScheduler.schedule(reminder, calendar: calendar, now: now)
        return reminder
    }

    func delete(_ reminder: CalendarToolReminder) {
        reminders.removeAll { $0.id == reminder.id }
        persist()
        notificationScheduler.cancel(reminder)
    }

    func reminders(overlapping range: CalendarToolDateRange) -> [CalendarToolReminder] {
        reminders.filter { $0.range.overlaps(range) }
    }

    func hasReminder(on date: Date, calendar: Calendar = .current) -> Bool {
        reminders.contains { $0.range.contains(date, calendar: calendar) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        defaults.set(data, forKey: Key.reminders)
    }

    private static func load(from defaults: UserDefaults) -> [CalendarToolReminder] {
        guard let data = defaults.data(forKey: Key.reminders),
              let reminders = try? JSONDecoder().decode([CalendarToolReminder].self, from: data) else {
            return []
        }
        return reminders.sorted {
            if $0.range.startDate == $1.range.startDate {
                return $0.createdAt < $1.createdAt
            }
            return $0.range.startDate < $1.range.startDate
        }
    }
}
