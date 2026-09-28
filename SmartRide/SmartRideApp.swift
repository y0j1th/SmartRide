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
    private let modelContainer: ModelContainer

    init() {
        // Set as early as possible so even a reminder that fires moments after
        // launch is presented by our delegate, not silently dropped.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        // Built explicitly (rather than via the `.modelContainer(for:)` scene
        // modifier) so the background refresh task below — which runs outside
        // the view hierarchy entirely — has a container to build its own
        // ModelContext from. Must be registered before the app finishes
        // launching, which `init()` satisfies.
        let container = Self.makeModelContainer()
        modelContainer = container
        BackgroundReminderRefresher.register(modelContainer: container)
        BackgroundReminderRefresher.scheduleNext(modelContext: ModelContext(container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appSettings)
        }
        .modelContainer(modelContainer)
    }

    private static func makeModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: HistoricalSample.self, LoggedTrip.self, SavedCommute.self, FavoriteLocation.self, ReminderItem.self, RecurringReminder.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
