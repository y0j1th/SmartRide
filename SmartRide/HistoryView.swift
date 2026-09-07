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

struct HistoryView: View {
    @Query(sort: \LoggedTrip.createdAt, order: .reverse) private var trips: [LoggedTrip]

    private var weekTrips: [LoggedTrip] {
        guard let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return trips.filter { $0.createdAt >= weekStart }
    }

    private var monthTrips: [LoggedTrip] {
        guard let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start else { return [] }
        return trips.filter { $0.createdAt >= monthStart }
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle("History")
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

    private func tripRow(_ trip: LoggedTrip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(trip.origin) → \(trip.destination)")
                .font(.headline)

            Text(trip.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Label(
                    "Left \(trip.plannedDeparture.formatted(date: .omitted, time: .shortened)) · saved ~\(trip.predictedSavedMinutes)m",
                    systemImage: "wand.and.stars"
                )
                Spacer()
                Text("\(trip.confidencePercent)%")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [HistoricalSample.self, LoggedTrip.self], inMemory: true)
}
