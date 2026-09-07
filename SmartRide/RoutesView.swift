//
//  RoutesView.swift
//  SmartRide
//
//  Saved/favorite commutes (doc §4.1 bottom nav). Tapping any commute loads it on
//  the Home tab; "Add Commute" opens a real form with place search.
//

import SwiftUI
import SwiftData

struct RoutesView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedCommute.createdAt) private var savedCommutes: [SavedCommute]
    @Query private var allFavorites: [FavoriteLocation]

    @State private var showAddCommute = false

    private var home: FavoriteLocation? { allFavorites.first { $0.kind == .home && !$0.address.isEmpty } }
    private var office: FavoriteLocation? { allFavorites.first { $0.kind == .office && !$0.address.isEmpty } }

    var body: some View {
        NavigationStack {
            List {
                Section("Favorite Commutes") {
                    if let home, let office {
                        Button {
                            select(origin: home.address, destination: office.address)
                        } label: {
                            commuteRow(name: "Home → Office", origin: home.address, destination: office.address)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(savedCommutes) { commute in
                        Button {
                            select(origin: commute.origin, destination: commute.destination)
                        } label: {
                            commuteRow(
                                name: commute.name, origin: commute.origin, destination: commute.destination,
                                alertsEnabled: commute.alertsEnabled
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                }

                Section {
                    Button {
                        showAddCommute = true
                    } label: {
                        Label("Add Commute", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Routes")
            .sheet(isPresented: $showAddCommute) {
                AddCommuteView()
            }
        }
    }

    private func commuteRow(name: String, origin: String, destination: String, alertsEnabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.headline)
                if alertsEnabled {
                    Image(systemName: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text("\(origin) → \(destination)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func select(origin: String, destination: String) {
        appSettings.pendingOrigin = origin
        appSettings.pendingDestination = destination
        appSettings.selectedTab = 0
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(savedCommutes[index])
        }
        try? modelContext.save()
    }
}

#Preview {
    RoutesView()
        .environmentObject(AppSettings())
        .modelContainer(for: [SavedCommute.self, FavoriteLocation.self], inMemory: true)
}
