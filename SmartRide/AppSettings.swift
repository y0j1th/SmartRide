//
//  AppSettings.swift
//  SmartRide
//

import Foundation
import Combine
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Nil means "follow the system setting" — SwiftUI's `.preferredColorScheme`
    /// already treats nil that way, so no extra branching is needed at the call site.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AccentColorChoice: String, CaseIterable, Identifiable {
    case blue
    case purple
    case green
    case orange
    case red
    case teal

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .teal: return .teal
        }
    }
}

/// Shared app state: notification preference (persisted to UserDefaults), a
/// demo-only toggle to simulate a live-traffic API failure (doc §4.3 edge cases),
/// appearance/personalization settings, and cross-tab navigation state.
/// Home/Office/frequent addresses live in FavoriteLocation (SwiftData) instead —
/// see FavoriteLocation.swift.
final class AppSettings: ObservableObject {
    /// Home's position in the tab bar — kept as a named constant since other tabs
    /// (Favorites, Alerts) jump here by setting `selectedTab` directly, and "Home is
    /// the middle tab" is a layout choice that could change again later.
    static let homeTabIndex = 2

    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notifications) }
    }
    @Published var simulateAPIFailure: Bool = false

    @Published var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearance) }
    }
    @Published var accentColorChoice: AccentColorChoice {
        didSet { UserDefaults.standard.set(accentColorChoice.rawValue, forKey: Keys.accentColor) }
    }
    /// Off hides the text under every tab icon for a cleaner look. Defaults on so
    /// the app reads normally until someone opts into the minimal look themselves.
    @Published var showTabLabels: Bool {
        didSet { UserDefaults.standard.set(showTabLabels, forKey: Keys.showTabLabels) }
    }

    /// Set by Routes/History when the user taps "Navigate" on a saved route or
    /// past trip; ContentView picks this up, pre-fills the trip, and clears it.
    /// Used together with `selectedTab` to jump the user to Home with that route
    /// loaded.
    @Published var pendingOrigin: String?
    @Published var pendingDestination: String?
    /// Set alongside the pair above only by History's "Travel Again" — carries the
    /// exact intermediate stops from that logged trip so re-running it reproduces
    /// the same route, not just the same endpoints.
    @Published var pendingStops: [String]?
    @Published var selectedTab = AppSettings.homeTabIndex

    private enum Keys {
        static let notifications = "smartride.notificationsEnabled"
        static let appearance = "smartride.appearanceMode"
        static let accentColor = "smartride.accentColorChoice"
        static let showTabLabels = "smartride.showTabLabels"
    }

    init() {
        notificationsEnabled = UserDefaults.standard.object(forKey: Keys.notifications) as? Bool ?? true
        appearanceMode = (UserDefaults.standard.string(forKey: Keys.appearance)).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        accentColorChoice = (UserDefaults.standard.string(forKey: Keys.accentColor)).flatMap(AccentColorChoice.init(rawValue:)) ?? .blue
        showTabLabels = UserDefaults.standard.object(forKey: Keys.showTabLabels) as? Bool ?? true
    }
}
