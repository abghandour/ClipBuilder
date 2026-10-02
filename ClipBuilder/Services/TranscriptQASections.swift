import Foundation

/// Source-time sections and trim calculations, independent of the editor and store.
nonisolated enum TranscriptQASections {
    static let minimumSpan = 1.0

    nonisolated enum Edge { case start, end }

    nonisolated struct Section: Identifiable {
        var scene: SceneRecord
        var question: String
        var asker: String?
        var answerer: String?
        var id: Int64 { scene.id }
        var range: ClosedRange<Double> { ProposedCutTrim.range(start: scene.startTime, end: scene.endTime) }
        var isTrimmed: Bool {
            ProposedCutTrim.differs(range, proposedStart: scene.originalStart, proposedEnd: scene.originalEnd)
        }
    }

    nonisolated struct Line: Identifiable {
        var row: TranscriptRow
        var isInside: Bool
        var id: Int64 { row.id }
    }

    static func sections(scenes: [SceneRecord], rows: [TranscriptRow], labels: [Int64: String]) -> [Section] {
        let ordered = orderedRows(rows)
        return scenes.filter { !$0.ignored && $0.tags.contains("q&a") }
            .sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
            .map { scene in
                let range = ProposedCutTrim.range(start: scene.startTime, end: scene.endTime)
                let lines = ordered.filter { $0.videoID == scene.videoID && contains($0, in: range) }
                let asker = lines.first.flatMap { labels[$0.id] }
                let answerer = asker.flatMap { asker in
                    lines.dropFirst().compactMap { labels[$0.id] }.first { $0 != asker }
                }
                return Section(scene: scene, question: lines.first?.text ?? "No transcript lines in this section",
                               asker: asker, answerer: answerer)
            }
    }

    /// Use the same midpoint rule as the transcript's scene tags.
    static func contains(_ row: TranscriptRow, in range: ClosedRange<Double>) -> Bool {
        let midpoint = (row.startTime + row.endTime) / 2
        return midpoint >= range.lowerBound && midpoint < range.upperBound
    }

    static func lines(rows: [TranscriptRow], range: ClosedRange<Double>, context: Int = 4) -> [Line] {
        let ordered = orderedRows(rows)
        let inside = ordered.indices.filter { contains(ordered[$0], in: range) }
        let insertion = ordered.firstIndex { ($0.startTime + $0.endTime) / 2 >= range.lowerBound } ?? ordered.count
        let first = inside.first ?? insertion
        let after = inside.last.map { $0 + 1 } ?? insertion
        let lower = max(0, first - max(0, context))
        let upper = min(ordered.count, after + max(0, context))
        return ordered[lower..<upper].map { Line(row: $0, isInside: contains($0, in: range)) }
    }

    static func snap(_ time: Double, edge: Edge, rows: [TranscriptRow], tolerance: Double = 1.5) -> Double {
        let boundaries = rows.map { edge == .start ? $0.startTime : $0.endTime }.filter(\.isFinite)
        let nearest = boundaries.min {
            let left = abs($0 - time), right = abs($1 - time)
            return left == right ? $0 < $1 : left < right
        }
        guard let nearest, abs(nearest - time) <= tolerance else { return time }
        return nearest
    }

    static func clamp(start: Double, end: Double, videoDuration: Double) -> ClosedRange<Double> {
        let total = max(0, videoDuration)
        let minimum = min(minimumSpan, total)
        let lower = min(max(0, start), total - minimum)
        return lower...min(total, max(lower + minimum, end))
    }

    /// Keep the other end fixed when a line would invert or collapse the section.
    static func setting(_ edge: Edge, at time: Double, in range: ClosedRange<Double>,
                        videoDuration: Double) -> ClosedRange<Double> {
        let range = clamp(start: range.lowerBound, end: range.upperBound, videoDuration: videoDuration)
        let minimum = min(minimumSpan, max(0, videoDuration))
        switch edge {
        case .start:
            return max(0, min(time, range.upperBound - minimum))...range.upperBound
        case .end:
            return range.lowerBound...min(max(0, videoDuration), max(time, range.lowerBound + minimum))
        }
    }

    static func releasing(start: Double, end: Double, from range: ClosedRange<Double>,
                          rows: [TranscriptRow], videoDuration: Double) -> ClosedRange<Double> {
        let startMoved = abs(start - range.lowerBound) > 0.001
        let endMoved = abs(end - range.upperBound) > 0.001
        let start = startMoved ? snap(start, edge: .start, rows: rows) : start
        let end = endMoved ? snap(end, edge: .end, rows: rows) : end
        if startMoved && !endMoved {
            return setting(.start, at: start, in: range, videoDuration: videoDuration)
        }
        if endMoved && !startMoved {
            return setting(.end, at: end, in: range, videoDuration: videoDuration)
        }
        return clamp(start: start, end: end, videoDuration: videoDuration)
    }

    static func window(for range: ClosedRange<Double>, videoDuration: Double) -> ProposedCutTrim.Window {
        ProposedCutTrim.window(for: range, scene: 0...max(0, videoDuration))
    }

    private static func orderedRows(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        rows.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.isTranslation != $1.isTranslation { return !$0.isTranslation }
            return $0.id < $1.id
        }
    }
}
