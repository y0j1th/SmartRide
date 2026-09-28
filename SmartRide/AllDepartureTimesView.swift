//
//  AllDepartureTimesView.swift
//  SmartRide
//
//  "View All Times" — the next 90 minutes at 10-minute intervals, as a chart +
//  list, reached from a button on the LEAVE AT card rather than shown inline on
//  Home. The engine's full 2.5-hour, 5-minute-granularity window still exists and
//  drives the actual recommendation and Traffic Cliff detection — this view is
//  just scoped to what's realistically useful to look at when picking a
//  departure right now.
//

import SwiftUI
import Charts

struct AllDepartureTimesView: View {
    let recommendation: Recommendation
    @Environment(\.dismiss) private var dismiss

    /// The next 10 points, 10 minutes apart (now through +90 min) — the full
    /// 2.5-hour, 5-minute-granularity window is still what the underlying
    /// recommendation and Traffic Cliff detection use internally; this view is
    /// scoped to what's actually useful for picking a departure right now, since
    /// almost nobody is realistically choosing between leaving now and leaving in
    /// two hours.
    private var displayedCandidates: [CandidateResult] {
        guard let first = recommendation.candidates.first else { return [] }
        return recommendation.candidates
            .filter { Int(($0.time.timeIntervalSince(first.time) / 60).rounded()) % 10 == 0 }
            .prefix(10)
            .map { $0 }
    }

    /// The best option within this near-term window specifically — may differ
    /// from `recommendation.recommendedTime` (the true best across the full
    /// 2.5-hour window, already shown on Home's main card), since that pick can
    /// fall outside the next 90 minutes shown here.
    private var bestDisplayedCandidate: CandidateResult? {
        displayedCandidates.min { $0.durationMinutes < $1.durationMinutes }
    }

    private var bestDuration: Int {
        bestDisplayedCandidate?.durationMinutes ?? recommendation.expectedDurationMinutes
    }

    private var worstDuration: Int {
        displayedCandidates.map(\.durationMinutes).max() ?? recommendation.expectedDurationMinutes
    }

    private var leaveNowDuration: Int { recommendation.leaveNowDurationMinutes }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    chart
                    legend
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

    /// The single most important fact up top, in plain language, before any chart
    /// or list — so it's obvious at a glance whether the engine actually found a
    /// meaningfully better time, not just something you have to infer from bar heights.
    private var summaryCard: some View {
        let saved = max(0, leaveNowDuration - bestDuration)
        return VStack(alignment: .leading, spacing: 6) {
            if saved >= 2 {
                Label("Best option saves \(Recommendation.minutesPhrase(saved)) vs. leaving now", systemImage: "arrow.down.right.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Label("Right now is already about as good as it gets", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Leaving now: \(Recommendation.minutesText(leaveNowDuration)) · Best: \(Recommendation.minutesText(bestDuration))\(bestDisplayedCandidate.map { " at \($0.timeText)" } ?? "") · \(recommendation.confidencePercent)% confidence")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A line, not bars — a 1-3 minute difference between neighboring 5-minute
    /// candidates barely registers as a bar-height difference at a glance, but
    /// reads immediately as a rising/falling curve. The Y-axis is scaled tightly
    /// to the actual min/max in this window (not from 0) specifically so small,
    /// real differences aren't visually flattened away.
    private var chart: some View {
        let padding = max(2, Int(Double(worstDuration - bestDuration) * 0.15))
        let bestTime = bestDisplayedCandidate?.time
        return Chart {
            ForEach(displayedCandidates) { candidate in
                LineMark(
                    x: .value("Time", candidate.time),
                    y: .value("Minutes", candidate.durationMinutes)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Time", candidate.time),
                    y: .value("Minutes", candidate.durationMinutes)
                )
                .symbolSize(candidate.time == bestTime ? 90 : 22)
                .foregroundStyle(candidate.time == bestTime ? Color.accentColor : condition(for: candidate).color)
            }

            RuleMark(y: .value("Leave now", leaveNowDuration))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .leading) {
                    Text("Leaving now")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            if let cliffTime = recommendation.trafficCliffTime,
               let windowStart = displayedCandidates.first?.time, let windowEnd = displayedCandidates.last?.time,
               cliffTime >= windowStart, cliffTime <= windowEnd {
                RuleMark(x: .value("Traffic Cliff", cliffTime))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(.orange)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Cliff")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 20)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                if let minutes = value.as(Int.self) {
                    AxisGridLine()
                    AxisValueLabel("\(minutes)m")
                }
            }
        }
        .chartYScale(domain: (bestDuration - padding)...(worstDuration + padding))
        .frame(height: 200)
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([TrafficCondition.light, .moderate, .congested], id: \.self) { condition in
                HStack(spacing: 4) {
                    Circle().fill(condition.color).frame(width: 8, height: 8)
                    Text(condition.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Leave at")
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(displayedCandidates) { candidate in
                let isBest = candidate.time == bestDisplayedCandidate?.time
                let delta = candidate.durationMinutes - leaveNowDuration
                HStack {
                    Circle()
                        .fill(condition(for: candidate).color)
                        .frame(width: 8, height: 8)
                    Text(candidate.timeText)
                        .font(.subheadline)
                    Spacer()
                    Text(deltaText(delta))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(delta <= -2 ? .green : (delta >= 2 ? .red : .secondary))
                    Text(Recommendation.minutesText(candidate.durationMinutes))
                        .font(.subheadline.weight(isBest ? .bold : .regular))
                        .frame(minWidth: 44, alignment: .trailing)
                    if isBest {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, isBest ? 8 : 0)
                .padding(.vertical, 6)
                .background(
                    isBest ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                Divider()
            }

            Text("Updated now")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    /// "vs. leaving now" for every row, not just the recommended one — this is
    /// what actually lets you tell the engine is differentiating between times
    /// rather than just showing a wall of similar-looking numbers.
    private func deltaText(_ delta: Int) -> String {
        if delta <= -1 { return "\(-delta)m faster" }
        if delta >= 1 { return "\(delta)m slower" }
        return "same"
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
