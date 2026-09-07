//
//  SmartRideApp.swift
//  SmartRide
//
//  Created by Aruna Miryala on 8/24/26.
//

import SwiftUI
import SwiftData

@main
struct SmartRideApp: App {
    @StateObject private var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appSettings)
        }
        .modelContainer(for: [HistoricalSample.self, LoggedTrip.self, SavedCommute.self, FavoriteLocation.self])
    }
}
