//
//  AppSettings.swift
//  SmartRide
//

import Foundation
import Combine

/// Shared app state: notification preference (persisted to UserDefaults), a
/// demo-only toggle to simulate a live-traffic API failure (doc §4.3 edge cases),
/// and cross-tab navigation state. Home/Office/frequent addresses live in
/// FavoriteLocation (SwiftData) instead — see FavoriteLocation.swift.
final class AppSettings: ObservableObject {
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notifications) }
    }
    @Published var simulateAPIFailure: Bool = false

    /// Set by RoutesView when the user taps a saved commute; ContentView picks this
    /// up, pre-fills the trip, and clears it. Used together with `selectedTab` to
    /// jump the user to Home with that commute loaded.
    @Published var pendingOrigin: String?
    @Published var pendingDestination: String?
    @Published var selectedTab = 0

    private enum Keys {
        static let notifications = "smartride.notificationsEnabled"
    }

    init() {
        notificationsEnabled = UserDefaults.standard.object(forKey: Keys.notifications) as? Bool ?? true
    }
}
