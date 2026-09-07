//
//  RecurringReminderScheduler.swift
//  SmartRide
//
//  Refreshes every enabled RecurringReminder's actual notification(s) using the
//  same engine Home uses — called when the app opens (RootView), the same
//  "checked on app open" honesty SmartAlertChecker already relies on, since local
//  notifications can't recompute live traffic themselves at the moment they fire.
//
//  Start At reminds `leadMinutes` before a fixed clock time every selected
//  weekday — one real weekly-repeating notification per weekday, refreshed here
//  only to keep its duration estimate current.
//
//  Reach By's actual leave time moves with traffic, so it can't be a fixed weekly
//  trigger at all: each refresh recomputes today's recommended departure (if today
//  is a selected weekday and that time hasn't already passed) and schedules one
//  fresh one-shot notification just for today.

import Foundation
import SwiftData

enum RecurringReminderScheduler {
    static func refreshAll(modelContext: ModelContext, simulateFailure: Bool = false) async {
        let descriptor = FetchDescriptor<RecurringReminder>(predicate: #Predicate { $0.isEnabled })
        guard let reminders = try? modelContext.fetch(descriptor) else { return }
        for reminder in reminders {
            await refresh(reminder, modelContext: modelContext, simulateFailure: simulateFailure)
        }
        try? modelContext.save()
    }

    static func refresh(_ reminder: RecurringReminder, modelContext: ModelContext, simulateFailure: Bool = false) async {
        switch reminder.plannerMode {
        case .startAt:
            await refreshStartAt(reminder, modelContext: modelContext, simulateFailure: simulateFailure)
        case .reachBy:
            await refreshReachBy(reminder, modelContext: modelContext, simulateFailure: simulateFailure)
        }
    }

    static func cancelAll(_ reminder: RecurringReminder) {
        NotificationManager.cancelReminders(ids: (1...7).map(reminder.notificationIdentifier(forWeekday:)))
        NotificationManager.cancelReminders(ids: reminder.specificDates.map(reminder.notificationIdentifier(forDate:)))
        NotificationManager.cancelReminder(id: reminder.oneShotIdentifier)
    }

    // MARK: - Start At

    private static func refreshStartAt(_ reminder: RecurringReminder, modelContext: ModelContext, simulateFailure: Bool) async {
        let trip = Trip(origin: reminder.origin, destination: reminder.destination, travelMode: reminder.travelMode)
        let outcome = await RecommendationEngine.recommend(
            trip: trip, departureOption: .now, simulateFailure: simulateFailure, modelContext: modelContext
        )
        if case .success(let rec) = outcome {
            reminder.cachedDurationMinutes = rec.leaveNowDurationMinutes
            reminder.cachedDistanceMiles = distanceMiles(from: rec)
        }

        let durationText = reminder.cachedDurationMinutes.map { " Estimated drive: ~\(Recommendation.minutesText($0))." } ?? ""
        let body = reminder.leadMinutes > 0
            ? "Start time is \(reminder.timeText) — leave in \(reminder.leadMinutes) min.\(durationText)"
            : "Start time is \(reminder.timeText).\(durationText)"

        if reminder.usesSpecificDates {
            // Each date gets its own one-shot notification (not a weekly repeat) —
            // past dates are simply skipped, nothing honest to schedule for them.
            let calendar = Calendar.current
            for date in reminder.specificDates {
                guard let occurrence = calendar.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: date) else { continue }
                let notifyDate = occurrence.addingTimeInterval(-Double(reminder.leadMinutes) * 60)
                guard notifyDate > Date() else { continue }
                _ = await NotificationManager.scheduleDepartureReminder(
                    id: reminder.notificationIdentifier(forDate: date), at: notifyDate,
                    origin: reminder.origin, destination: reminder.destination, travelMode: reminder.travelMode,
                    title: "Planner Reminder", body: body
                )
            }
        } else {
            for weekday in reminder.weekdays {
                let adjusted = leadAdjusted(weekday: weekday, hour: reminder.hour, minute: reminder.minute, leadMinutes: reminder.leadMinutes)
                _ = await NotificationManager.scheduleRecurringReminder(
                    id: reminder.notificationIdentifier(forWeekday: weekday),
                    weekday: adjusted.weekday, hour: adjusted.hour, minute: adjusted.minute,
                    origin: reminder.origin, destination: reminder.destination, travelMode: reminder.travelMode,
                    title: "Planner Reminder", body: body
                )
            }
        }
    }

