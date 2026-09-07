//
//  ProfileView.swift
//  SmartRide
//
//  Notification preferences (doc §4.1 bottom nav), plus a demo-only toggle to
//  simulate a live-traffic API failure so the "unhappy path" fallback state
//  (doc §4.3) can be shown live. Favorite locations live on their own tab —
//  see FavoritesView.swift.
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Toggle("Departure reminders", isOn: $appSettings.notificationsEnabled)
                }

                Section {
                    Toggle("Simulate API failure", isOn: $appSettings.simulateAPIFailure)
                } header: {
                    Text("Demo Controls")
                } footer: {
                    Text("Forces the Home screen to fall back to historical-only estimates with lower confidence, to demonstrate the offline/API-failure path.")
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0 (Prototype)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AppSettings())
}
