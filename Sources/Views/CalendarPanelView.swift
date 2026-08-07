import SwiftUI

struct CalendarPanelView: View {
    @Environment(AppState.self) private var appState

    @State private var calendarState = CalendarToolState.shared
    @State private var reminderStore = CalendarToolReminderStore.shared
    @State private var reminderTitle = ""
    @State private var reminderLeadValue = CalendarToolReminderLeadTime.defaultValue.value
    @State private var reminderLeadUnit = CalendarToolReminderLeadUnit.defaultValueUnit
    @State private var editingReminderID: CalendarToolReminder.ID?
    @State private var dayFrames: [Date: CGRect] = [:]
    @State private var dragAnchorDate: Date?
    @FocusState private var calendarHasFocus: Bool
    @FocusState private var reminderTitleHasFocus: Bool
    @FocusState private var reminderSearchHasFocus: Bool

    private let calendar = Calendar.current
    private let dayColumns = Array(
        repeating: GridItem(.flexible(minimum: 24), spacing: 4),
        count: 7
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            navigationBar
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    periodContent

                    if calendarState.showsAgenda {
                        agendaSection
                    }
                }
                .padding(14)
            }
            .focusable()
            .focused($calendarHasFocus)
            .coordinateSpace(name: CalendarToolLayout.coordinateSpace)
            .simultaneousGesture(dayRangeDragGesture)
            .onPreferenceChange(CalendarDayFramePreferenceKey.self) { frames in
                dayFrames = frames
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .onAppear {
            applyPendingFocus()
        }
        .onChange(of: calendarState.reminderComposerFocusTick) { _, _ in
            applyPendingFocus()
        }
        .onChange(of: calendarState.reminderSearchFocusTick) { _, _ in
            applyPendingFocus()
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            moveSelection(byDays: -1, keyPress: press)
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            moveSelection(byDays: 1, keyPress: press)
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            moveSelection(byDays: -7, keyPress: press)
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            moveSelection(byDays: 7, keyPress: press)
        }
        .onExitCommand {
            if !calendarState.reminderSearchQuery.isEmpty {
                calendarState.reminderSearchQuery = ""
            } else if editingReminderID != nil {
                cancelEditingReminder()
            } else {
                appState.hideCalendarTool()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Calendar", systemImage: "calendar")
                .font(.headline)

            Spacer()

            Button {
                calendarState.focusReminderSearch()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search reminders (Command-F)")

            Button {
                calendarState.showsAgenda.toggle()
            } label: {
                Image(systemName: calendarState.showsAgenda ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .help(calendarState.showsAgenda ? "Hide Agenda" : "Show Agenda")

            PanelIconButton(systemName: "xmark", help: "Hide Calendar") {
                appState.hideCalendarTool()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var navigationBar: some View {
        VStack(spacing: 10) {
            Picker("Period", selection: $calendarState.period) {
                ForEach(CalendarToolPeriod.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            if calendarState.period == .week {
                Picker("Weeks shown", selection: $calendarState.visibleWeekCount) {
                    ForEach(1...10, id: \.self) { count in
                        Text(count == 1 ? "1 week" : "\(count) weeks")
                            .tag(count)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 180)
                .help("Choose how many weeks are visible")
            }

            HStack(spacing: 8) {
                navigationButton(direction: -1)

                Text(navigationTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)

                navigationButton(direction: 1)

                Button("Today") {
                    calendarState.goToToday(calendar: calendar)
                    calendarHasFocus = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Return to today")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func navigationButton(direction: Int) -> some View {
        Button {
            calendarState.navigatePeriod(direction: direction, calendar: calendar)
            calendarHasFocus = true
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(direction < 0 ? "Previous \(navigationSpanTitle)" : "Next \(navigationSpanTitle)")
        .accessibilityLabel(direction < 0 ? "Previous \(navigationSpanTitle)" : "Next \(navigationSpanTitle)")
    }

    @ViewBuilder
    private var periodContent: some View {
        switch calendarState.period {
        case .week:
            weekView
        case .month:
            monthView
        case .year:
            yearView
        }
    }

    private var weekView: some View {
        let weeks = CalendarToolDateMath.weekRows(
            containing: calendarState.anchorDate,
            numberOfWeeks: calendarState.visibleWeekCount,
            calendar: calendar
        )
        return VStack(spacing: 5) {
            weekdayHeader(font: .caption)

            VStack(spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    if index > 0,
                       CalendarToolDateMath.startsInDifferentMonth(
                           week,
                           than: weeks[index - 1],
                           calendar: calendar
                       ) {
                        Divider()
                            .padding(.vertical, 2)
                            .accessibilityHidden(true)
                    }

                    LazyVGrid(columns: dayColumns, spacing: 4) {
                        ForEach(week, id: \.self) { date in
                            dayButton(date, style: .week)
                        }
                    }
                }
            }

            if let selectedRange = calendarState.selectedRange {
                selectedRangeCard(selectedRange)
            }
        }
    }

    private var monthView: some View {
        let dates = CalendarToolDateMath.monthGrid(containing: calendarState.anchorDate, calendar: calendar)
        return VStack(spacing: 5) {
            weekdayHeader(font: .caption)

            LazyVGrid(columns: dayColumns, spacing: 4) {
                ForEach(dates, id: \.self) { date in
                    dayButton(date, style: .month)
                }
            }

            if let selectedRange = calendarState.selectedRange {
                selectedRangeCard(selectedRange)
                    .padding(.top, 7)
            }
        }
    }

    private var yearView: some View {
        let months = CalendarToolDateMath.months(inYearContaining: calendarState.anchorDate, calendar: calendar)
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140, maximum: 230), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(months, id: \.self) { month in
                miniMonth(month)
            }
        }
    }

    private func miniMonth(_ month: Date) -> some View {
        let dates = CalendarToolDateMath.monthGrid(containing: month, calendar: calendar)
        let columns = Array(repeating: GridItem(.flexible(minimum: 12), spacing: 1), count: 7)

        return VStack(spacing: 5) {
            Button {
                calendarState.period = .month
                calendarState.selectDate(month, calendar: calendar)
                calendarHasFocus = true
            } label: {
                HStack {
                    Text(month.formatted(.dateTime.month(.wide)))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(month.formatted(.dateTime.month(.wide)))")

            weekdayHeader(font: .system(size: 8), columns: columns)

            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(dates, id: \.self) { date in
                    miniDayButton(date, month: month)
                }
            }
        }
        .padding(9)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private func weekdayHeader(
        font: Font,
        columns: [GridItem]? = nil
    ) -> some View {
        LazyVGrid(columns: columns ?? dayColumns, spacing: 1) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(font.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private enum DayCellStyle: Equatable {
        case week
        case month
    }

    private enum DaySelectionRole {
        case none
        case middle
        case edge
    }

    private func dayButton(_ date: Date, style: DayCellStyle) -> some View {
        let isToday = calendar.isDateInToday(date)
        let selectionRole = selectionRole(for: date)
        let isInAnchorMonth = calendar.isDate(
            date,
            equalTo: calendarState.anchorDate,
            toGranularity: .month
        )
        let hasReminder = reminderStore.hasReminder(on: date, calendar: calendar)

        return Button {
            selectSingleDate(date)
        } label: {
            ZStack(alignment: .bottom) {
                VStack(spacing: style == .week ? 2 : 4) {
                    Text("\(calendar.component(.day, from: date))")
                        .font(.callout.weight(selectionRole == .edge || isToday ? .semibold : .regular))

                    if style == .week {
                        Text(date.formatted(.dateTime.month(.abbreviated)))
                            .font(.caption2)
                            .foregroundStyle(
                                selectionRole == .edge ? Color.white.opacity(0.86) : Color.secondary
                            )
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.top, style == .week ? 7 : 8)
                .padding(.bottom, hasReminder ? 12 : 6)

                if hasReminder {
                    reminderDot(isSelected: selectionRole == .edge)
                        .padding(.bottom, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: style == .week ? 54 : 52)
            .padding(.horizontal, 2)
            .background(dayBackground(isToday: isToday, selectionRole: selectionRole))
            .overlay(dayBorder(isToday: isToday, selectionRole: selectionRole))
            .shadow(
                color: selectionRole == .edge ? Color.accentColor.opacity(0.18) : Color.clear,
                radius: 6,
                y: 2
            )
            .foregroundStyle(
                dayForeground(
                    selectionRole: selectionRole,
                    isInPeriod: style == .week || isInAnchorMonth
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(dayFrameReporter(for: date))
        .help(date.formatted(date: .complete, time: .omitted))
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selectionRole == .none ? [] : [.isSelected])
    }

    private func miniDayButton(_ date: Date, month: Date) -> some View {
        let isInMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(date)
        let selectionRole = selectionRole(for: date)
        let hasReminder = reminderStore.hasReminder(on: date, calendar: calendar)

        return Button {
            selectSingleDate(date)
        } label: {
            ZStack(alignment: .bottom) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 8, weight: isToday ? .bold : .regular))
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)

                if hasReminder {
                    reminderDot(isSelected: selectionRole == .edge, size: 3.5)
                        .padding(.bottom, 2)
                }
            }
            .background(dayBackground(isToday: isToday, selectionRole: selectionRole))
            .overlay(dayBorder(isToday: isToday, selectionRole: selectionRole))
            .foregroundStyle(dayForeground(selectionRole: selectionRole, isInPeriod: isInMonth))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(date.formatted(date: .complete, time: .omitted))
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selectionRole == .none ? [] : [.isSelected])
    }

    @ViewBuilder
    private func dayBackground(isToday: Bool, selectionRole: DaySelectionRole) -> some View {
        switch selectionRole {
        case .edge:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor)
        case .middle:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
        case .none:
            if isToday {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.04))
            }
        }
    }

    @ViewBuilder
    private func dayBorder(isToday: Bool, selectionRole: DaySelectionRole) -> some View {
        let color: Color = {
            switch selectionRole {
            case .edge:
                return Color.accentColor.opacity(0.20)
            case .middle:
                return Color.accentColor.opacity(0.16)
            case .none:
                return isToday ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.08)
            }
        }()

        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(color, lineWidth: 1)
    }

    private func reminderDot(isSelected: Bool, size: CGFloat = 5) -> some View {
        Circle()
            .fill(isSelected ? Color.white.opacity(0.94) : Color.accentColor)
            .frame(width: size, height: size)
            .shadow(color: Color.black.opacity(isSelected ? 0.14 : 0), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }

    private func dayForeground(selectionRole: DaySelectionRole, isInPeriod: Bool) -> Color {
        if selectionRole == .edge { return .white }
        if selectionRole == .middle { return isInPeriod ? .primary : .secondary.opacity(0.68) }
        return isInPeriod ? .primary : .secondary.opacity(0.48)
    }

    private func selectionRole(for date: Date) -> DaySelectionRole {
        guard let selectedRange = calendarState.selectedRange,
              selectedRange.contains(date, calendar: calendar) else {
            return .none
        }
        if calendar.isDate(date, inSameDayAs: selectedRange.startDate)
            || calendar.isDate(date, inSameDayAs: selectedRange.endDate) {
            return .edge
        }
        return .middle
    }

    private func dayFrameReporter(for date: Date) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: CalendarDayFramePreferenceKey.self,
                value: [
                    calendar.startOfDay(for: date): proxy.frame(
                        in: .named(CalendarToolLayout.coordinateSpace)
                    )
                ]
            )
        }
    }

    private var dayRangeDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CalendarToolLayout.coordinateSpace))
            .onChanged { value in
                guard calendarState.period != .year else { return }
                let anchor = dragAnchorDate ?? date(at: value.startLocation)
                guard let anchor else { return }
                if dragAnchorDate == nil {
                    dragAnchorDate = anchor
                }
                guard let current = date(at: value.location) else { return }
                calendarState.selectRange(
                    anchor: anchor,
                    current: current,
                    calendar: calendar
                )
                calendarHasFocus = true
            }
            .onEnded { _ in
                dragAnchorDate = nil
            }
    }

    private func date(at point: CGPoint) -> Date? {
        dayFrames.first { _, frame in
            frame.insetBy(dx: -2, dy: -2).contains(point)
        }?.key
    }

    private func selectSingleDate(_ date: Date) {
        cancelEditingReminder()
        calendarState.selectDate(date, calendar: calendar)
        calendarHasFocus = true
    }

    private func selectedRangeCard(_ range: CalendarToolDateRange) -> some View {
        let matchingReminders = reminderStore.reminders(overlapping: range)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "calendar")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rangeTitle(range))
                        .font(.callout.weight(.semibold))
                    Text(rangeDetail(range))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !matchingReminders.isEmpty {
                    Text("\(matchingReminders.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityLabel(reminderCountLabel(matchingReminders.count))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        editingReminderID == nil ? "New Reminder" : "Edit Reminder",
                        systemImage: editingReminderID == nil ? "bell.badge" : "pencil"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Spacer()

                    if editingReminderID != nil {
                        Button {
                            cancelEditingReminder()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel editing")
                    }
                }

                HStack(spacing: 8) {
                    TextField("What should I remember?", text: $reminderTitle)
                        .textFieldStyle(.roundedBorder)
                        .focused($reminderTitleHasFocus)
                        .onSubmit {
                            saveReminder(for: range)
                        }

                    Button {
                        saveReminder(for: range)
                    } label: {
                        Label(
                            editingReminderID == nil ? "Add" : "Save",
                            systemImage: editingReminderID == nil ? "plus" : "checkmark"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                reminderNotificationControls
            }
            .padding(9)
            .background(
                Color.secondary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            if !matchingReminders.isEmpty {
                VStack(spacing: 6) {
                    ForEach(matchingReminders) { reminder in
                        HStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.12))
                                Image(systemName: "bell.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                            }
                            .frame(width: 22, height: 22)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(reminder.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(rangeTitle(reminder.range)) • Notify \(reminder.notificationLeadTime.label)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                beginEditing(reminder)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Edit reminder")

                            Button {
                                deleteReminder(reminder)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Delete reminder")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            reminder.id == calendarState.selectedReminderID
                                ? Color.accentColor.opacity(0.10)
                                : Color.secondary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            calendarState.selectReminder(reminder, calendar: calendar)
                            calendarHasFocus = true
                        }
                        .contextMenu {
                            Button("Edit") { beginEditing(reminder) }
                            Button("Duplicate") { duplicateReminder(reminder) }
                            Divider()
                            Button("Delete", role: .destructive) { deleteReminder(reminder) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private var agendaSection: some View {
        let reminders = reminderStore.filteredReminders(
            query: calendarState.reminderSearchQuery,
            scope: calendarState.agendaScope,
            calendar: calendar
        )

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("Agenda", systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.semibold))

                if !reminders.isEmpty {
                    Text("\(reminders.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }

                Spacer()

                Picker("Agenda scope", selection: $calendarState.agendaScope) {
                    ForEach(CalendarToolAgendaScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 96)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search titles, dates, or notification timing", text: $calendarState.reminderSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($reminderSearchHasFocus)
                    .onSubmit {
                        if let first = reminders.first {
                            calendarState.selectReminder(first, calendar: calendar)
                        }
                    }

                if !calendarState.reminderSearchQuery.isEmpty {
                    Button {
                        calendarState.reminderSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))

            if reminders.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: calendarState.reminderSearchQuery.isEmpty ? "calendar.badge.checkmark" : "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(calendarState.reminderSearchQuery.isEmpty ? "No upcoming reminders" : "No matching reminders")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                LazyVStack(spacing: 5) {
                    ForEach(reminders) { reminder in
                        agendaRow(reminder)
                    }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private func agendaRow(_ reminder: CalendarToolReminder) -> some View {
        let isSelected = reminder.id == calendarState.selectedReminderID
        let isPast = reminder.range.endDate < calendar.startOfDay(for: .now)

        return HStack(spacing: 9) {
            VStack(spacing: 0) {
                Text(reminder.range.startDate.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 8, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                Text("\(calendar.component(.day, from: reminder.range.startDate))")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            .frame(width: 34, height: 36)
            .background(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(rangeTitle(reminder.range))
                    Text("•")
                    Text(reminder.notificationLeadTime.label)
                    if isPast {
                        Text("• Past")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                beginEditing(reminder)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Edit reminder")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            calendarState.selectReminder(reminder, calendar: calendar)
            calendarHasFocus = true
        }
        .contextMenu {
            Button("Edit") { beginEditing(reminder) }
            Button("Duplicate") { duplicateReminder(reminder) }
            Divider()
            Button("Delete", role: .destructive) { deleteReminder(reminder) }
        }
    }

    private var reminderNotificationControls: some View {
        HStack(spacing: 8) {
            Label("Notify", systemImage: "bell.and.waves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("1", value: $reminderLeadValue, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 54)
                .onChange(of: reminderLeadValue) { _, newValue in
                    reminderLeadValue = CalendarToolReminderLeadTime.clampedValue(newValue)
                }
                .accessibilityLabel("Reminder lead time")

            Picker("Lead time unit", selection: $reminderLeadUnit) {
                ForEach(CalendarToolReminderLeadUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 86)

            Text("before")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private func saveReminder(for range: CalendarToolDateRange) {
        let leadTime = CalendarToolReminderLeadTime(
            value: reminderLeadValue,
            unit: reminderLeadUnit
        )
        let savedReminder: CalendarToolReminder?
        if let editingReminderID {
            savedReminder = reminderStore.update(
                editingReminderID,
                title: reminderTitle,
                range: range,
                notificationLeadTime: leadTime,
                calendar: calendar
            )
        } else {
            savedReminder = reminderStore.add(
                title: reminderTitle,
                range: range,
                notificationLeadTime: leadTime,
                calendar: calendar
            )
        }
        if let savedReminder {
            calendarState.selectReminder(savedReminder, calendar: calendar)
        }
        cancelEditingReminder(clearSelection: false)
    }

    private func beginEditing(_ reminder: CalendarToolReminder) {
        editingReminderID = reminder.id
        reminderTitle = reminder.title
        reminderLeadValue = reminder.notificationLeadTime.value
        reminderLeadUnit = reminder.notificationLeadTime.unit
        calendarState.selectReminder(reminder, calendar: calendar)
        reminderTitleHasFocus = true
    }

    private func cancelEditingReminder(clearSelection: Bool = false) {
        editingReminderID = nil
        reminderTitle = ""
        reminderLeadValue = CalendarToolReminderLeadTime.defaultValue.value
        reminderLeadUnit = CalendarToolReminderLeadUnit.defaultValueUnit
        if clearSelection {
            calendarState.selectedReminderID = nil
        }
    }

    private func duplicateReminder(_ reminder: CalendarToolReminder) {
        if let copy = reminderStore.duplicate(reminder.id, calendar: calendar) {
            calendarState.selectReminder(copy, calendar: calendar)
        }
    }

    private func deleteReminder(_ reminder: CalendarToolReminder) {
        reminderStore.delete(reminder)
        if calendarState.selectedReminderID == reminder.id {
            calendarState.selectedReminderID = nil
        }
        if editingReminderID == reminder.id {
            cancelEditingReminder()
        }
    }

    private func moveSelection(byDays offset: Int, keyPress: KeyPress) -> KeyPress.Result {
        guard calendarHasFocus else { return .ignored }
        calendarState.moveSelection(
            byDays: offset,
            extending: keyPress.modifiers.contains(.shift),
            calendar: calendar
        )
        return .handled
    }

    private func applyPendingFocus() {
        switch calendarState.pendingFocusTarget {
        case .reminderComposer:
            reminderTitleHasFocus = true
        case .reminderSearch:
            reminderSearchHasFocus = true
        case nil:
            return
        }
        calendarState.pendingFocusTarget = nil
    }

    private func reminderCountLabel(_ count: Int) -> String {
        count == 1 ? "1 reminder" : "\(count) reminders"
    }

    private func rangeTitle(_ range: CalendarToolDateRange) -> String {
        if calendar.isDate(range.startDate, inSameDayAs: range.endDate) {
            return range.startDate.formatted(date: .long, time: .omitted)
        }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: range.startDate, to: range.endDate)
    }

    private func rangeDetail(_ range: CalendarToolDateRange) -> String {
        let dayCount = range.dayCount(calendar: calendar)
        if dayCount == 1 {
            return range.startDate.formatted(.dateTime.weekday(.wide))
        }
        return "\(dayCount) days selected"
    }

    private var navigationTitle: String {
        switch calendarState.period {
        case .week:
            let dates = CalendarToolDateMath.weekDates(
                containing: calendarState.anchorDate,
                numberOfWeeks: calendarState.visibleWeekCount,
                calendar: calendar
            )
            guard let first = dates.first, let last = dates.last else { return "Week" }
            let formatter = DateIntervalFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: first, to: last)
        case .month:
            return calendarState.anchorDate.formatted(.dateTime.month(.wide).year())
        case .year:
            return calendarState.anchorDate.formatted(.dateTime.year())
        }
    }

    private var navigationSpanTitle: String {
        if calendarState.period == .week {
            return calendarState.visibleWeekCount == 1
                ? "week"
                : "\(calendarState.visibleWeekCount) weeks"
        }
        return calendarState.period.title.lowercased()
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstIndex = calendar.firstWeekday - 1
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }
}

private enum CalendarToolLayout {
    static let coordinateSpace = "calendarToolCoordinateSpace"
}

private struct CalendarDayFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Date: CGRect] { [:] }

    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
