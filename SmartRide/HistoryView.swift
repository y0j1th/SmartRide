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

struct HistoryView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoggedTrip.createdAt, order: .reverse) private var trips: [LoggedTrip]
    @Query(sort: \ReminderItem.scheduledTime, order: .reverse) private var allReminders: [ReminderItem]
    @State private var selectedTab: HistoryTab = .trips
    @State private var expandedTripID: PersistentIdentifier?

    private var weekTrips: [LoggedTrip] {
        guard let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return trips.filter { $0.createdAt >= weekStart }
    }

    private var monthTrips: [LoggedTrip] {
        guard let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start else { return [] }
        return trips.filter { $0.createdAt >= monthStart }
    }

    /// Reminders whose time has already passed — the ones still ahead of now stay
    /// on the Home tab (editable/deletable there), so this tab is purely the
    /// "already happened" record, mirroring how a trip only shows up here once
    /// it's been started.
    private var pastReminders: [ReminderItem] {
        allReminders.filter { $0.scheduledTime < Date() }
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

                    Section("Trips") {
                        ForEach(trips) { trip in
                            tripRow(trip)
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
                    ForEach(pastReminders) { reminder in
                        ReminderRowView(reminder: reminder, allowEdit: false, allowDelete: false)
                    }
                }
            }
        }
    }

    private var weeklyIntelligenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Commute This Week")
                .font(.headline)

            if weekTrips.isEmpty {
                Text("No trips logged yet this week.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let avgDuration = weekTrips.map(\.expectedDurationMinutes).reduce(0, +) / weekTrips.count
                let weekSaved = weekTrips.map(\.predictedSavedMinutes).reduce(0, +)

                HStack {
                    statColumn("Average", Recommendation.minutesText(avgDuration))
                    Divider().frame(height: 34)
                    statColumn("Trips Logged", "\(weekTrips.count)")
                    Divider().frame(height: 34)
                    statColumn("Time Saved", Recommendation.minutesText(weekSaved))
                }
            }

            let monthSaved = monthTrips.map(\.predictedSavedMinutes).reduce(0, +)
            if monthSaved > 0 {
                Text("You've saved \(Recommendation.minutesText(monthSaved)) this month.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
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
                        Text(trip.createdAt.formatted(date: .abbreviated, time: .omitted))
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
                    detailRow(label: "Travel Mode", value: trip.travelMode.label)
                    detailRow(label: "Departed", value: trip.plannedDeparture.formatted(date: .abbreviated, time: .shortened))
                    detailRow(label: "Arrived", value: arrival.formatted(date: .abbreviated, time: .shortened))
                    detailRow(label: "Duration", value: Recommendation.minutesText(trip.expectedDurationMinutes))
                    detailRow(label: "Time Saved", value: Recommendation.minutesText(trip.predictedSavedMinutes))
                    detailRow(label: "Confidence", value: "\(trip.confidencePercent)%")

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
