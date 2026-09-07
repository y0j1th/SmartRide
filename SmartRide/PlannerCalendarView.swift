//
//  PlannerCalendarView.swift
//  SmartRide
//
//  A calendar at the top of Planner — a small accent dot marks any day with a
//  reminder (recurring weekday/specific-date match, or a one-shot reminder), and
//  tapping a day filters the list below to just that day. Defaults to a compact
//  week strip; a segmented control expands it to a full month grid or a 12-month
//  year overview, and back down again. Past days render exactly like any other
//  day — full opacity, still tappable — since seeing what already happened is the
//  point of a calendar; only the *creation* flows (AddRecurringReminderView) stop
//  you from scheduling something new in the past. A recurring reminder's dot also
//  only appears on past days from on/after the day it was actually created, so it
//  doesn't look like it fired before it existed.
//

import SwiftUI

private enum CalendarDisplayMode: String, CaseIterable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
}

struct PlannerCalendarView: View {
    let recurringReminders: [RecurringReminder]
    let oneShotReminders: [ReminderItem]
    @Binding var selectedDate: Date?

    @State private var displayMode: CalendarDisplayMode = .week
    @State private var anchorDate = Date()

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 14) {
            navHeader
            modeSwitcher

            Group {
                switch displayMode {
                case .week: weekView
                case .month: monthView
                case .year: yearView
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color(.secondarySystemBackground)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: displayMode)
    }

    // MARK: - Header

    private var navHeader: some View {
        HStack {
            Button {
                changePeriod(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(periodTitle)
                .font(.headline)
                .contentTransition(.numericText())

            Spacer()

            Button {
                changePeriod(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 8) {
            ForEach(CalendarDisplayMode.allCases, id: \.self) { mode in
                Button {
                    displayMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(displayMode == mode ? Color.accentColor : Color(.secondarySystemBackground))
                        .foregroundStyle(displayMode == mode ? .white : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // One button, contextual to whichever mode is active — jumps back to
            // the current week, month, or year depending on `displayMode`.
            Button {
                anchorDate = Date()
            } label: {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(Color.accentColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var periodTitle: String {
        let formatter = DateFormatter()
        switch displayMode {
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchorDate) else { return "" }
            let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            formatter.dateFormat = calendar.isDate(interval.start, equalTo: end, toGranularity: .month) ? "MMM d" : "MMM d"
            let startText = formatter.string(from: interval.start)
            let endText = formatter.string(from: end)
            return "\(startText) – \(endText)"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: anchorDate)
        case .year:
            formatter.dateFormat = "yyyy"
            return formatter.string(from: anchorDate)
        }
    }

    private func changePeriod(_ delta: Int) {
        let component: Calendar.Component
        switch displayMode {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        guard let newDate = calendar.date(byAdding: component, value: delta, to: anchorDate) else { return }
        anchorDate = newDate
    }

    // MARK: - Week

    private var weekDates: [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchorDate) else { return [] }
        var days: [Date] = []
        var current = interval.start
        while current < interval.end {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    private var weekView: some View {
        HStack(spacing: 4) {
            ForEach(weekDates, id: \.self) { date in
                VStack(spacing: 4) {
                    Text(shortWeekdaySymbol(for: date))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    dayCell(date, minHeight: 44)
                }
            }
        }
    }

    private func shortWeekdaySymbol(for date: Date) -> String {
        calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: date) - 1]
    }

    // MARK: - Month

    private var weekdayHeader: some View {
        HStack {
            ForEach(Array(calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var daysInMonthGrid: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchorDate) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        var current = monthInterval.start
        while current < monthInterval.end {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    private var monthView: some View {
        VStack(spacing: 6) {
            weekdayHeader
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(daysInMonthGrid.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayCell(date, minHeight: 40)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
    }

    // MARK: - Year

    private var monthsInYear: [Date] {
        guard let yearInterval = calendar.dateInterval(of: .year, for: anchorDate) else { return [] }
        var months: [Date] = []
        var current = yearInterval.start
        for _ in 0..<12 {
            months.append(current)
            guard let next = calendar.date(byAdding: .month, value: 1, to: current) else { break }
            current = next
        }
        return months
    }

    private var yearView: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(monthsInYear, id: \.self) { month in
                monthCell(month)
            }
        }
    }

    private func monthCell(_ month: Date) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let isCurrentMonth = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
        let hasAny = monthHasReminder(month)

        return Button {
            anchorDate = month
            displayMode = .month
        } label: {
            VStack(spacing: 4) {
                Text(formatter.string(from: month))
                    .font(.subheadline.weight(isCurrentMonth ? .bold : .medium))
                Circle()
                    .fill(hasAny ? Color.accentColor : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isCurrentMonth ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private func monthHasReminder(_ month: Date) -> Bool {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return false }
        var current = interval.start
        while current < interval.end {
            if hasReminder(on: current) { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return false
    }

    // MARK: - Shared day cell

    private func dayCell(_ date: Date, minHeight: CGFloat) -> some View {
        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let isToday = calendar.isDateInToday(date)
        let hasReminder = hasReminder(on: date)

        return Button {
            selectedDate = isSelected ? nil : date
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Circle()
                    .fill(hasReminder ? (isSelected ? .white : Color.accentColor) : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(
                Circle()
                    .fill(isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.18) : .clear))
                    .padding(2)
            )
        }
        .buttonStyle(.plain)
    }

    /// A weekly reminder's dot only shows on a past day if the reminder already
    /// existed by then — otherwise a reminder created today would look like it had
    /// been firing every week going back indefinitely, which never actually happened.
    private func hasReminder(on date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let dayStart = calendar.startOfDay(for: date)
        let matchesRecurring = recurringReminders.contains { reminder in
            guard reminder.isEnabled else { return false }
            guard calendar.startOfDay(for: reminder.createdAt) <= dayStart else { return false }
            if reminder.usesSpecificDates {
                return reminder.specificDates.contains { calendar.isDate($0, inSameDayAs: date) }
            }
            return reminder.weekdays.contains(weekday)
        }
        if matchesRecurring { return true }
        return oneShotReminders.contains { calendar.isDate($0.scheduledTime, inSameDayAs: date) }
    }
}
