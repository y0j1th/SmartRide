//
//  RouteMapView.swift
//  SmartRide
//
//  Route map for the top of the Home screen — shows the origin/destination pins
//  and, once a recommendation has been computed, every route alternative (selected
//  one highlighted). Fully interactive: pan/zoom, and tapping a route line on the
//  map selects it, same as tapping its card in the list below. Can be expanded to
//  a full-screen map (with a center-on-current-location button) and minimized
//  back down. While expanded, tapping anywhere that isn't a route line drops a
//  pin the user can confirm as either end of the trip — picking a place visually
//  instead of typing it.
//

import SwiftUI
import MapKit

struct RouteMapView: View {
    let originCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
    var stopCoordinates: [CLLocationCoordinate2D] = []
    let routes: [RouteOption]
    let selectedRouteID: UUID?
    var onSelectRoute: ((UUID) -> Void)? = nil
    var onPickOrigin: ((CLLocationCoordinate2D) -> Void)? = nil
    var onPickDestination: ((CLLocationCoordinate2D) -> Void)? = nil

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: .init(latitude: 37.4, longitude: -121.9), span: .init(latitudeDelta: 1.2, longitudeDelta: 1.2))
    )
    @State private var isExpanded = false
    @State private var awaitingLocationCenter = false
    @State private var pickedCoordinate: CLLocationCoordinate2D?
    @StateObject private var locationManager = LocationManager()

    private var selectedPolyline: MKPolyline? {
        (routes.first { $0.id == selectedRouteID } ?? routes.first)?.polyline
    }

    var body: some View {
        mapContent(allowsDestinationPicking: false)
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                expandCollapseButton(expand: true)
                    .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                miniCenterOnLocationButton
                    .padding(10)
            }
            .onAppear { updateCamera() }
            .onChange(of: selectedPolyline) { _, _ in updateCamera() }
            .onChange(of: originCoordinate) { _, _ in updateCamera() }
            .onChange(of: destinationCoordinate) { _, _ in updateCamera() }
            .onReceive(locationManager.$currentLocation) { location in
                guard let location, awaitingLocationCenter else { return }
                awaitingLocationCenter = false
                centerCamera(on: location.coordinate)
            }
            .fullScreenCover(isPresented: $isExpanded) {
                expandedMap
            }
    }

    private var expandedMap: some View {
        ZStack(alignment: .topLeading) {
            mapContent(allowsDestinationPicking: onPickOrigin != nil || onPickDestination != nil)
                .ignoresSafeArea()

            expandCollapseButton(expand: false)
                .padding(.top, 54)
                .padding(.leading, 16)

            VStack {
                Spacer()
                if pickedCoordinate != nil {
                    pickedLocationConfirmBar
                } else {
                    HStack {
                        Spacer()
                        centerOnLocationButton
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .onDisappear { pickedCoordinate = nil }
    }

    private func mapContent(allowsDestinationPicking: Bool) -> some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                if let originCoordinate {
                    Marker("From", systemImage: "circle.fill", coordinate: originCoordinate).tint(.blue)
                }
                if let destinationCoordinate {
                    Marker("To", systemImage: "mappin", coordinate: destinationCoordinate).tint(.orange)
                }
                ForEach(Array(stopCoordinates.enumerated()), id: \.offset) { index, coordinate in
                    Marker("Stop \(index + 1)", systemImage: "mappin.and.ellipse", coordinate: coordinate).tint(.purple)
                }
                // Unselected alternatives first (dimmed, thin), selected route last (drawn on top).
                ForEach(routes.filter { $0.id != (selectedRouteID ?? routes.first?.id) }) { route in
                    if let polyline = route.polyline {
                        MapPolyline(polyline)
                            .stroke(Color(.systemGray2), lineWidth: 3)
                    }
                }
                if let selectedPolyline {
                    MapPolyline(selectedPolyline)
                        .stroke(Color.accentColor, lineWidth: 5)
                }
                if let location = locationManager.currentLocation {
                    Marker("You", systemImage: "location.fill", coordinate: location.coordinate).tint(.blue)
                }
                if let pickedCoordinate {
                    Marker("Selected", systemImage: "mappin.circle.fill", coordinate: pickedCoordinate).tint(.red)
                }
            }
            .mapStyle(.standard(elevation: .flat, showsTraffic: true))
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                    if routes.count > 1, let onSelectRoute, let match = closestRoute(to: coordinate) {
                        onSelectRoute(match)
                    } else if allowsDestinationPicking {
                        pickedCoordinate = coordinate
                    }
                }
            )
        }
    }

    private var pickedLocationConfirmBar: some View {
        HStack(spacing: 10) {
            Button {
                pickedCoordinate = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(14)
                    .background(.regularMaterial, in: Circle())
            }

            if onPickOrigin != nil {
                Button {
                    confirmPicked(asOrigin: true)
                } label: {
                    Text("Set as Origin")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.regularMaterial, in: Capsule())
                }
            }

            if onPickDestination != nil {
                Button {
                    confirmPicked(asOrigin: false)
                } label: {
                    Text("Set as Destination")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func confirmPicked(asOrigin: Bool) {
        guard let pickedCoordinate else { return }
        if asOrigin {
            onPickOrigin?(pickedCoordinate)
        } else {
            onPickDestination?(pickedCoordinate)
        }
        self.pickedCoordinate = nil
        isExpanded = false
    }

    private func expandCollapseButton(expand: Bool) -> some View {
        Button {
            isExpanded = expand
        } label: {
            Image(systemName: expand ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.45), in: Circle())
        }
    }

    private var centerOnLocationButton: some View {
        Button {
            centerOnCurrentLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(14)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
    }

    private var miniCenterOnLocationButton: some View {
        Button {
            centerOnCurrentLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
    }

    private func centerOnCurrentLocation() {
        if let location = locationManager.currentLocation {
            centerCamera(on: location.coordinate)
        } else {
            awaitingLocationCenter = true
            locationManager.requestLocation()
        }
    }

    private func centerCamera(on coordinate: CLLocationCoordinate2D) {
        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .region(
                MKCoordinateRegion(center: coordinate, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
            )
        }
    }

    /// Nearest route line to a tapped map coordinate, by minimum distance to any
    /// vertex (a close-enough approximation given route polylines are densely
    /// sampled) — nil if nothing is within a reasonable tap tolerance.
    private func closestRoute(to coordinate: CLLocationCoordinate2D) -> UUID? {
        let tapPoint = MKMapPoint(coordinate)
        var best: (id: UUID, distance: Double)?
        for route in routes {
            guard let polyline = route.polyline else { continue }
            let points = polyline.points()
            var minDistance = Double.greatestFiniteMagnitude
            for i in 0..<polyline.pointCount {
                let distance = tapPoint.distance(to: points[i])
                if distance < minDistance { minDistance = distance }
            }
            if best == nil || minDistance < best!.distance {
                best = (route.id, minDistance)
            }
        }
        guard let best, best.distance < 500 else { return nil }
        return best.id
    }

    private func updateCamera() {
        if let selectedPolyline {
            let rect = selectedPolyline.boundingMapRect
            let padded = rect.insetBy(dx: -rect.width * 0.18, dy: -rect.height * 0.18)
            cameraPosition = .rect(padded)
        } else if let originCoordinate, let destinationCoordinate {
            var region = MKCoordinateRegion(
                center: .init(
                    latitude: (originCoordinate.latitude + destinationCoordinate.latitude) / 2,
                    longitude: (originCoordinate.longitude + destinationCoordinate.longitude) / 2
                ),
                span: .init(
                    latitudeDelta: max(0.05, abs(originCoordinate.latitude - destinationCoordinate.latitude) * 1.6),
                    longitudeDelta: max(0.05, abs(originCoordinate.longitude - destinationCoordinate.longitude) * 1.6)
                )
            )
            region.span.latitudeDelta = min(region.span.latitudeDelta, 3)
            region.span.longitudeDelta = min(region.span.longitudeDelta, 3)
            cameraPosition = .region(region)
        }
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}
