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

    init(
        origin: String,
        destination: String,
        plannedDeparture: Date,
        predictedSavedMinutes: Int,
        confidencePercent: Int,
        expectedDurationMinutes: Int = 0,
        stopAddresses: [String] = [],
        travelMode: TravelMode = .driving,
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
        self.createdAt = createdAt
    }

    var travelMode: TravelMode {
        TravelMode(rawValue: travelModeRaw) ?? .driving
    }
}
