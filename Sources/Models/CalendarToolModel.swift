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

enum CalendarToolAgendaScope: String, CaseIterable, Identifiable, Sendable {
    case upcoming
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upcoming: "Upcoming"
        case .all: "All"
        }
    }
}

enum CalendarToolFocusTarget: Sendable {
    case reminderComposer
    case reminderSearch
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

enum CalendarToolReminderSearch {
    static func terms(in query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var insideQuotes = false

        for character in query {
            if character == "\"" {
                insideQuotes.toggle()
                if !insideQuotes {
                    append(&terms, token: &current)
                }
            } else if character.isWhitespace && !insideQuotes {
                append(&terms, token: &current)
            } else {
                current.append(character)
            }
        }
        append(&terms, token: &current)
        return terms
    }

    static func matches(_ reminder: CalendarToolReminder, query: String) -> Bool {
        let queryTerms = terms(in: query)
        guard !queryTerms.isEmpty else { return true }

        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        let searchableText = [
            reminder.title,
            formatter.string(from: reminder.range.startDate, to: reminder.range.endDate),
            reminder.notificationLeadTime.label
        ]
        .joined(separator: " ")
        .localizedLowercase

        return queryTerms.allSatisfy { searchableText.contains($0.localizedLowercase) }
    }

    private static func append(_ terms: inout [String], token: inout String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            terms.append(trimmed)
        }
        token = ""
    }
}

@Observable
@MainActor
final class CalendarToolState {
    static let shared = CalendarToolState()

    private enum Key {
        static let period = "calendarTool.period"
        static let anchorDate = "calendarTool.anchorDate"
        static let weeksShown = "calendarTool.weeksShown"
        static let showsAgenda = "calendarTool.showsAgenda"
        static let agendaScope = "calendarTool.agendaScope"
    }

    var period: CalendarToolPeriod {
        didSet { defaults.set(period.rawValue, forKey: Key.period) }
    }
    var anchorDate: Date {
        didSet { defaults.set(anchorDate, forKey: Key.anchorDate) }
    }
    var selectedRange: CalendarToolDateRange?
    var visibleWeekCount: Int {
        didSet { defaults.set(visibleWeekCount, forKey: Key.weeksShown) }
    }
    var showsAgenda: Bool {
        didSet { defaults.set(showsAgenda, forKey: Key.showsAgenda) }
    }
    var agendaScope: CalendarToolAgendaScope {
        didSet { defaults.set(agendaScope.rawValue, forKey: Key.agendaScope) }
    }
    var reminderSearchQuery = ""
    var selectedReminderID: UUID?
    var reminderComposerFocusTick = 0
    var reminderSearchFocusTick = 0
    var pendingFocusTarget: CalendarToolFocusTarget?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var selectionAnchorDate: Date
    @ObservationIgnored private var selectionFocusDate: Date

    init(
        defaults: UserDefaults = .standard,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.defaults = defaults
        period = CalendarToolPeriod(
            rawValue: defaults.string(forKey: Key.period) ?? ""
        ) ?? .month
        let restoredAnchorDate = defaults.object(forKey: Key.anchorDate) as? Date ?? now
        anchorDate = restoredAnchorDate
        let storedWeekCount = defaults.integer(forKey: Key.weeksShown)
        visibleWeekCount = min(max(storedWeekCount == 0 ? 1 : storedWeekCount, 1), 10)
        showsAgenda = defaults.object(forKey: Key.showsAgenda) as? Bool ?? true
        agendaScope = CalendarToolAgendaScope(
            rawValue: defaults.string(forKey: Key.agendaScope) ?? ""
        ) ?? .upcoming
        let day = calendar.startOfDay(for: restoredAnchorDate)
        selectedRange = CalendarToolDateRange(single: day, calendar: calendar)
        selectionAnchorDate = day
        selectionFocusDate = day
    }

    func selectDate(_ date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        selectedRange = CalendarToolDateRange(single: day, calendar: calendar)
        selectionAnchorDate = day
        selectionFocusDate = day
        anchorDate = day
        selectedReminderID = nil
    }

