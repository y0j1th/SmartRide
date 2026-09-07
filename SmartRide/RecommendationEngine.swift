//
//  RecommendationEngine.swift
//  SmartRide
//
//  Real implementation of the "best time to leave" algorithm from doc §5, extended
//  with a continuous prediction window, joint route+time optimization, and an
//  Arrive-By mode.
//
//  MapKit only gives us one live sample (there's no public API for time-shifted
//  future traffic prediction), so the whole continuous window is built by reshaping
//  that one live sample with our own locally-learned historical pattern store (see
//  HistoricalSample) — the engine only starts finding real dips/peaks once it has
//  real logged data; with none yet it's honestly flat and just recommends "now".
//
//  Route + departure joint optimization: each fetched route alternative is given a
//  time-sensitivity multiplier (highway "fastest" routes react more to a worsening
//  time-factor than slower local/alternate routes, which are more consistently slow
//  regardless of time-of-day) — a documented simplifying assumption, not independently
//  measured per route, since that would need one live query per route per candidate.
//  This lets a different route legitimately win at a different candidate time.

import Foundation
import MapKit
import CoreLocation
import SwiftData

enum RecommendationOutcome {
    case success(Recommendation)
    case invalidAddress(String)
}

enum RecommendationError: Error {
    case geocodingFailed
    case directionsFailed
}

enum RecommendationEngine {

    private static let candidateStepMinutes = 10
    private static let candidateWindowMinutes = 150 // ~2.5 hours of continuous prediction
    private static let liveHorizonMinutes = 150.0
    private static let fallbackAverageSpeedMph = 45.0

    // MARK: - Depart-At mode

    static func recommend(
        trip: Trip,
        departureOption: DepartureOption,
        simulateFailure: Bool,
        referenceDate: Date = Date(),
        modelContext: ModelContext
    ) async -> RecommendationOutcome {
        let windowStart = startDate(for: departureOption, referenceDate: referenceDate)

        guard let ctx = await resolveContext(
            trip: trip, simulateFailure: simulateFailure, liveDepartureDate: windowStart, modelContext: modelContext
        ) else {
            return .invalidAddress("Couldn't find one of those addresses. Try a more specific city or street.")
        }

        let times = stride(from: 0, through: candidateWindowMinutes, by: candidateStepMinutes)
            .map { windowStart.addingTimeInterval(Double($0) * 60) }

        let candidates = buildCandidates(times: times, liveAnchor: windowStart, ctx: ctx)
        guard let baseline = candidates.first else {
            return .invalidAddress("Couldn't compute a route for this trip.")
        }

        let best = candidates.min { $0.durationMinutes < $1.durationMinutes } ?? baseline
        let timeSaved = max(0, baseline.durationMinutes - best.durationMinutes)
        let alreadyOptimal = timeSaved <= 2

        let durations = candidates.map { Double($0.durationMinutes) }
        var confidence = confidenceScore(best: Double(best.durationMinutes), all: durations)
        if ctx.liveNowMinutes == nil { confidence -= 15 }
        if ctx.historicalPointsUsed < 3 { confidence -= 15 }
        confidence = min(97, max(30, confidence))

        let range = durationRange(around: best.durationMinutes, all: durations)
        let routes = buildRouteOptions(liveRoutes: ctx.liveRoutes, fallbackMinutes: ctx.fallbackMinutes, straightLineMiles: ctx.straightLineMiles, timeFactor: timeFactor(for: best.time, ctx: ctx, liveAnchor: windowStart))

        logHistoricalSampleIfNeeded(ctx: ctx, trip: trip, at: windowStart, modelContext: modelContext)

        let recommendation = Recommendation(
            referenceNow: referenceDate,
            mode: .departAt,
            recommendedTime: best.time,
            expectedDurationMinutes: best.durationMinutes,
            durationRangeMinutes: range,
            arrivalTime: best.arrivalTime,
            timeSavedMinutes: timeSaved,
            leaveNowDurationMinutes: baseline.durationMinutes,
            confidencePercent: confidence,
            isFallback: ctx.liveNowMinutes == nil,
            alreadyOptimal: alreadyOptimal,
            routes: routes,
            candidates: candidates,
            originCoordinate: ctx.originCoordinate,
            destinationCoordinate: ctx.destinationCoordinate,
            routePolyline: ctx.liveRoutes?.first?.polyline,
            targetArrival: nil,
            latestSafeDeparture: nil,
            reliabilityPercent: nil
        )
        return .success(recommendation)
    }

