import SwiftUI

/// Fight momentum graph rendered from the scored fight events: a diverging
/// "tug of war" between the two fighters. The graph is split at a center
/// line — the leader's momentum grows toward the TOP, the opponent's toward
/// the BOTTOM. Each landed action is zero-sum (it raises the striker and
/// takes from the opponent, floored at zero), and consecutive actions by the
/// same fighter escalate (a combo: 1pt, then 2pt, 3pt…) until a >3s lull or
/// the opponent lands, which resets that fighter's combo to 1. Divergence
/// toward one side = that fighter has the momentum.
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

    /// A landed action's combo continues only if the same fighter landed
    /// again within this window with no opponent action in between.
    private static let comboWindow: Double = 3.0
    /// Top fighter, bottom fighter.
    private static let topColor: Color = .red
    private static let bottomColor: Color = .cyan

    private var span: Double { max(1, range.upperBound - range.lowerBound) }

    private var visible: [FightEventRecord] {
        events.filter { $0.time >= range.lowerBound && $0.time <= range.upperBound }
    }

    private var bucketCount: Int {
        max(24, min(160, Int(span / 1.5)))
    }

    private func name(for key: String) -> String {
        people.first { $0.key == key }?.displayName ?? key
    }

    // MARK: - Momentum model

    private struct Momentum {
        var topKey: String
        var bottomKey: String
        var topTotal: Double
        var bottomTotal: Double
        /// Per-bucket running momentum for each side (≥0).
        var top: [Double]
        var bottom: [Double]
        var peak: Double
    }

    /// Walk the events in time order, escalating combos and applying the
    /// zero-sum swing, sampling each side's running momentum into buckets.
    private func momentum() -> Momentum? {
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
        var scoreTop = 0.0, scoreBottom = 0.0
        var comboTop = 0, comboBottom = 0
        var lastTimeTop = -Double.infinity, lastTimeBottom = -Double.infinity
        var lastFighter = ""
        var eventIndex = 0

        func apply(_ event: FightEventRecord) {
            if event.fighterKey == topKey {
                let continues = lastFighter == topKey
                    && event.time - lastTimeTop <= Self.comboWindow
                comboTop = continues ? comboTop + 1 : 1
                let delta = event.points * Double(comboTop)
                scoreTop += delta
                scoreBottom = max(0, scoreBottom - delta)
                lastTimeTop = event.time
                lastFighter = topKey
            } else if event.fighterKey == bottomKey, !bottomKey.isEmpty {
                let continues = lastFighter == bottomKey
                    && event.time - lastTimeBottom <= Self.comboWindow
                comboBottom = continues ? comboBottom + 1 : 1
                let delta = event.points * Double(comboBottom)
                scoreBottom += delta
                scoreTop = max(0, scoreTop - delta)
                lastTimeBottom = event.time
                lastFighter = bottomKey
            }
        }

        for bucket in 0..<count {
            let bucketEnd = range.lowerBound + span * Double(bucket + 1) / Double(count)
            while eventIndex < attributed.count, attributed[eventIndex].time <= bucketEnd {
                apply(attributed[eventIndex])
                eventIndex += 1
            }
            top[bucket] = scoreTop
            bottom[bucket] = scoreBottom
        }
        let peak = max(1, top.max() ?? 1, bottom.max() ?? 1)
        return Momentum(topKey: topKey, bottomKey: bottomKey,
                        topTotal: scoreTop, bottomTotal: scoreBottom,
                        top: top, bottom: bottom, peak: peak)
    }

    // MARK: - View

    var body: some View {
        let model = momentum()
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
        .help("Fight momentum: each fighter fills their half from the center line. A landed action lifts the striker and pushes the opponent back (zero-sum); consecutive hits escalate (a combo), resetting after a 3s lull or when the opponent answers. Whoever's area reaches further is winning the exchange.")
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

    /// Filled area between the center line and one fighter's momentum curve,
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
