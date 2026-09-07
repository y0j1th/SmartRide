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

struct ContentView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteLocation.createdAt) private var allFavorites: [FavoriteLocation]
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
    /// The real place name behind "Current Location" (e.g. "Tracy, CA"), resolved
    /// in the background via reverse geocoding. Used whenever "Current Location"
    /// needs to appear as plain text elsewhere — swapped into Destination, or
    /// logged to History — since it stops meaning "here, right now" the moment
    /// it's anything other than the live origin.
    @State private var currentLocationResolvedAddress: String?

    private static let currentLocationLabel = "Current Location"

    private var recomputeKey: String {
        let modePart = mode == .departAt ? departureOption.kind + "|\(customDate.timeIntervalSince1970)" : "arrive|\(targetArrival.timeIntervalSince1970)"
        return "\(trip.origin)|\(trip.destination)|\(mode.rawValue)|\(modePart)|\(appSettings.simulateAPIFailure)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    logoHeader
                    tripCard

                    FavoriteChipsRow(favorites: favoritesWithAddress, onSelect: applyFavorite)

                    RouteMapView(
                        originCoordinate: trip.originCoordinate,
                        destinationCoordinate: trip.destinationCoordinate,
                        routes: recommendation?.routes ?? [],
                        selectedRouteID: selectedRouteID,
                        onSelectRoute: { selectedRouteID = $0 }
                    )

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

                    BestTimeToLeaveCard(
                        recommendation: recommendation,
                        isLoading: isLoading,
                        origin: originNameForLogging,
                        destination: trip.destination,
                        onViewAllTimes: { showAllTimes = true }
                    )

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
                }
                .padding()
            }
            .navigationBarHidden(true)
            .onAppear {
                loadPendingCommuteIfNeeded()
                if trip.origin.isEmpty {
                    useCurrentLocationForOrigin()
                }
                Task { await SmartAlertChecker.checkAll(appSettings: appSettings, modelContext: modelContext) }
            }
            .onChange(of: appSettings.selectedTab) { _, newValue in
                if newValue == 0 { loadPendingCommuteIfNeeded() }
            }
            .onReceive(locationManager.$currentLocation) { location in
                guard let location, awaitingCurrentLocationForOrigin else { return }
                applyCurrentLocation(location)
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

    private var tripCard: some View {
        VStack(spacing: 8) {
            LocationSearchField(placeholder: "From", text: $trip.origin, coordinate: $trip.originCoordinate)

            HStack(alignment: .top) {
                LocationSearchField(placeholder: "Destination", text: $trip.destination, coordinate: $trip.destinationCoordinate)
                Button {
                    swapOriginAndDestination()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func swapOriginAndDestination() {
        // "Current Location" only makes sense while it's the origin — moving it to
        // Destination should show the actual place (e.g. "Tracy, CA"), not the
        // literal label, since you can't navigate to "here, right now" as a target.
        let originValue = trip.origin == Self.currentLocationLabel
            ? (currentLocationResolvedAddress ?? trip.origin)
            : trip.origin
        let originCoordinateValue = trip.originCoordinate
        trip.origin = trip.destination
        trip.originCoordinate = trip.destinationCoordinate
        trip.destination = originValue
        trip.destinationCoordinate = originCoordinateValue
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

    private var actionButtons: some View {
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

            if let rec = recommendation, !rec.alreadyOptimal, !isLoading {
                VStack(spacing: 4) {
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
        guard let origin = appSettings.pendingOrigin, let destination = appSettings.pendingDestination else { return }
        trip = Trip(origin: origin, destination: destination)
        appSettings.pendingOrigin = nil
        appSettings.pendingDestination = nil
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
            let parts = [placemark.locality, placemark.administrativeArea].compactMap { $0 }
            currentLocationResolvedAddress = parts.isEmpty ? placemark.name : parts.joined(separator: ", ")
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
        Task {
            let ok = await NotificationManager.scheduleDepartureReminder(at: rec.recommendedTime, destination: trip.destination)
            reminderSet = ok
            reminderInFlight = false
            if !ok {
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
            expectedDurationMinutes: rec.expectedDurationMinutes
        )
        modelContext.insert(logged)
        try? modelContext.save()
    }

    /// Passes coordinates instead of free-text addresses whenever we have them —
    /// free text (especially a place-search result like "Crunch Fitness, 3120 W
    /// Grant Line Rd, Tracy, CA") is exactly what made Maps sometimes fail to
    /// resolve a route and land on a plain search/pin screen instead. Omits the
    /// origin param entirely for "Current Location", letting the target app use
    /// its own live position (fresher than our captured coordinate).
    ///
    /// For Google Maps specifically, also forces the route you picked in-app: a
    /// point from the middle of that route's own geometry is passed as a waypoint,
    /// which requires Google to route through it — collapsing the alternates down
    /// to that one path instead of presenting the picker again. Apple Maps' URL
    /// scheme has no waypoint parameter at all, so this isn't possible there; it
    /// will always show its own route picker regardless of what's selected here.
    private func navigationURL(origin: String, destination: String) -> URL? {
        let originParam: String?
        if origin == Self.currentLocationLabel {
            originParam = nil
        } else if let coordinate = trip.originCoordinate {
            originParam = "\(coordinate.latitude),\(coordinate.longitude)"
        } else {
            originParam = origin
        }

        let destinationParam: String
        if let coordinate = trip.destinationCoordinate {
            destinationParam = "\(coordinate.latitude),\(coordinate.longitude)"
        } else {
            destinationParam = destination
        }

        switch preferredMapsApp {
        case "google":
            var items = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "destination", value: destinationParam),
                URLQueryItem(name: "travelmode", value: "driving"),
            ]
            if let originParam { items.append(URLQueryItem(name: "origin", value: originParam)) }
            if let waypoint = selectedRouteMidpoint() {
                items.append(URLQueryItem(name: "waypoints", value: "\(waypoint.latitude),\(waypoint.longitude)"))
            }
            var components = URLComponents(string: "https://www.google.com/maps/dir/")
            components?.queryItems = items
            return components?.url
        default:
            var items = [
                URLQueryItem(name: "daddr", value: destinationParam),
                URLQueryItem(name: "dirflg", value: "d"),
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
        .modelContainer(for: [HistoricalSample.self, LoggedTrip.self, SavedCommute.self, FavoriteLocation.self], inMemory: true)
}
