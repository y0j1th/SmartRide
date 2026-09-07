//
//  RootView.swift
//  SmartRide
//
//  Shows LaunchScreenView while real startup work runs (seeding demo history
//  data), then fades into the app. A short minimum display time keeps the launch
//  feeling intentional rather than a flash, since seeding itself is near-instant
//  after the very first run.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @State private var isLaunching = true

    var body: some View {
        ZStack {
            if isLaunching {
                LaunchScreenView()
                    .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .tint(appSettings.accentColorChoice.color)
        .preferredColorScheme(appSettings.appearanceMode.colorScheme)
        .animation(.easeInOut(duration: 0.35), value: isLaunching)
        .task {
            DemoSeedData.seedIfNeeded(modelContext: modelContext)
            try? await Task.sleep(nanoseconds: 900_000_000)
            isLaunching = false
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppSettings())
        .modelContainer(for: [HistoricalSample.self, LoggedTrip.self, SavedCommute.self, FavoriteLocation.self, ReminderItem.self, RecurringReminder.self], inMemory: true)
}
