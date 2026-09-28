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

    private static let candidateStepMinutes = 5
    private static let candidateWindowMinutes = 150 // ~2.5 hours of continuous prediction
    /// Minutes of extra drive time per minute of delay past which a jump counts as
    /// a "cliff" rather than ordinary traffic drift — tuned so a slow, steady climb
    /// doesn't trigger it, but the sharp knee where rush hour actually bites does.
    private static let trafficCliffSlopeThreshold = 0.6
    /// Spacing between the extra live checkpoints fetched across the window — 15
    /// minutes gives 10 extra live readings (+15 through +150 min) across the
    /// 2.5-hour window, closely tracking a real rush-hour rise and fall instead of
    /// only roughly bracketing it.
    private static let checkpointStepMinutes = 15

    // MARK: - Depart-At mode

    static func recommend(
        trip: Trip,
        departureOption: DepartureOption,
        simulateFailure: Bool,
        referenceDate: Date = Date(),
        modelContext: ModelContext,
        logHistory: Bool = true
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
        confidence += accuracyConfidenceAdjustment(routeKey: ctx.routeKey, modelContext: modelContext)
        confidence = min(97, max(30, confidence))

        let range = durationRange(around: best.durationMinutes, all: durations)
        let routes = buildRouteOptions(liveRoutes: ctx.liveRoutes, fallbackMinutes: ctx.fallbackMinutes, straightLineMiles: ctx.straightLineMiles, timeFactor: timeFactor(for: best.time, ctx: ctx, liveAnchor: windowStart))
        let cliff = trafficCliff(in: candidates)

        if logHistory {
            logHistoricalSampleIfNeeded(ctx: ctx, trip: trip, at: windowStart, modelContext: modelContext)
        }

        let recommendation = Recommendation(
            referenceNow: referenceDate,
            mode: .departAt,
            travelMode: trip.travelMode,
            recommendedTime: best.time,
            expectedDurationMinutes: best.durationMinutes,
            durationRangeMinutes: range,
            arrivalTime: best.arrivalTime,
            timeSavedMinutes: timeSaved,
            leaveNowDurationMinutes: baseline.durationMinutes,
            confidencePercent: confidence,
            isFallback: ctx.liveNowMinutes == nil,
            alreadyOptimal: alreadyOptimal,
            trafficCliffTime: cliff?.time,
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

    /// A quick "if I left this exact moment" duration estimate, independent of any
    /// Arrive-By target — used only to work out the earliest arrival time worth
    /// offering in the Arrive By picker (current drive time + a 1-hour buffer),
    /// before the user has picked a target for the full `recommendArriveBy` call
    /// to search backward from.
    static func quickLiveDuration(trip: Trip, simulateFailure: Bool, modelContext: ModelContext) async -> Int? {
        guard let ctx = await resolveContext(
            trip: trip, simulateFailure: simulateFailure, liveDepartureDate: Date(), modelContext: modelContext
        ) else { return nil }
        return Int((ctx.liveNowMinutes ?? ctx.fallbackMinutes).rounded())
    }

    // MARK: - Arrive-By mode

    static func recommendArriveBy(
        trip: Trip,
        targetArrival: Date,
        simulateFailure: Bool,
        referenceDate: Date = Date(),
        modelContext: ModelContext,
        logHistory: Bool = true
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

        let best: CandidateResult
        let latestSafe: CandidateResult?
        let reliability: Int

        if let latest = onTime.max(by: { $0.time < $1.time }),
           case let preciseTime = targetArrival.addingTimeInterval(-Double(latest.durationMinutes) * 60),
           preciseTime >= referenceDate {
            // "Leave at" = arrive-by time minus the actual predicted duration —
            // exactly, to the minute, not whichever 5-minute-grid candidate
            // happened to land on-time. `latest` finds the right duration to use
            // (the traffic-aware estimate for departing around this time); this
            // then recomputes the departure precisely from the target itself, so
            // the arrival lands exactly at the target rather than up to 5 minutes
            // before it purely as an artifact of the candidate grid. No safety
            // buffer is subtracted either — "arrive by 6:15" means exactly that,
            // not some earlier, unrequested cushion time. Reliability instead
            // reflects how consistent this route's traffic normally is — a
            // low-variance route can be cut this close with real confidence; a
            // highly variable one can't, and that's reflected in the percentage,
            // not by silently leaving early.
            best = CandidateResult(time: preciseTime, durationMinutes: latest.durationMinutes)
            latestSafe = best
            let variabilityRatio = stdDev / max(mean, 1)
            reliability = Int(min(97, max(35, 90 - variabilityRatio * 220)))
        } else {
            // Nothing in the window arrives on time — recommend leaving as soon as
            // possible anyway and say so honestly, rather than pretending otherwise.
            best = candidates.min { $0.durationMinutes < $1.durationMinutes } ?? baseline
            latestSafe = nil
            reliability = 15
        }

        let adjustedReliability = min(97, max(15, reliability + accuracyConfidenceAdjustment(routeKey: ctx.routeKey, modelContext: modelContext)))

        let timeSaved = max(0, baseline.durationMinutes - best.durationMinutes)
        let range = durationRange(around: best.durationMinutes, all: durations)
        let routes = buildRouteOptions(liveRoutes: ctx.liveRoutes, fallbackMinutes: ctx.fallbackMinutes, straightLineMiles: ctx.straightLineMiles, timeFactor: timeFactor(for: best.time, ctx: ctx, liveAnchor: referenceDate))
        let cliff = trafficCliff(in: candidates)

        if logHistory {
            logHistoricalSampleIfNeeded(ctx: ctx, trip: trip, at: referenceDate, modelContext: modelContext)
        }

        let recommendation = Recommendation(
            referenceNow: referenceDate,
            mode: .arriveBy,
            travelMode: trip.travelMode,
            recommendedTime: best.time,
            expectedDurationMinutes: best.durationMinutes,
            durationRangeMinutes: range,
            arrivalTime: best.arrivalTime,
            timeSavedMinutes: timeSaved,
            leaveNowDurationMinutes: baseline.durationMinutes,
            confidencePercent: adjustedReliability,
            isFallback: ctx.liveNowMinutes == nil,
            alreadyOptimal: timeSaved <= 2,
            trafficCliffTime: cliff?.time,
            routes: routes,
            candidates: candidates,
            originCoordinate: ctx.originCoordinate,
            destinationCoordinate: ctx.destinationCoordinate,
            routePolyline: ctx.liveRoutes?.first?.polyline,
            targetArrival: targetArrival,
            latestSafeDeparture: latestSafe?.time,
            reliabilityPercent: adjustedReliability
        )
        return .success(recommendation)
    }

    // MARK: - Shared context (geocoding + one live routes fetch)

    /// A route alternative reduced to just what the rest of the engine and the UI
    /// actually need. Exists so a single fetched MKRoute (the common case) and a
    /// synthesized multi-stop route (several legs stitched into one) can flow
    /// through the exact same scoring and display code — MKRoute itself can't be
    /// constructed by hand, so a multi-leg trip has nothing else to stand in as one.
    private struct LiveRoute {
        let id = UUID()
        let name: String?
        let expectedTravelTime: TimeInterval
        let distance: CLLocationDistance
        let hasTolls: Bool
        let highwaySummary: String?
        let polyline: MKPolyline?
        /// Fraction of this route's distance spent on a numbered highway (0 = all
        /// surface streets, 1 = all highway) — drives `trafficSensitivity`.
        let highwayDistanceFraction: Double
    }

    private struct Context {
        let liveRoutes: [LiveRoute]?
        let liveNowMinutes: Double?
        let fallbackMinutes: Double
        let straightLineMiles: Double
        let history: [Int: Double]
        let historicalPointsUsed: Int
        /// Distinct calendar days this route has real data from — what personal
        /// trust (`blendedMinutes`) actually weights on, since a single trip now
        /// logs several checkpoint samples at once.
        let distinctDaysSampled: Int
        let routeKey: String
        let travelMode: TravelMode
        let originCoordinate: CLLocationCoordinate2D
        let destinationCoordinate: CLLocationCoordinate2D
        /// Extra live samples at future departure times (offset in minutes from
        /// `liveDepartureDate`, paired with Apple's own traffic-aware minutes for
        /// that specific future time) — real per-time signal, not an assumption
        /// reshaped from the one "now" reading. Empty for non-traffic-sensitive
        /// modes (walking/transit) or when the live fetch failed.
        let liveCheckpoints: [(offsetMinutes: Int, minutes: Double)]
    }

    private static func resolveContext(
        trip: Trip, simulateFailure: Bool, liveDepartureDate: Date, modelContext: ModelContext
    ) async -> Context? {
        let originLocation: CLLocation
        let destinationLocation: CLLocation
        var stopLocations: [CLLocation] = []
        do {
            originLocation = try await resolveLocation(text: trip.origin, coordinate: trip.originCoordinate)
            destinationLocation = try await resolveLocation(text: trip.destination, coordinate: trip.destinationCoordinate)
            for stop in trip.filledStops {
                stopLocations.append(try await resolveLocation(text: stop.address, coordinate: stop.coordinate))
            }
        } catch {
            return nil
        }

        let straightLineMiles = originLocation.distance(from: destinationLocation) / 1609.34
        let fallbackMinutes = max(5.0, (straightLineMiles / trip.travelMode.fallbackAverageSpeedMph) * 60.0)

        var liveRoutes: [LiveRoute]?
        if !simulateFailure {
            if stopLocations.isEmpty {
                if let mkRoutes = try? await fetchRoutes(
                    from: originLocation.coordinate, to: destinationLocation.coordinate,
                    departureDate: liveDepartureDate, transportType: trip.travelMode.mkTransportType
                ) {
                    liveRoutes = mkRoutes.map { liveRoute(from: $0, travelMode: trip.travelMode) }
                }
            } else {
                let waypoints = [originLocation.coordinate] + stopLocations.map(\.coordinate) + [destinationLocation.coordinate]
                if let combined = try? await fetchMultiLegRoute(
                    waypoints: waypoints, departureDate: liveDepartureDate,
                    transportType: trip.travelMode.mkTransportType, travelMode: trip.travelMode
                ) {
                    liveRoutes = [combined]
                }
            }
        }
        let liveNowMinutes = liveRoutes?.map { $0.expectedTravelTime / 60 }.min()

        var liveCheckpoints: [(offsetMinutes: Int, minutes: Double)] = []
        if let liveNowMinutes {
            liveCheckpoints.append((0, liveNowMinutes))
        }
        if !simulateFailure && trip.travelMode.isTrafficSensitive {
            liveCheckpoints.append(contentsOf: await fetchLiveCheckpoints(
                originLocation: originLocation, destinationLocation: destinationLocation, stopLocations: stopLocations,
                anchor: liveDepartureDate, transportType: trip.travelMode.mkTransportType, travelMode: trip.travelMode
            ))
        }

        let routeKey = trip.routeKey
        let dow = Calendar.current.component(.weekday, from: liveDepartureDate)
        let (history, distinctDaysSampled) = historicalMinutesByBucket(routeKey: routeKey, dayOfWeek: dow, modelContext: modelContext)

        return Context(
            liveRoutes: liveRoutes, liveNowMinutes: liveNowMinutes, fallbackMinutes: fallbackMinutes,
            straightLineMiles: straightLineMiles, history: history,
            historicalPointsUsed: history.count, distinctDaysSampled: distinctDaysSampled,
            routeKey: routeKey, travelMode: trip.travelMode,
            originCoordinate: originLocation.coordinate, destinationCoordinate: destinationLocation.coordinate,
            liveCheckpoints: liveCheckpoints.sorted { $0.offsetMinutes < $1.offsetMinutes }
        )
    }

    /// Fetches Apple's own traffic-aware duration at several future departure
    /// times across the window, concurrently. This is real per-time signal from
    /// MapKit itself — the same mechanism the Maps app uses for "leave now" vs.
    /// "leave in an hour" — not an assumption manufactured by reshaping the one
    /// "now" reading with a personal historical store that might not have any
    /// data yet. Crucial for a brand-new route: without this, its very first
    /// prediction would be predicted completely flat until enough personal
    /// history built up over many real trips.
    private static func fetchLiveCheckpoints(
        originLocation: CLLocation, destinationLocation: CLLocation, stopLocations: [CLLocation],
        anchor: Date, transportType: MKDirectionsTransportType, travelMode: TravelMode
    ) async -> [(offsetMinutes: Int, minutes: Double)] {
        let offsets = Array(stride(from: checkpointStepMinutes, through: candidateWindowMinutes, by: checkpointStepMinutes))
        return await withTaskGroup(of: (offsetMinutes: Int, minutes: Double)?.self) { group in
            for offset in offsets {
                group.addTask {
                    let departureDate = anchor.addingTimeInterval(Double(offset) * 60)
                    do {
                        let minutes: Double
                        if stopLocations.isEmpty {
                            let routes = try await fetchRoutes(
                                from: originLocation.coordinate, to: destinationLocation.coordinate,
                                departureDate: departureDate, transportType: transportType
                            )
                            guard let fastest = routes.first else { return nil }
                            minutes = travelMode.adjustedMinutes(
                                rawMinutes: fastest.expectedTravelTime / 60, distanceMiles: fastest.distance / 1609.34
                            )
                        } else {
                            let waypoints = [originLocation.coordinate] + stopLocations.map(\.coordinate) + [destinationLocation.coordinate]
                            let combined = try await fetchMultiLegRoute(
                                waypoints: waypoints, departureDate: departureDate,
                                transportType: transportType, travelMode: travelMode
                            )
                            minutes = combined.expectedTravelTime / 60
                        }
                        return (offset, minutes)
                    } catch {
                        return nil
                    }
                }
            }
            var results: [(offsetMinutes: Int, minutes: Double)] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }

    private static func liveRoute(from route: MKRoute, travelMode: TravelMode) -> LiveRoute {
        let minutes = travelMode.adjustedMinutes(rawMinutes: route.expectedTravelTime / 60, distanceMiles: route.distance / 1609.34)
        return LiveRoute(
            name: route.name.isEmpty ? nil : route.name,
            expectedTravelTime: minutes * 60,
            distance: route.distance,
            hasTolls: route.advisoryNotices.contains { $0.localizedCaseInsensitiveContains("toll") },
            highwaySummary: highwayChain(steps: route.steps),
            polyline: route.polyline,
            highwayDistanceFraction: highwayDistanceFraction(steps: route.steps, totalDistance: route.distance)
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

    /// Scans the already-computed candidates (assumed in time order) for the
    /// first consecutive pair whose slope — extra drive minutes per minute of
    /// delay — crosses `trafficCliffSlopeThreshold`. Returns the candidate right
    /// after that jump, i.e. the first point that's already past the cliff, or
    /// nil if the window never climbs that sharply.
    private static func trafficCliff(in candidates: [CandidateResult]) -> CandidateResult? {
        guard candidates.count > 1 else { return nil }
        for i in 0..<(candidates.count - 1) {
            let stepMinutes = candidates[i + 1].time.timeIntervalSince(candidates[i].time) / 60
            guard stepMinutes > 0 else { continue }
            let slope = Double(candidates[i + 1].durationMinutes - candidates[i].durationMinutes) / stepMinutes
            if slope >= trafficCliffSlopeThreshold {
                return candidates[i + 1]
            }
        }
        return nil
    }

    /// Blended expected minutes for the primary route at `t`, relative to the same
    /// quantity at `liveAnchor`. 1.0 means "same as right now." Always exactly 1.0
    /// for a non-traffic-sensitive mode (walking, transit) — congestion-based
    /// time-of-day blending has no physical basis for a walk, and transit runs on
    /// a timetable, not traffic, so treating either as if it had a rush hour would
    /// only manufacture a fake pattern out of noise.
    private static func timeFactor(for t: Date, ctx: Context, liveAnchor: Date) -> Double {
        guard ctx.travelMode.isTrafficSensitive else { return 1 }
        let anchorBlended = blendedMinutes(at: liveAnchor, referenceForTrust: liveAnchor, ctx: ctx)
        guard anchorBlended > 0 else { return 1 }
        let blended = blendedMinutes(at: t, referenceForTrust: liveAnchor, ctx: ctx)
        return blended / anchorBlended
    }

    /// Interpolates between the two checkpoints (see `fetchLiveCheckpoints`)
    /// bracketing `t`'s offset from `anchor` — real Apple-predicted minutes at
    /// real future times, not a ratio projected from a single reading. Extends
    /// flat past either end of the fetched range rather than extrapolating
    /// unboundedly. Nil only when no checkpoints were fetched at all (e.g. a
    /// non-traffic-sensitive mode, or every checkpoint request failed).
    private static func checkpointMinutes(at t: Date, anchor: Date, checkpoints: [(offsetMinutes: Int, minutes: Double)]) -> Double? {
        guard !checkpoints.isEmpty else { return nil }
        let offset = t.timeIntervalSince(anchor) / 60
        guard let first = checkpoints.first, let last = checkpoints.last else { return nil }
        if offset <= Double(first.offsetMinutes) { return first.minutes }
        if offset >= Double(last.offsetMinutes) { return last.minutes }
        for i in 0..<(checkpoints.count - 1) {
            let a = checkpoints[i], b = checkpoints[i + 1]
            guard offset >= Double(a.offsetMinutes), offset <= Double(b.offsetMinutes) else { continue }
            let span = Double(b.offsetMinutes - a.offsetMinutes)
            guard span > 0 else { return a.minutes }
            let fraction = (offset - Double(a.offsetMinutes)) / span
            return a.minutes + (b.minutes - a.minutes) * fraction
        }
        return last.minutes
    }

    /// Blends two independent real signals: Apple's own multi-point live traffic
    /// prediction for this exact route (available from the very first time it's
    /// ever entered), and your personal historical average for this route, if
    /// you've built any up. Personal trust scales with distinct days you've
    /// actually driven this route (capped well short of fully replacing the live
    /// signal) — not raw sample count, since one trip now logs ~10 checkpoints at
    /// once and counting those as independent observations would let 1-2 uses
    /// max out "personal" trust before there's any real personal pattern to trust.
    private static func blendedMinutes(at t: Date, referenceForTrust: Date, ctx: Context) -> Double {
        let bucket = minuteBucket(for: t)
        let baseline = ctx.liveNowMinutes ?? ctx.fallbackMinutes
        let checkpointEstimate = checkpointMinutes(at: t, anchor: referenceForTrust, checkpoints: ctx.liveCheckpoints) ?? baseline
        let historicalEstimate = interpolatedHistoricalMinutes(at: bucket, in: ctx.history, fallback: checkpointEstimate)

        let personalTrust = min(0.7, Double(ctx.distinctDaysSampled) / 10.0)
        return personalTrust * historicalEstimate + (1 - personalTrust) * checkpointEstimate
    }

    /// How much a route's own duration should react to the window's time factor —
    /// grounded in a real, measurable property of the route (how much of it is
    /// numbered highway) rather than an arbitrary constant or a comparison to
    /// whichever route happens to be fastest right now. This follows traffic flow
    /// theory's "fundamental diagram": limited-access highways show sharp,
    /// nonlinear speed drops as they approach capacity (classic rush-hour
    /// behavior), while signal-controlled surface streets are governed more by
    /// fixed signal timing and speed limits, so their travel time is comparatively
    /// stable across the day. A route that's 100% highway scales at 1.3x the
    /// window's time factor; one that's 0% highway (all surface streets) scales at
    /// 0.5x; anything in between scales linearly with its actual highway fraction.
    private static func trafficSensitivity(for route: LiveRoute) -> Double {
        0.5 + 0.8 * route.highwayDistanceFraction
    }

    /// Applies each route's own sensitivity (see `trafficSensitivity`) and returns
    /// the best (minimum) duration across all fetched routes for this time factor —
    /// this is the joint route+departure-time optimization.
    private static func candidateDuration(timeFactor: Double, liveRoutes: [LiveRoute]?, fallbackMinutes: Double) -> Int {
        guard let liveRoutes, !liveRoutes.isEmpty else {
            return Int((fallbackMinutes * timeFactor).rounded())
        }
        let options = liveRoutes.map { route -> Double in
            let sensitivity = trafficSensitivity(for: route)
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

    /// Logs every live checkpoint fetched for this recommendation, not just the
    /// "now" one — one real trip request now contributes several genuine
    /// data points spread across the day's time buckets instead of a single one,
    /// so the personal historical store builds up meaningfully faster.
    private static func logHistoricalSampleIfNeeded(ctx: Context, trip: Trip, at date: Date, modelContext: ModelContext) {
        guard !ctx.liveCheckpoints.isEmpty else { return }
        for checkpoint in ctx.liveCheckpoints {
            let sampleDate = date.addingTimeInterval(Double(checkpoint.offsetMinutes) * 60)
            let dow = Calendar.current.component(.weekday, from: sampleDate)
            modelContext.insert(HistoricalSample(
                routeKey: ctx.routeKey, dayOfWeek: dow, minuteOfDayBucket: minuteBucket(for: sampleDate), travelMinutes: checkpoint.minutes
            ))
        }
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
        from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
        departureDate: Date, transportType: MKDirectionsTransportType
    ) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType
        request.departureDate = departureDate
        request.requestsAlternateRoutes = true

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw RecommendationError.directionsFailed }
        return response.routes.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    /// Stitches origin → stop 1 → stop 2 → ... → destination into a single combined
    /// route by fetching each leg separately (MKDirections has no native multi-
    /// waypoint request) and summing durations/distances, concatenating polylines
    /// and turn-by-turn steps. Each leg's departure is offset by the running total
    /// so far, so the whole chain reflects one continuous trip rather than every
    /// leg independently assuming it starts at the original departure time. The
    /// mode adjustment is applied per leg, before that offset — MapKit only ever
    /// routes at automobile speed, so for biking the *actual* (distance-based)
    /// time spent on leg 1 is what determines what time you'd really be starting
    /// leg 2, and thus what traffic conditions leg 2's own query should be asking
    /// about. Applying the adjustment only once at the end, after already chaining
    /// departures off the raw automobile durations, would ask every leg after the
    /// first for traffic at a time earlier than you'd actually be there.
    private static func fetchMultiLegRoute(
        waypoints: [CLLocationCoordinate2D], departureDate: Date, transportType: MKDirectionsTransportType, travelMode: TravelMode
    ) async throws -> LiveRoute {
        guard waypoints.count >= 2 else { throw RecommendationError.directionsFailed }

        var totalTime: TimeInterval = 0
        var totalDistance: CLLocationDistance = 0
        var hasTolls = false
        var allSteps: [MKRoute.Step] = []
        var combinedCoordinates: [CLLocationCoordinate2D] = []
        var legDeparture = departureDate

        for i in 0..<(waypoints.count - 1) {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[i]))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[i + 1]))
            request.transportType = transportType
            request.departureDate = legDeparture
            request.requestsAlternateRoutes = false

            let response = try await MKDirections(request: request).calculate()
            guard let leg = response.routes.first else { throw RecommendationError.directionsFailed }

            let legMinutes = travelMode.adjustedMinutes(rawMinutes: leg.expectedTravelTime / 60, distanceMiles: leg.distance / 1609.34)
            let scaledLegTime = legMinutes * 60
            totalTime += scaledLegTime
            totalDistance += leg.distance
            if leg.advisoryNotices.contains(where: { $0.localizedCaseInsensitiveContains("toll") }) { hasTolls = true }
            allSteps.append(contentsOf: leg.steps)
            combinedCoordinates.append(contentsOf: leg.polyline.coordinates)
            legDeparture = legDeparture.addingTimeInterval(scaledLegTime)
        }

        let combinedPolyline = combinedCoordinates.isEmpty ? nil : MKPolyline(coordinates: combinedCoordinates, count: combinedCoordinates.count)
        return LiveRoute(
            name: "Multi-stop route",
            expectedTravelTime: totalTime,
            distance: totalDistance,
            hasTolls: hasTolls,
            highwaySummary: highwayChain(steps: allSteps),
            polyline: combinedPolyline,
            highwayDistanceFraction: highwayDistanceFraction(steps: allSteps, totalDistance: totalDistance)
        )
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

    /// A sample older than this has decayed to roughly half its original weight in
    /// the average — traffic patterns drift (new construction, seasonal changes,
    /// a schedule that's shifted), so a 3-month-old sample shouldn't count exactly
    /// as much as one from last week forever.
    private static let recencyHalfLifeDays = 30.0

    /// Weekday (Mon-Fri) vs weekend (Sat/Sun) — rush-hour patterns repeat across
    /// the whole workweek, so pooling every weekday's samples together gives each
    /// time-of-day bucket far more real data to average than restricting to the
    /// exact same day-of-week (e.g. only Tuesdays) ever would, especially early on
    /// when the store hasn't built up much history yet.
    private static func isWeekday(_ dayOfWeek: Int) -> Bool {
        (2...6).contains(dayOfWeek)
    }

    /// `distinctDaysSampled` is what personal-trust weighting (`blendedMinutes`)
    /// actually keys off, not the raw bucket count below — a single real trip now
    /// logs ~10 checkpoint samples across as many buckets, so counting buckets
    /// would treat one drive as if it were ten independent observations. Counting
    /// distinct calendar days instead means "how many times have you actually
    /// driven this route," which is what personal trust should really track.
    private static func historicalMinutesByBucket(
        routeKey: String, dayOfWeek: Int, modelContext: ModelContext
    ) -> (buckets: [Int: Double], distinctDaysSampled: Int) {
        let descriptor = FetchDescriptor<HistoricalSample>(predicate: #Predicate { $0.routeKey == routeKey })
        guard let allSamples = try? modelContext.fetch(descriptor), !allSamples.isEmpty else { return ([:], 0) }

        let wantWeekday = isWeekday(dayOfWeek)
        let samples = allSamples.filter { isWeekday($0.dayOfWeek) == wantWeekday }
        guard !samples.isEmpty else { return ([:], 0) }

        let calendar = Calendar.current
        let distinctDays = Set(samples.map { calendar.startOfDay(for: $0.recordedAt) }).count

        let now = Date()
        var weightedSums: [Int: Double] = [:]
        var weightTotals: [Int: Double] = [:]
        for sample in samples {
            let ageDays = max(0, now.timeIntervalSince(sample.recordedAt) / 86400)
            let weight = pow(0.5, ageDays / recencyHalfLifeDays)
            weightedSums[sample.minuteOfDayBucket, default: 0] += sample.travelMinutes * weight
            weightTotals[sample.minuteOfDayBucket, default: 0] += weight
        }
        let buckets = weightedSums.reduce(into: [Int: Double]()) { result, entry in
            result[entry.key] = entry.value / weightTotals[entry.key]!
        }
        return (buckets, distinctDays)
    }

    /// Looks up the historical estimate for a specific 5-minute bucket. Bracketed
    /// by two real neighboring samples, it interpolates fully between them (real
    /// data on both sides, fully trusted). With only one neighbor in range, it
    /// fades that lone sample's influence toward `fallback` the further away this
    /// bucket is, rather than repeating that single value flatly across the whole
    /// hour-wide search radius — flat-carrying one lone point was exactly what
    /// produced fake plateaus (with a single fake "jump" right at the search
    /// radius's edge) instead of a real curve.
    private static func interpolatedHistoricalMinutes(at bucket: Int, in history: [Int: Double], fallback: Double) -> Double {
        if let exact = history[bucket] { return exact }
        guard !history.isEmpty else { return fallback }

        let maxSearchMinutes = 60
        var before: (bucket: Int, value: Double)?
        var after: (bucket: Int, value: Double)?
        var offset = 5
        while offset <= maxSearchMinutes {
            if before == nil, let v = history[bucket - offset] { before = (bucket - offset, v) }
            if after == nil, let v = history[bucket + offset] { after = (bucket + offset, v) }
            if before != nil && after != nil { break }
            offset += 5
        }

        func fadeToward(_ point: (bucket: Int, value: Double)) -> Double {
            let distance = Double(abs(bucket - point.bucket))
            let trust = max(0, 1 - distance / Double(maxSearchMinutes))
            return point.value * trust + fallback * (1 - trust)
        }

        switch (before, after) {
        case (let b?, let a?):
            let span = Double(a.bucket - b.bucket)
            guard span > 0 else { return b.value }
            let t = Double(bucket - b.bucket) / span
            return b.value + (a.value - b.value) * t
        case (let b?, nil):
            return fadeToward(b)
        case (nil, let a?):
            return fadeToward(a)
        case (nil, nil):
            return fallback
        }
    }

    // MARK: - Confidence

    /// Folds the user's own 0-5 "how accurate was this?" ratings (History) for
    /// past trips on this exact route into confidence — the only real feedback
    /// signal available, since the app has no background tracking to check its
    /// duration estimates against directly. A single rating is too easily an
    /// outlier to move confidence on its own, so this waits for at least 2.
    /// Deliberately confidence-only, not a correction to the duration estimate
    /// itself — a rating says whether the estimate felt right, not by how much or
    /// which direction it was wrong, so there's nothing honest to recompute the
    /// actual minutes from.
    private static func accuracyConfidenceAdjustment(routeKey: String, modelContext: ModelContext) -> Int {
        guard !routeKey.isEmpty else { return 0 }
        let descriptor = FetchDescriptor<LoggedTrip>(predicate: #Predicate { $0.routeKey == routeKey })
        guard let trips = try? modelContext.fetch(descriptor) else { return 0 }
        let ratings = trips.compactMap(\.accuracyRating)
        guard ratings.count >= 2 else { return 0 }
        let average = Double(ratings.reduce(0, +)) / Double(ratings.count)
        // 2.5/5 average is treated as neutral (no adjustment). Below neutral pulls
        // confidence down harder than above neutral pulls it up — a run of
        // inaccurate ratings on this exact route is a stronger warning sign than a
        // run of accurate ones is a reason for extra confidence. Final clamping at
        // the call site keeps this from pushing confidence outside its normal bounds.
        let delta = average - 2.5
        return Int((delta >= 0 ? delta * 4 : delta * 8).rounded())
    }

    private static func confidenceScore(best: Double, all: [Double]) -> Int {
        let mean = all.reduce(0, +) / Double(all.count)
        let variance = all.reduce(0) { $0 + pow($1 - mean, 2) } / Double(all.count)
        let stdDev = sqrt(variance)
        let z = stdDev > 0 ? (mean - best) / stdDev : 0
        return Int(min(97, max(40, 60 + z * 18)))
    }

    // MARK: - Route options

    private static func buildRouteOptions(
        liveRoutes: [LiveRoute]?, fallbackMinutes: Double, straightLineMiles: Double, timeFactor: Double
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

        var scored: [(route: LiveRoute, minutes: Double)] = liveRoutes.map { route in
            let sensitivity = trafficSensitivity(for: route)
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
                summary: pair.route.name ?? "Route \(index + 1)",
                durationMinutes: Int(pair.minutes.rounded()),
                distanceMiles: pair.route.distance / 1609.34,
                condition: condition,
                delayNote: delay,
                isFastest: index == 0,
                hasTolls: pair.route.hasTolls,
                fullRouteSummary: pair.route.highwaySummary,
                polyline: pair.route.polyline
            )
        }
    }

    /// Extracts numbered highways (I-680, US-101, CA-84, SR-84, ...) from turn-by-turn
    /// step instructions, in order, collapsing consecutive repeats — MapKit's own
    /// `route.name` often only names the primary highway, not the full chain.
    private static func highwayChain(steps: [MKRoute.Step]) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:I|US|CA|SR)-\d+(?:\s[NSEW])?\b"#) else { return nil }
        var found: [String] = []
        for step in steps {
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

    /// Fraction of the route's total distance spent on a step tagged as a
    /// numbered highway — the measurable, per-route input to `trafficSensitivity`.
    private static func highwayDistanceFraction(steps: [MKRoute.Step], totalDistance: CLLocationDistance) -> Double {
        guard totalDistance > 0, let regex = try? NSRegularExpression(pattern: #"\b(?:I|US|CA|SR)-\d+(?:\s[NSEW])?\b"#) else { return 0 }
        var highwayDistance: CLLocationDistance = 0
        for step in steps {
            let text = step.instructions
            guard !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                highwayDistance += step.distance
            }
        }
        return min(1, highwayDistance / totalDistance)
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