    // MARK: - Arrive-By mode

    static func recommendArriveBy(
        trip: Trip,
        targetArrival: Date,
        simulateFailure: Bool,
        referenceDate: Date = Date(),
        modelContext: ModelContext
    ) async -> RecommendationOutcome {
        guard let ctx = await resolveContext(
            trip: trip, simulateFailure: simulateFailure, liveDepartureDate: referenceDate, modelContext: modelContext
        ) else {
            return .invalidAddress("Couldn't find one of those addresses. Try a more specific city or street.")
        }

        let earliest = max(referenceDate, targetArrival.addingTimeInterval(-Double(candidateWindowMinutes) * 60))
        var times: [Date] = []
        var t = earliest
        while t < targetArrival {
            times.append(t)
            t = t.addingTimeInterval(Double(candidateStepMinutes) * 60)
        }
        if times.isEmpty { times = [earliest] }

        let candidates = buildCandidates(times: times, liveAnchor: referenceDate, ctx: ctx)
        guard let baseline = candidates.first else {
            return .invalidAddress("Couldn't compute a route for this trip.")
        }

        let durations = candidates.map { Double($0.durationMinutes) }
        let onTime = candidates.filter { $0.arrivalTime <= targetArrival }

        let mean = durations.reduce(0, +) / Double(durations.count)
        let variance = durations.reduce(0) { $0 + pow($1 - mean, 2) } / Double(durations.count)
        let stdDev = sqrt(variance)
        let bufferMinutes = max(5, Int((stdDev * 0.8).rounded()))

        let best: CandidateResult
        let latestSafe: CandidateResult?
        let reliability: Int

        if let latest = onTime.max(by: { $0.time < $1.time }) {
            latestSafe = latest
            let safeCandidates = onTime.filter {
                $0.arrivalTime.addingTimeInterval(Double(bufferMinutes) * 60) <= targetArrival
            }
            best = safeCandidates.max(by: { $0.time < $1.time }) ?? onTime.min(by: { $0.time < $1.time })!
            let marginMinutes = targetArrival.timeIntervalSince(best.arrivalTime) / 60
            reliability = Int(min(97, max(35, 60 + (marginMinutes / max(stdDev, 1)) * 15)))
        } else {
            // Nothing in the window arrives on time — recommend leaving as soon as
            // possible anyway and say so honestly, rather than pretending otherwise.
            best = candidates.min { $0.durationMinutes < $1.durationMinutes } ?? baseline
            latestSafe = nil
            reliability = 15
        }

        let timeSaved = max(0, baseline.durationMinutes - best.durationMinutes)
        let range = durationRange(around: best.durationMinutes, all: durations)
        let routes = buildRouteOptions(liveRoutes: ctx.liveRoutes, fallbackMinutes: ctx.fallbackMinutes, straightLineMiles: ctx.straightLineMiles, timeFactor: timeFactor(for: best.time, ctx: ctx, liveAnchor: referenceDate))

        logHistoricalSampleIfNeeded(ctx: ctx, trip: trip, at: referenceDate, modelContext: modelContext)

        let recommendation = Recommendation(
            referenceNow: referenceDate,
            mode: .arriveBy,
            recommendedTime: best.time,
            expectedDurationMinutes: best.durationMinutes,
            durationRangeMinutes: range,
            arrivalTime: best.arrivalTime,
            timeSavedMinutes: timeSaved,
            leaveNowDurationMinutes: baseline.durationMinutes,
            confidencePercent: reliability,
            isFallback: ctx.liveNowMinutes == nil,
            alreadyOptimal: timeSaved <= 2,
            routes: routes,
            candidates: candidates,
            originCoordinate: ctx.originCoordinate,
            destinationCoordinate: ctx.destinationCoordinate,
            routePolyline: ctx.liveRoutes?.first?.polyline,
            targetArrival: targetArrival,
            latestSafeDeparture: latestSafe?.time,
            reliabilityPercent: reliability
        )
        return .success(recommendation)
    }

