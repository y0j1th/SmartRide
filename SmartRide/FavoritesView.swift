//
//  FavoritesView.swift
//  SmartRide
//
//  Manage Home, Office, and frequent locations (doc §4.1 bottom nav) — these are
//  the places that quick-fill the From/To fields on Home via the favorite chips.
//

import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteLocation.createdAt) private var allFavorites: [FavoriteLocation]

    @State private var editingFavorite: EditingFavorite?

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

    private var home: FavoriteLocation? { allFavorites.first { $0.kind == .home } }
    private var office: FavoriteLocation? { allFavorites.first { $0.kind == .office } }
    private var customFavorites: [FavoriteLocation] { allFavorites.filter { $0.kind == .custom } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Favorites") {
                    favoriteRow(title: "Home", favorite: home, kind: .home)
                    favoriteRow(title: "Office", favorite: office, kind: .office)
                }

                Section("Frequent Locations") {
                    if customFavorites.isEmpty {
                        Text("No frequent locations yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(customFavorites) { favorite in
                        Button {
                            editingFavorite = .existing(favorite)
                        } label: {
                            favoriteLabel(name: favorite.name, address: favorite.address, icon: favorite.kind.icon)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteCustomFavorites)

                    Button {
                        editingFavorite = .new(.custom)
                    } label: {
                        Label("Add Frequent Location", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Favorites")
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

    private func favoriteRow(title: String, favorite: FavoriteLocation?, kind: FavoriteKind) -> some View {
        Button {
            if let favorite {
                editingFavorite = .existing(favorite)
            } else {
                editingFavorite = .new(kind)
            }
        } label: {
            favoriteLabel(name: title, address: favorite?.address ?? "Not set", icon: kind.icon)
        }
        .buttonStyle(.plain)
    }

    private func favoriteLabel(name: String, address: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(.primary)
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func deleteCustomFavorites(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(customFavorites[index])
        }
        try? modelContext.save()
    }
}

#Preview {
    FavoritesView()
        .modelContainer(for: [FavoriteLocation.self], inMemory: true)
}
