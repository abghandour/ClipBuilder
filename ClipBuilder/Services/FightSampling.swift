import Foundation

/// Where the fight scoring pass looks, and how densely.
///
/// A punch is over in a fifth of a second, so one still per second shows the
/// model almost none of them. The pass samples four stills a second and packs
/// them four to an image (a sheet), which keeps the image count per second of
/// footage where it was. Stretches where both fighters are clearly out of
/// reach drop to one still a second.
///
/// The body detector behind `gap` loses a fighter in roughly a third of fight
/// frames and sometimes pairs a fighter with the referee, so distance is only
/// believed when it holds for `minFarRun`: every doubtful reading keeps the
/// dense rate.
///
/// Everything here is pure so it can be tested without video or Vision.
nonisolated enum FightSampling {
    typealias Range = (start: Double, end: Double)

    /// Seconds between stills while the fighters are in reach, or unknown.
    static let denseInterval = 0.25
    /// Seconds between stills while they are confirmed apart.
    static let sparseInterval = 1.0
    /// Seconds between body-detector readings.
    static let probeInterval = 0.5
    static let tilesPerSheet = 4
    /// One call covers at most this much footage: 12 sheets at the dense rate.
    /// A provider that opens images one by one takes about ten seconds a
    /// sheet, so a longer window runs into the five minute call timeout.
    static let maxWindow = 12.0
    /// A file typed Fight and no longer than this is scored end to end. The
    /// tagging pass sees thirty frames and leaves real exchanges untagged,
    /// so its action tags only choose the footage in longer files and recaps.
    static let fullCoverageLimit = 1200.0
    /// Scoring calls in flight at once.
    static let concurrency = 3
    /// Longest edge of one still; a sheet of four is twice that.
    static let tileEdge = 768

    /// Gap between the fighters, in body heights, at or above which they are
    /// out of punching and kicking reach.
    static let farGap = 0.7
    /// Distance must hold this long before the rate drops.
    static let minFarRun = 3.0
    /// The dense rate resumes this long before the fighters close again and
    /// lasts this long after they part.
    static let farMargin = 0.5
    /// A body counts when it is this tall relative to the tallest one…
    static let comparableHeight = 0.75
    /// …and the tallest is at least this share of the frame height.
    static let minBodyHeight = 0.25
    /// A box wider than this share of its height holds two people, or one
    /// mid-kick: either way not a fighter standing apart.
    static let maxBodyAspect = 0.55

    /// One detected body: horizontal extent and height, each 0…1 of the frame.
    nonisolated struct Body: Equatable, Sendable {
        var minX: Double
        var maxX: Double
        var height: Double
    }

    /// The smallest horizontal gap between any two fighter-sized bodies, in
    /// body heights. nil when the frame cannot confirm two separate fighters:
    /// fewer than two bodies, or one box wide enough to hold both.
    /// `aspect` is frame width over height.
    static func gap(bodies: [Body], aspect: Double) -> Double? {
        guard let tallest = bodies.map(\.height).max(), tallest >= minBodyHeight, aspect > 0 else { return nil }
        let fighters = bodies.filter { $0.height >= tallest * comparableHeight }
        guard fighters.count >= 2 else { return nil }
        guard fighters.allSatisfy({ ($0.maxX - $0.minX) * aspect <= $0.height * maxBodyAspect }) else { return nil }
        var smallest = Double.infinity
        for (index, first) in fighters.enumerated() {
            for second in fighters.dropFirst(index + 1) {
                let between = max(0, max(first.minX, second.minX) - min(first.maxX, second.maxX)) * aspect
                smallest = min(smallest, between / ((first.height + second.height) / 2))
            }
        }
        return smallest
    }

    /// Stretches where every reading confirmed distance for `minFarRun`,
    /// pulled in by `farMargin` at both ends. A nil or close reading ends a run.
    static func farRanges(probes: [(time: Double, gap: Double?)], interval: Double = probeInterval) -> [Range] {
        var ranges: [Range] = []
        var run: Range?
        func close() {
            if let run, run.end - run.start >= minFarRun {
                ranges.append((run.start + farMargin, run.end - farMargin))
            }
            run = nil
        }
        for probe in probes.sorted(by: { $0.time < $1.time }) {
            guard let gap = probe.gap, gap >= farGap else { close(); continue }
            if let current = run, probe.time - current.end <= interval * 0.5 {
                run = (current.start, probe.time + interval)
            } else {
                close()
                run = (probe.time, probe.time + interval)
            }
        }
        close()
        return ranges
    }

    /// Still times across a window: dense, except sparse inside `far`.
    static func timestamps(window: Range, far: [Range] = []) -> [Double] {
        var times: [Double] = []
        var time = window.start
        while time < window.end - 0.05 {
            times.append((time * 100).rounded() / 100)
            let apart = far.contains { time >= $0.start && time + sparseInterval <= $0.end }
            time += apart ? sparseInterval : denseInterval
        }
        if times.isEmpty, window.end > window.start { times.append(window.start) }
        return times
    }

    /// Consecutive stills grouped into sheets.
    static func sheets(_ timestamps: [Double]) -> [[Double]] {
        stride(from: 0, to: timestamps.count, by: tilesPerSheet).map {
            Array(timestamps[$0..<min($0 + tilesPerSheet, timestamps.count)])
        }
    }

    /// Probe on the scoring grid so every decoded probe can also be a tile.
    static func probeTimes(window: Range) -> [Double] {
        timestamps(window: window).enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
    }

    static func extractionComplete(requested: [Double], extracted: Set<Double>) -> Bool {
        !requested.isEmpty && requested.allSatisfy { extracted.contains($0) }
    }

    static func retainedEvents(_ events: [FightEventRecord], unscored: [Range]) -> [FightEventRecord] {
        events.filter { event in unscored.contains { event.time >= $0.start && event.time < $0.end } }
    }

    /// Coverage lives in the existing local analysis-pass note, alongside the
    /// readable summary. Old notes have unknown coverage, never inferred coverage.
    static func coverageNote(_ summary: String, ranges: [Range]) -> String {
        let values = ranges.map { [$0.start, $0.end] }
        guard let data = try? JSONEncoder().encode(values) else { return summary }
        return summary + "\nSuccessful ranges v1: " + String(decoding: data, as: UTF8.self)
    }

    static func successfulRanges(_ pass: AnalysisPassRecord) -> [Range]? {
        guard pass.pass == .fightScore, pass.version >= 3,
              let json = pass.note?.components(separatedBy: "\nSuccessful ranges v1: ").last,
              let values = try? JSONDecoder().decode([[Double]].self, from: Data(json.utf8)) else { return nil }
        let ranges: [Range] = values.compactMap {
            guard $0.count == 2, $0[0].isFinite, $0[1].isFinite, $0[1] > $0[0] else { return nil }
            return (start: $0[0], end: $0[1])
        }
        // Sampling's merge rule bridges short gaps. Coverage must never do so.
        var merged: [Range] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else { merged.append(range) }
        }
        return merged
    }

    static func noteSummary(_ pass: AnalysisPassRecord) -> String? {
        pass.note?.components(separatedBy: "\nSuccessful ranges v1: ").first
    }

    /// The footage the pass scores: all of a fight up to `fullCoverageLimit`,
    /// otherwise the action-tagged scene ranges, merged where they touch.
    static func scoredRanges(actionRanges: [Range], type: VideoType?, duration: Double) -> [Range] {
        if type == .fight, duration > 0, duration <= fullCoverageLimit { return [(0, duration)] }
        return SmartSampling.mergeOverlapping(actionRanges.filter { $0.end > $0.start })
    }

    /// Scoring windows: each range cut into equal parts no longer than `maxWindow`.
    static func windows(_ ranges: [Range]) -> [Range] {
        SmartSampling.chunk(ranges.filter { $0.end > $0.start }, maximum: maxWindow)
    }

    static func stamp(_ time: Double) -> String { String(format: "%.2fs", time) }

    /// The label the model sees for one sheet.
    static func label(_ times: [Double]) -> String {
        let list = times.map(stamp).joined(separator: ", ")
        return times.count == 1 ? list
            : "\(list) — \(times.count) consecutive stills on one sheet, left to right then top to bottom, each stamped with its time"
    }

    /// Seconds of `window` sampled at the sparse rate.
    static func sparseSeconds(window: Range, far: [Range]) -> Double {
        far.reduce(0) { $0 + max(0, min(window.end, $1.end) - max(window.start, $1.start)) }
    }
}
