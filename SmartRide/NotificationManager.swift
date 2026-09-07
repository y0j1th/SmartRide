//
//  NotificationManager.swift
//  SmartRide
//
//  Local notification for the "Remind Me" button (doc §3 Step 5: "Dad ... gets a
//  reminder notification"). Purely local — no push infrastructure needed.
//

import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Without this, iOS suppresses local notification banners while the app is in the
/// foreground by default — a reminder set a few minutes out would silently never
/// appear if the user kept the app open, looking like nothing notified them at all.
/// Presenting explicitly here is what makes SmartRide itself the one visibly
/// notifying, in foreground or background alike. It also handles a tap on the
/// notification itself, jumping straight into turn-by-turn navigation instead of
/// just opening the app to the home screen.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        openNavigation(from: response.notification.request.content.userInfo)
        completionHandler()
    }

    private func openNavigation(from userInfo: [AnyHashable: Any]) {
        guard let destination = userInfo["destination"] as? String, !destination.isEmpty else { return }
        let origin = userInfo["origin"] as? String
        let travelMode = (userInfo["travelMode"] as? String).flatMap(TravelMode.init(rawValue:)) ?? .driving
        let preferredMapsApp = UserDefaults.standard.string(forKey: "preferredMapsApp") ?? "apple"
        guard let url = MapsNavigator.url(originText: origin, destinationText: destination, preferredApp: preferredMapsApp, travelMode: travelMode) else { return }

        #if canImport(UIKit)
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

enum NotificationManager {
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])) ?? false
        default:
            return false
        }
    }

    /// Schedules a one-shot local reminder for `date` under `id`, so it can later be
    /// individually canceled (delete) or replaced (edit) without touching any other
    /// reminder the user has set. `origin`/`destination` ride along in the
    /// notification's userInfo so tapping it can open navigation directly, without
    /// needing the app's in-memory trip state to still match by then. Marked
    /// time-sensitive so it's more likely to break through a Focus mode that would
    /// otherwise silently swallow it — a common reason a reminder never visibly
    /// appears even though it really was scheduled. Returns false if the user has
    /// denied notifications or scheduling otherwise fails, so the UI can say so.
    static func scheduleDepartureReminder(
        id: String, at date: Date, origin: String?, destination: String, travelMode: TravelMode = .driving,
        title: String = "Time to leave", body: String? = nil
    ) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body ?? "Leave now for \(destination) to hit your optimal departure window. Tap to start navigating."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        var userInfo: [String: String] = ["destination": destination, "travelMode": travelMode.rawValue]
        if let origin, !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInfo["origin"] = origin
        }
        content.userInfo = userInfo

        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    static func cancelReminder(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    static func cancelReminders(ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Schedules a weekly-repeating reminder for one weekday. `UNCalendarNotification
    /// Trigger` with `repeats: true` and only hour/minute/weekday set fires every
    /// week on its own — there's no need to re-schedule this each week ourselves.
    static func scheduleRecurringReminder(
        id: String, weekday: Int, hour: Int, minute: Int, origin: String?, destination: String, travelMode: TravelMode,
        title: String = "Time to leave", body: String? = nil
    ) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body ?? "Leave now for \(destination) to hit your usual departure time."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        var userInfo: [String: String] = ["destination": destination, "travelMode": travelMode.rawValue]
        if let origin, !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInfo["origin"] = origin
        }
        content.userInfo = userInfo

        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
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
