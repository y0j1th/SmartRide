//
//  RecurringReminder.swift
//  SmartRide
//
//  A weekly recurring departure reminder — the Planner idea folded into Alerts
//  rather than its own tab. Two modes, mirroring Home's Depart-At/Arrive-By:
//
//  - Start At: "every weekday, leave by 8:00 AM" — a fixed clock time, backed by
//    one repeating local notification per selected weekday (UNCalendarNotification
//    Trigger handles the weekly recurrence natively).
//  - Reach By: "every weekday, arrive by 9:00 AM" — the actual leave time varies
//    day to day with traffic, so this can't be a single fixed weekly trigger. It's
//    recomputed each time the app is opened (RecurringReminderScheduler), same
//    honest "checked on app open" approach SmartAlertChecker already uses, and
//    scheduled as a fresh one-shot notification for just that day.
//
//  Either way, the notification fires `leadMinutes` before the relevant time, not
//  at it — "start in 5 minutes" is only useful before you needed to already be gone.

import Foundation
import SwiftData

enum PlannerMode: String, CaseIterable, Identifiable {
    case startAt
    case reachBy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .startAt: return "Start At"
        case .reachBy: return "Reach By"
        }
    }
}

@Model
final class RecurringReminder {
    var id: UUID
    /// User-given label (e.g. "Morning Commute") — what the Planner list sorts and
    /// groups by, since "origin → destination" alone doesn't distinguish two
    /// reminders for the same route in different modes. Defaults empty for rows
    /// written before this field existed (lightweight SwiftData migration).
    var name: String = ""
    var origin: String
    var destination: String
    var plannerModeRaw: String
    /// Start At: the leave time. Reach By: the target arrival time.
    var hour: Int
    var minute: Int
    /// How long before the relevant time (leave time, or the computed departure
    /// for a Reach By target) to actually notify — "start in 5 min", not "it's 8:00".
    var leadMinutes: Int
    /// Calendar weekday numbers: 1 = Sunday ... 7 = Saturday. Ignored (and hidden
    /// in the editor) once `specificDates` is non-empty — a reminder is either a
    /// weekly pattern or a fixed set of one-off dates, not both at once.
    var weekdays: [Int]
    /// Specific calendar dates (day-level; time comes from `hour`/`minute` as
    /// usual), picked via the calendar icon instead of the weekday circles. Once
    /// this is set, the reminder fires only on these dates rather than repeating
    /// weekly. Defaults empty for rows written before this field existed
    /// (lightweight SwiftData migration).
    var specificDates: [Date] = []
    var isEnabled: Bool
    var travelModeRaw: String
    var createdAt: Date
    /// Last known drive duration — used for the notification body (a same-day,
    /// freshly recomputed estimate at the moment it fires, so showing minutes
    /// there is reasonable) but deliberately NOT shown in the Planner list itself:
    /// a duration cached from whenever this last refreshed goes stale immediately
    /// since traffic-based drive time genuinely varies day to day, and displaying
    /// it as a fixed fact on the row would be misleading.
    var cachedDurationMinutes: Int?
    /// Route distance in miles — unlike duration this doesn't change day to day,
    /// so it's what the Planner list shows instead as a stable fact about the route.
    var cachedDistanceMiles: Double?

    var plannerMode: PlannerMode {
        get { PlannerMode(rawValue: plannerModeRaw) ?? .startAt }
        set { plannerModeRaw = newValue.rawValue }
    }

    var travelMode: TravelMode {
        get { TravelMode(rawValue: travelModeRaw) ?? .driving }
        set { travelModeRaw = newValue.rawValue }
    }

    var usesSpecificDates: Bool { !specificDates.isEmpty }

    /// One notification identifier per weekday (Start At mode) — a single weekday
    /// can be individually canceled/rescheduled without touching the others.
    func notificationIdentifier(forWeekday weekday: Int) -> String {
        "smartride.recurring.\(id.uuidString).wd\(weekday)"
    }

    /// One notification identifier per specific date (Start At + specific-dates
    /// mode) — each date's own one-shot notification, individually cancelable.
    func notificationIdentifier(forDate date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "smartride.recurring.\(id.uuidString).date\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    /// Reach By mode's single reusable identifier — replaced with a fresh one-shot
    /// every time the day's recommended departure is recomputed.
    var oneShotIdentifier: String {
        "smartride.recurring.\(id.uuidString).oneshot"
    }

    var timeText: String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? Date()
        return Recommendation.timeFormatter.string(from: date)
    }

    var leadText: String {
        leadMinutes == 0 ? "At the time" : "\(leadMinutes) min before"
    }

    var weekdaysText: String {
        if usesSpecificDates {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return specificDates.sorted().map { formatter.string(from: $0) }.joined(separator: ", ")
        }
        let symbols = Calendar.current.shortWeekdaySymbols
        let weekdaySet = Set(weekdays)
        if weekdaySet == Set(1...7) { return "Every day" }
        if weekdaySet == Set([2, 3, 4, 5, 6]) { return "Weekdays" }
        if weekdaySet == Set([1, 7]) { return "Weekends" }
        return weekdays.sorted().compactMap { symbols[safe: $0 - 1] }.joined(separator: ", ")
    }

    init(
        name: String,
        origin: String,
        destination: String,
        plannerMode: PlannerMode,
        hour: Int,
        minute: Int,
        leadMinutes: Int,
        weekdays: [Int],
        specificDates: [Date] = [],
        travelMode: TravelMode = .driving,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.name = name
        self.origin = origin
        self.specificDates = specificDates
        self.destination = destination
        self.plannerModeRaw = plannerMode.rawValue
        self.hour = hour
        self.minute = minute
        self.leadMinutes = leadMinutes
        self.weekdays = weekdays
        self.travelModeRaw = travelMode.rawValue
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
