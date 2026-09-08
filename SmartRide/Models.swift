//
//  Models.swift
//  SmartRide
//

import SwiftUI
import CoreLocation
import MapKit

enum TrafficCondition: String {
    case light, moderate, congested

    var label: String {
        switch self {
        case .light: return "Light traffic"
        case .moderate: return "Moderate traffic"
        case .congested: return "Congested"
        }
    }

    var color: Color {
        switch self {
        case .light: return .green
        case .moderate: return .orange
        case .congested: return .red
        }
    }
}

struct RouteOption: Identifiable {
    let id = UUID()
    let summary: String
    let durationMinutes: Int
    let distanceMiles: Double
    let condition: TrafficCondition
    let delayNote: String
    let isFastest: Bool
    let hasTolls: Bool
    /// Highway chain extracted from turn-by-turn steps, e.g. "I-580 W → I-680 S →
    /// US-101 N" — fuller than `summary`, which MapKit sometimes only names the
    /// primary highway. Nil when no numbered highways were found in the steps.
    let fullRouteSummary: String?
    let polyline: MKPolyline?

    var durationText: String {
        let h = durationMinutes / 60
        let m = durationMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var distanceText: String {
        String(format: "%.0f mi", distanceMiles)
    }
}

enum DepartureOption: Hashable {
    case now
    case in15
    case in30
    case custom(Date)

    var label: String {
        switch self {
        case .now: return "Now"
        case .in15: return "15 min"
        case .in30: return "30 min"
        case .custom: return "Custom"
        }
    }

    /// Stable identity ignoring the exact custom date, used for the segmented control.
    var kind: String {
        switch self {
        case .now: return "now"
        case .in15: return "in15"
        case .in30: return "in30"
        case .custom: return "custom"
        }
    }
}

enum TripMode: String, Hashable {
    case departAt
    case arriveBy
}

enum TravelMode: String, CaseIterable, Hashable {
    case driving
    case walking
    case biking
    case motorcycling
    case transit

    var label: String {
        switch self {
        case .driving: return "Driving"
        case .walking: return "Walking"
        case .biking: return "Biking"
        case .motorcycling: return "Motorcycling"
        case .transit: return "Transit"
        }
    }

    var systemImage: String {
        switch self {
        case .driving: return "car.fill"
        case .walking: return "figure.walk"
        case .biking: return "bicycle"
        case .motorcycling: return "motorcycle.fill"
        case .transit: return "bus.fill"
        }
    }

    /// MapKit has no bicycling or motorcycle transport type — both route over the
    /// same road network a car would, so `.automobile` is the closest real routing
    /// available; `durationScaleFactor` corrects the resulting duration.
    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .driving, .biking, .motorcycling: return .automobile
        case .walking: return .walking
        case .transit: return .transit
        }
    }

    /// Multiplies the automobile-routed duration to approximate this mode's real
    /// travel time, since MapKit can only give us a driving route to start from.
    /// Motorcycles keep pace with car traffic closely enough to leave as-is; bikes
    /// are meaningfully slower on the same roads, especially anywhere with highway
    /// segments a bike wouldn't actually take — an acknowledged approximation, not
    /// a real bike-routing engine.
    var durationScaleFactor: Double {
        switch self {
        case .biking: return 2.2
        case .driving, .motorcycling, .walking, .transit: return 1.0
        }
    }

    /// Apple Maps' `dirflg` URL parameter. No cycling or motorcycle flag exists in
    /// Apple's scheme, so both fall back to driving directions there.
    var appleDirectionsFlag: String {
        switch self {
        case .driving, .biking, .motorcycling: return "d"
        case .walking: return "w"
        case .transit: return "r"
        }
    }

    /// Google Maps supports a real "bicycling" mode; it has no distinct motorcycle
    /// mode, so that one also falls back to driving directions.
    var googleTravelMode: String {
        switch self {
        case .driving, .motorcycling: return "driving"
        case .walking: return "walking"
        case .biking: return "bicycling"
        case .transit: return "transit"
        }
    }

    /// Distance-based fallback speed for when live directions can't be fetched at
    /// all (MapKit walking directions in particular have a distance limit and
    /// simply fail beyond it — a very ordinary occurrence for a normal commute
    /// distance, not an edge case). Using the driving speed here regardless of mode
    /// used to make a failed walking fetch estimate a hike at car speed.
    var fallbackAverageSpeedMph: Double {
        switch self {
        case .driving, .motorcycling: return 45.0
        case .walking: return 3.0
        case .biking: return 12.0
        case .transit: return 25.0
        }
    }
}

/// One intermediate stop between origin and destination. Free-standing (not tied to
/// FavoriteLocation) so a stop can be anything typed or map-picked, same as origin
/// and destination.
struct TripStop: Identifiable, Hashable {
    let id: UUID
    var address: String
    var coordinate: CLLocationCoordinate2D?

    init(id: UUID = UUID(), address: String = "", coordinate: CLLocationCoordinate2D? = nil) {
        self.id = id
        self.address = address
        self.coordinate = coordinate
    }

    static func == (lhs: TripStop, rhs: TripStop) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One point in the continuous departure-time prediction window: what it would cost
/// (in total drive time, across the best available route) to leave at `time`.
struct CandidateResult: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let durationMinutes: Int

