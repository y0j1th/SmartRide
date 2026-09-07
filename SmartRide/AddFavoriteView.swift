//
//  AddFavoriteView.swift
//  SmartRide
//
//  Sheet for setting a Home/Office address, or adding a custom frequent location.
//  Editing an existing favorite is the same form, pre-filled.
//

import SwiftUI
import CoreLocation
import SwiftData

struct AddFavoriteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let kind: FavoriteKind
    let existing: FavoriteLocation?

    @State private var name: String
    @State private var address: String
    @State private var coordinate: CLLocationCoordinate2D?

    init(kind: FavoriteKind, existing: FavoriteLocation? = nil) {
        self.kind = kind
        self.existing = existing
        _name = State(initialValue: existing?.name ?? (kind == .custom ? "" : kind.rawValue.capitalized))
        _address = State(initialValue: existing?.address ?? "")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if kind == .custom {
                    Section("Name") {
                        TextField("e.g. Gym, Parents' House", text: $name)
                    }
                }
                Section("Address") {
                    LocationSearchField(placeholder: "Search for an address", text: $address, coordinate: $coordinate)
                        .listRowInsets(EdgeInsets())
                        .padding(12)
                }
            }
            .navigationTitle(kind == .custom ? "Add Favorite" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            existing.name = trimmedName
            existing.address = address
        } else {
            modelContext.insert(FavoriteLocation(name: trimmedName, address: address, kind: kind))
        }
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    AddFavoriteView(kind: .home)
        .modelContainer(for: [FavoriteLocation.self], inMemory: true)
}
