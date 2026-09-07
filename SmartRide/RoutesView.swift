//
//  RoutesView.swift
//  SmartRide
//
//  Everything reusable about where you go: routes marked as favorites, patterns
//  noticed from real driving history (frequently visited, and recommended-to-save
//  ones not yet saved), and plain saved routes. Every saved/editable row shows
//  just its name; tapping expands it in place to show the details (read-only —
//  editing stays swipe-only) with a Navigate button. Swipe left-to-right for
//  Edit, right-to-left for Delete. There is deliberately no separate "frequent
//  locations" list — Frequently Visited already surfaces places driven often,
//  derived from real trip history rather than a manually-managed one.
//

import SwiftUI
import SwiftData

struct RoutesView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedCommute.createdAt) private var savedCommutes: [SavedCommute]
    @Query(sort: \LoggedTrip.createdAt, order: .reverse) private var loggedTrips: [LoggedTrip]

    @State private var commuteSheet: CommuteSheet?
    @State private var expandedCommuteID: PersistentIdentifier?

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

    private struct FrequentTrip: Identifiable {
        let id = UUID()
        let origin: String
        let destination: String
        let count: Int
    }

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

    /// All origin/destination pairs driven at least twice — a simple frequency-
    /// based browsing list, independent of whether it's already saved.
    private var frequentTrips: [FrequentTrip] {
        var counts: [String: FrequentTrip] = [:]
        for trip in loggedTrips {
            let key = "\(trip.origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(trip.destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            if let existing = counts[key] {
                counts[key] = FrequentTrip(origin: existing.origin, destination: existing.destination, count: existing.count + 1)
            } else {
                counts[key] = FrequentTrip(origin: trip.origin, destination: trip.destination, count: 1)
            }
        }
        return counts.values.filter { $0.count >= 2 }.sorted { $0.count > $1.count }.prefix(5).map { $0 }
    }

    /// Frequent trips not already saved as a route — a nudge toward saving what
    /// you're clearly already doing often, rather than a fabricated suggestion
    /// with no basis in real usage.
    private var recommendedTrips: [FrequentTrip] {
        let saved = Set(savedCommutes.map {
            "\($0.origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\($0.destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        })
        return frequentTrips.filter { !saved.contains("\($0.origin.lowercased())|\($0.destination.lowercased())") }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Favorite") {
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
                }

                if !frequentTrips.isEmpty {
                    Section {
                        ForEach(frequentTrips) { trip in
                            Button {
                                select(origin: trip.origin, destination: trip.destination)
                            } label: {
                                frequentTripBrowseRow(trip)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Frequently Visited")
                    } footer: {
                        Text("Routes you've driven often, based on your trip history.")
                    }
                }

                Section("Saved Routes") {
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
        }
    }

    /// Collapsed shows just the name; tapping expands in place to show the route
    /// details (read-only) and a Navigate button. Editing stays swipe-only.
    private func commuteButtonRow(_ commute: SavedCommute, icon: String) -> some View {
        let isExpanded = expandedCommuteID == commute.persistentModelID
        return VStack(alignment: .leading, spacing: 10) {
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
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow(label: "From", value: commute.origin)
                    detailRow(label: "To", value: commute.destination)
                    if commute.alertsEnabled {
                        Text("Traffic alerts on")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        select(origin: commute.origin, destination: commute.destination)
                    } label: {
                        Label("Navigate", systemImage: "location.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
                .padding(.leading, 32)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                commuteSheet = .edit(commute)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteCommute(commute)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
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

    private func frequentTripBrowseRow(_ trip: FrequentTrip) -> some View {
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
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
            Button {
                saveFrequentAsRoute(trip)
            } label: {
                Label("Save", systemImage: "signpost.right.and.left")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    private func saveFrequentAsRoute(_ trip: FrequentTrip) {
        let commute = SavedCommute(name: "\(trip.origin) → \(trip.destination)", origin: trip.origin, destination: trip.destination)
        modelContext.insert(commute)
        try? modelContext.save()
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
}

#Preview {
    RoutesView()
        .environmentObject(AppSettings())
        .modelContainer(for: [SavedCommute.self, LoggedTrip.self], inMemory: true)
}
