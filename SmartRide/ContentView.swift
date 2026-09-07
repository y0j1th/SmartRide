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

                    FavoriteChipsRow(favorites: favoritesWithAddress, onSelect: applyFavorite)
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

                    TripModeSelector(mode: $mode)

                    if mode == .departAt {
                        DepartureTimeSelector(selection: $departureOption, customDate: $customDate)
                    } else {
                        ArriveBySelector(targetArrival: $targetArrival)
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
                }
            }
            .task(id: recomputeKey) {
                await recompute()
            }
            .sheet(isPresented: $showAllTimes) {
                if let recommendation {
                    AllDepartureTimesView(recommendation: recommendation)
                }
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

    private var saveRouteButton: some View {
        RouteSaveMenu(origin: originNameForLogging, destination: trip.destination, travelMode: trip.travelMode, isEnabled: trip.isValid)
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

    private var favoritesWithAddress: [FavoriteLocation] {
        allFavorites.filter { !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        }
    }

    private func recompute() async {
        reminderSet = false
        reminderError = nil
        addressError = nil
        guard trip.isValid else {
            recommendation = nil
            return
        }

        // Debounce: task(id:) cancels this on every keystroke, so only the last
        // edit's task survives the sleep and actually hits the network.
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }

        isLoading = true
        let outcome: RecommendationOutcome
        switch mode {
        case .departAt:
            outcome = await RecommendationEngine.recommend(
                trip: trip,
                departureOption: departureOption,
                simulateFailure: appSettings.simulateAPIFailure,
                modelContext: modelContext
            )
        case .arriveBy:
            outcome = await RecommendationEngine.recommendArriveBy(
                trip: trip,
                targetArrival: targetArrival,
                simulateFailure: appSettings.simulateAPIFailure,
                modelContext: modelContext
            )
        }
        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let rec):
            recommendation = rec
            selectedRouteID = nil // defaults back to the fastest route for the new recommendation
            // Keeps the map's pins accurate even when the user typed a full address
            // without tapping a search suggestion (which is the only other path that
            // sets these coordinates).
            trip.originCoordinate = rec.originCoordinate
            trip.destinationCoordinate = rec.destinationCoordinate
        case .invalidAddress(let message):
            recommendation = nil
            addressError = message
        }
        isLoading = false
    }

    /// A coordinate roughly at the midpoint of the currently-selected route's own
    /// geometry (falling back to the fastest route, same default the UI shows),
    /// used to force Google Maps onto that specific path. Nil when there's only
    /// one route anyway (nothing to disambiguate) or no polyline is available.
    private func selectedRouteMidpoint() -> CLLocationCoordinate2D? {
        guard let routes = recommendation?.routes, routes.count > 1 else { return nil }
        let route = routes.first { $0.id == selectedRouteID } ?? routes.first { $0.isFastest } ?? routes.first
        guard let polyline = route?.polyline, polyline.pointCount > 0 else { return nil }
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

    private func applyCurrentLocation(_ location: CLLocation) {
        trip.origin = Self.currentLocationLabel
        trip.originCoordinate = location.coordinate
        awaitingCurrentLocationForOrigin = false
        currentLocationResolvedAddress = nil
        resolveCurrentLocationAddress(location)
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

    private func logTripStart() {
        guard let rec = recommendation else { return }
        let logged = LoggedTrip(
            origin: originNameForLogging,
            destination: trip.destination,
            plannedDeparture: rec.recommendedTime,
            predictedSavedMinutes: rec.timeSavedMinutes,
            confidencePercent: rec.confidencePercent,
            expectedDurationMinutes: rec.expectedDurationMinutes,
            stopAddresses: trip.stops.map(\.address).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            travelMode: trip.travelMode
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
