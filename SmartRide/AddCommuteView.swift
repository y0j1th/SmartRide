//
//  AddCommuteView.swift
//  SmartRide
//
//  Sheet for saving (or editing) a route, with the same place-search fields as
//  the Home screen. `isFavorite` is fixed by which button opened this — Routes'
//  "Add Favorite Route" vs. "Add Route" — and carried through unchanged when
//  editing, since switching a route between the two sections isn't this form's job.
//

import SwiftUI
import CoreLocation
import SwiftData

struct AddCommuteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var savedCommutes: [SavedCommute]

    let existing: SavedCommute?
    let isFavorite: Bool

    @State private var name: String
    @State private var origin: String
    @State private var originCoordinate: CLLocationCoordinate2D?
    @State private var destination: String
    @State private var destinationCoordinate: CLLocationCoordinate2D?
    @State private var alertsEnabled: Bool
    @State private var targetArrival: Date

    init(existing: SavedCommute? = nil, isFavorite: Bool = false) {
        self.existing = existing
        self.isFavorite = existing?.isFavorite ?? isFavorite
        _name = State(initialValue: existing?.name ?? "")
        _origin = State(initialValue: existing?.origin ?? "")
        _destination = State(initialValue: existing?.destination ?? "")
        _alertsEnabled = State(initialValue: existing?.alertsEnabled ?? false)

        if let minute = existing?.targetArrivalMinuteOfDay {
            var comps = DateComponents()
            comps.hour = minute / 60
            comps.minute = minute % 60
            _targetArrival = State(initialValue: Calendar.current.date(from: comps) ?? Date())
        } else {
            _targetArrival = State(initialValue: Date())
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicateName: Bool {
        guard !trimmedName.isEmpty else { return false }
        return savedCommutes.contains { commute in
            commute.isFavorite == isFavorite
                && commute.persistentModelID != existing?.persistentModelID
                && commute.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var isValid: Bool {
        let a = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && !a.isEmpty && !b.isEmpty && a.lowercased() != b.lowercased() && !isDuplicateName
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Name")
                        TextField("e.g. Gym, Parents' House", text: $name)
                            .textFieldStyle(.roundedBorder)
                        if isDuplicateName {
                            Text("You already have a \(isFavorite ? "favorite" : "saved") route named \"\(trimmedName)\".")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("From")
                        LocationSearchField(placeholder: "Starting point", text: $origin, coordinate: $originCoordinate)
                    }
                    .zIndex(2)
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("To")
                        LocationSearchField(placeholder: "Destination", text: $destination, coordinate: $destinationCoordinate)
                    }
                    .zIndex(1)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Smart traffic alerts", isOn: $alertsEnabled)
                        if alertsEnabled {
                            DatePicker("Usual arrival time", selection: $targetArrival, displayedComponents: .hourAndMinute)
                        }
                        Text("SmartRide checks this commute when you open the app and lets you know if traffic is building faster than usual for your usual arrival time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .zIndex(0)

                    Spacer(minLength: 0)
                }
                .padding()
            }
            .navigationTitle(existing == nil ? (isFavorite ? "Add Favorite Route" : "Add Route") : "Edit Route")
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
        let targetMinute: Int?
        if alertsEnabled {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: targetArrival)
            targetMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        } else {
            targetMinute = nil
        }

        if let existing {
            existing.name = trimmedName
            existing.origin = origin
            existing.destination = destination
            existing.targetArrivalMinuteOfDay = targetMinute
            existing.alertsEnabled = alertsEnabled
        } else {
            let commute = SavedCommute(
                name: trimmedName, origin: origin, destination: destination,
                targetArrivalMinuteOfDay: targetMinute, alertsEnabled: alertsEnabled, isFavorite: isFavorite
            )
            modelContext.insert(commute)
        }
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    AddCommuteView()
        .modelContainer(for: [SavedCommute.self], inMemory: true)
}
