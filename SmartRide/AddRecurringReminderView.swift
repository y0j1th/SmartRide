//
//  AddRecurringReminderView.swift
//  SmartRide
//
//  Sheet for setting up (or editing) a weekly recurring reminder — the Planner
//  feature on its own tab. Two modes: Start At ("leave by 8:00 AM") and Reach By
//  ("arrive by 9:00 AM", leave time computed fresh each day by
//  RecurringReminderScheduler), each firing a chosen number of minutes ahead of
//  the relevant time rather than exactly at it.
//

import SwiftUI
import CoreLocation
import SwiftData

struct AddRecurringReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allReminders: [RecurringReminder]

    let existing: RecurringReminder?

    @State private var name: String
    @State private var origin: String
    @State private var originCoordinate: CLLocationCoordinate2D?
    @State private var destination: String
    @State private var destinationCoordinate: CLLocationCoordinate2D?
    @State private var plannerMode: PlannerMode
    @State private var time: Date
    @State private var selectedWeekdays: Set<Int>
    /// Non-empty means "specific dates" mode: the weekday circles are hidden and
    /// this reminder fires only on these exact dates instead of repeating weekly.
    @State private var specificDates: [Date]
    @State private var travelMode: TravelMode
    @State private var leadOption: LeadOption
    @State private var customLeadMinutes: Int
    @State private var showCalendarPicker = false
    @State private var calendarSelection: Set<DateComponents> = []
    @State private var calendarConfirmationText: String?
    @State private var showConflictAlert = false

    private enum LeadOption: CaseIterable, Hashable {
        case five, ten, fifteen, custom

        var label: String {
            switch self {
            case .five: return "5 min"
            case .ten: return "10 min"
            case .fifteen: return "15 min"
            case .custom: return "Custom"
            }
        }

        var minutes: Int? {
            switch self {
            case .five: return 5
            case .ten: return 10
            case .fifteen: return 15
            case .custom: return nil
            }
        }

        static func matching(_ minutes: Int) -> LeadOption {
            allCases.first { $0.minutes == minutes } ?? .custom
        }
    }

    private let weekdaySymbols = Calendar.current.shortWeekdaySymbols // index 0 = Sunday = weekday 1

    init(
        existing: RecurringReminder? = nil,
        prefilledOrigin: String = "",
        prefilledDestination: String = "",
        prefilledTravelMode: TravelMode = .driving
    ) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _origin = State(initialValue: existing?.origin ?? prefilledOrigin)
        _destination = State(initialValue: existing?.destination ?? prefilledDestination)
        _plannerMode = State(initialValue: existing?.plannerMode ?? .startAt)
        _travelMode = State(initialValue: existing?.travelMode ?? prefilledTravelMode)
        _selectedWeekdays = State(initialValue: Set(existing?.weekdays ?? [2, 3, 4, 5, 6]))
        _specificDates = State(initialValue: existing?.specificDates ?? [])

        var comps = DateComponents()
        comps.hour = existing?.hour ?? 8
        comps.minute = existing?.minute ?? 0
        _time = State(initialValue: Calendar.current.date(from: comps) ?? Date())

        let lead = existing?.leadMinutes ?? 5
        let option = LeadOption.matching(lead)
        _leadOption = State(initialValue: option)
        _customLeadMinutes = State(initialValue: option == .custom ? lead : 20)
    }

    private var leadMinutes: Int {
        leadOption.minutes ?? customLeadMinutes
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Names only need to be unique within the same mode — a "Morning Commute"
    /// Start At and a "Morning Commute" Reach By aren't the same schedule and
    /// don't collide, since Planner lists them in separate sections anyway.
    private var isDuplicateName: Bool {
        guard !trimmedName.isEmpty else { return false }
        return allReminders.contains { reminder in
            reminder.plannerMode == plannerMode
                && reminder.id != existing?.id
                && reminder.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    /// Weekly mode self-heals every week, so "the time already passed today" just
    /// means it waits for next week — not an error. Specific dates don't repeat,
    /// so a date+time+lead combination that's already passed has nothing left to
    /// fire; this only returns non-nil if every picked date is like that.
    private var pastSpecificDatesWarning: String? {
        guard !specificDates.isEmpty else { return nil }
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: time)
        let hasFutureOccurrence = specificDates.contains { date in
            guard let occurrence = calendar.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: date) else { return false }
            return occurrence.addingTimeInterval(-Double(leadMinutes) * 60) > Date()
        }
        return hasFutureOccurrence ? nil : "All selected dates and times have already passed — pick a future date or time."
    }

    /// Two reminders that both need you leaving/arriving at the same moment for
    /// different destinations is a real scheduling conflict — checked against the
    /// same hour/minute and at least one shared day, recurring or specific.
    private var conflictingReminder: RecurringReminder? {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let candidateHour = comps.hour ?? 0
        let candidateMinute = comps.minute ?? 0
        let candidateWeekdays = specificDates.isEmpty ? Array(selectedWeekdays) : []
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)

        return allReminders.first { other in
            other.id != existing?.id
                && other.isEnabled
                && other.hour == candidateHour
                && other.minute == candidateMinute
                && other.destination.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedDestination) != .orderedSame
                && daysOverlap(weekdaysA: other.weekdays, datesA: other.specificDates, weekdaysB: candidateWeekdays, datesB: specificDates)
        }
    }

    private func daysOverlap(weekdaysA: [Int], datesA: [Date], weekdaysB: [Int], datesB: [Date]) -> Bool {
        let calendar = Calendar.current
        if !datesA.isEmpty && !datesB.isEmpty {
            return datesA.contains { a in datesB.contains { b in calendar.isDate(a, inSameDayAs: b) } }
        } else if !datesA.isEmpty {
            return datesA.contains { date in weekdaysB.contains(calendar.component(.weekday, from: date)) }
        } else if !datesB.isEmpty {
            return datesB.contains { date in weekdaysA.contains(calendar.component(.weekday, from: date)) }
        } else {
            return !Set(weekdaysA).isDisjoint(with: Set(weekdaysB))
        }
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
            && !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(selectedWeekdays.isEmpty && specificDates.isEmpty)
            && !isDuplicateName
            && pastSpecificDatesWarning == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NAME")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("e.g. Morning Commute", text: $name)
                            .textFieldStyle(.roundedBorder)
                        if isDuplicateName {
                            Text("You already have a \(plannerMode.label) reminder named \"\(trimmedName)\".")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Picker("Mode", selection: $plannerMode) {
                        ForEach(PlannerMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("FROM")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LocationSearchField(placeholder: "Starting point", text: $origin, coordinate: $originCoordinate, inline: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("TO")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LocationSearchField(placeholder: "Destination", text: $destination, coordinate: $destinationCoordinate, inline: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(specificDates.isEmpty ? "REPEATS ON" : "ON THESE DATES")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if specificDates.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(1...7, id: \.self) { weekday in
                                    weekdayToggle(weekday)
                                }
                                calendarButton
                            }
                        } else {
                            datesChipList
                            HStack(spacing: 10) {
                                Button {
                                    openCalendarPicker()
                                } label: {
                                    Label("Edit Dates", systemImage: "calendar.badge.plus")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    specificDates = []
                                    calendarConfirmationText = nil
                                } label: {
                                    Text("Use Weekly Schedule Instead")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if let calendarConfirmationText {
                            Text(calendarConfirmationText)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if let pastSpecificDatesWarning {
                            Text(pastSpecificDatesWarning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(plannerMode == .startAt ? "START TIME" : "REACH BY")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("NOTIFY ME")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("Lead time", selection: $leadOption) {
                            ForEach(LeadOption.allCases, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)

                        if leadOption == .custom {
                            Picker("Minutes before", selection: $customLeadMinutes) {
                                ForEach(1...120, id: \.self) { minute in
                                    Text("\(minute) min").tag(minute)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 120)
                        }

                        Text(previewText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("TRAVEL MODE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TravelModeSelector(mode: $travelMode)
                    }

                    Spacer(minLength: 0)
                }
                .padding()
            }
            .navigationTitle(existing == nil ? "Recurring Reminder" : "Edit Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if conflictingReminder != nil {
                            showConflictAlert = true
                        } else {
                            save()
                        }
                    }
                    .disabled(!isValid)
                }
            }
            .alert("Scheduling Conflict", isPresented: $showConflictAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                if let conflictingReminder {
                    Text("\"\(conflictingReminder.name)\" already needs you at \(conflictingReminder.destination) at \(conflictingReminder.timeText). You can't be in two places at once — change the time or day to fix this.")
                } else {
                    Text("This conflicts with another reminder.")
                }
            }
            .sheet(isPresented: $showCalendarPicker) {
                NavigationStack {
                    MultiDatePicker("Pick upcoming days", selection: $calendarSelection, in: Date()...)
                        .navigationTitle("Pick Dates")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showCalendarPicker = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Set") {
                                    applyCalendarSelection()
                                    showCalendarPicker = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var calendarButton: some View {
        Button {
            openCalendarPicker()
        } label: {
            Image(systemName: "calendar")
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemBackground))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var datesChipList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(specificDates.sorted(), id: \.self) { date in
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(Color.accentColor)
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                    Spacer()
                    Button {
                        specificDates.removeAll { Calendar.current.isDate($0, inSameDayAs: date) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    /// Pre-seeds the calendar sheet with whatever dates are already picked, so
    /// reopening it shows them as already selected instead of starting blank.
    private func openCalendarPicker() {
        let calendar = Calendar.current
        calendarSelection = Set(specificDates.map { calendar.dateComponents([.year, .month, .day], from: $0) })
        showCalendarPicker = true
    }

    /// Picking specific upcoming dates on a real calendar is really just another
    /// way to fill in `selectedWeekdays` — a recurring reminder only stores a
    /// weekly pattern, so tapping, say, "next Tuesday" adds Tuesday to the
    /// pattern rather than a genuine one-off occurrence.
    /// Picking specific dates switches this reminder out of the weekly-pattern
    /// mode entirely — the weekday circles disappear and only these exact dates
    /// fire a reminder, each getting its own one-shot notification. Replaces
    /// `specificDates` outright (not merges) since the sheet was pre-seeded with
    /// whatever was already picked, so this naturally captures both additions and
    /// removals made inside the calendar.
    private func applyCalendarSelection() {
        let calendar = Calendar.current
        let dates = calendarSelection.compactMap { calendar.date(from: $0) }.map { calendar.startOfDay(for: $0) }
        specificDates = dates

        if dates.isEmpty {
            calendarConfirmationText = nil
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            let names = dates.sorted().map { formatter.string(from: $0) }
            calendarConfirmationText = "Set for \(names.joined(separator: ", ")) — this reminder no longer repeats weekly."
        }
    }

    private var previewText: String {
        let timeText = Recommendation.timeFormatter.string(from: time)
        switch plannerMode {
        case .startAt:
            return "You'll be notified \(leadMinutes) min before \(timeText)."
        case .reachBy:
            return "SmartRide checks traffic each day and notifies you \(leadMinutes) min before you need to leave to reach your destination by \(timeText)."
        }
    }

    private func weekdayToggle(_ weekday: Int) -> some View {
        let isSelected = selectedWeekdays.contains(weekday)
        return Button {
            if isSelected { selectedWeekdays.remove(weekday) } else { selectedWeekdays.insert(weekday) }
        } label: {
            Text(weekdaySymbols[weekday - 1].prefix(1))
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Specific dates and a weekly pattern are mutually exclusive — clear
        // whichever one isn't in use so `usesSpecificDates` stays unambiguous.
        let weekdaysToSave = specificDates.isEmpty ? Array(selectedWeekdays) : []

        let reminder: RecurringReminder
        if let existing {
            RecurringReminderScheduler.cancelAll(existing)
            existing.name = trimmedName
            existing.origin = origin
            existing.destination = destination
            existing.plannerMode = plannerMode
            existing.hour = comps.hour ?? 8
            existing.minute = comps.minute ?? 0
            existing.leadMinutes = leadMinutes
            existing.weekdays = weekdaysToSave
            existing.specificDates = specificDates
            existing.travelMode = travelMode
            reminder = existing
        } else {
            reminder = RecurringReminder(
                name: trimmedName, origin: origin, destination: destination, plannerMode: plannerMode,
                hour: comps.hour ?? 8, minute: comps.minute ?? 0, leadMinutes: leadMinutes,
                weekdays: weekdaysToSave, specificDates: specificDates, travelMode: travelMode
            )
            modelContext.insert(reminder)
        }
        try? modelContext.save()

        Task {
            await RecurringReminderScheduler.refresh(reminder, modelContext: modelContext)
            try? modelContext.save()
        }
        dismiss()
    }
}

#Preview {
    AddRecurringReminderView()
        .modelContainer(for: [RecurringReminder.self], inMemory: true)
}
