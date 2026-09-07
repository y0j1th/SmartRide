//
//  RouteMapView.swift
//  SmartRide
//
//  Route map for the top of the Home screen — shows the origin/destination pins
//  and, once a recommendation has been computed, every route alternative (selected
//  one highlighted). Fully interactive: pan/zoom, and tapping a route line on the
//  map selects it, same as tapping its card in the list below.
//

import SwiftUI
import MapKit

struct RouteMapView: View {
    let originCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
    let routes: [RouteOption]
    let selectedRouteID: UUID?
    var onSelectRoute: ((UUID) -> Void)? = nil

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: .init(latitude: 37.4, longitude: -121.9), span: .init(latitudeDelta: 1.2, longitudeDelta: 1.2))
    )

    private var selectedPolyline: MKPolyline? {
        (routes.first { $0.id == selectedRouteID } ?? routes.first)?.polyline
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                if let originCoordinate {
                    Marker("From", systemImage: "circle.fill", coordinate: originCoordinate).tint(.blue)
                }
                if let destinationCoordinate {
                    Marker("To", systemImage: "mappin", coordinate: destinationCoordinate).tint(.orange)
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
            }
            .mapStyle(.standard(elevation: .flat))
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard routes.count > 1, let onSelectRoute else { return }
                    guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                    if let match = closestRoute(to: coordinate) {
                        onSelectRoute(match)
                    }
                }
            )
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { updateCamera() }
        .onChange(of: selectedPolyline) { _, _ in updateCamera() }
        .onChange(of: originCoordinate) { _, _ in updateCamera() }
        .onChange(of: destinationCoordinate) { _, _ in updateCamera() }
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
