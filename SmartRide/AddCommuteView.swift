//
//  AddCommuteView.swift
//  SmartRide
//
//  Sheet for saving a new favorite commute, with the same place-search fields as
//  the Home screen.
//

import SwiftUI
import CoreLocation
import SwiftData

struct AddCommuteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var origin = ""
    @State private var originCoordinate: CLLocationCoordinate2D?
    @State private var destination = ""
    @State private var destinationCoordinate: CLLocationCoordinate2D?
    @State private var alertsEnabled = false
    @State private var targetArrival = Date()

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && !a.isEmpty && !b.isEmpty && a.lowercased() != b.lowercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Gym, Parents' House", text: $name)
                }
                Section("From") {
                    LocationSearchField(placeholder: "Starting point", text: $origin, coordinate: $originCoordinate)
                        .listRowInsets(EdgeInsets())
                        .padding(12)
                }
                Section("To") {
                    LocationSearchField(placeholder: "Destination", text: $destination, coordinate: $destinationCoordinate)
                        .listRowInsets(EdgeInsets())
                        .padding(12)
                }
                Section {
                    Toggle("Smart traffic alerts", isOn: $alertsEnabled)
                    if alertsEnabled {
                        DatePicker("Usual arrival time", selection: $targetArrival, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("SmartRide checks this commute when you open the app and lets you know if traffic is building faster than usual for your usual arrival time.")
                }
            }
            .navigationTitle("Add Commute")
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
        let commute = SavedCommute(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            origin: origin,
            destination: destination,
            targetArrivalMinuteOfDay: targetMinute,
            alertsEnabled: alertsEnabled
        )
        modelContext.insert(commute)
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    AddCommuteView()
        .modelContainer(for: [SavedCommute.self], inMemory: true)
}