    var arrivalTime: Date { time.addingTimeInterval(Double(durationMinutes) * 60) }

    var timeText: String { Recommendation.timeFormatter.string(from: time) }

    static func == (lhs: CandidateResult, rhs: CandidateResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Trip {
    var origin: String
    /// Set when `origin` was chosen from a place-search suggestion, so the engine can
    /// skip re-geocoding free text (which may be an ambiguous business name like
    /// "Crunch Tracy" that a plain address geocoder can't reliably resolve).
    var originCoordinate: CLLocationCoordinate2D?
    var destination: String
    var destinationCoordinate: CLLocationCoordinate2D?
    /// Intermediate stops, in visit order. Ones with a blank address are ignored by
    /// the engine and the nav hand-off — they exist only as an in-progress row in
    /// the UI (a newly-added stop the user hasn't searched yet).
    var stops: [TripStop] = []
    var travelMode: TravelMode = .driving

    var isValid: Bool {
        let a = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && !b.isEmpty && a != b
    }

    /// True only once both fields are actually filled in and identical — distinct
    /// from `isValid` so the UI can tell "not finished typing yet" (no error) apart
    /// from "typed the same place twice" (a real error).
    var isSameLocation: Bool {
        let a = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && !b.isEmpty && a == b
    }

    var filledStops: [TripStop] {
        stops.filter { !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Normalized key used to bucket this route's samples in the historical store —
    /// includes stops and travel mode so a multi-stop or walking version of the same
    /// origin/destination pair never gets blended with a direct drive's history.
    var routeKey: String {
        let a = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stopsKey = filledStops.map { $0.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: ">")
        return "\(a)|\(b)|\(stopsKey)|\(travelMode.rawValue)"
    }
}

struct Recommendation {
    let referenceNow: Date
    let mode: TripMode
    var travelMode: TravelMode = .driving

    let recommendedTime: Date
    let expectedDurationMinutes: Int
    /// "Likely range" band around `expectedDurationMinutes`, derived from historical
    /// variance at this time — shown instead of a bare confidence number so users can
    /// reason about it directly (doc enhancement: confidence should be actionable).
    let durationRangeMinutes: ClosedRange<Int>
    let arrivalTime: Date

    let timeSavedMinutes: Int
    let leaveNowDurationMinutes: Int
    let confidencePercent: Int
    let isFallback: Bool
    let alreadyOptimal: Bool
    /// The first point, scanning forward through `candidates`, where drive time
    /// starts climbing sharply rather than drifting — leaving after this moment
    /// costs noticeably more per minute of delay than leaving before it. Nil if
    /// nothing in the window jumps that sharply.
    var trafficCliffTime: Date? = nil

    /// Route alternatives for the recommended departure time.
    let routes: [RouteOption]
    /// The full continuous prediction window (every candidate time considered),
    /// backing the departure-time graph and the "leave now / leave X / leave Y"
    /// mini comparison list.
    let candidates: [CandidateResult]

    // MARK: Map (top section)

    let originCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
    /// Geometry for the fastest fetched route, for the route map preview.
    let routePolyline: MKPolyline?

    // MARK: Arrive-By mode only (nil in Depart-At mode)

    let targetArrival: Date?
    /// Latest departure that still comfortably meets the reliability buffer — this is
    /// what's shown as "Best departure" in Arrive-By mode (later best-effort still
    /// keeps a margin, matching the doc's "Latest Safe Departure" being riskier than
    /// the recommended one).
    let latestSafeDeparture: Date?
    let reliabilityPercent: Int?

    var explanation: String {
        isFallback ? "Based on typical patterns (live data unavailable)" : "Based on real-time + historical trends"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static func minutesText(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// Same duration, spelled out in full words ("1 hour 1 min" rather than
    /// "1h 1m") — used in prose sentences (History's "You've saved…" lines) where
    /// the compact abbreviation used everywhere else reads awkwardly.
    static func minutesPhrase(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        let hourPart = h > 0 ? "\(h) hour\(h == 1 ? "" : "s")" : nil
        let minutePart = m > 0 ? "\(m) min" : nil
        switch (hourPart, minutePart) {
        case (let h?, let m?): return "\(h) \(m)"
        case (let h?, nil): return h
        case (nil, let m?): return m
        case (nil, nil): return "0 min"
        }
    }

    var recommendedTimeText: String { Self.timeFormatter.string(from: recommendedTime) }
    var arrivalTimeText: String { Self.timeFormatter.string(from: arrivalTime) }
    var latestSafeDepartureText: String? {
        latestSafeDeparture.map { Self.timeFormatter.string(from: $0) }
    }
    var targetArrivalText: String? {
        targetArrival.map { Self.timeFormatter.string(from: $0) }
    }
    var trafficCliffTimeText: String? {
        trafficCliffTime.map { Self.timeFormatter.string(from: $0) }
    }

    var durationText: String { Self.minutesText(expectedDurationMinutes) }

    var rangeText: String {
        "\(Self.minutesText(durationRangeMinutes.lowerBound))–\(Self.minutesText(durationRangeMinutes.upperBound))"
    }
}
