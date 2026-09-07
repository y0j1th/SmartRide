//
//  FavoriteLocation.swift
//  SmartRide
//
//  A single reusable place — Home or Office — that can quick-fill the From/To
//  fields on Home. Distinct from SavedCommute (a full From+To trip preset):
//  this is one place, usable as either end of a trip. There is deliberately no
//  freeform "frequent location" kind — Routes' "Frequently Visited" section
//  already surfaces places driven often, from real trip history rather than a
//  manually-managed list.
//

import Foundation
import SwiftData

enum FavoriteKind: String, Codable {
    case home
    case office

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .office: return "briefcase.fill"
        }
    }
}

@Model
final class FavoriteLocation {
    var name: String
    var address: String
    var kindRaw: String
    var createdAt: Date

    init(name: String, address: String, kind: FavoriteKind, createdAt: Date = Date()) {
        self.name = name
        self.address = address
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
    }

    var kind: FavoriteKind {
        get { FavoriteKind(rawValue: kindRaw) ?? .home }
        set { kindRaw = newValue.rawValue }
    }
}
