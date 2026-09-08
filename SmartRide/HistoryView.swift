//
//  HistoryView.swift
//  SmartRide
//
//  Real, persisted trips the user started navigation on (doc §3 Step 6 / §4.1
//  bottom nav), plus weekly/monthly commute intelligence rolled up from that same
//  data — no fabricated "actual arrival" tracking, since this MVP has no background
//  tracking to measure that; everything shown here is what the engine predicted.
//

import SwiftUI
import SwiftData

private enum HistoryTab: String, CaseIterable {
    case trips = "Trips"
    case reminders = "Reminders"
}

private enum HistoryRangePreset: String, CaseIterable, Identifiable {
    case week = "Week"
    case twoWeeks = "2 Weeks"
    case month = "Month"
    case custom = "Custom"

    var id: String { rawValue }
}

struct HistoryView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoggedTrip.createdAt, order: .reverse) private var trips: [LoggedTrip]
    @Query(sort: \ReminderItem.scheduledTime, order: .reverse) private var allReminders: [ReminderItem]
    @State private var selectedTab: HistoryTab = .trips
    @State private var expandedTripID: PersistentIdentifier?

    @State private var rangePreset: HistoryRangePreset = .week
    @State private var customRangeStart: Date = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    @State private var customRangeEnd: Date = Date()

    /// Start/end of whichever range is currently selected — one card, one figure,
    /// instead of separate always-on week/month numbers.
    private var selectedRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()
        switch rangePreset {
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return (start, now)
        case .twoWeeks:
            let start = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now)) ?? now
            return (start, now)
        case .month:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
            return (start, now)
        case .custom:
            let start = calendar.startOfDay(for: customRangeStart)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customRangeEnd)) ?? customRangeEnd
            return (start, end)
        }
    }

    private var rangeTrips: [LoggedTrip] {
        let range = selectedRange
        return trips.filter { $0.createdAt >= range.start && $0.createdAt < range.end }
    }

    /// How the range reads in a sentence — "You've saved X ___."
    private var rangePhrase: String {
        switch rangePreset {
        case .week: return "this week"
        case .twoWeeks: return "in the last 2 weeks"
        case .month: return "this month"
        case .custom: return "in this range"
        }
    }

    /// The exact dates the selected range covers, e.g. "Sep 1 - Sep 7" — spelled
    /// out on the card itself so the stats' scope isn't just implied by a label.
    private var rangeDatesText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let range = selectedRange
        let displayEnd = rangePreset == .custom ? customRangeEnd : (Calendar.current.date(byAdding: .second, value: -1, to: range.end) ?? range.end)
        return "\(formatter.string(from: range.start)) - \(formatter.string(from: displayEnd))"
    }

    /// Reminders whose time has already passed — the ones still ahead of now stay
    /// on the Home tab (editable/deletable there), so this tab is purely the
    /// "already happened" record, mirroring how a trip only shows up here once
    /// it's been started.
    private var pastReminders: [ReminderItem] {
        allReminders.filter { $0.scheduledTime < Date() }
    }

    /// Trips bucketed by calendar day, most recent day first. `trips` is already
    /// sorted newest-first, so a single pass — starting a new bucket whenever the
    /// day changes — keeps both the day order and each day's own trip order intact
    /// without needing a separate sort afterward.
    private var tripsByDay: [(day: Date, items: [LoggedTrip])] {
        groupedByDay(trips, date: \.createdAt)
    }

    /// Same day-bucketing as trips, applied to past reminders (already sorted
    /// newest-first).
    private var remindersByDay: [(day: Date, items: [ReminderItem])] {
        groupedByDay(pastReminders, date: \.scheduledTime)
    }

    private func groupedByDay<T>(_ items: [T], date: (T) -> Date) -> [(day: Date, items: [T])] {
        let calendar = Calendar.current
        var result: [(day: Date, items: [T])] = []
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if let lastIndex = result.indices.last, result[lastIndex].day == day {
                result[lastIndex].items.append(item)
            } else {
                result.append((day: day, items: [item]))
            }
        }
        return result
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    ForEach(HistoryTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch selectedTab {
                    case .trips: tripsContent
                    case .reminders: remindersContent
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private var tripsContent: some View {
        Group {
            if trips.isEmpty {
                ContentUnavailableView(
                    "No Trips Yet",
                    systemImage: "clock",
                    description: Text("Trips you start navigation on from the Home tab will show up here.")
                )
            } else {
                List {
                    Section {
                        weeklyIntelligenceCard
                            .listRowInsets(EdgeInsets())
                            .padding(.vertical, 6)
                    }
                    .listRowBackground(Color.clear)

                    ForEach(tripsByDay, id: \.day) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.items) { trip in
                                tripRow(trip)
                            }
                        }
                    }
                }
            }
        }
    }

    private var remindersContent: some View {
        Group {
            if pastReminders.isEmpty {
                ContentUnavailableView(
                    "No Past Reminders",
                    systemImage: "bell",
                    description: Text("Reminders you've set from the Home tab move here once their time has passed.")
                )
            } else {
                List {
                    ForEach(remindersByDay, id: \.day) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.items) { reminder in
                                ReminderRowView(reminder: reminder, allowEdit: false, allowDelete: false)
                            }
                        }
                    }
                }
            }
        }
    }

    private var weeklyIntelligenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Commute")
                .font(.headline)

            Picker("Range", selection: $rangePreset) {
                ForEach(HistoryRangePreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            if rangePreset == .custom {
                HStack(spacing: 10) {
                    DatePicker("From", selection: $customRangeStart, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                    Text("to")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker("To", selection: $customRangeEnd, in: customRangeStart...Date(), displayedComponents: .date)
                        .labelsHidden()
                }
            }

            Text(rangeDatesText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if rangeTrips.isEmpty {
                Text("No trips logged \(rangePhrase).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let avgDuration = rangeTrips.map(\.expectedDurationMinutes).reduce(0, +) / rangeTrips.count
                let rangeSaved = rangeTrips.map(\.predictedSavedMinutes).reduce(0, +)

                HStack {
                    statColumn("Average", Recommendation.minutesText(avgDuration))
                    Divider().frame(height: 34)
                    statColumn("Trips Logged", "\(rangeTrips.count)")
                    Divider().frame(height: 34)
                    statColumn("Time Saved", Recommendation.minutesText(rangeSaved))
                }

                if rangeSaved > 0 {
                    Text("You've saved \(Recommendation.minutesPhrase(rangeSaved)) \(rangePhrase).")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Collapsed shows just the route name; tapping expands in place to show
    /// the full trip detail (read-only) plus Travel Again and the same
    /// list.bullet save menu Home uses, so a past trip can become any of the
    /// 4 route options.
    private func tripRow(_ trip: LoggedTrip) -> some View {
        let isExpanded = expandedTripID == trip.persistentModelID
        let arrival = trip.plannedDeparture.addingTimeInterval(TimeInterval(trip.expectedDurationMinutes * 60))

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedTripID = isExpanded ? nil : trip.persistentModelID
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(trip.origin) → \(trip.destination)")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(trip.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    routeStops(trip)
                    if let routeSummary = trip.routeSummary, !routeSummary.isEmpty {
                        detailRow(label: "Selected Route", value: routeSummary)
                    }
                    detailRow(label: "Travel Mode", value: trip.travelMode.label)
                    detailRow(label: "Left At", value: trip.plannedDeparture.formatted(date: .abbreviated, time: .shortened))
                    detailRow(label: "Expected Arrival", value: arrival.formatted(date: .abbreviated, time: .shortened))
                    detailRow(label: "Duration", value: Recommendation.minutesText(trip.expectedDurationMinutes))
                    detailRow(label: "Time Saved", value: Recommendation.minutesText(trip.predictedSavedMinutes))
                    detailRow(label: "Confidence", value: "\(trip.confidencePercent)%")

                    accuracyRatingRow(trip)

                    HStack(spacing: 10) {
                        Button {
                            travelAgain(trip)
                        } label: {
                            Label("Travel Again", systemImage: "location.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        RouteSaveMenu(origin: trip.origin, destination: trip.destination, travelMode: trip.travelMode)
                    }
                    .padding(.top, 4)
                }
                .padding(.leading, 32)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    /// The exact route driven — origin, every stop in visit order, then
    /// destination — so it's clear what will happen before tapping Navigate or
    /// Travel Again, not just the two endpoints.
    private func routeStops(_ trip: LoggedTrip) -> some View {
        let points = [trip.origin] + trip.stopAddresses + [trip.destination]
        return VStack(alignment: .leading, spacing: 4) {
            Text("Route")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: index == 0 ? "circle.fill" : (index == points.count - 1 ? "mappin.circle.fill" : "circle.fill"))
                        .font(.system(size: index == 0 || index == points.count - 1 ? 8 : 6))
                        .foregroundStyle(index == points.count - 1 ? Color.accentColor : .secondary)
                        .padding(.top, 4)
                    Text(point)
                        .font(.subheadline)
                }
            }
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

    /// Lets the user say how close the predicted duration/arrival actually was,
    /// per trip — the app has no background tracking to check this itself, so
    /// this is the only honest way to learn whether estimates are trustworthy.
    /// 0-5, colored red-to-green, so the scale reads at a glance without needing
    /// to look at the number.
    private func accuracyRatingRow(_ trip: LoggedTrip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How accurate was this estimate?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0...5, id: \.self) { value in
                    let isSelected = trip.accuracyRating == value
                    Button {
                        setAccuracyRating(trip, value: value)
                    } label: {
                        Text("\(value)")
                            .font(.caption.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(ratingColor(value).opacity(isSelected ? 1 : 0.2), in: Circle())
                            .foregroundStyle(isSelected ? .white : .primary)
                            .overlay(
                                Circle().stroke(ratingColor(value), lineWidth: isSelected ? 0 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            if let rating = trip.accuracyRating {
                Text("Rated \(rating)/5")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 0 (red) to 5 (green), stepping through the hue wheel — no separate lookup
    /// table needed since red and green sit at opposite ends of it.
    private func ratingColor(_ value: Int) -> Color {
        Color(hue: (Double(value) / 5) * 0.33, saturation: 0.75, brightness: 0.85)
    }

    private func setAccuracyRating(_ trip: LoggedTrip, value: Int) {
        trip.accuracyRating = value
        try? modelContext.save()
    }

    private func travelAgain(_ trip: LoggedTrip) {
        appSettings.pendingOrigin = trip.origin
        appSettings.pendingDestination = trip.destination
        appSettings.pendingStops = trip.stopAddresses
        appSettings.selectedTab = AppSettings.homeTabIndex
    }
}

#Preview {
    HistoryView()
        .environmentObject(AppSettings())
        .modelContainer(for: [HistoricalSample.self, LoggedTrip.self, ReminderItem.self], inMemory: true)
}
