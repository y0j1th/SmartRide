//
//  HistoricalSample.swift
//  SmartRide
//
//  A single observed travel time for a route at a given day-of-week/time-of-day
//  bucket. This is the "Historical Pattern Store" from doc §5.1 — the engine writes
//  one of these every time it gets a real live ETA, so the store genuinely builds up
//  over real usage (doc §5.2: "built by periodically sampling and logging the same
//  route over weeks").
//

import Foundation
import SwiftData

@Model
final class HistoricalSample {
    var routeKey: String
    var dayOfWeek: Int
    var minuteOfDayBucket: Int
    var travelMinutes: Double
    var recordedAt: Date

    init(routeKey: String, dayOfWeek: Int, minuteOfDayBucket: Int, travelMinutes: Double, recordedAt: Date = Date()) {
        self.routeKey = routeKey
        self.dayOfWeek = dayOfWeek
        self.minuteOfDayBucket = minuteOfDayBucket
        self.travelMinutes = travelMinutes
        self.recordedAt = recordedAt
    }
}
