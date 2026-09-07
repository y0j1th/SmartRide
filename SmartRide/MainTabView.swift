//
//  MainTabView.swift
//  SmartRide
//
//  Bottom navigation: Home, Routes, Favorites, History, Profile (doc §4.1).
//

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        TabView(selection: $appSettings.selectedTab) {
            ContentView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            RoutesView()
                .tabItem { Label("Routes", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                .tag(1)

            FavoritesView()
                .tabItem { Label("Favorites", systemImage: "star.fill") }
                .tag(2)

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(3)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(4)
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppSettings())
}
