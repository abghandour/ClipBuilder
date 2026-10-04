import Foundation
import CoreGraphics

/// Word-level Q&A editing. Recording and minimum-span limits take precedence
/// over snapping when a word straddles a legal boundary.
nonisolated enum TranscriptQATrim {
    typealias Word = PodcastHighlightTrim.Word
    typealias Line = PodcastHighlightTrim.Line
    typealias Edge = TranscriptQASections.Edge
    static let minimumSpan = TranscriptQASections.minimumSpan

    struct Input: Equatable, Sendable {
        var rows: [TranscriptRow]
        var labels: [Int64: String]
        var videoID: Int64
    }

    struct Transcript: Equatable, Sendable {
        var lines: [Line] = []
        var words: [Word] = []

        init() {}

        init(_ input: Input) {
            let rows = input.rows.filter { $0.videoID == input.videoID && !$0.isTranslation }.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                return $0.id < $1.id
            }
            for row in rows {
                let tokens = TranscriptQATrim.words(for: row, startingAt: words.count)
                guard !tokens.isEmpty else { continue }
                lines.append(Line(id: lines.count, start: row.startTime, end: row.endTime,
                                  speaker: input.labels[row.id], words: tokens))
                words.append(contentsOf: tokens)
            }
        }

        func lineID(at time: Double) -> Int? {
            lines.last { $0.start <= time && time < $0.end }?.id
        }
    }

    /// Callers scope rows to the recording before discovering or matching translations.
    /// Empty means no controls; one language needs only the checkbox, multiple need a menu.
    static func availableTranslationLanguages(rows: [TranscriptRow]) -> [String] {
        Set(rows.filter(\.isTranslation).map(\.language)).sorted()
    }

    static func translationLanguage(available: [String], selected: String?, preferred: String?) -> String? {
        if let selected, available.contains(selected) { return selected }
        if let preferred, available.contains(preferred) { return preferred }
        return available.first
    }

    /// Each translation belongs to just one original line. Exact ranges win,
    /// then greatest positive overlap; ties keep the first line in transcript order.
    static func translations(for lines: [Line], rows: [TranscriptRow], language: String) -> [Int: String] {
        let rows = rows.filter {
            $0.isTranslation && $0.language == language
                && $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime
        }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
            return $0.id < $1.id
        }
        var result: [Int: String] = [:]
        for row in rows {
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var match = lines.first { $0.start == row.startTime && $0.end == row.endTime }
            if match == nil {
                var bestOverlap = 0.0
                for line in lines {
                    let overlap = min(line.end, row.endTime) - max(line.start, row.startTime)
                    if overlap > bestOverlap {
                        match = line
                        bestOverlap = overlap
                    }
                }
            }
            guard let match else { continue }
            if let existing = result[match.id] { result[match.id] = existing + " " + text }
            else { result[match.id] = text }
        }
        return result
    }

    static func words(for row: TranscriptRow, startingAt firstID: Int = 0) -> [Word] {
        let timed = (row.words ?? []).filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
                && !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.start < $1.start }
        if !timed.isEmpty {
            return timed.enumerated().map { index, word in
                Word(id: firstID + index, text: word.word.trimmingCharacters(in: .whitespacesAndNewlines),
                     start: word.start, end: word.end)
            }
        }
        // Approximation for older/untimed transcripts: distribute whitespace-
        // separated words evenly across the row, without claiming forced alignment.
        guard row.startTime.isFinite, row.endTime.isFinite, row.endTime > row.startTime else { return [] }
        let tokens = row.text.split(whereSeparator: \.isWhitespace)
        let span = (row.endTime - row.startTime) / Double(max(1, tokens.count))
        return tokens.enumerated().map { index, text in
            Word(id: firstID + index, text: String(text), start: row.startTime + Double(index) * span,
                 end: index == tokens.count - 1 ? row.endTime : row.startTime + Double(index + 1) * span)
        }
    }

    /// Exchanges are independent selections: neighbours no longer bound edits,
    /// and overlapping ranges are allowed anywhere in the recording.
    static func limits(for section: TranscriptQASections.Section,
                       in sections: [TranscriptQASections.Section], duration: Double) -> ClosedRange<Double> {
        let total = duration.isFinite ? max(0, duration) : 0
        return 0...total
    }

    static func clamped(_ range: ClosedRange<Double>, limits: ClosedRange<Double>) -> ClosedRange<Double> {
        let minimum = min(minimumSpan, limits.upperBound - limits.lowerBound)
        let lower = min(max(limits.lowerBound, range.lowerBound), limits.upperBound - minimum)
        return lower...min(limits.upperBound, max(lower + minimum, range.upperBound))
    }

    static func setting(_ edge: Edge, at time: Double, in range: ClosedRange<Double>,
                        limits: ClosedRange<Double>) -> ClosedRange<Double> {
        let range = clamped(range, limits: limits)
        let minimum = min(minimumSpan, limits.upperBound - limits.lowerBound)
        switch edge {
        case .start: return max(limits.lowerBound, min(time, range.upperBound - minimum))...range.upperBound
        case .end: return range.lowerBound...min(limits.upperBound, max(time, range.lowerBound + minimum))
        }
    }

    static func range(_ range: ClosedRange<Double>, movingStartTo word: Word,
                      limits: ClosedRange<Double>) -> ClosedRange<Double> {
        setting(.start, at: word.start, in: range, limits: limits)
    }

    static func range(_ range: ClosedRange<Double>, movingEndTo word: Word,
                      limits: ClosedRange<Double>) -> ClosedRange<Double> {
        setting(.end, at: word.end, in: range, limits: limits)
    }

    static func nearestEdge(for word: Word, in range: ClosedRange<Double>) -> Edge {
        abs(word.mid - range.lowerBound) <= abs(word.mid - range.upperBound) ? .start : .end
    }

    static func contains(_ word: Word, in range: ClosedRange<Double>) -> Bool {
        word.mid >= range.lowerBound && word.mid < range.upperBound
    }

    /// Frames and pointer must be in the same coordinate space. Empty space
    /// does not move a cut; overlapping frames resolve deterministically by ID.
    static func word(at point: CGPoint, frames: [Int: CGRect]) -> Int? {
        frames.filter { $0.value.contains(point) }.keys.min()
    }

    static func snap(_ time: Double, edge: Edge, words: [Word], tolerance: Double = 1.5) -> Double {
        let boundaries = words.map { edge == .start ? $0.start : $0.end }
        let nearest = boundaries.min {
            abs($0 - time) == abs($1 - time) ? $0 < $1 : abs($0 - time) < abs($1 - time)
        }
        guard let nearest, abs(nearest - time) <= tolerance else { return time }
        return nearest
    }

    static func releasing(_ draft: ClosedRange<Double>, from original: ClosedRange<Double>,
                          words: [Word], limits: ClosedRange<Double>) -> ClosedRange<Double> {
        let startMoved = abs(draft.lowerBound - original.lowerBound) > 0.001
        let endMoved = abs(draft.upperBound - original.upperBound) > 0.001
        let start = startMoved ? snap(draft.lowerBound, edge: .start, words: words) : draft.lowerBound
        let end = endMoved ? snap(draft.upperBound, edge: .end, words: words) : draft.upperBound
        if startMoved && !endMoved { return setting(.start, at: start, in: original, limits: limits) }
        if endMoved && !startMoved { return setting(.end, at: end, in: original, limits: limits) }
        return clamped(start...max(start, end), limits: limits)
    }
}
