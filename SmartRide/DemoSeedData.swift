//
//  DemoSeedData.swift
//  SmartRide
//
//  One-time seed of HistoricalSample rows for the proposal's demo route (Mountain
//  House, CA -> Menlo Park, CA), shaped to reproduce the worked example in doc §5.3
//  (a brief AM dip around 7:12 driving an ~18min recommendation). Any other route
//  the user tries has no seed data and starts genuinely cold — the engine only
//  learns it from real usage, same as it would for the demo route past this seed.
//

import Foundation
import SwiftData

enum DemoSeedData {
    private static let seededKey = "smartride.didSeedDemoHistory"
    static let demoRouteKey = "mountain house, ca|menlo park, ca"

    static func seedIfNeeded(modelContext: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }

        let calendar = Calendar.current
        let today = Date()

        for dayOffset in 1...14 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard weekday != 1 && weekday != 7 else { continue } // weekdays only

            for minuteOfDay in stride(from: 390, through: 480, by: 5) { // 6:30-8:00 AM
                guard let sampleDate = calendar.date(
                    bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day
                ) else { continue }

                let sample = HistoricalSample(
                    routeKey: demoRouteKey,
                    dayOfWeek: weekday,
                    minuteOfDayBucket: (minuteOfDay / 5) * 5,
                    travelMinutes: demoCongestionMinutes(minuteOfDay: minuteOfDay),
                    recordedAt: sampleDate
                )
                modelContext.insert(sample)
            }
        }
        try? modelContext.save()
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    private static func demoCongestionMinutes(minuteOfDay: Int) -> Double {
        let base = 72.0
        var mult = 1.0
        mult += gaussian(Double(minuteOfDay), center: 405, width: 22, height: 0.45)
        mult -= gaussian(Double(minuteOfDay), center: 432, width: 6, height: 0.42)
        mult += gaussian(Double(minuteOfDay), center: 465, width: 25, height: 0.30)
        return base * max(1.0, mult)
    }

    private static func gaussian(_ x: Double, center: Double, width: Double, height: Double) -> Double {
        height * exp(-pow(x - center, 2) / (2 * width * width))
    }
}
