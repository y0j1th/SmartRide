//
//  SaveRouteAsView.swift
//  SmartRide
//
//  Sheet for naming a route before it's saved (as a Favorite Route or a plain
//  Route) — reached from Home's save menu. Names only need to be unique within
//  the same favorite/plain grouping, matching how the Routes tab shows them as
//  two separate sections.
//

import SwiftUI
import SwiftData

struct SaveRouteAsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var savedCommutes: [SavedCommute]

    let origin: String
    let destination: String
    let isFavorite: Bool

    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicateName: Bool {
        guard !trimmedName.isEmpty else { return false }
        return savedCommutes.contains {
            $0.isFavorite == isFavorite
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !isDuplicateName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NAME")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("e.g. Morning Commute", text: $name)
                            .textFieldStyle(.roundedBorder)
                        if isDuplicateName {
                            Text("You already have a \(isFavorite ? "favorite" : "saved") route named \"\(trimmedName)\".")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("ROUTE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(origin)
                            Divider()
                            Text(destination)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Spacer(minLength: 0)
                }
                .padding()
            }
            .navigationTitle(isFavorite ? "Save as Favorite Route" : "Save as Route")
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
        let commute = SavedCommute(name: trimmedName, origin: origin, destination: destination, isFavorite: isFavorite)
        modelContext.insert(commute)
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    SaveRouteAsView(origin: "Tracy, CA", destination: "San Jose, CA", isFavorite: true)
        .modelContainer(for: [SavedCommute.self], inMemory: true)
}