    /// Shifts a weekday+time back by `leadMinutes`, rolling the weekday back a day
    /// (wrapping Sunday→Saturday) if that crosses midnight — e.g. a 12:03 AM start
    /// with a 10-minute lead notifies at 11:53 PM the day before.
    private static func leadAdjusted(weekday: Int, hour: Int, minute: Int, leadMinutes: Int) -> (weekday: Int, hour: Int, minute: Int) {
        var totalMinutes = hour * 60 + minute - leadMinutes
        var adjustedWeekday = weekday
        while totalMinutes < 0 {
            totalMinutes += 24 * 60
            adjustedWeekday = adjustedWeekday == 1 ? 7 : adjustedWeekday - 1
        }
        while totalMinutes >= 24 * 60 {
            totalMinutes -= 24 * 60
            adjustedWeekday = adjustedWeekday == 7 ? 1 : adjustedWeekday + 1
        }
        return (adjustedWeekday, totalMinutes / 60, totalMinutes % 60)
    }

    // MARK: - Reach By

    private static func refreshReachBy(_ reminder: RecurringReminder, modelContext: ModelContext, simulateFailure: Bool) async {
        NotificationManager.cancelReminder(id: reminder.oneShotIdentifier)

        let calendar = Calendar.current
        let now = Date()
        let matchesToday = reminder.usesSpecificDates
            ? reminder.specificDates.contains { calendar.isDate($0, inSameDayAs: now) }
            : reminder.weekdays.contains(calendar.component(.weekday, from: now))
        guard matchesToday else { return }
        guard let targetArrival = calendar.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: now) else { return }

        let trip = Trip(origin: reminder.origin, destination: reminder.destination, travelMode: reminder.travelMode)
        let outcome = await RecommendationEngine.recommendArriveBy(
            trip: trip, targetArrival: targetArrival, simulateFailure: simulateFailure, modelContext: modelContext
        )
        guard case .success(let rec) = outcome else { return }

        reminder.cachedDurationMinutes = rec.expectedDurationMinutes
        reminder.cachedDistanceMiles = distanceMiles(from: rec)
        let notifyDate = rec.recommendedTime.addingTimeInterval(-Double(reminder.leadMinutes) * 60)
        // Already past for today — nothing honest left to schedule; it'll pick back
        // up tomorrow when this weekday comes around again.
        guard notifyDate > Date() else { return }

        let departText = Recommendation.timeFormatter.string(from: rec.recommendedTime)
        let body = reminder.leadMinutes > 0
            ? "Start in \(reminder.leadMinutes) min (\(departText)) to reach \(reminder.destination) by \(reminder.timeText). ~\(Recommendation.minutesText(rec.expectedDurationMinutes)) drive."
            : "Leave now (\(departText)) to reach \(reminder.destination) by \(reminder.timeText). ~\(Recommendation.minutesText(rec.expectedDurationMinutes)) drive."

        _ = await NotificationManager.scheduleDepartureReminder(
            id: reminder.oneShotIdentifier, at: notifyDate, origin: reminder.origin, destination: reminder.destination,
            travelMode: reminder.travelMode, title: "Planner Reminder", body: body
        )
    }

    /// The fastest route's distance — a stable fact about the route, unlike its
    /// duration, so this is what's safe to cache and show on the Planner list.
    private static func distanceMiles(from rec: Recommendation) -> Double? {
        (rec.routes.first { $0.isFastest } ?? rec.routes.first)?.distanceMiles
    }
}