    // MARK: - Shared context (geocoding + one live routes fetch)

    private struct Context {
        let liveRoutes: [MKRoute]?
        let liveNowMinutes: Double?
        let fallbackMinutes: Double
        let straightLineMiles: Double
        let history: [Int: Double]
        let historicalPointsUsed: Int
        let routeKey: String
        let originCoordinate: CLLocationCoordinate2D
        let destinationCoordinate: CLLocationCoordinate2D
    }

    private static func resolveContext(
        trip: Trip, simulateFailure: Bool, liveDepartureDate: Date, modelContext: ModelContext
    ) async -> Context? {
        let originLocation: CLLocation
        let destinationLocation: CLLocation
        do {
            originLocation = try await resolveLocation(text: trip.origin, coordinate: trip.originCoordinate)
            destinationLocation = try await resolveLocation(text: trip.destination, coordinate: trip.destinationCoordinate)
        } catch {
            return nil
        }

        let straightLineMiles = originLocation.distance(from: destinationLocation) / 1609.34
        let fallbackMinutes = max(5.0, (straightLineMiles / fallbackAverageSpeedMph) * 60.0)

        var liveRoutes: [MKRoute]?
        if !simulateFailure {
            liveRoutes = try? await fetchRoutes(
                from: originLocation.coordinate, to: destinationLocation.coordinate, departureDate: liveDepartureDate
            )
        }
        let liveNowMinutes = liveRoutes?.map { $0.expectedTravelTime / 60 }.min()

        let routeKey = trip.routeKey
        let dow = Calendar.current.component(.weekday, from: liveDepartureDate)
        let history = historicalMinutesByBucket(routeKey: routeKey, dayOfWeek: dow, modelContext: modelContext)

        return Context(
            liveRoutes: liveRoutes, liveNowMinutes: liveNowMinutes, fallbackMinutes: fallbackMinutes,
            straightLineMiles: straightLineMiles, history: history,
            historicalPointsUsed: history.count, routeKey: routeKey,
            originCoordinate: originLocation.coordinate, destinationCoordinate: destinationLocation.coordinate
        )
    }

    // MARK: - Candidate building

    private static func buildCandidates(times: [Date], liveAnchor: Date, ctx: Context) -> [CandidateResult] {
        times.map { t in
            let factor = timeFactor(for: t, ctx: ctx, liveAnchor: liveAnchor)
            let duration = candidateDuration(timeFactor: factor, liveRoutes: ctx.liveRoutes, fallbackMinutes: ctx.fallbackMinutes)
            return CandidateResult(time: t, durationMinutes: duration)
        }
    }

    /// Blended expected minutes for the primary route at `t`, relative to the same
    /// quantity at `liveAnchor` (where the one real live sample was taken). 1.0 means
    /// "same as right now."
    private static func timeFactor(for t: Date, ctx: Context, liveAnchor: Date) -> Double {
        let anchorBlended = blendedMinutes(at: liveAnchor, referenceForTrust: liveAnchor, ctx: ctx)
        guard anchorBlended > 0 else { return 1 }
        let blended = blendedMinutes(at: t, referenceForTrust: liveAnchor, ctx: ctx)
        return blended / anchorBlended
    }

