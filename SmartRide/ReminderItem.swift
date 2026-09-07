//
//  ReminderItem.swift
//  SmartRide
//
//  A departure reminder the user asked for — persisted (not just the underlying
//  local notification) so it can be listed, edited, or deleted from the Home tab
//  while upcoming, and still show up under History > Reminders once its time has
//  passed, the same way a trip does.
//

import Foundation
import SwiftData

@Model
final class ReminderItem {
    var origin: String
    var destination: String
    var scheduledTime: Date
    /// Identifier of the underlying UNNotificationRequest, so editing/deleting this
    /// item can cancel or reschedule the exact local notification it created.
    var notificationIdentifier: String
    var createdAt: Date
    /// Stored as a raw string (matching FavoriteLocation.kindRaw) rather than
    /// TravelMode directly, since SwiftData models custom enums least riskily this
    /// way. Defaults to "driving" for reminders written before this field existed.
    var travelModeRaw: String = TravelMode.driving.rawValue

    var travelMode: TravelMode {
        get { TravelMode(rawValue: travelModeRaw) ?? .driving }
        set { travelModeRaw = newValue.rawValue }
    }

    init(
        origin: String,
        destination: String,
        scheduledTime: Date,
        notificationIdentifier: String,
        travelMode: TravelMode = .driving,
        createdAt: Date = Date()
    ) {
        self.origin = origin
        self.destination = destination
        self.scheduledTime = scheduledTime
        self.notificationIdentifier = notificationIdentifier
        self.travelModeRaw = travelMode.rawValue
        self.createdAt = createdAt
    }
}
