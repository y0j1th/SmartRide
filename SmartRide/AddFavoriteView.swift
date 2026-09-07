//
//  AddFavoriteView.swift
//  SmartRide
//
//  Sheet for setting a Home or Office address. Editing an existing favorite is
//  the same form, pre-filled.
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
        _name = State(initialValue: existing?.name ?? kind.rawValue.capitalized)
        _address = State(initialValue: existing?.address ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ADDRESS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LocationSearchField(placeholder: "Search for an address", text: $address, coordinate: $coordinate)
                    }
                    Spacer(minLength: 0)
                }
                .padding()
            }
            .navigationTitle(name)
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
