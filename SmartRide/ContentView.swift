//
//  ContentView.swift
//  SmartRide
//
//  Home screen — the core of the MVP. Trip input, Depart-At / Arrive-By mode, the
//  redesigned "Leave At" recommendation card (with mini comparison), ranked route
//  options, and the navigation hand-off.
//

import SwiftUI
import SwiftData
import CoreLocation
import MapKit
import UniformTypeIdentifiers
import UIKit

/// Drag one stop's remove button and drop it onto the other stop's row to swap
/// their order — with only ever up to 2 stops, "entered the other row" is a
/// complete reordering, no need for insert-at-index logic a longer list would need.
private struct StopDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var stops: [TripStop]
    @Binding var draggingID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID,
              let fromIndex = stops.firstIndex(where: { $0.id == draggingID }),
              let toIndex = stops.firstIndex(where: { $0.id == targetID }) else { return }
        stops.swapAt(fromIndex, toIndex)
    }
}

struct ContentView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteLocation.createdAt) private var allFavorites: [FavoriteLocation]
    @Query(sort: \ReminderItem.scheduledTime) private var allReminders: [ReminderItem]
    @Query(sort: \SavedCommute.createdAt) private var savedCommutes: [SavedCommute]
    @StateObject private var locationManager = LocationManager()
    @AppStorage("preferredMapsApp") private var preferredMapsApp: String = "apple"

    @State private var trip = Trip(origin: "", destination: "")
    @State private var mode: TripMode = .departAt
    @State private var departureOption: DepartureOption = .now
    @State private var customDate = Date().addingTimeInterval(3600)
    @State private var targetArrival = Date().addingTimeInterval(2 * 3600)
    @State private var recommendation: Recommendation?
    @State private var isLoading = false
    @State private var addressError: String?
    @State private var reminderSet = false
    @State private var reminderInFlight = false
    @State private var reminderError: String?
    @State private var showAllTimes = false
    @State private var selectedRouteID: UUID?
    @State private var awaitingCurrentLocationForOrigin = false
    @State private var showSwapAlert = false
    @State private var activeStopPopoverID: UUID?
    @State private var draggingStopID: UUID?
    /// Current ("if I left right now") drive time for the entered From/To, used
    /// only to compute the Arrive By picker's earliest offerable time. Refreshed
    /// whenever the route changes while Arrive By is the active mode.
    @State private var currentNowMinutes: Int?
    /// The real place name behind "Current Location" (e.g. "Tracy, CA"), resolved
    /// in the background via reverse geocoding. Used whenever "Current Location"
    /// needs to appear as plain text elsewhere — swapped into Destination, or
    /// logged to History — since it stops meaning "here, right now" the moment
    /// it's anything other than the live origin.
    @State private var currentLocationResolvedAddress: String?

    private static let currentLocationLabel = "Current Location"

    private var recomputeKey: String {
        let modePart = mode == .departAt ? departureOption.kind + "|\(customDate.timeIntervalSince1970)" : "arrive|\(targetArrival.timeIntervalSince1970)"
        let stopsPart = trip.filledStops.map(\.address).joined(separator: ">")
        return "\(trip.origin)|\(trip.destination)|\(stopsPart)|\(trip.travelMode.rawValue)|\(mode.rawValue)|\(modePart)|\(appSettings.simulateAPIFailure)"
    }

    /// Reminders still ahead of now — once one's time passes it drops out of this
    /// list and shows up under History > Reminders instead, the same way a trip
    /// moves from "in progress" to logged history.
    private var upcomingReminders: [ReminderItem] {
        allReminders.filter { $0.scheduledTime >= Date() }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    logoHeader
                    tripCard
                        .zIndex(2)

                    FavoriteChipsRow(chips: quickChips)
                        .zIndex(1)

                    RouteMapView(
                        originCoordinate: trip.originCoordinate,
                        destinationCoordinate: trip.destinationCoordinate,
                        stopCoordinates: trip.filledStops.compactMap(\.coordinate),
                        routes: recommendation?.routes ?? [],
                        selectedRouteID: selectedRouteID,
                        onSelectRoute: { selectedRouteID = $0 },
                        onPickOrigin: applyMapPickedOrigin,
                        onPickDestination: applyMapPickedDestination
                    )
                    .zIndex(0)

                    TripModeSelector(mode: $mode, isEnabled: hasOriginAndDestination)

                    if mode == .departAt {
                        DepartureTimeSelector(selection: $departureOption, customDate: $customDate)
                    } else {
                        ArriveBySelector(targetArrival: $targetArrival, minimum: minimumArriveBy)
                    }

                    if trip.isSameLocation {
                        Label("Origin and destination can't be the same.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if let addressError {
                        Label(addressError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    if trip.isValid {
                        BestTimeToLeaveCard(
                            recommendation: recommendation,
                            isLoading: isLoading,
                            origin: originNameForLogging,
                            destination: trip.destination,
                            stops: trip.stops,
                            travelMode: trip.travelMode,
                            onViewAllTimes: { showAllTimes = true }
                        )
                    }

                    if let rec = recommendation, !isLoading {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Route Options")
                                .font(.headline)
                            ForEach(rec.routes) { route in
                                RouteOptionRow(
                                    route: route,
                                    isSelected: selectedRouteID == route.id || (selectedRouteID == nil && route.isFastest),
                                    onSelect: { selectedRouteID = route.id }
                                )
                            }
                        }
                    }

                    actionButtons

                    if !upcomingReminders.isEmpty {
                        reminderListSection
                    }
                }
                .padding()
            }
            .navigationBarHidden(true)
            // Tapping any blank area dismisses the keyboard (and, since that also
            // drops focus, whatever field's suggestions dropdown was showing) —
            // buttons and fields still get first crack at their own taps.
            .onTapGesture {
                dismissKeyboard()
            }
            .alert("Can't Switch Yet", isPresented: $showSwapAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Enter a destination before switching them.")
            }
            .onAppear {
                loadPendingCommuteIfNeeded()
                if trip.origin.isEmpty {
                    useCurrentLocationForOrigin()
                }
                Task { await SmartAlertChecker.checkAll(appSettings: appSettings, modelContext: modelContext) }
                Task { await RecurringReminderScheduler.refreshAll(modelContext: modelContext, simulateFailure: appSettings.simulateAPIFailure) }
                // Re-arms the background refresh chain on every real app use —
                // BGAppRefreshTaskRequest is one-shot, so this keeps a fresh one
                // pending rather than only ever having the one from launch.
                BackgroundReminderRefresher.scheduleNext(modelContext: modelContext)
            }
            .onChange(of: appSettings.selectedTab) { _, newValue in
                if newValue == AppSettings.homeTabIndex { loadPendingCommuteIfNeeded() }
            }
            .onReceive(locationManager.$currentLocation) { location in
                guard let location else { return }
                if awaitingCurrentLocationForOrigin {
                    applyCurrentLocation(location)
                } else if trip.origin == Self.currentLocationLabel {
                    // The device keeps refining its fix for a few seconds after the
                    // first one; as long as "Current Location" hasn't been swapped
                    // or edited away yet, keep tightening the coordinate and resolved
                    // address behind it instead of freezing on that first, coarser fix.
                    trip.originCoordinate = location.coordinate
                    resolveCurrentLocationAddress(location)
                } else if let originCoordinate = trip.originCoordinate, isSameLocation(originCoordinate, location.coordinate) {
                    // A typed/picked From address that turns out to be right where the
                    // phone actually is — switch it over to Current Location so it
                    // keeps tracking live instead of freezing on this one coincidental
                    // match (e.g. picking your own current position on the map).
                    applyCurrentLocation(location)
                }
            }
            .task(id: recomputeKey) {
                await recompute()
            }
            .task(id: arriveByQuickKey) {
                guard mode == .arriveBy, trip.isValid else {
                    currentNowMinutes = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                currentNowMinutes = await RecommendationEngine.quickLiveDuration(
                    trip: trip, simulateFailure: appSettings.simulateAPIFailure, modelContext: modelContext
                )
                guard !Task.isCancelled else { return }
                // The picker's own minimum just moved — pull the target up with it
                // if it's now sitting before the earliest reachable time.
                if targetArrival < minimumArriveBy {
                    targetArrival = minimumArriveBy
                }
            }
            .task {
                await periodicRefreshLoop()
            }
            .sheet(isPresented: $showAllTimes) {
                if let recommendation {
                    AllDepartureTimesView(recommendation: recommendation)
                }
            }
        }
    }

    /// Live traffic otherwise only gets fetched when an input actually changes —
    /// if the screen just sits open with the same trip, the one live sample it
    /// started with silently goes stale. This keeps it honest by quietly
    /// re-fetching every few minutes for as long as the screen stays open, same
    /// as re-editing a field would. SwiftUI cancels this `.task` on its own once
    /// the view disappears, so there's nothing to clean up manually.
    /// 5 minutes (not 3) because each refresh now fetches the full multi-point
    /// live curve (~11 calls, not 1) — traffic a real 15-minute-spaced checkpoint
    /// away from stale doesn't need checking again every 3 minutes.
    private func periodicRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled else { return }
            if trip.isValid {
                await recompute(silent: true)
            }
        }
    }

    private static let maxStops = 2

    private var tripCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                LocationSearchField(placeholder: "From", text: $trip.origin, coordinate: $trip.originCoordinate)
                // Only appears once From has been cleared out — this is the way
                // back to live location after that, since typing it out again
                // isn't possible ("Current Location" isn't a searchable place).
                if trip.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        useCurrentLocationForOrigin()
                    } label: {
                        Image(systemName: "location.fill")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    if trip.stops.count < Self.maxStops { trip.stops.append(TripStop()) }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(trip.stops.count >= Self.maxStops)
            }
            // Stops no longer float an overlay of their own (they use a popover,
            // which the system draws above everything regardless of zIndex), so
            // From only needs to out-rank Destination below it.
            .zIndex(2)

            ForEach(Array(trip.stops.enumerated()), id: \.element.id) { index, stop in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        activeStopPopoverID = stop.id
                    } label: {
                        HStack {
                            Text(trip.stops[index].address.isEmpty ? "Add a stop" : trip.stops[index].address)
                                .lineLimit(1)
                                .foregroundStyle(trip.stops[index].address.isEmpty ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(.systemGray4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(
                        get: { activeStopPopoverID == stop.id },
                        set: { if !$0 { activeStopPopoverID = nil } }
                    ), attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                        StopSearchPopover { text, coordinate in
                            if let idx = trip.stops.firstIndex(where: { $0.id == stop.id }) {
                                trip.stops[idx].address = text
                                trip.stops[idx].coordinate = coordinate
                            }
                            activeStopPopoverID = nil
                        }
                    }

                    // Tap to remove; press and hold to drag this stop and drop it
                    // onto the other one to swap their order.
                    Button {
                        removeStop(stop.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .onDrag {
                        draggingStopID = stop.id
                        return NSItemProvider(object: stop.id.uuidString as NSString)
                    }
                }
                .onDrop(of: [.text], delegate: StopDropDelegate(targetID: stop.id, stops: $trip.stops, draggingID: $draggingStopID))
            }

            HStack(alignment: .top) {
                LocationSearchField(placeholder: "Destination", text: $trip.destination, coordinate: $trip.destinationCoordinate)
                Button {
                    // An empty origin is fine to swap — the old destination becomes
                    // origin and the (empty) origin becomes an empty destination
                    // ready for new input. An empty destination has nothing useful
                    // to move into origin, so that's the only case worth blocking.
                    if trip.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showSwapAlert = true
                    } else {
                        swapOriginAndDestination()
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .zIndex(1)

            TravelModeSelector(mode: $trip.travelMode)
                .padding(.top, 4)
                .zIndex(0)
        }
    }

    private func removeStop(_ id: UUID) {
        trip.stops.removeAll { $0.id == id }
    }

    private func swapOriginAndDestination() {
        // "Current Location" only makes sense while it's the origin — moving it to
        // Destination should show the actual place (e.g. "Tracy, CA"), not the
        // literal label, since you can't navigate to "here, right now" as a target.
        let originValue = trip.origin == Self.currentLocationLabel
            ? (currentLocationResolvedAddress ?? trip.origin)
            : trip.origin
        let originCoordinateValue = trip.originCoordinate

        // Swapping back the other way should restore live "Current Location"
        // rather than moving the resolved address text back as if it were
        // something the user typed — it's still the same live location, just
        // heading the other direction again.
        let destinationWasCurrentLocation = currentLocationResolvedAddress != nil && trip.destination == currentLocationResolvedAddress

        trip.origin = trip.destination
        trip.originCoordinate = trip.destinationCoordinate
        trip.destination = originValue
        trip.destinationCoordinate = originCoordinateValue

        if destinationWasCurrentLocation {
            useCurrentLocationForOrigin()
        }
    }

    private var logoHeader: some View {
        HStack(spacing: 12) {
            Image("LogoMark")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("SmartRide")
                    .font(.title2.weight(.bold))
                Text("Smarter Commutes, Less Traffic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    /// Once a recommendation targets a departure more than a minute out — either
    /// because Arrive-By needs a later leave time, or the user explicitly picked
    /// "15 min"/"30 min"/a custom time — navigating right now wouldn't match the
    /// plan. `now` comes from a live timer so this flips back on its own the
    /// moment that time actually arrives, whether or not a reminder was set.
    /// Choosing "Now" always means "let me go right now", even if the engine's own
    /// optimum happens to land a few minutes out — that's what the secondary
    /// "Remind Me" suggestion below is for, not the primary button.
    private func isFutureDeparture(_ rec: Recommendation, now: Date) -> Bool {
        if mode == .departAt && departureOption.kind == "now" { return false }
        return rec.recommendedTime.timeIntervalSince(now) > 60
    }

    /// Passes the raw origin (which may literally be "Current Location"), not the
    /// resolved snapshot address — a saved Favorite Route/Route is meant to be
    /// reused later, so it should re-resolve wherever the phone actually is *at
    /// that later moment*, not freeze on wherever it was saved from. Recurring
    /// Reminder gets the resolved address instead (`reminderOrigin`), since its
    /// schedule refreshes in the background with no live GPS fix to resolve
    /// against. (History and one-shot reminders are also the "already happened"
    /// case, so those persist the resolved address too; see `originNameForLogging`.)
    private var saveRouteButton: some View {
        RouteSaveMenu(
            origin: trip.origin, destination: trip.destination, travelMode: trip.travelMode,
            isEnabled: trip.isValid, reminderOrigin: originNameForLogging
        )
    }

    private var actionButtons: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 10) {
                HStack {
                    Text("Navigate with")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Maps app", selection: $preferredMapsApp) {
                        Text("Apple Maps").tag("apple")
                        Text("Google Maps").tag("google")
                    }
                    .pickerStyle(.menu)
                    .font(.footnote)
                }

                if !trip.filledStops.isEmpty && preferredMapsApp == "apple" {
                    Text("Opening in Google Maps instead — Apple Maps doesn't support routes with stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let rec = recommendation, !isLoading, isFutureDeparture(rec, now: context.date) {
                    VStack(spacing: 4) {
                        HStack(spacing: 10) {
                            Button {
                                scheduleReminder(for: rec)
                            } label: {
                                Label(
                                    reminderSet ? "Reminder Set for \(rec.recommendedTimeText)" : (reminderInFlight ? "Scheduling…" : "Set Reminder for \(rec.recommendedTimeText)"),
                                    systemImage: reminderSet ? "checkmark.circle.fill" : "bell.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(reminderSet || reminderInFlight)

                            saveRouteButton
                        }

                        if let reminderError {
                            Text(reminderError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if reminderSet {
                            Text("You can start navigation as soon as it's time to leave.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Button {
                            if let url = navigationURL(origin: trip.origin, destination: trip.destination) {
                                openURL(url)
                            }
                            logTripStart()
                        } label: {
                            Label("Start Navigation", systemImage: "location.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!trip.isValid || recommendation == nil || isLoading)

                        saveRouteButton
                    }

                    if let rec = recommendation, !rec.alreadyOptimal, !isLoading {
                        Button {
                            scheduleReminder(for: rec)
                        } label: {
                            Label(
                                reminderSet ? "Reminder set for \(rec.recommendedTimeText)" : (reminderInFlight ? "Scheduling…" : "Remind Me at \(rec.recommendedTimeText)"),
                                systemImage: reminderSet ? "checkmark.circle.fill" : "bell"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(reminderSet || reminderInFlight)

                        if let reminderError {
                            Text(reminderError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var reminderListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Upcoming Reminders")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(upcomingReminders) { reminder in
                    ReminderRowView(
                        reminder: reminder,
                        onEdit: { newDate in updateReminder(reminder, to: newDate) },
                        onDelete: { deleteReminder(reminder) }
                    )
                    if reminder.id != upcomingReminders.last?.id {
                        Divider()
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
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

    /// Home and Office pinned first (in that order, only when each actually has an
    /// address set), then Favorite Routes fill any remaining slots up to 3 total —
    /// sourced live from the same `@Query` Routes uses, so a route saved, renamed,
    /// or moved into/out of Favorites there shows up here immediately rather than
    /// a separate, stale copy.
    private var quickChips: [QuickChip] {
        var chips: [QuickChip] = []
        if let home = allFavorites.first(where: { $0.kind == .home }), !home.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chips.append(QuickChip(id: "home", icon: home.kind.icon, label: home.name, action: { applyFavorite(home) }))
        }
        if let office = allFavorites.first(where: { $0.kind == .office }), !office.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chips.append(QuickChip(id: "office", icon: office.kind.icon, label: office.name, action: { applyFavorite(office) }))
        }
        let remainingSlots = 3 - chips.count
        if remainingSlots > 0 {
            let favoriteRoutes = savedCommutes
                .filter { $0.isFavorite }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(remainingSlots)
            for route in favoriteRoutes {
                chips.append(QuickChip(id: "route-\(route.persistentModelID.hashValue)", icon: "star.fill", label: route.name, action: { applyFavoriteRoute(route) }))
            }
        }
        return chips
    }

    /// Loads both ends of a Favorite Route at once — unlike Home/Office (a single
    /// address filling whichever field is next), a route replaces the whole trip.
    private func applyFavoriteRoute(_ commute: SavedCommute) {
        trip.origin = commute.origin
        trip.originCoordinate = nil
        trip.destination = commute.destination
        trip.destinationCoordinate = nil
    }

    /// Fills From if it's blank, else To if that's blank, else replaces To (most
    /// recently tapped favorite wins as the destination).
    private func applyFavorite(_ favorite: FavoriteLocation) {
        if trip.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trip.origin = favorite.address
            trip.originCoordinate = nil
        } else {
            trip.destination = favorite.address
            trip.destinationCoordinate = nil
        }
    }

    private func loadPendingCommuteIfNeeded() {
        if let origin = appSettings.pendingOrigin, let destination = appSettings.pendingDestination {
            var newTrip = Trip(origin: origin, destination: destination)
            newTrip.stops = (appSettings.pendingStops ?? []).map { TripStop(address: $0) }
            trip = newTrip
            appSettings.pendingOrigin = nil
            appSettings.pendingDestination = nil
            appSettings.pendingStops = nil
            // A saved route's origin may literally be "Current Location" (kept
            // unresolved on purpose so it stays live) — resolve it against wherever
            // the phone actually is right now rather than waiting on the next
            // incidental location tick, same as tapping the Current Location button.
            if origin == Self.currentLocationLabel {
                useCurrentLocationForOrigin()
            }
        }
    }

    /// `silent` is what the periodic background refresh (below) uses: it updates
    /// the numbers with fresh live traffic without disturbing anything the user is
    /// mid-interaction with — no loading skeleton flash, no clearing a route they
    /// manually picked, no resetting "Reminder Set" back to unset, and critically,
    /// no writing a new HistoricalSample. Logging on every silent refresh would
    /// have every 3-minute tick pile more weight onto whatever moment the screen
    /// happened to be left open at, skewing the historical pattern store toward
    /// that instead of genuinely varied real-world sampling.
    ///
    /// A silent refresh runs on its own timer, entirely independent of
    /// `.task(id: recomputeKey)` — it isn't cancelled just because the user edited
    /// something while its ~11 live checkpoint calls were still in flight. Without
    /// a staleness check, a silent refresh that happened to start against the old
    /// trip could finish *after* the edit's own fresh recompute and overwrite the
    /// screen with an answer for a trip that isn't even showing anymore. Snapshot
    /// the key before starting, and only apply the result if it still matches.
    private func recompute(silent: Bool = false) async {
        let keyAtStart = recomputeKey
        if !silent {
            reminderSet = false
            reminderError = nil
            addressError = nil
        }
        guard trip.isValid else {
            if !silent { recommendation = nil }
            return
        }

        if !silent {
            // Debounce: task(id:) cancels this on every keystroke, so only the last
            // edit's task survives the sleep and actually hits the network.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            isLoading = true
        }

        let outcome: RecommendationOutcome
        switch mode {
        case .departAt:
            outcome = await RecommendationEngine.recommend(
                trip: trip,
                departureOption: departureOption,
                simulateFailure: appSettings.simulateAPIFailure,
                modelContext: modelContext,
                logHistory: !silent
            )
        case .arriveBy:
            outcome = await RecommendationEngine.recommendArriveBy(
                trip: trip,
                targetArrival: targetArrival,
                simulateFailure: appSettings.simulateAPIFailure,
                modelContext: modelContext,
                logHistory: !silent
            )
        }
        guard !Task.isCancelled else { return }
        if silent && recomputeKey != keyAtStart {
            // Something more current has already taken over — a stale silent
            // answer for a trip that's no longer showing is worse than no update.
            return
        }

        switch outcome {
        case .success(let rec):
            recommendation = rec
            if !silent {
                selectedRouteID = nil // defaults back to the fastest route for the new recommendation
            }
            // Keeps the map's pins accurate even when the user typed a full address
            // without tapping a search suggestion (which is the only other path that
            // sets these coordinates).
            trip.originCoordinate = rec.originCoordinate
            trip.destinationCoordinate = rec.destinationCoordinate
        case .invalidAddress(let message):
            if !silent {
                recommendation = nil
                addressError = message
            }
        }
        if !silent { isLoading = false }
    }

    /// The Route Options entry currently in effect — whichever the user tapped,
    /// falling back to the fastest (the UI's own default when nothing's been
    /// explicitly picked yet).
    private var selectedRoute: RouteOption? {
        guard let routes = recommendation?.routes else { return nil }
        return routes.first { $0.id == selectedRouteID } ?? routes.first { $0.isFastest } ?? routes.first
    }

    /// A coordinate roughly at the midpoint of the currently-selected route's own
    /// geometry, used to force Google Maps onto that specific path. Nil when
    /// there's only one route anyway (nothing to disambiguate) or no polyline is
    /// available.
    private func selectedRouteMidpoint() -> CLLocationCoordinate2D? {
        guard let routes = recommendation?.routes, routes.count > 1 else { return nil }
        guard let polyline = selectedRoute?.polyline, polyline.pointCount > 0 else { return nil }
        let midpoint = polyline.points()[polyline.pointCount / 2]
        return midpoint.coordinate
    }

    private func useCurrentLocationForOrigin() {
        awaitingCurrentLocationForOrigin = true
        if let location = locationManager.currentLocation {
            applyCurrentLocation(location)
        } else {
            locationManager.requestLocation()
        }
    }

    /// Within ~50m counts as "the same place" for switching a typed/picked origin
    /// over to Current Location — loose enough to absorb GPS drift and a
    /// reverse-geocoded address not landing on the exact same rooftop point, tight
    /// enough that a nearby-but-different address doesn't get relabeled.
    private func isSameLocation(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) < 50
    }

    private func applyCurrentLocation(_ location: CLLocation) {
        // The Current Location button only shows while From is empty and focused
        // (keyboard up); resigning first responder here — rather than leaving the
        // field focused — is what stops the field's own suggestions search from
        // firing on "Current Location" as if it were a typed query.
        dismissKeyboard()
        trip.origin = Self.currentLocationLabel
        trip.originCoordinate = location.coordinate
        awaitingCurrentLocationForOrigin = false
        currentLocationResolvedAddress = nil
        resolveCurrentLocationAddress(location)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func resolveCurrentLocationAddress(_ location: CLLocation) {
        Task {
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
            currentLocationResolvedAddress = Self.preciseAddressText(from: placemark)
        }
    }

    /// A specific, mappable address from a placemark — a named place kept with its
    /// city (e.g. "Crunch Fitness, Tracy, CA") or, when there's no POI name, the
    /// actual street address (e.g. "1975 11th St, Tracy, CA"). Deliberately never
    /// falls back to just a city name: handing "Tracy, CA" to a maps app for
    /// directions lands you at the city center, not the point that was tapped.
    private static func preciseAddressText(from placemark: CLPlacemark) -> String? {
        let context = [placemark.locality, placemark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        if let name = placemark.name, !name.isEmpty, name != placemark.thoroughfare {
            return context.isEmpty ? name : "\(name), \(context)"
        }
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        if !street.isEmpty {
            return context.isEmpty ? street : "\(street), \(context)"
        }
        return context.isEmpty ? placemark.name : context
    }

    /// Tapping a spot on the expanded map sets it as the destination immediately
    /// (using the raw coordinate, so route calculation isn't blocked on geocoding),
    /// then swaps in a precise, mappable address once reverse geocoding resolves —
    /// unless the user has since picked a different point or typed over the field.
    private func applyMapPickedDestination(_ coordinate: CLLocationCoordinate2D) {
        trip.destinationCoordinate = coordinate
        trip.destination = "Selected Location"
        Task {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
            guard trip.destinationCoordinate == coordinate else { return }
            if let text = Self.preciseAddressText(from: placemark) { trip.destination = text }
        }
    }

    /// Same as above, but for setting the origin — lets a spot tapped on the map
    /// be used as "come from" instead of only ever "go to". Since it's now a
    /// specific picked point rather than the device's live position, it replaces
    /// "Current Location" outright rather than tracking it.
    private func applyMapPickedOrigin(_ coordinate: CLLocationCoordinate2D) {
        awaitingCurrentLocationForOrigin = false
        currentLocationResolvedAddress = nil
        trip.originCoordinate = coordinate
        trip.origin = "Selected Location"
        Task {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
            guard trip.originCoordinate == coordinate else { return }
            if let text = Self.preciseAddressText(from: placemark) { trip.origin = text }
        }
    }

    /// "Current Location" is meaningful in the From field; anywhere it's persisted
    /// or read back later (History, notifications), the resolved place name reads
    /// far better than a label that stops being true the moment you look at it again.
    private var originNameForLogging: String {
        trip.origin == Self.currentLocationLabel ? (currentLocationResolvedAddress ?? trip.origin) : trip.origin
    }

    /// Depart At / Arrive By only makes sense once there's an actual trip to time —
    /// picking a mode before that just leaves the picker referring to nothing.
    private var hasOriginAndDestination: Bool {
        !trip.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trip.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Earliest arrival time worth offering: current drive time plus a 1-hour
    /// buffer, rounded to the nearest 5 minutes — picking an arrival any sooner
    /// than that isn't realistically reachable with any safety margin at all.
    /// Falls back to a 20-minute drive assumption before the live estimate has
    /// come back (e.g. right after typing a new destination).
    private var minimumArriveBy: Date {
        let minutes = currentNowMinutes ?? 20
        let raw = Date().addingTimeInterval(Double(minutes + 60) * 60)
        return Self.roundedToNearestFiveMinutes(raw)
    }

    private static func roundedToNearestFiveMinutes(_ date: Date) -> Date {
        let fiveMinutes = 300.0
        let interval = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (interval / fiveMinutes).rounded() * fiveMinutes)
    }

    /// Only meaningful while Arrive By is active — empty (so the quick-duration
    /// task above does nothing) whenever it isn't, so switching to Depart At
    /// doesn't fire a redundant live lookup the main recommendation already covers.
    private var arriveByQuickKey: String {
        mode == .arriveBy ? trip.routeKey : ""
    }

    private func scheduleReminder(for rec: Recommendation) {
        reminderInFlight = true
        reminderError = nil
        let identifier = "smartride.reminder.\(UUID().uuidString)"
        Task {
            // Passes the raw origin (which may literally be "Current Location") so a
            // tap on the notification lets Maps fall back to live GPS at that later
            // moment, rather than baking in wherever the phone was when this was set.
            let ok = await NotificationManager.scheduleDepartureReminder(id: identifier, at: rec.recommendedTime, origin: trip.origin, destination: trip.destination, travelMode: trip.travelMode)
            reminderSet = ok
            reminderInFlight = false
            if ok {
                let item = ReminderItem(
                    origin: originNameForLogging,
                    destination: trip.destination,
                    scheduledTime: rec.recommendedTime,
                    notificationIdentifier: identifier,
                    travelMode: trip.travelMode
                )
                modelContext.insert(item)
                try? modelContext.save()
            } else {
                reminderError = "Enable notifications in Settings to get reminders."
            }
        }
    }

    /// "Start Navigation" always means leaving right now, so the logged departure
    /// is the actual tap time — not `rec.recommendedTime`, which can lag a little
    /// behind by the time the user actually taps (recommendations refresh
    /// periodically, not on every render). Duration/arrival math uses whichever
    /// Route Option is actually in effect, since an alternate (non-fastest) pick
    /// can take longer than the recommendation's own fastest-route estimate.
    private func logTripStart() {
        guard let rec = recommendation else { return }
        let route = selectedRoute
        let logged = LoggedTrip(
            origin: originNameForLogging,
            destination: trip.destination,
            plannedDeparture: Date(),
            predictedSavedMinutes: rec.timeSavedMinutes,
            confidencePercent: rec.confidencePercent,
            expectedDurationMinutes: route?.durationMinutes ?? rec.expectedDurationMinutes,
            stopAddresses: trip.stops.map(\.address).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            travelMode: trip.travelMode,
            routeSummary: route?.fullRouteSummary ?? route?.summary,
            routeKey: trip.routeKey
        )
        modelContext.insert(logged)
        try? modelContext.save()
    }

    /// Prefers a resolved, human-readable address for both ends of the trip — Maps
    /// then shows the actual place name/address as the destination instead of a
    /// bare pair of numbers, and still geocodes it into a real route on its own,
    /// since every text address we hand it by this point came from either a place-
    /// search selection or our own reverse geocoding (never raw, ambiguous typing).
    /// Only falls back to a coordinate when there's genuinely no resolved text yet
    /// (e.g. a map pin whose reverse geocode hasn't returned). Omits the origin
    /// param entirely for "Current Location", letting the target app use its own
    /// live position (fresher than our captured coordinate).
    ///
    /// For Google Maps specifically, also forces the route you picked in-app: a
    /// point from the middle of that route's own geometry is passed as a waypoint,
    /// which requires Google to route through it — collapsing the alternates down
    /// to that one path instead of presenting the picker again. Apple Maps' URL
    /// scheme has no waypoint parameter at all, so this isn't possible there; it
    /// will always show its own route picker regardless of what's selected here.
    private func navigationURL(origin: String, destination: String) -> URL? {
        func resolvedParam(text: String, coordinate: CLLocationCoordinate2D?) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "Selected Location" {
                return trimmed
            }
            guard let coordinate else { return trimmed.isEmpty ? nil : trimmed }
            return "\(coordinate.latitude),\(coordinate.longitude)"
        }

        let originParam: String?
        if origin == Self.currentLocationLabel {
            originParam = nil
        } else {
            originParam = resolvedParam(text: origin, coordinate: trip.originCoordinate)
        }

        let destinationParam = resolvedParam(text: destination, coordinate: trip.destinationCoordinate) ?? destination

        // Google Maps supports real multi-stop waypoints; Apple Maps' URL scheme has
        // no equivalent at all (same gap documented for route-forcing above). Rather
        // than silently drop the stops when Apple Maps is preferred (the default),
        // force Google Maps for this hand-off — the alternative is a "stop" that
        // quietly never shows up in navigation, which is worse than switching apps.
        let stopWaypoints: [String] = trip.filledStops.compactMap { stop in
            if let coordinate = stop.coordinate { return "\(coordinate.latitude),\(coordinate.longitude)" }
            let trimmed = stop.address.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let effectiveMapsApp = stopWaypoints.isEmpty ? preferredMapsApp : "google"

        switch effectiveMapsApp {
        case "google":
            var items = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "destination", value: destinationParam),
                URLQueryItem(name: "travelmode", value: trip.travelMode.googleTravelMode),
            ]
            if let originParam { items.append(URLQueryItem(name: "origin", value: originParam)) }
            if !stopWaypoints.isEmpty {
                items.append(URLQueryItem(name: "waypoints", value: stopWaypoints.joined(separator: "|")))
            } else if let waypoint = selectedRouteMidpoint() {
                items.append(URLQueryItem(name: "waypoints", value: "\(waypoint.latitude),\(waypoint.longitude)"))
            }
            var components = URLComponents(string: "https://www.google.com/maps/dir/")
            components?.queryItems = items
            return components?.url
        default:
            var items = [
                URLQueryItem(name: "daddr", value: destinationParam),
                URLQueryItem(name: "dirflg", value: trip.travelMode.appleDirectionsFlag),
            ]
            if let originParam { items.append(URLQueryItem(name: "saddr", value: originParam)) }
            var components = URLComponents(string: "https://maps.apple.com/")
            components?.queryItems = items
            return components?.url
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .modelContainer(for: [HistoricalSample.self, LoggedTrip.self, SavedCommute.self, FavoriteLocation.self, ReminderItem.self], inMemory: true)
}
