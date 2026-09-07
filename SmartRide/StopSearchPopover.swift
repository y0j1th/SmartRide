//
//  StopSearchPopover.swift
//  SmartRide
//
//  Search for a stop, shown as a popover anchored right under the field —
//  distinct from `LocationSearchField`'s floating overlay because a popover is
//  presented by the system at the window level, entirely outside the normal view
//  hierarchy's z-ordering. With a variable number of stop fields possibly stacked
//  between From and Destination, getting an overlay to reliably draw above every
//  possible sibling arrangement kept failing; a popover has no such siblings to
//  contend with — it always renders on top, by construction, and (with
//  `.presentationCompactAdaptation(.popover)`) still reads as a small anchored
//  panel on iPhone rather than a full-screen sheet.
//

import SwiftUI
import MapKit

struct StopSearchPopover: View {
    @StateObject private var completer = LocationSearchCompleter()
    @State private var query = ""
    @FocusState private var isFocused: Bool

    let onSelect: (String, CLLocationCoordinate2D?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search for a stop", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .focused($isFocused)
                .padding(10)
                .onChange(of: query) { _, newValue in
                    completer.update(query: newValue)
                }

            Divider()

            if completer.results.isEmpty {
                Text(query.isEmpty ? "Start typing a business, address, or place." : "No matches yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let suggestions = Array(completer.results.prefix(8).enumerated())
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
                }
            }
        }
        .frame(width: 300, height: 320)
        .presentationCompactAdaptation(.popover)
        .task {
            // A popover's content appears already-presented, but the field
            // doesn't focus itself automatically — this is what puts the
            // keyboard up right away instead of requiring an extra tap.
            try? await Task.sleep(nanoseconds: 150_000_000)
            isFocused = true
        }
    }

    private func select(_ result: MKLocalSearchCompletion) {
        let display = result.subtitle.isEmpty ? result.title : "\(result.title), \(result.subtitle)"
        Task {
            let request = MKLocalSearch.Request(completion: result)
            let response = try? await MKLocalSearch(request: request).start()
            let coordinate = response?.mapItems.first?.placemark.coordinate
            onSelect(display, coordinate)
        }
    }
}
