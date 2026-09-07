//
//  SavedCommute.swift
//  SmartRide
//
//  A user-saved favorite commute (doc §4.1 "Routes — saved/favorite commutes").
//  Optionally carries a target arrival time so the Smart Commute Alert can watch it.
//

import Foundation
import SwiftData

@Model
final class SavedCommute {
    var name: String
    var origin: String
    var destination: String
    var createdAt: Date
    /// Minutes since midnight the user usually wants to arrive by, e.g. 9:30 AM = 570.
    /// Nil means "no alert" for this commute.
    var targetArrivalMinuteOfDay: Int?
    var alertsEnabled: Bool = false
    /// Baseline duration (minutes) the alert last compared against, so we only fire
    /// again when conditions have moved, not on every check.
    var lastAlertedDurationMinutes: Int?

    init(
        name: String,
        origin: String,
        destination: String,
        targetArrivalMinuteOfDay: Int? = nil,
        alertsEnabled: Bool = false,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.origin = origin
        self.destination = destination
        self.targetArrivalMinuteOfDay = targetArrivalMinuteOfDay
        self.alertsEnabled = alertsEnabled
        self.createdAt = createdAt
    }
}
