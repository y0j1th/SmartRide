//
//  LocationManager.swift
//  SmartRide
//
//  Wraps CLLocationManager so the From field can default to (or be reset to) the
//  device's real current location, matching how Google/Apple Maps behave.
//
//  A single `requestLocation()` call from CLLocationManager often hands back a
//  fast but coarse fix (cell/WiFi-based, sometimes hundreds of meters off, or an
//  outright stale cached one) — enough to look like "a different location"
//  entirely once it's swapped into an address. Instead this keeps the GPS radio
//  on for a short window, discards stale/low-confidence fixes, and only settles
//  once a genuinely precise one arrives (or the window times out).

import Foundation
import CoreLocation
import Combine

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var timeoutTask: Task<Void, Never>?

    /// Once a fix is at least this precise, stop refining — no need to keep the
    /// GPS radio spinning for accuracy the app doesn't need.
    private let accuracyTargetMeters: Double = 50
    /// Give up waiting for a better fix after this long (e.g. indoors/underground
    /// where GPS never locks) and just use whatever arrived.
    private let maxWaitSeconds: UInt64 = 8

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startRefining()
        default:
            break
        }
    }

    private func startRefining() {
        timeoutTask?.cancel()
        manager.startUpdatingLocation()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.maxWaitSeconds ?? 8) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.manager.stopUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            startRefining()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        // A cached fix from before this request (e.g. from app launch, or a
        // previous location) reads as "stale" here and is skipped — only a fix
        // produced by this active request should ever set the current location.
        guard abs(location.timestamp.timeIntervalSinceNow) < 5 else { return }

        currentLocation = location
        if location.horizontalAccuracy <= accuracyTargetMeters {
            timeoutTask?.cancel()
            manager.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silently ignore — the From field just stays whatever the user typed/left blank.
    }
}
