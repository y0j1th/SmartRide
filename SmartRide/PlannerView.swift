//
//  PlannerView.swift
//  SmartRide
//
//  Everything that can notify you, in one place: recurring weekly departure
//  reminders, one-shot reminders still ahead of now (also editable from Home), and
//  the saved routes currently being watched for a Smart Commute Alert
//  (SmartAlertChecker) — with a quick way to see which routes are watched and turn
//  that off without digging into Favorites.
//

import SwiftUI
import SwiftData

struct PlannerView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringReminder.createdAt) private var recurringReminders: [RecurringReminder]
    @Query(sort: \ReminderItem.scheduledTime) private var allReminders: [ReminderItem]
    @Query(sort: \SavedCommute.createdAt) private var savedCommutes: [SavedCommute]

    @State private var showAddRecurring = false
    @State private var editingReminder: RecurringReminder?
    @State private var selectedDate: Date?
    @State private var expandedReminderID: PersistentIdentifier?

    private var upcomingReminders: [ReminderItem] {
        allReminders.filter { $0.scheduledTime >= Date() }
    }

    private var watchedCommutes: [SavedCommute] {
        savedCommutes.filter { $0.alertsEnabled }
    }

    @ViewBuilder
    private func remindersForDaySection(_ date: Date) -> some View {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let matchingRecurring = recurringReminders.filter { reminder in
            guard reminder.isEnabled else { return false }
            if reminder.usesSpecificDates {
                return reminder.specificDates.contains { calendar.isDate($0, inSameDayAs: date) }
            }
            return reminder.weekdays.contains(weekday)
        }
        let matchingOneShot = allReminders.filter { calendar.isDate($0.scheduledTime, inSameDayAs: date) }

        Section {
            if matchingRecurring.isEmpty && matchingOneShot.isEmpty {
                Text("No reminders on this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(matchingRecurring) { reminder in
                HStack(spacing: 10) {
                    Image(systemName: "repeat.circle.fill")
                        .foregroundStyle(reminder.isEnabled ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reminder.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(reminder.plannerMode.label) · \(reminder.timeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(matchingOneShot) { reminder in
                HStack(spacing: 10) {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reminder.destination)
                            .font(.subheadline.weight(.semibold))
                        Text(reminder.scheduledTime.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Reminders on \(date.formatted(date: .abbreviated, time: .omitted))")
        }
    }

    private func sortedByName(_ mode: PlannerMode) -> [RecurringReminder] {
        recurringReminders
            .filter { $0.plannerMode == mode }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PlannerCalendarView(
                        recurringReminders: recurringReminders, oneShotReminders: allReminders, selectedDate: $selectedDate
                    )
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)

                if let selectedDate {
                    remindersForDaySection(selectedDate)
                }

                // Start At always above Reach By, each sorted alphabetically by name —
                // grouping by mode first keeps a mixed list of both from interleaving
                // in a way that makes the schedule harder to scan at a glance.
                recurringSection(mode: .startAt, title: "Start At")
                recurringSection(mode: .reachBy, title: "Reach By")

                Section {
                    Button {
                        editingReminder = nil
                        showAddRecurring = true
                    } label: {
                        Label("Add Recurring Reminder", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("A recurring reminder repeats every week on the days you pick — set it once for your regular commute instead of setting a reminder every day.")
                }

                if !upcomingReminders.isEmpty {
                    Section("Upcoming Reminders") {
                        ForEach(upcomingReminders) { reminder in
                            ReminderRowView(
                                reminder: reminder,
                                onEdit: { newDate in updateReminder(reminder, to: newDate) },
                                onDelete: { deleteReminder(reminder) }
                            )
                        }
                    }
                }

                if !watchedCommutes.isEmpty {
                    Section {
                        ForEach(watchedCommutes) { commute in
                            watchedRow(commute)
                        }
                    } header: {
                        Text("Watched Routes")
                    } footer: {
                        Text("SmartRide checks these when you open the app and alerts you if traffic is building faster than usual for your usual arrival time.")
                    }
                }
            }
            .navigationTitle("Planner")
            .sheet(isPresented: $showAddRecurring) {
                AddRecurringReminderView(existing: editingReminder)
            }
            .task {
                // Covers opening Planner without ever visiting Home first, and
                // fills in the distance for any reminder whose own creation-time
                // refresh hadn't finished yet by the time this list was checked.
                await RecurringReminderScheduler.refreshAll(modelContext: modelContext)
            }
        }
    }

    @ViewBuilder
    private func recurringSection(mode: PlannerMode, title: String) -> some View {
        let reminders = sortedByName(mode)
        if !reminders.isEmpty {
            Section(title) {
                ForEach(reminders) { reminder in
                    recurringRow(reminder)
                }
            }
        }
    }

    /// Collapsed shows just the name (plus the enable toggle); tapping expands
    /// in place to show the route/schedule details (read-only) and a Navigate
    /// button. Editing is only reachable through the swipe action, alongside delete.
    private func recurringRow(_ reminder: RecurringReminder) -> some View {
        let isExpanded = expandedReminderID == reminder.persistentModelID
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedReminderID = isExpanded ? nil : reminder.persistentModelID
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "repeat.circle.fill")
                        .font(.title3)
                        .foregroundStyle(reminder.isEnabled ? Color.accentColor : .secondary)
                    Text(reminder.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { reminder.isEnabled },
                        set: { toggleRecurring(reminder, isEnabled: $0) }
                    ))
                    .labelsHidden()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    detailRow(label: "From", value: reminder.origin)
                    detailRow(label: "To", value: reminder.destination)
                    detailRow(label: "Type", value: reminder.plannerMode.label)
                    detailRow(label: "Schedule", value: "\(reminder.timeText) · \(reminder.weekdaysText)")
                    detailRow(label: "Notify", value: reminder.leadText + (reminder.cachedDistanceMiles.map { String(format: " · ~%.0f mi", $0) } ?? ""))
                    Button {
                        navigate(origin: reminder.origin, destination: reminder.destination)
                    } label: {
                        Label("Navigate", systemImage: "location.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
                .padding(.leading, 32)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        // Same app-wide convention: swipe left-to-right (leading) for Edit,
        // right-to-left (trailing) for Delete — separate edges, not stacked on
        // one. The app also sets a custom global accent tint (Profile >
        // Appearance), which otherwise overrides the destructive role's default
        // red here, so both need an explicit tint regardless.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                editingReminder = reminder
                showAddRecurring = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteRecurring(reminder)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }

    private func navigate(origin: String, destination: String) {
        appSettings.pendingOrigin = origin
        appSettings.pendingDestination = destination
        appSettings.selectedTab = AppSettings.homeTabIndex
    }

    private func toggleRecurring(_ reminder: RecurringReminder, isEnabled: Bool) {
        reminder.isEnabled = isEnabled
        try? modelContext.save()
        if isEnabled {
            Task {
                await RecurringReminderScheduler.refresh(reminder, modelContext: modelContext)
                try? modelContext.save()
            }
        } else {
            RecurringReminderScheduler.cancelAll(reminder)
        }
    }

    private func deleteRecurring(_ reminder: RecurringReminder) {
        RecurringReminderScheduler.cancelAll(reminder)
        modelContext.delete(reminder)
        try? modelContext.save()
    }

    private func watchedRow(_ commute: SavedCommute) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(Color.accentColor)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(commute.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(commute.origin) → \(commute.destination)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastAlerted = commute.lastAlertedDurationMinutes {
                    Text("Last check: ~\(lastAlerted) min drive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { commute.alertsEnabled },
                set: { newValue in
                    commute.alertsEnabled = newValue
                    try? modelContext.save()
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private func updateReminder(_ reminder: ReminderItem, to date: Date) {
        reminder.scheduledTime = date
        try? modelContext.save()
        Task {
            NotificationManager.cancelReminder(id: reminder.notificationIdentifier)
            _ = await NotificationManager.scheduleDepartureReminder(id: reminder.notificationIdentifier, at: date, origin: reminder.origin, destination: reminder.destination, travelMode: reminder.travelMode)
        }
    }

    private func deleteReminder(_ reminder: ReminderItem) {
        NotificationManager.cancelReminder(id: reminder.notificationIdentifier)
        modelContext.delete(reminder)
        try? modelContext.save()
    }
}

#Preview {
    PlannerView()
        .modelContainer(for: [RecurringReminder.self, ReminderItem.self, SavedCommute.self], inMemory: true)
}
