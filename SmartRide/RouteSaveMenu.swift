//
//  RouteSaveMenu.swift
//  SmartRide
//
//  The "list.bullet" save menu — save this origin/destination as a Favorite
//  Route, a plain Route, or a Recurring Reminder. Originally built inline on
//  Home; pulled out so History's expanded trip detail can offer the exact same
//  options for a past trip. There is deliberately no "save as frequent
//  location" option — Routes' "Frequently Visited" section already surfaces
//  places driven often, from real trip history.
//

import SwiftUI

struct RouteSaveMenu: View {
    let origin: String
    let destination: String
    var travelMode: TravelMode = .driving
    var isEnabled: Bool = true

    @State private var activeAction: SaveAction?

    private enum SaveAction: Identifiable {
        case favoriteRoute
        case route
        case recurringReminder

        var id: Int {
            switch self {
            case .favoriteRoute: return 0
            case .route: return 1
            case .recurringReminder: return 2
            }
        }
    }

    var body: some View {
        Menu {
            Button {
                activeAction = .favoriteRoute
            } label: {
                Label("Save as Favorite Route", systemImage: "star.fill")
            }
            Button {
                activeAction = .route
            } label: {
                Label("Save as Route", systemImage: "signpost.right.and.left")
            }
            Button {
                activeAction = .recurringReminder
            } label: {
                Label("Add Recurring Reminder", systemImage: "calendar.badge.clock")
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!isEnabled)
        .sheet(item: $activeAction) { action in
            switch action {
            case .favoriteRoute:
                SaveRouteAsView(origin: origin, destination: destination, isFavorite: true)
            case .route:
                SaveRouteAsView(origin: origin, destination: destination, isFavorite: false)
            case .recurringReminder:
                AddRecurringReminderView(prefilledOrigin: origin, prefilledDestination: destination, prefilledTravelMode: travelMode)
            }
        }
    }
}
