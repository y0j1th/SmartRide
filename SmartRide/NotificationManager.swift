//
//  NotificationManager.swift
//  SmartRide
//
//  Local notification for the "Remind Me" button (doc §3 Step 5: "Dad ... gets a
//  reminder notification"). Purely local — no push infrastructure needed.
//

import Foundation
import UserNotifications

enum NotificationManager {
    private static let reminderIdentifier = "smartride.departure.reminder"

    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    /// Schedules a one-shot local reminder for `date`. Returns false if the user has
    /// denied notifications or scheduling otherwise fails, so the UI can say so.
    static func scheduleDepartureReminder(at date: Date, destination: String) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Time to leave"
        content.body = "Leave now for \(destination) to hit your optimal departure window."
        content.sound = .default

        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: reminderIdentifier, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    static func cancelDepartureReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
    }

    /// "Traffic is building faster than usual" alert for a watched saved commute
    /// (Smart Commute Alert). Fired immediately (not scheduled ahead), since it's
    /// only ever triggered by a fresh recompute.
    static func scheduleTrafficAlert(commuteName: String, recommendedDeparture: Date, extraMinutes: Int) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Traffic building on \(commuteName)"
        content.body = "Leave by \(Recommendation.timeFormatter.string(from: recommendedDeparture)) to avoid ~\(extraMinutes) minutes of extra travel."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "smartride.trafficalert.\(commuteName)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }
}
