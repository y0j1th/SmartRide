//
//  AllDepartureTimesView.swift
//  SmartRide
//
//  "View All Times" — the full continuous prediction window as a chart + list,
//  reached from a button on the LEAVE AT card rather than shown inline on Home.
//

import SwiftUI
import Charts

struct AllDepartureTimesView: View {
    let recommendation: Recommendation
    @Environment(\.dismiss) private var dismiss

    private var bestDuration: Int {
        recommendation.candidates.map(\.durationMinutes).min() ?? recommendation.expectedDurationMinutes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    chart
                    listSection
                }
                .padding()
            }
            .navigationTitle("All Departure Times")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var chart: some View {
        Chart(recommendation.candidates) { candidate in
            BarMark(
                x: .value("Time", candidate.time),
                y: .value("Minutes", candidate.durationMinutes)
            )
            .foregroundStyle(candidate.time == recommendation.recommendedTime ? Color.accentColor : condition(for: candidate).color)
            .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                if let minutes = value.as(Int.self) {
                    AxisValueLabel("\(minutes)m")
                }
            }
        }
        .frame(height: 180)
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Leave at")
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(recommendation.candidates) { candidate in
                let isBest = candidate.time == recommendation.recommendedTime
                HStack {
                    Circle()
                        .fill(condition(for: candidate).color)
                        .frame(width: 8, height: 8)
                    Text(candidate.timeText)
                        .font(.subheadline)
                    Spacer()
                    Text(Recommendation.minutesText(candidate.durationMinutes))
                        .font(.subheadline.weight(isBest ? .bold : .regular))
                    if isBest {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }

            Text("Updated now")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func condition(for candidate: CandidateResult) -> TrafficCondition {
        let ratio = Double(candidate.durationMinutes) / Double(max(bestDuration, 1))
        if ratio <= 1.05 { return .light }
        if ratio <= 1.3 { return .moderate }
        return .congested
    }
}

#Preview {
    AllDepartureTimesView(recommendation: Recommendation(
        referenceNow: .now, mode: .departAt, recommendedTime: .now, expectedDurationMinutes: 33,
        durationRangeMinutes: 28...42, arrivalTime: .now, timeSavedMinutes: 9, leaveNowDurationMinutes: 42,
        confidencePercent: 82, isFallback: false, alreadyOptimal: false, routes: [], candidates: [
            CandidateResult(time: .now, durationMinutes: 42),
            CandidateResult(time: .now.addingTimeInterval(600), durationMinutes: 33),
            CandidateResult(time: .now.addingTimeInterval(1200), durationMinutes: 38),
        ],
        originCoordinate: nil, destinationCoordinate: nil, routePolyline: nil,
        targetArrival: nil, latestSafeDeparture: nil, reliabilityPercent: nil
    ))
}
