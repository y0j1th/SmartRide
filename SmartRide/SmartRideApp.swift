//
//  SmartRideApp.swift
//  SmartRide
//
//  Created by Aruna Miryala on 8/24/26.
//

import SwiftUI
import SwiftData
import UserNotifications

@main
struct SmartRideApp: App {
    @StateObject private var appSettings = AppSettings()

    init() {
        // Set as early as possible so even a reminder that fires moments after
        // launch is presented by our delegate, not silently dropped.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appSettings)
        }
        .modelContainer(for: [HistoricalSample.self, LoggedTrip.self, SavedCommute.self, FavoriteLocation.self, ReminderItem.self, RecurringReminder.self])
    }
}
