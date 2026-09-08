//
//  Components.swift
//  SmartRide
//

import SwiftUI
import SwiftData

// MARK: - Favorite Chips

/// One tappable quick-fill chip — deliberately generic (icon/label/action) so the
/// row can mix Home/Office (a single address) with Favorite Routes (an
/// origin+destination pair) without the row itself knowing about either model.
struct QuickChip: Identifiable {
    let id: String
    let icon: String
    let label: String
    let action: () -> Void
}

struct FavoriteChipsRow: View {
    let chips: [QuickChip]

    var body: some View {
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        Button(action: chip.action) {
                            Label(chip.label, systemImage: chip.icon)
                                .font(.footnote.weight(.medium))
                                .padding(.vertical, 7)
                                .padding(.horizontal, 12)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Trip Mode Selector (Depart-At / Arrive-By)

struct TripModeSelector: View {
    @Binding var mode: TripMode
    var isEnabled: Bool = true

    var body: some View {
        Picker("Mode", selection: $mode) {
            Text("Depart At").tag(TripMode.departAt)
            Text("Arrive By").tag(TripMode.arriveBy)
        }
        .pickerStyle(.segmented)
        .font(.subheadline.weight(.bold))
        .disabled(!isEnabled)
    }
}

// MARK: - Travel Mode Selector

struct TravelModeSelector: View {
    @Binding var mode: TravelMode

    var body: some View {
        // Icon-only: 5 full text labels don't fit a segmented control on a phone
        // screen without truncating illegibly.
        Picker("Travel Mode", selection: $mode) {
            ForEach(TravelMode.allCases, id: \.self) { option in
                Image(systemName: option.systemImage)
                    .accessibilityLabel(option.label)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Departure Time Selector

struct DepartureTimeSelector: View {
    @Binding var selection: DepartureOption
    @Binding var customDate: Date

    private let options: [DepartureOption] = [.now, .in15, .in30, .custom(Date())]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(options, id: \.kind) { option in
                    pill(for: option)
                }
            }

            if selection.kind == "custom" {
                DatePicker("Departure", selection: $customDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .onChange(of: customDate) { _, newValue in
                        selection = .custom(newValue)
                    }
            }
        }
    }

    private func pill(for option: DepartureOption) -> some View {
        let isSelected = selection.kind == option.kind
        return Button {
            if option.kind == "custom" {
                selection = .custom(customDate)
            } else {
                selection = option
            }
        } label: {
            Text(option.label)
                .font(.subheadline.weight(.medium))
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Arrive-By Time Selector

struct ArriveBySelector: View {
    @Binding var targetArrival: Date
    /// Earliest offerable arrival — current drive time + a 1-hour buffer, rounded
    /// to the nearest 5 minutes by the caller. Defaults to now for callers that
    /// don't yet know the current drive time.
    var minimum: Date = Date()

    var body: some View {
        HStack {
            Text("Arrive by")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            DatePicker("Arrive by", selection: $targetArrival, in: minimum..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        }
    }
}

// MARK: - Best Time To Leave Card

struct BestTimeToLeaveCard: View {
    let recommendation: Recommendation?
    let isLoading: Bool
    let origin: String
    let destination: String
    var stops: [TripStop] = []
    var travelMode: TravelMode = .driving
    var onViewAllTimes: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoading || recommendation == nil {
                loadingContent
            } else if let rec = recommendation {
                if rec.mode == .arriveBy {
                    arriveByContent(rec)
                } else {
                    departAtContent(rec)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.35, blue: 0.98), Color(red: 0.08, green: 0.16, blue: 0.46)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .redacted(reason: isLoading ? .placeholder : [])
        .opacity(isLoading ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: isLoading)
    }

    private var loadingContent: some View {
        Group {
            Text("LEAVE AT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("7:00 AM")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Calculating…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: Depart-At

    private func departAtContent(_ rec: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BEST TIME TO LEAVE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))

            if rec.candidates.count > 1 {
                DepartureOptionCards(recommendation: rec, origin: origin, destination: destination, stops: stops, travelMode: travelMode)
            } else if rec.alreadyOptimal {
                Text("Already a great time to leave · \(rec.durationText) drive")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                Text("\(rec.recommendedTimeText) · \(rec.durationText) drive")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack {
                Text(rec.explanation)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(rec.confidencePercent)% confidence")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            if let cliffText = rec.trafficCliffTimeText {
                Text("Traffic Cliff: ~\(cliffText) — drive time jumps sharply after this.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let onViewAllTimes, rec.candidates.count > 1 {
                Button(action: onViewAllTimes) {
                    Label("View All Times", systemImage: "chart.bar.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
    }

    // MARK: Arrive-By

    private func arriveByContent(_ rec: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ARRIVE BY \(rec.targetArrivalText ?? "")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(rec.recommendedTimeText)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Best departure · \(rec.durationText) drive · arrive \(rec.arrivalTimeText)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))

            if let latestSafeText = rec.latestSafeDepartureText {
                Text("Latest safe: \(latestSafeText) · \(rec.reliabilityPercent ?? rec.confidencePercent)% reliability")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("Not achievable in this window — try an earlier target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if let latestSafe = rec.latestSafeDeparture {
                Text("After \(Recommendation.timeFormatter.string(from: latestSafe)): high risk of being late")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }

            if let cliffText = rec.trafficCliffTimeText {
                Text("Traffic Cliff: ~\(cliffText) — drive time jumps sharply after this.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Departure Option Cards ("Leave Now" vs "Leave Later", each actionable)

struct DepartureOptionCards: View {
    let recommendation: Recommendation
    let origin: String
    let destination: String
    var stops: [TripStop] = []
    var travelMode: TravelMode = .driving

    @Environment(\.modelContext) private var modelContext
    @State private var activeReminderCandidateID: UUID?
    @State private var reminderInFlightFor: UUID?
    @State private var savedCandidateIDs: Set<UUID> = []

    /// Three parallel picks — "leave now (or whatever's most efficient right around
    /// now)", then the most efficient time in the ~15-minute window after that, then
    /// the most efficient time in the ~30-minute window after that. Each is the real
    /// argmin within its window, not a literal 0/15/30 — the label reflects whatever
    /// time actually won.
    private var windowPicks: [CandidateResult] {
        let candidates = recommendation.candidates
        guard !candidates.isEmpty else { return [] }
        let now = recommendation.referenceNow

        func best(inWindow range: Range<TimeInterval>) -> CandidateResult? {
            candidates
                .filter { let offset = $0.time.timeIntervalSince(now); return range.contains(offset) }
                .min { $0.durationMinutes < $1.durationMinutes }
        }

        let nowPick = best(inWindow: 0..<(12 * 60)) ?? candidates.first
        let midPick = best(inWindow: (12 * 60)..<(25 * 60))
            ?? candidates.first { $0.time.timeIntervalSince(now) >= 12 * 60 }
        let latePick = best(inWindow: (25 * 60)..<(45 * 60))
            ?? candidates.last { $0.time.timeIntervalSince(now) >= 25 * 60 }

        var picked = [nowPick, midPick, latePick].compactMap { $0 }
        var seen = Set<UUID>()
        picked = picked.filter { seen.insert($0.id).inserted }
        return picked.sorted { $0.time < $1.time }
    }

    private func label(for candidate: CandidateResult) -> String {
        let minutesOut = Int((candidate.time.timeIntervalSince(recommendation.referenceNow) / 60).rounded())
        return minutesOut <= 2 ? "Leave Now" : "Leave in \(minutesOut) min"
    }

    var body: some View {
        let bestDuration = windowPicks.map(\.durationMinutes).min()
        VStack(spacing: 8) {
            ForEach(windowPicks) { candidate in
                card(for: candidate, isRecommended: candidate.durationMinutes == bestDuration)
            }
        }
    }

    private func card(for candidate: CandidateResult, isRecommended: Bool) -> some View {
        let hasReminder = activeReminderCandidateID == candidate.id
        let isSaved = savedCandidateIDs.contains(candidate.id)
        let savedVsNow = max(0, recommendation.leaveNowDurationMinutes - candidate.durationMinutes)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(label(for: candidate))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if isRecommended {
                            Text("RECOMMENDED")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(candidate.timeText) · \(Recommendation.minutesText(candidate.durationMinutes))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                    if savedVsNow > 0 {
                        Text("Save \(savedVsNow) min")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.35, green: 0.88, blue: 0.48))
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    scheduleReminder(candidate)
                } label: {
                    Label(hasReminder ? "Reminder Set" : "Set Reminder", systemImage: hasReminder ? "checkmark" : "bell")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(hasReminder || reminderInFlightFor == candidate.id)

                Button {
                    savePreferred(candidate)
                } label: {
                    Label(isSaved ? "Saved" : "Save as Preferred", systemImage: isSaved ? "checkmark" : "bookmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(isSaved)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func scheduleReminder(_ candidate: CandidateResult) {
        reminderInFlightFor = candidate.id
        let identifier = "smartride.reminder.\(UUID().uuidString)"
        Task {
            let ok = await NotificationManager.scheduleDepartureReminder(id: identifier, at: candidate.time, origin: origin, destination: destination, travelMode: recommendation.travelMode)
            if ok {
                activeReminderCandidateID = candidate.id
                let item = ReminderItem(origin: origin, destination: destination, scheduledTime: candidate.time, notificationIdentifier: identifier, travelMode: recommendation.travelMode)
                modelContext.insert(item)
                try? modelContext.save()
            }
            reminderInFlightFor = nil
        }
    }

    private func savePreferred(_ candidate: CandidateResult) {
        let logged = LoggedTrip(
            origin: origin,
            destination: destination,
            plannedDeparture: candidate.time,
            predictedSavedMinutes: max(0, recommendation.leaveNowDurationMinutes - candidate.durationMinutes),
            confidencePercent: recommendation.confidencePercent,
            expectedDurationMinutes: candidate.durationMinutes,
            stopAddresses: stops.map(\.address).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            travelMode: travelMode,
            routeKey: Trip(origin: origin, destination: destination, stops: stops, travelMode: travelMode).routeKey
        )
        modelContext.insert(logged)
        try? modelContext.save()
        savedCandidateIDs.insert(candidate.id)
    }
}

// MARK: - Route Option Row

struct RouteOptionRow: View {
    let route: RouteOption
    let isSelected: Bool
    var onSelect: (() -> Void)? = nil

    var body: some View {
        Button {
            onSelect?()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(route.condition.color)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text(route.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(route.durationText)
                            .font(.subheadline.weight(.bold))
                        Text("· \(route.distanceText)")
                            .foregroundStyle(.secondary)
                        Text("· \(route.condition.label)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                    if let fullRouteSummary = route.fullRouteSummary, fullRouteSummary != route.summary {
                        Text("Via \(fullRouteSummary)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text(route.delayNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if route.hasTolls {
                        Label("Tolls on this route", systemImage: "dollarsign.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if route.isFastest {
                        Text("Fastest")
                            .font(.caption2.weight(.bold))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reminder Row (Home's "Upcoming Reminders" list + History > Reminders)

struct ReminderRowView: View {
    let reminder: ReminderItem
    /// History's past reminders are read-only — rescheduling or deleting one that's
    /// already fired would edit the record of what actually happened, the same
    /// reason a logged trip in History can't be edited either.
    var allowEdit: Bool = true
    var allowDelete: Bool = true
    var onEdit: ((Date) -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var showEditSheet = false
    @State private var editDate = Date()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.fill")
                .foregroundStyle(Color.accentColor)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.destination)
                    .font(.subheadline.weight(.semibold))
                Text(reminder.scheduledTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        // App-wide convention: swipe left-to-right (leading) for Edit, right-to-
        // left (trailing) for Delete. An explicit tint on both since the app's
        // custom global accent (Profile > Appearance) would otherwise override
        // the destructive role's default red.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if allowEdit {
                Button {
                    editDate = reminder.scheduledTime
                    showEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if allowDelete {
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            NavigationStack {
                Form {
                    DatePicker("Remind me at", selection: $editDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
                .navigationTitle("Edit Reminder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showEditSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onEdit?(editDate)
                            showEditSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
    }
}