    private static func blendedMinutes(at t: Date, referenceForTrust: Date, ctx: Context) -> Double {
        let bucket = minuteBucket(for: t)
        let anchorBucket = minuteBucket(for: referenceForTrust)
        let anchorHistorical = ctx.history[anchorBucket]
        let historicalEstimate = ctx.history[bucket] ?? ctx.liveNowMinutes ?? ctx.fallbackMinutes

        let liveEstimate: Double
        if let liveNowMinutes = ctx.liveNowMinutes {
            if let anchorHistorical, anchorHistorical > 0 {
                liveEstimate = liveNowMinutes * (historicalEstimate / anchorHistorical)
            } else {
                liveEstimate = liveNowMinutes
            }
        } else {
            liveEstimate = historicalEstimate
        }

        let minutesFromNow = abs(t.timeIntervalSince(referenceForTrust)) / 60
        let liveTrust: Double
        if ctx.liveNowMinutes == nil || minutesFromNow > liveHorizonMinutes {
            liveTrust = 0
        } else {
            liveTrust = max(0.35, 1 - minutesFromNow / liveHorizonMinutes)
        }

        return liveTrust * liveEstimate + (1 - liveTrust) * historicalEstimate
    }

    /// Applies a time-sensitivity multiplier per route (see file header) and returns
    /// the best (minimum) duration across all fetched routes for this time factor —
    /// this is the joint route+departure-time optimization.
    private static func candidateDuration(timeFactor: Double, liveRoutes: [MKRoute]?, fallbackMinutes: Double) -> Int {
        guard let liveRoutes, !liveRoutes.isEmpty else {
            return Int((fallbackMinutes * timeFactor).rounded())
        }
        let fastest = liveRoutes[0]
        let options = liveRoutes.map { route -> Double in
            let sensitivity: Double
            if route === fastest {
                sensitivity = 1.3
            } else {
                let ratio = route.expectedTravelTime / fastest.expectedTravelTime
                sensitivity = ratio <= 1.35 ? 0.9 : 0.6
            }
            let adjustedFactor = max(0.5, 1 + (timeFactor - 1) * sensitivity)
            return (route.expectedTravelTime / 60) * adjustedFactor
        }
        return Int((options.min() ?? fallbackMinutes).rounded())
    }

    private static func durationRange(around best: Int, all: [Double]) -> ClosedRange<Int> {
        let mean = all.reduce(0, +) / Double(all.count)
        let variance = all.reduce(0) { $0 + pow($1 - mean, 2) } / Double(all.count)
        let stdDev = sqrt(variance)
        let half = max(3, Int((stdDev * 0.6).rounded()))
        return (best - half)...(best + half)
    }

    // MARK: - Historical logging

    private static func logHistoricalSampleIfNeeded(ctx: Context, trip: Trip, at date: Date, modelContext: ModelContext) {
        guard let liveNowMinutes = ctx.liveNowMinutes else { return }
        let dow = Calendar.current.component(.weekday, from: date)
        modelContext.insert(HistoricalSample(
            routeKey: ctx.routeKey, dayOfWeek: dow, minuteOfDayBucket: minuteBucket(for: date), travelMinutes: liveNowMinutes
        ))
        try? modelContext.save()
    }

    // MARK: - Networking

