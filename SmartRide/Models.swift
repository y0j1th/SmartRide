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

    /// Normalized key used to bucket this route's samples in the historical store.
    var routeKey: String {
        let a = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(a)|\(b)"
    }
}

struct Recommendation {
    let referenceNow: Date
    let mode: TripMode

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
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var recommendedTimeText: String { Self.timeFormatter.string(from: recommendedTime) }
    var arrivalTimeText: String { Self.timeFormatter.string(from: arrivalTime) }
    var latestSafeDepartureText: String? {
        latestSafeDeparture.map { Self.timeFormatter.string(from: $0) }
    }
    var targetArrivalText: String? {
        targetArrival.map { Self.timeFormatter.string(from: $0) }
    }

    var durationText: String { Self.minutesText(expectedDurationMinutes) }

    var rangeText: String {
        "\(Self.minutesText(durationRangeMinutes.lowerBound))–\(Self.minutesText(durationRangeMinutes.upperBound))"
    }
}
