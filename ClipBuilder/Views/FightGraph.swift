import SwiftUI

/// Fight activity graph rendered from the scored fight events, split at a
/// center line — one fighter's activity grows toward the TOP, the other's
/// toward the BOTTOM. Each curve shows how much action that fighter is
/// landing RIGHT NOW: a landed action adds its points and fades out over
/// the next 3 seconds, so 3s without action brings the score back to zero.
/// Taller reach = more action from that fighter; both curves flat on the
/// center line = nothing is happening.
struct FightGraphView: View {
    let events: [FightEventRecord]
    /// Source-time window displayed.
    let range: ClosedRange<Double>
    /// People registry, for fighter names in the legend.
    var people: [PersonRecord] = []
    var height: CGFloat = 72
    var showsLegend = true
    /// Tap-to-seek (source seconds); nil = inert graph.
    var onSeek: ((Double) -> Void)?

    /// A landed action fades out linearly over this many seconds — with no
    /// follow-up action the score is back at zero when the window elapses.
    private static let activityWindow: Double = 3.0
    /// Top fighter, bottom fighter.
    private static let topColor: Color = .red
    private static let bottomColor: Color = .cyan

    private var span: Double { max(1, range.upperBound - range.lowerBound) }

    private var visible: [FightEventRecord] {
        events.filter { $0.time >= range.lowerBound && $0.time <= range.upperBound }
    }

    /// Buckets well under the 3s fade window, so a burst of action and its
    /// decay back to zero are both visible even on long videos.
    private var bucketCount: Int {
        max(48, min(600, Int(span / 0.5)))
    }

    private func name(for key: String) -> String {
        people.first { $0.key == key }?.displayName ?? key
    }

    // MARK: - Activity model

    private struct Activity {
        var topKey: String
        var bottomKey: String
        /// Total action points over the visible range — the "who did the
        /// most" tally in the legend.
        var topTotal: Double
        var bottomTotal: Double
        /// Per-bucket current activity for each side (≥0).
        var top: [Double]
        var bottom: [Double]
        var peak: Double
    }

    /// Sample each fighter's current activity into buckets: every landed
    /// action contributes its points, fading linearly to zero over the 3s
    /// window — so a lull reads as both curves sitting on the center line.
    private func activity() -> Activity? {
        let attributed = visible.filter { !$0.fighterKey.isEmpty }.sorted { $0.time < $1.time }
        // The two fighters carrying the most action own the two sides; a
        // third detected person (rare) is ignored in the split view.
        var totals: [String: Double] = [:]
        for event in attributed { totals[event.fighterKey, default: 0] += event.points }
        let ranked = totals.sorted { $0.value > $1.value }.map(\.key)
        guard let topKey = ranked.first else { return nil }
        let bottomKey = ranked.count > 1 ? ranked[1] : ""

        let count = bucketCount
        var top = [Double](repeating: 0, count: count)
        var bottom = [Double](repeating: 0, count: count)
        // Only events inside the fade window matter at each sample time;
        // both bounds advance monotonically as the sample time moves.
        var firstLive = 0
        for bucket in 0..<count {
            let sampleTime = range.lowerBound + span * Double(bucket + 1) / Double(count)
            while firstLive < attributed.count,
                  attributed[firstLive].time < sampleTime - Self.activityWindow {
                firstLive += 1
            }
            var index = firstLive
            while index < attributed.count, attributed[index].time <= sampleTime {
                let event = attributed[index]
                let weight = 1 - (sampleTime - event.time) / Self.activityWindow
                if event.fighterKey == topKey {
                    top[bucket] += event.points * weight
                } else if event.fighterKey == bottomKey {
                    bottom[bucket] += event.points * weight
                }
                index += 1
            }
        }
        let peak = max(1, top.max() ?? 1, bottom.max() ?? 1)
        return Activity(topKey: topKey, bottomKey: bottomKey,
                        topTotal: totals[topKey] ?? 0,
                        bottomTotal: bottomKey.isEmpty ? 0 : totals[bottomKey] ?? 0,
                        top: top, bottom: bottom, peak: peak)
    }

    // MARK: - View

