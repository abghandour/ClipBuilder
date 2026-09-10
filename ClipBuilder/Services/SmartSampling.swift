import Foundation

/// Smart Sampling: analyze long footage in phases instead of one fixed grid.
///
/// The classic pass samples at most 30 frames for the whole file, so an hour
/// of footage gets one frame every two minutes. Smart Sampling keeps that pass
/// (it still returns people, the fight outcome and the video type) and adds:
///
/// 1. A coarse map: 5-minute windows sampled every 15 s, run in parallel,
///    each returning tag ranges plus an activity score for the window.
/// 2. A dense pass only where the map or the tags say action happens
///    (fights, sparring, scrambles), split into ≤60 s windows and run in
///    parallel. Podcasts and interviews never enter it.
///
/// Everything here is pure so it can be tested without ffmpeg or a model.
nonisolated enum SmartSampling {
    typealias Range = (start: Double, end: Double)

    /// Below this the classic 30-frame grid is already ≤10 s apart.
    static let minDuration = 300.0
    static let windowSeconds = 300.0
    static let coarseInterval = 15.0
    /// A trailing window shorter than this joins the previous one.
    static let minTrailingWindow = 60.0
    /// Dense windows stay inside the 120-frame budget at ≥0.5 s spacing.
    static let maxDenseWindow = 60.0
    static let minDenseWindow = 8.0
    /// Windows this close (seconds) merge before chunking.
    static let mergeGap = 2.0
    /// Model activity (0–10) at or above this earns a dense pass on its own.
    static let activityThreshold = 7.0
    /// ffmpeg cut rate at or above this marks a window as edited action.
    static let activeCutsPerMinute = 12.0
    static let coarseConcurrency = 3
    static let denseConcurrency = 3
    /// Per-file call budget: longer files get longer coarse windows, and the
    /// dense pass keeps the most promising chunks. Twelve hours of live
    /// footage costs 48 map calls and at most 40 dense calls, not hundreds.
    static let maxCoarseWindows = 48
    static let maxDenseWindows = 40

    /// Tags whose ranges deserve a frame-by-frame look. Shared with fight scoring.
    static let actionTags: Set<String> = [
        "striking", "punching", "kicking", "grappling", "takedown", "submission", "clinch",
        "sparring", "knockdown", "ground-and-pound", "high-energy",
    ]

    /// Video types that never get a dense pass: the interesting part is speech.
    static func skipsDensePass(_ type: VideoType?) -> Bool {
        switch type {
        case .podcast, .interview: true
        default: false
        }
    }

    static func appliesTo(duration: Double, customInterval: Double?, trimmed: Bool, nativeVideo: Bool) -> Bool {
        duration >= minDuration && customInterval == nil && !trimmed && !nativeVideo
    }

    /// Consecutive windows covering [0, duration]; a short tail joins its predecessor.
    static func coarseWindows(duration: Double, windowSeconds: Double = windowSeconds) -> [Range] {
        guard duration > 0 else { return [] }
        let windowSeconds = max(windowSeconds, duration / Double(maxCoarseWindows))
        var windows: [Range] = []
        var cursor = 0.0
        while cursor < duration {
            windows.append((cursor, min(cursor + windowSeconds, duration)))
            cursor += windowSeconds
        }
        if windows.count > 1, let last = windows.last, last.end - last.start < minTrailingWindow {
            windows.removeLast()
            windows[windows.count - 1].end = last.end
        }
        return windows
    }

    /// Frame times inside one window at the coarse interval.
    static func coarseTimestamps(window: Range, interval: Double = coarseInterval) -> [Double] {
        var times: [Double] = []
        var t = window.start + 0.5
        while t < window.end - 0.3 {
            times.append((t * 10).rounded() / 10)
            t += interval
        }
        if times.isEmpty, window.end > window.start {
            times.append(window.start + min(0.5, (window.end - window.start) / 2))
        }
        return times
    }

    static func cutsPerMinute(cuts: [Double], window: Range) -> Double {
        let span = window.end - window.start
        guard span > 0 else { return 0 }
        let count = cuts.filter { $0 >= window.start && $0 < window.end }.count
        return Double(count) * 60 / span
    }

    /// Adds `incoming` ranges to `existing` per tag, dropping any incoming
    /// range that an existing range of the same tag already covers by 70 %.
    /// The two passes look at the same footage; near-duplicates would become
    /// near-duplicate scenes.
    static func merge(existing: [String: [Range]], incoming: [String: [Range]]) -> [String: [Range]] {
        var result = existing
        for (tag, ranges) in incoming {
            var kept = result[tag] ?? []
            for range in ranges where range.end > range.start {
                let covered = kept.contains { current in
                    let overlap = min(current.end, range.end) - max(current.start, range.start)
                    return overlap > 0 && overlap / (range.end - range.start) >= 0.7
                }
                if !covered { kept.append(range) }
            }
            if !kept.isEmpty { result[tag] = kept }
        }
        return result
    }

    /// Where the dense pass looks: the user's own breakdown windows, action-
    /// tagged ranges, windows the model scored as busy, and windows whose cut
    /// rate reads as edited action — unioned so the same footage is never
    /// examined twice, chunked to the frame budget, then capped by priority.
    /// Talk formats keep only what the user asked for explicitly.
    static func denseWindows(
        tagRanges: [String: [Range]], activity: [(window: Range, score: Double)],
        cuts: [Double], type: VideoType?, manual: [Range] = [], extraTags: Set<String> = []
    ) -> [Range] {
        var candidates = manual.filter { $0.end - $0.start >= minDenseWindow }
        if !skipsDensePass(type) {
            let wanted = actionTags.union(extraTags)
            for (tag, ranges) in tagRanges where wanted.contains(tag) {
                candidates += ranges.filter { $0.end - $0.start >= minDenseWindow }
            }
            for entry in activity {
                let busy = entry.score >= activityThreshold
                    || cutsPerMinute(cuts: cuts, window: entry.window) >= activeCutsPerMinute
                if busy { candidates.append(entry.window) }
            }
        }
        let chunks = chunk(mergeOverlapping(candidates), maximum: maxDenseWindow)
        guard chunks.count > maxDenseWindows else { return chunks }
        // Over budget: explicit and action-tagged footage first, then the
        // busiest sections, then earliest.
        let explicit = manual + tagRanges.filter { actionTags.union(extraTags).contains($0.key) }.flatMap(\.value)
        func priority(_ range: Range) -> (Int, Double) {
            let asked = explicit.contains { $0.start < range.end && range.start < $0.end } ? 1 : 0
            let score = activity.filter { $0.window.start < range.end && range.start < $0.window.end }
                .map(\.score).max() ?? 0
            return (asked, score)
        }
        struct Ranked {
            var range: Range
            var asked: Int
            var score: Double
        }
        var ranked: [Ranked] = chunks.map { chunk in
            let (asked, score) = priority(chunk)
            return Ranked(range: chunk, asked: asked, score: score)
        }
        ranked.sort { a, b in
            if a.asked != b.asked { return a.asked > b.asked }
            if a.score != b.score { return a.score > b.score }
            return a.range.start < b.range.start
        }
        let kept = ranked.prefix(maxDenseWindows).map(\.range)
        return kept.sorted { $0.start < $1.start }
    }

    static func mergeOverlapping(_ ranges: [Range]) -> [Range] {
        var merged: [Range] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start - last.end <= mergeGap {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func chunk(_ ranges: [Range], maximum: Double) -> [Range] {
        ranges.flatMap { range -> [Range] in
            guard range.end - range.start > maximum else { return [range] }
            // Equal chunks so the last one is never a sliver.
            let count = Int(((range.end - range.start) / maximum).rounded(.up))
            let size = (range.end - range.start) / Double(count)
            return (0..<count).map { index in
                (range.start + size * Double(index), index == count - 1 ? range.end : range.start + size * Double(index + 1))
            }
        }
    }
}
