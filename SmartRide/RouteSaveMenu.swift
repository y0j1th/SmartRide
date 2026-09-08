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
    /// May literally be "Current Location" — Favorite Route and Route are meant
    /// to stay live, re-resolving wherever the phone actually is whenever they're
    /// next navigated, rather than freezing on wherever they were saved from.
    let origin: String
    let destination: String
    var travelMode: TravelMode = .driving
    var isEnabled: Bool = true
    /// Origin to use for Add Recurring Reminder specifically — its schedule
    /// refreshes in the background (RootView, independent of Home's live-location
    /// UI), so it can't safely re-resolve the literal "Current Location" label the
    /// way Navigate can. Defaults to `origin` for callers where the two are
    /// already the same resolved text (e.g. History, where a logged trip's origin
    /// is never that literal label).
    var reminderOrigin: String? = nil

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
                AddRecurringReminderView(prefilledOrigin: reminderOrigin ?? origin, prefilledDestination: destination, prefilledTravelMode: travelMode)
            }
        }
    }
}
