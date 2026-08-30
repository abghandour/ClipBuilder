import SwiftUI
import Charts

/// Follower count over time — the web report's "Account Growth" line.
struct FollowerLineChart: View {
    let series: [InstagramReport.DatedValue]

    var body: some View {
        if series.count < 2 {
            EmptyNote(text: "Follower history builds up with each Refresh (or import the peace-grappler history in Settings).")
        } else {
            let values = series.map(\.value)
            let low = (values.min() ?? 0), high = (values.max() ?? 0)
            let pad = max(5, (high - low) * 0.15)
            Chart(series) { point in
                AreaMark(x: .value("Date", point.date), y: .value("Followers", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [ReportColors.accent.opacity(0.35),
                                                             ReportColors.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", point.date), y: .value("Followers", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(ReportColors.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYScale(domain: max(0, low - pad)...(high + pad))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            } }
            .chartYAxis { AxisMarks { value in
                AxisGridLine(); AxisValueLabel {
                    if let number = value.as(Double.self) { Text(Int(number).compactFormatted) }
                }
            } }
            .frame(height: 220)
        }
    }
}

/// New followers per day (day-over-day gains).
struct NewFollowersChart: View {
    let series: [InstagramReport.DatedValue]

    var body: some View {
        if series.isEmpty {
            EmptyNote(text: "No daily follower data for this period yet.")
        } else {
            Chart(series) { point in
                BarMark(x: .value("Date", point.date, unit: .day), y: .value("New followers", point.value))
                    .foregroundStyle(ReportColors.accent)
                    .cornerRadius(2)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            } }
            .frame(height: 160)
        }
    }
}

/// Daily reach/views or likes/comments/saves/shares lines for posts or reels.
struct DailyTrendChart: View {
    struct Series: Identifiable {
        var label: String
        var color: Color
        var keyPath: KeyPath<InstagramReport.DailyPoint, Int>
        var id: String { label }
    }

    let points: [InstagramReport.DailyPoint]
    let series: [Series]

    private struct Sample: Identifiable {
        var date: Date
        var label: String
        var value: Int
        var id: String { "\(label)-\(date.timeIntervalSince1970)" }
    }

    private var samples: [Sample] {
        points.flatMap { point in series.map { Sample(date: point.date, label: $0.label, value: point[keyPath: $0.keyPath]) } }
    }

    var body: some View {
        if points.isEmpty {
            EmptyNote(text: "No posts in this period.")
        } else {
            Chart(samples) { sample in
                LineMark(x: .value("Date", sample.date, unit: .day), y: .value("Value", sample.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value("Metric", sample.label))
                PointMark(x: .value("Date", sample.date, unit: .day), y: .value("Value", sample.value))
                    .symbolSize(18)
                    .foregroundStyle(by: .value("Metric", sample.label))
            }
            .chartForegroundStyleScale(domain: series.map(\.label), range: series.map(\.color))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            } }
            .chartYAxis { AxisMarks { value in
                AxisGridLine(); AxisValueLabel {
                    if let number = value.as(Double.self) { Text(Int(number).compactFormatted) }
                }
            } }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 200)
        }
    }
}

/// Donut of posts by type, with a legend.
struct ContentMixDonut: View {
    let items: [InstagramReport.LabeledValue]

    var body: some View {
        if items.isEmpty {
            EmptyNote(text: "No posts in this period.")
        } else {
            HStack(spacing: Theme.spaceL) {
                Chart(items) { item in
                    SectorMark(angle: .value("Posts", item.value), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .cornerRadius(3)
                        .foregroundStyle(ReportColors.forType(item.label))
                }
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Circle().fill(ReportColors.forType(item.label)).frame(width: 8, height: 8)
                            Text(item.label).font(.caption)
                            Text(item.intValue.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Reach per post in chronological order, colored by type.
struct ReachPerPostBars: View {
    let bars: [InstagramReport.ReachBar]

    var body: some View {
        if bars.isEmpty {
            EmptyNote(text: "No reach data for this period.")
        } else {
            Chart(Array(bars.enumerated()), id: \.element.id) { index, bar in
                BarMark(x: .value("Post", index), y: .value("Reach", bar.reach))
                    .foregroundStyle(by: .value("Type", bar.type))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: Array(Set(bars.map(\.type))).sorted(),
                                       range: Array(Set(bars.map(\.type))).sorted().map(ReportColors.forType))
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { value in
                AxisGridLine(); AxisValueLabel {
                    if let number = value.as(Double.self) { Text(Int(number).compactFormatted) }
                }
            } }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 180)
        }
    }
}

/// Vertical bars per age bucket.
struct AgeBars: View {
    let items: [InstagramReport.LabeledValue]
    var color = ReportColors.accent

    var body: some View {
        if items.isEmpty {
            EmptyNote(text: "No demographics yet — they arrive with the next Refresh of the connected account.")
        } else {
            Chart(items) { item in
                BarMark(x: .value("Age", item.label), y: .value("Followers", item.value))
                    .foregroundStyle(color)
                    .cornerRadius(3)
                    .annotation(position: .top) {
                        Text(item.intValue.compactFormatted).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartYAxis { AxisMarks { value in
                AxisGridLine(); AxisValueLabel {
                    if let number = value.as(Double.self) { Text(Int(number).compactFormatted) }
                }
            } }
            .frame(height: 200)
        }
    }
}

/// Gender split donut with percentage tiles.
struct GenderDonut: View {
    let items: [InstagramReport.LabeledValue]

    private func color(_ label: String) -> Color {
        switch label {
        case "Male": return ReportColors.accent
        case "Female": return ReportColors.pink
        default: return ReportColors.green
        }
    }

    var body: some View {
        if items.isEmpty {
            EmptyNote(text: "No gender data yet.")
        } else {
            let total = items.reduce(0) { $0 + $1.value }
            HStack(spacing: Theme.spaceL) {
                Chart(items) { item in
                    SectorMark(angle: .value("Followers", item.value), innerRadius: .ratio(0.55), angularInset: 1.5)
                        .cornerRadius(3)
                        .foregroundStyle(color(item.label))
                }
                .frame(width: 140, height: 140)
                HStack(spacing: Theme.spaceL) {
                    ForEach(items) { item in
                        VStack(spacing: 2) {
                            Text(total > 0 ? String(format: "%.0f%%", item.value / total * 100) : "–")
                                .font(.title3.bold().monospacedDigit())
                                .foregroundStyle(color(item.label))
                            Text(item.label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Horizontal bars (Ad / Feed / Reel / Story, follower vs non-follower).
struct BreakdownBarChart: View {
    let items: [InstagramReport.LabeledValue]
    var colors: [Color] = ReportColors.series

    var body: some View {
        if items.isEmpty {
            EmptyNote(text: "No breakdown for this period.")
        } else {
            Chart(Array(items.enumerated()), id: \.element.id) { index, item in
                BarMark(x: .value("Value", item.value), y: .value("Type", item.label))
                    .foregroundStyle(colors[index % colors.count])
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text(item.intValue.compactFormatted).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { _ in AxisValueLabel() } }
            .frame(height: CGFloat(items.count) * 26 + 10)
        }
    }
}
