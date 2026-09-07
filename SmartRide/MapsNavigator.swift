//
//  MapsNavigator.swift
//  SmartRide
//
//  Builds a Maps deep link from plain addresses. Used when opening navigation from
//  a tapped reminder notification, where only the text that was baked into the
//  notification's payload is available — no live coordinates or Trip state, since
//  the app may not even be running yet when the tap happens.
//

import Foundation

enum MapsNavigator {
    static func url(originText: String?, destinationText: String, preferredApp: String, travelMode: TravelMode = .driving) -> URL? {
        let trimmedOrigin = originText?.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Current Location" isn't a real address — omitting it lets the maps app
        // fall back to the device's own live position, which is also more accurate
        // by the time a reminder actually fires than whatever was captured when it
        // was scheduled.
        let originParam: String? = (trimmedOrigin?.isEmpty ?? true) || trimmedOrigin == "Current Location" ? nil : trimmedOrigin

        switch preferredApp {
        case "google":
            var items = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "destination", value: destinationText),
                URLQueryItem(name: "travelmode", value: travelMode.googleTravelMode),
            ]
            if let originParam { items.append(URLQueryItem(name: "origin", value: originParam)) }
            var components = URLComponents(string: "https://www.google.com/maps/dir/")
            components?.queryItems = items
            return components?.url
        default:
            var items = [
                URLQueryItem(name: "daddr", value: destinationText),
                URLQueryItem(name: "dirflg", value: travelMode.appleDirectionsFlag),
            ]
            if let originParam { items.append(URLQueryItem(name: "saddr", value: originParam)) }
            var components = URLComponents(string: "https://maps.apple.com/")
            components?.queryItems = items
            return components?.url
        }
    }
}