    private static func resolveLocation(text: String, coordinate: CLLocationCoordinate2D?) async throws -> CLLocation {
        if let coordinate {
            return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        return try await geocode(text)
    }

    private static func geocode(_ address: String) async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            CLGeocoder().geocodeAddressString(address) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location = placemarks?.first?.location else {
                    continuation.resume(throwing: RecommendationError.geocodingFailed)
                    return
                }
                continuation.resume(returning: location)
            }
        }
    }

    private static func fetchRoutes(
        from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, departureDate: Date
    ) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.departureDate = departureDate
        request.requestsAlternateRoutes = true

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw RecommendationError.directionsFailed }
        return response.routes.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    // MARK: - Window start (Depart-At)

    private static func startDate(for option: DepartureOption, referenceDate: Date) -> Date {
        switch option {
        case .now: return referenceDate
        case .in15: return referenceDate.addingTimeInterval(15 * 60)
        case .in30: return referenceDate.addingTimeInterval(30 * 60)
        case .custom(let date): return max(date, referenceDate)
        }
    }

    // MARK: - Historical store

    private static func minuteBucket(for date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return (minuteOfDay / 5) * 5
    }

    private static func historicalMinutesByBucket(routeKey: String, dayOfWeek: Int, modelContext: ModelContext) -> [Int: Double] {
        let descriptor = FetchDescriptor<HistoricalSample>(
            predicate: #Predicate { $0.routeKey == routeKey && $0.dayOfWeek == dayOfWeek }
        )
        guard let samples = try? modelContext.fetch(descriptor), !samples.isEmpty else { return [:] }

        var buckets: [Int: [Double]] = [:]
        for sample in samples {
            buckets[sample.minuteOfDayBucket, default: []].append(sample.travelMinutes)
        }
        return buckets.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    // MARK: - Confidence

    private static func confidenceScore(best: Double, all: [Double]) -> Int {
        let mean = all.reduce(0, +) / Double(all.count)
        let variance = all.reduce(0) { $0 + pow($1 - mean, 2) } / Double(all.count)
        let stdDev = sqrt(variance)
        let z = stdDev > 0 ? (mean - best) / stdDev : 0
        return Int(min(97, max(40, 60 + z * 18)))
    }

    // MARK: - Route options

    private static func buildRouteOptions(
        liveRoutes: [MKRoute]?, fallbackMinutes: Double, straightLineMiles: Double, timeFactor: Double
    ) -> [RouteOption] {
        guard let liveRoutes, !liveRoutes.isEmpty else {
            return [
                RouteOption(
                    summary: "Estimated route",
                    durationMinutes: Int((fallbackMinutes * timeFactor).rounded()),
                    distanceMiles: straightLineMiles,
                    condition: .moderate,
                    delayNote: "Live routing unavailable — showing a distance-based estimate",
                    isFastest: true,
                    hasTolls: false,
                    fullRouteSummary: nil,
                    polyline: nil
                )
            ]
        }

        let fastest = liveRoutes[0]
        var scored: [(route: MKRoute, minutes: Double)] = liveRoutes.map { route in
            let sensitivity: Double
            if route === fastest {
                sensitivity = 1.3
            } else {
                let ratio = route.expectedTravelTime / fastest.expectedTravelTime
                sensitivity = ratio <= 1.35 ? 0.9 : 0.6
            }
            let adjustedFactor = max(0.5, 1 + (timeFactor - 1) * sensitivity)
            return (route, (route.expectedTravelTime / 60) * adjustedFactor)
        }
        scored.sort { $0.minutes < $1.minutes }

        let bestMinutes = scored[0].minutes
        return scored.prefix(3).enumerated().map { index, pair in
            let ratio = pair.minutes / bestMinutes
            let condition: TrafficCondition = ratio <= 1.05 ? .light : (ratio <= 1.35 ? .moderate : .congested)
            let delay = index == 0
                ? "Fastest option for this departure time"
                : "+\(Int((pair.minutes - bestMinutes).rounded())) min vs. fastest"
            return RouteOption(
                summary: pair.route.name.isEmpty ? "Route \(index + 1)" : pair.route.name,
                durationMinutes: Int(pair.minutes.rounded()),
                distanceMiles: pair.route.distance / 1609.34,
                condition: condition,
                delayNote: delay,
                isFastest: index == 0,
                hasTolls: pair.route.advisoryNotices.contains { $0.localizedCaseInsensitiveContains("toll") },
                fullRouteSummary: highwayChain(for: pair.route),
                polyline: pair.route.polyline
            )
        }
    }

    /// Extracts numbered highways (I-680, US-101, CA-84, SR-84, ...) from turn-by-turn
    /// step instructions, in order, collapsing consecutive repeats — MapKit's own
    /// `route.name` often only names the primary highway, not the full chain.
    private static func highwayChain(for route: MKRoute) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:I|US|CA|SR)-\d+(?:\s[NSEW])?\b"#) else { return nil }
        var found: [String] = []
        for step in route.steps {
            let text = step.instructions
            guard !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), let matchRange = Range(match.range, in: text) {
                let name = String(text[matchRange])
                if found.last != name {
                    found.append(name)
                }
            }
        }
        guard !found.isEmpty else { return nil }
        return found.joined(separator: " → ")
    }
}