    var body: some View {
        let model = activity()
        return VStack(alignment: .leading, spacing: 3) {
            if showsLegend, let model {
                HStack(spacing: 10) {
                    legendChip(name(for: model.topKey), score: model.topTotal,
                               color: Self.topColor, up: true)
                    if !model.bottomKey.isEmpty {
                        legendChip(name(for: model.bottomKey), score: model.bottomTotal,
                                   color: Self.bottomColor, up: false)
                    }
                    Spacer()
                }
            }
            GeometryReader { geo in
                let size = geo.size
                let mid = size.height / 2
                ZStack {
                    // Center baseline (even momentum).
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: mid))
                        path.addLine(to: CGPoint(x: size.width, y: mid))
                    }
                    .stroke(.secondary.opacity(0.4), lineWidth: 1)

                    if let model {
                        divergingArea(values: model.top, peak: model.peak, size: size, up: true)
                            .fill(Self.topColor.opacity(0.28))
                        divergingLine(values: model.top, peak: model.peak, size: size, up: true)
                            .stroke(Self.topColor, lineWidth: 1.5)
                        if !model.bottomKey.isEmpty {
                            divergingArea(values: model.bottom, peak: model.peak, size: size, up: false)
                                .fill(Self.bottomColor.opacity(0.28))
                            divergingLine(values: model.bottom, peak: model.peak, size: size, up: false)
                                .stroke(Self.bottomColor, lineWidth: 1.5)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard let onSeek, size.width > 0 else { return }
                    onSeek(range.lowerBound + span * Double(location.x / size.width))
                }
            }
            .frame(height: height)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if model == nil {
                    Text("No attributed fight action in this range")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .help("Fight activity: each fighter fills their half from the center line. A landed action lifts their curve and fades out over 3 seconds, so with no action the score falls back to zero — flat stretches on the center line are lulls, and whoever reaches further is doing the most at that moment. The legend shows each fighter's total action points for the range.")
    }

    private func legendChip(_ name: String, score: Double, color: Color, up: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 7))
                .foregroundStyle(color)
            Text("\(name) \(Int(score))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Filled area between the center line and one fighter's activity curve,
    /// growing up (toward y=0) or down (toward y=height).
    private func divergingArea(values: [Double], peak: Double, size: CGSize, up: Bool) -> Path {
        let mid = size.height / 2
        return Path { path in
            path.move(to: CGPoint(x: 0, y: mid))
            for (index, value) in values.enumerated() {
                path.addLine(to: point(index: index, value: value, count: values.count,
                                       peak: peak, size: size, up: up))
            }
            path.addLine(to: CGPoint(x: size.width, y: mid))
            path.closeSubpath()
        }
    }

    private func divergingLine(values: [Double], peak: Double, size: CGSize, up: Bool) -> Path {
        Path { path in
            for (index, value) in values.enumerated() {
                let p = point(index: index, value: value, count: values.count,
                              peak: peak, size: size, up: up)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }

    private func point(index: Int, value: Double, count: Int, peak: Double,
                       size: CGSize, up: Bool) -> CGPoint {
        let mid = size.height / 2
        let x = size.width * CGFloat(index) / CGFloat(max(1, count - 1))
        let reach = CGFloat(value / peak) * mid * 0.92
        return CGPoint(x: x, y: up ? mid - reach : mid + reach)
    }
}

extension FightGraphView {
    /// Per-bucket pace values (total action volume) for sparkline hosts — the
    /// trim slider and Builder clip chips draw their own path from this. Pace
    /// stays volume-based (who lands doesn't matter) so it reads as "how much
    /// action is in this range" while trimming.
    static func paceCurve(events: [FightEventRecord], start: Double, end: Double,
                          buckets: Int) -> [Double] {
        let span = max(0.1, end - start)
        let count = max(2, buckets)
        var values = [Double](repeating: 0, count: count)
        var any = false
        for event in events where event.time >= start && event.time <= end {
            let index = min(count - 1, max(0, Int((event.time - start) / span * Double(count))))
            values[index] += event.points
            any = true
        }
        return any ? values : []
    }
}
