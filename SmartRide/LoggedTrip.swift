//
//  LoggedTrip.swift
//  SmartRide
//
//  A real, persisted trip the user started navigation on (doc §3 Step 6 / History
//  tab). We only log what we can honestly know at trip-start time — predicted
//  departure, predicted duration, predicted savings, confidence — not a fabricated
//  "actual arrival," since the MVP has no background tracking to measure that.
//

import Foundation
import SwiftData

@Model
final class LoggedTrip {
    var origin: String
    var destination: String
    var plannedDeparture: Date
    var predictedSavedMinutes: Int
    var confidencePercent: Int
    var createdAt: Date
    /// Predicted total drive time for the planned departure. Backs the weekly/monthly
    /// "average commute" rollup on the History tab. Defaults to 0 for rows written
    /// before this field existed (lightweight SwiftData migration).
    var expectedDurationMinutes: Int = 0
    /// Intermediate stops in visit order, so History can show the exact route driven
    /// (not just origin/destination). Empty for rows written before this field existed.
    var stopAddresses: [String] = []
    var travelModeRaw: String = TravelMode.driving.rawValue
    /// Which of the Route Options the user had selected when they tapped Start
    /// Navigation — e.g. "via I-580 W" — distinct from `stopAddresses`, which is
    /// the places, not the road path between them. Nil for rows written before
    /// this field existed, or when only one route was ever offered.
    var routeSummary: String?
    /// 0-5, set by the user in History after the fact — the app has no
    /// background tracking to check its own predicted duration/arrival against,
    /// so this is the only real signal on whether estimates are trustworthy. Nil
    /// until rated.
    var accuracyRating: Int?
    /// Same normalized key as `Trip.routeKey` (origin|destination|stops|travelMode),
    /// captured at log time — lets RecommendationEngine look up past accuracy
    /// ratings for this exact route when scoring a new recommendation's
    /// confidence. Empty for rows written before this field existed.
    var routeKey: String = ""

    init(
        origin: String,
        destination: String,
        plannedDeparture: Date,
        predictedSavedMinutes: Int,
        confidencePercent: Int,
        expectedDurationMinutes: Int = 0,
        stopAddresses: [String] = [],
        travelMode: TravelMode = .driving,
        routeSummary: String? = nil,
        routeKey: String = "",
        createdAt: Date = Date()
    ) {
        self.origin = origin
        self.destination = destination
        self.plannedDeparture = plannedDeparture
        self.predictedSavedMinutes = predictedSavedMinutes
        self.confidencePercent = confidencePercent
        self.expectedDurationMinutes = expectedDurationMinutes
        self.stopAddresses = stopAddresses
        self.travelModeRaw = travelMode.rawValue
        self.routeSummary = routeSummary
        self.routeKey = routeKey
        self.createdAt = createdAt
    }

    var travelMode: TravelMode {
        TravelMode(rawValue: travelModeRaw) ?? .driving
    }
}
