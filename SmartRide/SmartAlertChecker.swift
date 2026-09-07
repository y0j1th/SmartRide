//
//  SmartAlertChecker.swift
//  SmartRide
//
//  "Smart commute alert" — for each saved commute with alerts enabled and a target
//  arrival time, recompute today's recommendation and fire a local notification if
//  the predicted drive time has gotten meaningfully worse since the last check.
//
//  This runs opportunistically when Home appears (foreground), not on a true
//  background schedule — real always-on monitoring needs BGTaskScheduler + the
//  Background App Refresh capability, which requires a real device to configure and
//  verify and is a reasonable next step beyond this MVP prototype.

import Foundation
import SwiftData

enum SmartAlertChecker {
    /// Minimum worsening (minutes) since the last check before we bother the user.
    private static let alertThresholdMinutes = 12

    static func checkAll(appSettings: AppSettings, modelContext: ModelContext) async {
        guard appSettings.notificationsEnabled else { return }

        let descriptor = FetchDescriptor<SavedCommute>(predicate: #Predicate { $0.alertsEnabled == true })
        guard let commutes = try? modelContext.fetch(descriptor), !commutes.isEmpty else { return }

        let now = Date()
        for commute in commutes {
            guard let targetMinute = commute.targetArrivalMinuteOfDay else { continue }

            var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
            comps.hour = targetMinute / 60
            comps.minute = targetMinute % 60
            guard let targetDate = Calendar.current.date(from: comps), targetDate > now else { continue }

            let trip = Trip(origin: commute.origin, destination: commute.destination)
            let outcome = await RecommendationEngine.recommendArriveBy(
                trip: trip, targetArrival: targetDate, simulateFailure: false, referenceDate: now, modelContext: modelContext
            )
            guard case .success(let rec) = outcome else { continue }

            if let baseline = commute.lastAlertedDurationMinutes {
                let worsenedBy = rec.expectedDurationMinutes - baseline
                if worsenedBy >= alertThresholdMinutes {
                    let ok = await NotificationManager.scheduleTrafficAlert(
                        commuteName: commute.name,
                        recommendedDeparture: rec.recommendedTime,
                        extraMinutes: worsenedBy
                    )
                    if ok {
                        commute.lastAlertedDurationMinutes = rec.expectedDurationMinutes
                    }
                }
            } else {
                commute.lastAlertedDurationMinutes = rec.expectedDurationMinutes
            }
        }
        try? modelContext.save()
    }
}
