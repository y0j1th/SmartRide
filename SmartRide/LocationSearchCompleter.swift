//
//  LocationSearchCompleter.swift
//  SmartRide
//
//  Wraps MKLocalSearchCompleter so typing a business name like "crunch tracy" (not
//  just a street address) surfaces real place suggestions to pick from.
//

import Foundation
import MapKit
import Combine

final class LocationSearchCompleter: NSObject, ObservableObject {
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        completer.queryFragment = query
    }

    func clear() {
        results = []
        completer.queryFragment = ""
    }
}

extension LocationSearchCompleter: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.results = completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.results = []
        }
    }
}
