//
//  BackgroundReminderRefresher.swift
//  SmartRide
//
//  Best-effort background refresh for Reach By reminders. Start At is a real
//  weekly system alarm (UNCalendarNotificationTrigger) that fires with zero
//  dependence on the app ever being opened — that part is already solved. Reach
//  By is different: its fire time depends on that day's traffic, so it can only
//  be (re)computed by actually running RecurringReminderScheduler, which normally
//  only happens when the app is opened (Home, Planner, launch).
//
//  BGTaskScheduler asks iOS to occasionally run that same refresh in the
//  background too — entirely on-device, nothing external, no separate app or
//  setup step, invisible to the user. But iOS alone decides whether and when it
//  actually runs (based on usage patterns, battery, etc.) — there is no iOS API
//  that guarantees a specific wake time. This narrows the "reminder never even
//  gets scheduled on a day the app isn't opened" gap; it does not close it with
//  a guarantee. A guarantee would require a server that computes on its own
//  schedule and sends a push at the exact right moment — a different, much
//  bigger piece of infrastructure than this.
//

import Foundation
import BackgroundTasks
import SwiftData

enum BackgroundReminderRefresher {
    static let taskIdentifier = "nm.smartRide.refreshReminders"

    /// Floor and ceiling for how soon the *next* attempt is allowed to run —
    /// never sooner than 15 minutes from now (iOS won't grant tighter than this
    /// in practice anyway), never further out than 3 hours even when nothing is
    /// due soon, so the chain doesn't go quiet for too long.
    private static let minimumInterval: TimeInterval = 15 * 60
    private static let maximumInterval: TimeInterval = 3 * 60 * 60
    /// Don't bother aiming a check for less than this long before an alert is
    /// actually due — nothing useful comes from a refresh that lands after the
    /// moment it was meant to inform.
    private static let usefulnessBuffer: TimeInterval = 5 * 60

    /// Call once, at app launch, before the app finishes starting up — iOS
    /// requires the handler to be registered before launch completes.
    static func register(modelContainer: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask, modelContainer: modelContainer)
        }
    }

    private static func handle(_ task: BGAppRefreshTask, modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        // Re-arm the next attempt immediately — if this run gets cut short by
        // the expiration handler below, the chain shouldn't die with it.
        scheduleNext(modelContext: context)

        let refreshTask = Task {
            await RecurringReminderScheduler.refreshAll(modelContext: context)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            refreshTask.cancel()
        }
    }

    /// Submits the next background refresh request, aimed at landing shortly
    /// before whichever enabled reminder is due soonest today — narrowing in as
    /// that deadline approaches (a reminder due at 10 PM gets a coarse check in
    /// the morning, then progressively tighter ones through the day) rather than
    /// one flat interval with no relation to what's actually at stake. This is
    /// still only ever a *request* for the earliest iOS may run it — not a
    /// scheduled time, and not a promise it runs at all. A `BGAppRefreshTaskRequest`
    /// is one-shot, so this needs calling again every time one is used — both
    /// here (after the background task itself runs) and from the app's own
    /// normal foreground refresh points, so the chain keeps re-arming itself
    /// whenever the app is used, not just once at first launch. Silently does
    /// nothing if submission fails (e.g. the Simulator, which doesn't run real
    /// background tasks at all) — this is inherently best-effort.
    static func scheduleNext(modelContext: ModelContext?) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: nextInterval(modelContext: modelContext))
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func nextInterval(modelContext: ModelContext?) -> TimeInterval {
        guard let modelContext, let nearest = RecurringReminderScheduler.nearestUpcomingAlertTime(modelContext: modelContext) else {
            return minimumInterval
        }
        let latestUseful = nearest.timeIntervalSinceNow - usefulnessBuffer
        guard latestUseful > 0 else { return minimumInterval }
        // Aim for halfway to the deadline each time — naturally tightens from
        // hours apart in the morning down toward the 15-minute floor as evening
        // approaches, without ever overshooting past the point of being useful.
        let halfway = latestUseful / 2
        return min(maximumInterval, max(minimumInterval, min(latestUseful, halfway)))
    }
}
