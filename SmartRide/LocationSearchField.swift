//
//  LocationSearchField.swift
//  SmartRide
//
//  A text field with a live suggestions list (business names, POIs, and
//  addresses), so typing "crunch tracy" offers "Crunch Fitness - Tracy, CA" to tap
//  instead of requiring a full, exact street address.
//
//  Two presentations: by default the list floats as an overlay so opening/closing
//  it doesn't shove the rest of the screen up and down — but that requires getting
//  its z-ordering right relative to whatever sits below it, which broke down once
//  a field could have OTHER address fields (stops) stacked below it rather than
//  just static content. `inline: true` sidesteps that entirely by making the list
//  a normal layout child instead of an overlay — it can never render behind
//  anything, at the cost of pushing later rows down while it's showing.
//

import SwiftUI
import MapKit

struct LocationSearchField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var coordinate: CLLocationCoordinate2D?
    var inline: Bool = false

    @StateObject private var completer = LocationSearchCompleter()
    @FocusState private var isFocused: Bool

    private var showSuggestions: Bool { isFocused && !completer.results.isEmpty }

    var body: some View {
        if inline {
            VStack(alignment: .leading, spacing: 6) {
                textField
                if showSuggestions {
                    suggestionsList
                }
            }
        } else {
            textField
                .overlay(alignment: .topLeading) {
                    if showSuggestions {
                        suggestionsList
                            .offset(y: 44)
                    }
                }
                .zIndex(isFocused ? 1 : 0)
        }
    }

    private var textField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .focused($isFocused)
            .onChange(of: text) { _, newValue in
                // Only search — and only clear the coordinate — when the user is
                // actually the one editing this field (it has focus). A
                // programmatic update — from "Current Location", a favorite chip,
                // or the swap button — sets text and coordinate together; searching
                // "Current Location" itself as a place query is exactly the bug
                // that used to pop an unrelated suggestions list open underneath it.
                if isFocused {
                    coordinate = nil
                    completer.update(query: newValue)
                } else {
                    completer.clear()
                }
            }
            .onSubmit {
                isFocused = false
            }
    }

    private var suggestionsList: some View {
        let suggestions = Array(completer.results.prefix(5).enumerated())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.offset) { index, result in
                Button {
                    select(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index != suggestions.count - 1 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private func select(_ result: MKLocalSearchCompletion) {
        let display = result.subtitle.isEmpty ? result.title : "\(result.title), \(result.subtitle)"
        text = display
        completer.clear()
        isFocused = false

        Task {
            let request = MKLocalSearch.Request(completion: result)
            let response = try? await MKLocalSearch(request: request).start()
            if let item = response?.mapItems.first {
                coordinate = item.placemark.coordinate
            }
        }
    }
}