    func selectRange(
        anchor: Date,
        current: Date,
        calendar: Calendar = .current
    ) {
        let anchorDay = calendar.startOfDay(for: anchor)
        let currentDay = calendar.startOfDay(for: current)
        selectedRange = CalendarToolDateRange(
            startDate: anchorDay,
            endDate: currentDay,
            calendar: calendar
        )
        selectionAnchorDate = anchorDay
        selectionFocusDate = currentDay
        anchorDate = currentDay
        selectedReminderID = nil
    }

    func moveSelection(
        byDays offset: Int,
        extending: Bool,
        calendar: Calendar = .current
    ) {
        guard let next = calendar.date(
            byAdding: .day,
            value: offset,
            to: selectionFocusDate
        ) else { return }

        if extending {
            selectRange(anchor: selectionAnchorDate, current: next, calendar: calendar)
        } else {
            selectDate(next, calendar: calendar)
        }
    }

    func navigatePeriod(direction: Int, calendar: Calendar = .current) {
        let offset = period == .week ? direction * visibleWeekCount : direction
        let destination = CalendarToolDateMath.date(
            byMoving: period,
            offset: offset,
            from: anchorDate,
            calendar: calendar
        )
        selectDate(destination, calendar: calendar)
    }

    func goToToday(now: Date = .now, calendar: Calendar = .current) {
        selectDate(now, calendar: calendar)
    }

    func selectReminder(_ reminder: CalendarToolReminder, calendar: Calendar = .current) {
        selectedRange = reminder.range
        selectionAnchorDate = reminder.range.startDate
        selectionFocusDate = reminder.range.endDate
        anchorDate = reminder.range.startDate
        selectedReminderID = reminder.id
    }

    func focusReminderComposer() {
        if period == .year {
            period = .month
        }
        pendingFocusTarget = .reminderComposer
        reminderComposerFocusTick += 1
    }

    func focusReminderSearch() {
        showsAgenda = true
        pendingFocusTarget = .reminderSearch
        reminderSearchFocusTick += 1
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

@MainActor
protocol CalendarToolReminderNotificationScheduling: AnyObject {
    func schedule(_ reminder: CalendarToolReminder, calendar: Calendar, now: Date)
    func cancel(_ reminder: CalendarToolReminder)
}

@MainActor
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

    @discardableResult
    func update(
        _ reminderID: CalendarToolReminder.ID,
        title: String,
        range: CalendarToolDateRange,
        notificationLeadTime: CalendarToolReminderLeadTime,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> CalendarToolReminder? {
        guard let index = reminders.firstIndex(where: { $0.id == reminderID }) else {
            return nil
        }

        let existing = reminders[index]
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = CalendarToolReminder(
            id: existing.id,
            title: trimmed.isEmpty ? "Reminder" : trimmed,
            range: range,
            notificationLeadTime: notificationLeadTime,
            createdAt: existing.createdAt
        )
        notificationScheduler.cancel(existing)
        reminders[index] = updated
        sortAndPersist()
        notificationScheduler.schedule(updated, calendar: calendar, now: now)
        return updated
    }

    @discardableResult
    func duplicate(
        _ reminderID: CalendarToolReminder.ID,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> CalendarToolReminder? {
        guard let reminder = reminder(id: reminderID) else { return nil }
        return add(
            title: "\(reminder.title) Copy",
            range: reminder.range,
            notificationLeadTime: reminder.notificationLeadTime,
            calendar: calendar,
            now: now
        )
    }

    func reminder(id: CalendarToolReminder.ID?) -> CalendarToolReminder? {
        guard let id else { return nil }
        return reminders.first { $0.id == id }
    }

    func filteredReminders(
        query: String,
        scope: CalendarToolAgendaScope,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [CalendarToolReminder] {
        let today = calendar.startOfDay(for: now)
        return reminders.filter { reminder in
            let isInScope = scope == .all || reminder.range.endDate >= today
            return isInScope && CalendarToolReminderSearch.matches(reminder, query: query)
        }
    }

    func reminders(overlapping range: CalendarToolDateRange) -> [CalendarToolReminder] {
        reminders.filter { $0.range.overlaps(range) }
    }

    func hasReminder(on date: Date, calendar: Calendar = .current) -> Bool {
        reminders.contains { $0.range.contains(date, calendar: calendar) }
    }

    private func sortAndPersist() {
        reminders.sort {
            if $0.range.startDate == $1.range.startDate {
                return $0.createdAt < $1.createdAt
            }
            return $0.range.startDate < $1.range.startDate
        }
        persist()
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
