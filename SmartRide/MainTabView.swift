//
//  MainTabView.swift
//  SmartRide
//
//  Bottom navigation: Routes, Planner, Home, History, Profile — Home sits in the
//  middle since it's the screen used every time, with saved places to its left and
//  what's coming up (reminders/watched routes) and what's already happened
//  (history) fanning out to either side.
//

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        TabView(selection: $appSettings.selectedTab) {
            RoutesView()
                .tabItem { tabLabel("Routes", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                .tag(0)

            PlannerView()
                .tabItem { tabLabel("Planner", systemImage: "calendar") }
                .tag(1)

            ContentView()
                .tabItem { tabLabel("Home", systemImage: "house.fill") }
                .tag(AppSettings.homeTabIndex)

            HistoryView()
                .tabItem { tabLabel("History", systemImage: "clock.arrow.circlepath") }
                .tag(3)

            ProfileView()
                .tabItem { tabLabel("Profile", systemImage: "person.crop.circle") }
                .tag(4)
        }
        // Giving just the label content a fresh identity (rather than the whole
        // TabView) turned out not to be enough to make UIKit's underlying tab bar
        // actually re-read the item — it only ever picked up the change on next
        // launch. Forcing the TabView itself to rebuild is what reliably works;
        // the trade-off is each tab's own @State resets when this fires, but
        // toggling a display preference in Profile is rare enough that this is
        // an acceptable cost for a setting that's supposed to take effect now.
        .id(appSettings.showTabLabels)
    }

    @ViewBuilder
    private func tabLabel(_ text: String, systemImage: String) -> some View {
        if appSettings.showTabLabels {
            Label(text, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppSettings())
}
