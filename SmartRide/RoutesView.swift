//
//  RoutesView.swift
//  SmartRide
//
//  Everything reusable about where you go: Home/Office (single fixed slots),
//  routes marked as favorites, patterns noticed from real driving history
//  (frequently visited, and recommended-to-save ones not yet saved), and plain
//  saved routes. Every saved/editable row shows just its name; tapping expands
//  it in place to show the details (read-only — editing stays swipe-only) with a
//  Navigate button. Swipe left-to-right for Edit, right-to-left for Delete.
//  There is deliberately no separate "frequent locations" list — Frequently
//  Visited already surfaces places driven often, derived from real trip history
//  rather than a manually-managed one.
//

import SwiftUI
import SwiftData

struct RoutesView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedCommute.createdAt) private var savedCommutes: [SavedCommute]
    @Query(sort: \LoggedTrip.createdAt, order: .reverse) private var loggedTrips: [LoggedTrip]
    @Query private var allFavorites: [FavoriteLocation]

    @State private var commuteSheet: CommuteSheet?
    @State private var editingFavorite: EditingFavorite?
    @State private var expandedCommuteID: PersistentIdentifier?
    /// Origin|destination keys the user has dismissed from Recommended — kept in
    /// UserDefaults (a lightweight preference, not real trip data) so a dismissed
    /// suggestion stays gone across launches instead of reappearing the next time
    /// it's driven.
    @State private var dismissedRecommendationKeys: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "smartride.dismissedRecommendations") ?? []
    )

    private enum CommuteSheet: Identifiable {
        case addFavorite
        case addPlain
        case edit(SavedCommute)

        var id: String {
            switch self {
            case .addFavorite: return "add-favorite"
            case .addPlain: return "add-plain"
            case .edit(let commute): return "edit-\(commute.persistentModelID.hashValue)"
            }
        }
    }

    private enum EditingFavorite: Identifiable {
        case new(FavoriteKind)
        case existing(FavoriteLocation)

        var id: String {
            switch self {
            case .new(let kind): return "new-\(kind.rawValue)"
            case .existing(let favorite): return favorite.persistentModelID.hashValue.description
            }
        }
    }

    private struct FrequentTrip: Identifiable {
        let id = UUID()
        let origin: String
        let destination: String
        let count: Int
    }

    private static let maxFavoriteRoutes = 5
    private static let maxSavedRoutes = 10

    /// Named, user-managed lists sort alphabetically rather than by creation
    /// order — Frequently Visited/Recommended below stay frequency-ranked since
    /// they're not named entries, and ranking by how often you actually drive
    /// them is the entire point of those two.
    private var favoriteCommutes: [SavedCommute] {
        savedCommutes.filter { $0.isFavorite }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var plainSavedCommutes: [SavedCommute] {
        savedCommutes.filter { !$0.isFavorite }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var favoritesAtCap: Bool { favoriteCommutes.count >= Self.maxFavoriteRoutes }
    private var savedAtCap: Bool { plainSavedCommutes.count >= Self.maxSavedRoutes }

    private func key(_ origin: String, _ destination: String) -> String {
        "\(origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    /// Origin/destination pairs driven 3 or more times, not already saved as a
    /// Favorite Route or a plain Route — once something's saved it has a proper
    /// home in one of those sections already, so it drops out of here rather than
    /// showing twice. Top 3 by drive count, most-driven first. Backed directly by
    /// `@Query loggedTrips`/`savedCommutes`, so this — and the "Driven N times"
    /// count on each row — updates immediately the moment a trip is logged (Start
    /// Navigation) or a route gets saved/moved, no manual refresh needed.
    private var frequentTrips: [FrequentTrip] {
        let saved = Set(savedCommutes.map { key($0.origin, $0.destination) })
        var counts: [String: FrequentTrip] = [:]
        for trip in loggedTrips {
            let tripKey = key(trip.origin, trip.destination)
            guard !saved.contains(tripKey) else { continue }
            if let existing = counts[tripKey] {
                counts[tripKey] = FrequentTrip(origin: existing.origin, destination: existing.destination, count: existing.count + 1)
            } else {
                counts[tripKey] = FrequentTrip(origin: trip.origin, destination: trip.destination, count: 1)
            }
        }
        return counts.values.filter { $0.count >= 3 }.sorted { $0.count > $1.count }.prefix(3).map { $0 }
    }

    /// The top of Frequently Visited, minus anything dismissed — a nudge toward
    /// saving what's clearly already a habit. Capped at 3 so this stays a short,
    /// high-signal nudge rather than a growing list.
    private var recommendedTrips: [FrequentTrip] {
        frequentTrips
            .filter { !dismissedRecommendationKeys.contains(key($0.origin, $0.destination)) }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Home & Office") {
                    homeOfficeRow(kind: .home, icon: "house.fill", label: "Home")
                    homeOfficeRow(kind: .office, icon: "briefcase.fill", label: "Office")
                }

                Section {
                    if favoriteCommutes.isEmpty {
                        Text("No favorite routes yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(favoriteCommutes) { commute in
                        commuteButtonRow(commute, icon: "star.fill")
                    }

                    Button {
                        commuteSheet = .addFavorite
                    } label: {
                        Label("Add Favorite Route", systemImage: "plus.circle")
                    }
                    .disabled(favoritesAtCap)
                } header: {
                    Text("Favorites")
                } footer: {
                    if favoritesAtCap {
                        Text("Limit of \(Self.maxFavoriteRoutes) favorite routes reached — remove one to add another.")
                    }
                }

                Section {
                    if plainSavedCommutes.isEmpty {
                        Text("No saved routes yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(plainSavedCommutes) { commute in
                        commuteButtonRow(commute, icon: "signpost.right.and.left")
                    }

                    Button {
                        commuteSheet = .addPlain
                    } label: {
                        Label("Add Route", systemImage: "plus.circle")
                    }
                    .disabled(savedAtCap)
                } header: {
                    Text("Saved Routes")
                } footer: {
                    if savedAtCap {
                        Text("Limit of \(Self.maxSavedRoutes) saved routes reached — remove one to add another.")
                    }
                }

                if !frequentTrips.isEmpty {
                    Section {
                        ForEach(frequentTrips) { trip in
                            frequentTripBrowseRow(trip)
                        }
                    } header: {
                        Text("Frequently Visited")
                    } footer: {
                        Text("Routes you've driven often, based on your trip history.")
                    }
                }

                if !recommendedTrips.isEmpty {
                    Section {
                        ForEach(recommendedTrips) { trip in
                            frequentTripRow(trip)
                        }
                    } header: {
                        Text("Recommended")
                    } footer: {
                        Text("Not saved yet — save one to quick-load it from here anytime.")
                    }
                }
            }
            .navigationTitle("Routes")
            .sheet(item: $commuteSheet) { sheet in
                switch sheet {
                case .addFavorite:
                    AddCommuteView(isFavorite: true)
                case .addPlain:
                    AddCommuteView(isFavorite: false)
                case .edit(let commute):
                    AddCommuteView(existing: commute)
                }
            }
            .sheet(item: $editingFavorite) { editing in
                switch editing {
                case .new(let kind):
                    AddFavoriteView(kind: kind)
                case .existing(let favorite):
                    AddFavoriteView(kind: favorite.kind, existing: favorite)
                }
            }
        }
    }

    /// Home and Office are fixed, single slots (not a named list) — shows "Not
    /// Set" with an Add affordance until one exists, then the address with an Edit
    /// affordance. These are also what fill the first 2 quick-chip slots on Home.
    private func homeOfficeRow(kind: FavoriteKind, icon: String, label: String) -> some View {
        let favorite = allFavorites.first { $0.kind == kind }
        let hasAddress = !(favorite?.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return Button {
            if let favorite {
                editingFavorite = .existing(favorite)
            } else {
                editingFavorite = .new(kind)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(hasAddress ? favorite!.address : "Not Set")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(hasAddress ? "Edit" : "Add")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Collapsed shows just the name; tapping anywhere in that leading section
    /// (not just the name text itself) expands it in place to show the route
    /// details (read-only). A dedicated Navigate icon sits beside it so it works
    /// with a single tap whether or not the row is expanded. Long-press for Edit,
    /// Move to Favorites/Saved Routes, and Delete — a context menu instead of
    /// swipe actions, since there are now three options rather than two.
    private func commuteButtonRow(_ commute: SavedCommute, icon: String) -> some View {
        let isExpanded = expandedCommuteID == commute.persistentModelID
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedCommuteID = isExpanded ? nil : commute.persistentModelID
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                        Text(commute.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if commute.alertsEnabled {
                            Image(systemName: "bell.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    select(origin: commute.origin, destination: commute.destination)
                } label: {
                    Image(systemName: "location.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow(label: "From", value: commute.origin)
                    detailRow(label: "To", value: commute.destination)
                    if commute.alertsEnabled {
                        Text("Traffic alerts on")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 32)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                commuteSheet = .edit(commute)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                toggleFavorite(commute)
            } label: {
                if commute.isFavorite {
                    Label("Move to Saved Routes", systemImage: "signpost.right.and.left")
                } else {
                    Label("Move to Favorites", systemImage: "star.fill")
                }
            }
            .disabled(commute.isFavorite ? savedAtCap : favoritesAtCap)
            Button(role: .destructive) {
                deleteCommute(commute)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }

    /// Same "•••" menu as Recommended, minus Dismiss — a Frequently Visited entry
    /// is a real pattern pulled from actual trip history, not a suggestion, so
    /// there's nothing to dismiss; it can only be promoted to a Route or Favorite.
    private func frequentTripBrowseRow(_ trip: FrequentTrip) -> some View {
        HStack(spacing: 12) {
            Button {
                select(origin: trip.origin, destination: trip.destination)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(trip.origin) → \(trip.destination)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Driven \(trip.count) times")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    saveFrequentAsRoute(trip, isFavorite: false)
                } label: {
                    Label("Add as Route", systemImage: "signpost.right.and.left")
                }
                .disabled(savedAtCap)
                Button {
                    saveFrequentAsRoute(trip, isFavorite: true)
                } label: {
                    Label("Add as Favorite", systemImage: "star.fill")
                }
                .disabled(favoritesAtCap)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func frequentTripRow(_ trip: FrequentTrip) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(trip.origin) → \(trip.destination)")
                    .font(.subheadline.weight(.medium))
                Text("Driven \(trip.count) times")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    saveFrequentAsRoute(trip, isFavorite: false)
                } label: {
                    Label("Add as Route", systemImage: "signpost.right.and.left")
                }
                .disabled(savedAtCap)
                Button {
                    saveFrequentAsRoute(trip, isFavorite: true)
                } label: {
                    Label("Add as Favorite", systemImage: "star.fill")
                }
                .disabled(favoritesAtCap)
                Button(role: .destructive) {
                    dismissRecommendation(trip)
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func saveFrequentAsRoute(_ trip: FrequentTrip, isFavorite: Bool) {
        let commute = SavedCommute(name: "\(trip.origin) → \(trip.destination)", origin: trip.origin, destination: trip.destination, isFavorite: isFavorite)
        modelContext.insert(commute)
        try? modelContext.save()
    }

    private func dismissRecommendation(_ trip: FrequentTrip) {
        dismissedRecommendationKeys.insert(key(trip.origin, trip.destination))
        UserDefaults.standard.set(Array(dismissedRecommendationKeys), forKey: "smartride.dismissedRecommendations")
    }

    private func select(origin: String, destination: String) {
        appSettings.pendingOrigin = origin
        appSettings.pendingDestination = destination
        appSettings.selectedTab = AppSettings.homeTabIndex
    }

    private func deleteCommute(_ commute: SavedCommute) {
        modelContext.delete(commute)
        try? modelContext.save()
    }

    private func toggleFavorite(_ commute: SavedCommute) {
        commute.isFavorite.toggle()
        try? modelContext.save()
    }
}

#Preview {
    RoutesView()
        .environmentObject(AppSettings())
        .modelContainer(for: [SavedCommute.self, LoggedTrip.self, FavoriteLocation.self], inMemory: true)
}
