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
        /// Who talks when, by name, from the speaker map. A row whose words
        /// cross a speaker change is split into one line per speaker; rows
        /// the user attributed by hand keep their single label.
        var speakerSpans: [SpeakerSpan] = []
    }

    /// One speaker turn with the name the transcript shows for it.
    struct SpeakerSpan: Equatable, Sendable, Hashable {
        var start: Double
        var end: Double
        var label: String
        /// The recording the span belongs to; nil applies to any recording.
        var videoID: Int64? = nil
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
            // Consecutive rows of the same speaker read as one block, broken
            // only where the other person talks. Rows nobody is known to
            // speak stay their own lines.
            let spans = input.speakerSpans.filter { $0.videoID == nil || $0.videoID == input.videoID }
            for row in rows {
                let tokens = TranscriptQATrim.words(for: row, startingAt: words.count)
                guard !tokens.isEmpty else { continue }
                for run in TranscriptQATrim.speakerRuns(row: row, words: tokens, label: input.labels[row.id],
                                                        spans: spans) {
                    if let index = lines.indices.last, let label = run.label, label == lines[index].speaker {
                        lines[index].end = max(lines[index].end, run.end)
                        lines[index].words.append(contentsOf: run.words)
                    } else {
                        lines.append(Line(id: lines.count, start: run.start, end: run.end,
                                          speaker: run.label, words: run.words))
                    }
                }
                words.append(contentsOf: tokens)
            }
        }

        func lineID(at time: Double) -> Int? {
            lines.last { $0.start <= time && time < $0.end }?.id
        }

        /// Resolve once for the panel, never once per token. Gaps and parked
        /// playheads have no spoken word; at a shared boundary the next wins.
        func spokenWordID(at time: Double, isPlaying: Bool) -> Int? {
            guard isPlaying else { return nil }
            return words.first { $0.start <= time && time < $0.end }?.id
        }
    }

    /// Only the part of a selection that can affect this line's words.
    /// Use word bounds: recorded timings can extend beyond the row's clocks.
    static func selectionRange(_ range: ClosedRange<Double>, in line: Line) -> ClosedRange<Double>? {
        guard let start = line.words.map(\.start).min(), let end = line.words.map(\.end).max() else { return nil }
        let lower = max(start, range.lowerBound), upper = min(end, range.upperBound)
        return lower <= upper ? lower...upper : nil
    }

    static func touches(_ range: ClosedRange<Double>, line: Line) -> Bool {
        line.words.contains { contains($0, in: range) }
    }

    /// Clipping the selection changes its midpoint. Preserve the original
    /// nearest-edge help as a value input, without invalidating unrelated lines.
    static func startEdgeWordIDs(in line: Line, range: ClosedRange<Double>) -> Set<Int> {
        Set(line.words.filter { nearestEdge(for: $0, in: range) == .start }.map(\.id))
    }

    /// Includes removals when a lazy line disappears, not just new frames.
    static func changedFrameLineIDs(lines: [Line], before: [Int: CGRect], after: [Int: CGRect]) -> Set<Int> {
        Set(lines.filter { line in
            line.words.contains { before[$0.id] != after[$0.id] }
        }.map(\.id))
    }

    /// Preserve order: equally tight overlapping picks use the first owner.
    static func changedRangeLineIDs(lines: [Line], before: [ClosedRange<Double>],
                                    after: [ClosedRange<Double>]) -> Set<Int> {
        Set(lines.filter { line in
            before.filter { touches($0, line: line) } != after.filter { touches($0, line: line) }
        }.map(\.id))
    }

    /// Keep untouched lines' results. A missing frame set removes stale bars.
    static func updatingLineStarts(_ previous: [Int: Set<Int>], lines: [Line], changed: Set<Int>,
                                   ranges: [ClosedRange<Double>], frames: [Int: CGRect]) -> [Int: Set<Int>] {
        var result = previous
        for id in changed { result.removeValue(forKey: id) }
        for line in lines where changed.contains(line.id) {
            let starts = lineStartWords(words: line.words, ranges: ranges, frames: frames)
            if !starts.isEmpty { result[line.id] = starts }
        }
        return result
    }

    /// FlowLayout reports local placement; the line's single geometry reader
    /// supplies its origin in the stationary scroll viewport, including scroll.
    static func offsetFrames(_ frames: [Int: CGRect], by origin: CGPoint) -> [Int: CGRect] {
        frames.mapValues { $0.offsetBy(dx: origin.x, dy: origin.y) }
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

    struct SpeakerRun: Equatable, Sendable {
        var start: Double
        var end: Double
        var label: String?
        var words: [Word]
    }

    /// A row's words grouped by who the speaker map says is talking. Each
    /// word takes the span covering most of it; a word no span covers stays
    /// with the words before it. Rows attributed by hand, rows without
    /// timed words and rows no span touches stay one run under `label`.
    static func speakerRuns(row: TranscriptRow, words: [Word], label: String?, spans: [SpeakerSpan]) -> [SpeakerRun] {
        let whole = [SpeakerRun(start: row.startTime, end: row.endTime, label: label, words: words)]
        guard !words.isEmpty, !spans.isEmpty, row.speaker == .automatic,
              !(row.words ?? []).isEmpty else { return whole }
        let covering = spans.filter { $0.end > row.startTime && $0.start < row.endTime }
            .sorted { $0.start < $1.start }
        guard covering.count > 1 else { return whole }
        func speaker(of word: Word) -> String? {
            var best: (label: String, overlap: Double)?
            for span in covering {
                let overlap = min(span.end, max(word.end, word.start + 0.001)) - max(span.start, word.start)
                guard overlap > 0, overlap > (best?.overlap ?? 0) else { continue }
                best = (span.label, overlap)
            }
            return best?.label
        }
        var runs: [SpeakerRun] = []
        for word in words {
            let name = speaker(of: word) ?? runs.last?.label
            if let index = runs.indices.last, runs[index].label == name {
                runs[index].words.append(word)
                runs[index].end = max(runs[index].end, word.end)
            } else {
                runs.append(SpeakerRun(start: word.start, end: word.end, label: name, words: [word]))
            }
        }
        // Words before the first covered word belong to the first speaker.
        if runs.count > 1, runs[0].label == nil {
            let first = runs.removeFirst()
            runs[0].words.insert(contentsOf: first.words, at: 0)
            runs[0].start = first.start
        }
        guard runs.count > 1 else { return whole }
        runs[0].start = min(runs[0].start, row.startTime)
        runs[runs.count - 1].end = max(runs[runs.count - 1].end, row.endTime)
        return runs
    }

    static func words(for row: TranscriptRow, startingAt firstID: Int = 0) -> [Word] {
        let timed = (row.words ?? []).filter {
            $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
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
        word.mid >= range.lowerBound && (word.mid < range.upperBound || (word.start == word.end && word.mid == range.upperBound))
    }

    /// The first word on each wrapped line of each saved pick, so every line
    /// of a pick can carry the pick's bar. A word belongs to the tightest pick
    /// containing it; lines are the measured frames grouped by their top edge.
    /// Words without a frame (not laid out yet) are skipped.
    static func lineStartWords(words: [Word], ranges: [ClosedRange<Double>], frames: [Int: CGRect]) -> Set<Int> {
        var owners: [Int: [Word]] = [:]
        // Only measured (on-screen) words can start a line; matching every
        // word of a long recording against every pick on each scroll was the cost.
        for word in words where frames[word.id] != nil {
            let owner = ranges.indices.filter { contains(word, in: ranges[$0]) }
                .min { (ranges[$0].upperBound - ranges[$0].lowerBound) < (ranges[$1].upperBound - ranges[$1].lowerBound) }
            if let owner { owners[owner, default: []].append(word) }
        }
        var result = Set<Int>()
        for group in owners.values {
            var lines: [Int: (id: Int, minX: CGFloat)] = [:]
            for word in group {
                guard let frame = frames[word.id] else { continue }
                let line = Int((frame.minY * 2).rounded())
                if let best = lines[line], best.minX <= frame.minX { continue }
                lines[line] = (word.id, frame.minX)
            }
            result.formUnion(lines.values.map(\.id))
        }
        return result
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

    // MARK: Word steps

    /// One-click adjustments for a marked range: take in or drop one word
    /// or one sentence at either edge, or include the pause that follows
    /// the last word (up to the next word, or the end of the limits). nil
    /// when there is no such step, so the button disables.
    enum Step: CaseIterable, Sendable, Equatable {
        case wordBefore, dropFirstWord, sentenceBefore, dropFirstSentence
        case dropLastWord, wordAfter, pauseAfter, sentenceAfter, dropLastSentence

        var edge: Edge {
            switch self {
            case .wordBefore, .dropFirstWord, .sentenceBefore, .dropFirstSentence: .start
            case .dropLastWord, .wordAfter, .pauseAfter, .sentenceAfter, .dropLastSentence: .end
            }
        }
    }

    static func stepped(_ range: ClosedRange<Double>, by step: Step, words: [Word],
                        limits: ClosedRange<Double>, tolerance: Double = 0.05) -> ClosedRange<Double>? {
        let inside = words.filter { $0.start >= range.lowerBound - tolerance && $0.end <= range.upperBound + tolerance }
        let before = words.filter { $0.end <= range.lowerBound + tolerance && $0.start < range.lowerBound - tolerance }
            .sorted { $0.start < $1.start }
        let after = words.filter { $0.start >= range.upperBound - tolerance && $0.end > range.upperBound + tolerance }
            .sorted { $0.start < $1.start }
        let target: Double?
        switch step {
        case .wordBefore:
            target = before.last?.start
        case .dropFirstWord:
            guard inside.count > 1 else { return nil }
            target = inside.dropFirst().first?.start
        case .sentenceBefore:
            // Back to the word after the previous sentence end, or the first word.
            // Already at a sentence start (the word before ends one): go
            // back a whole sentence instead of standing still.
            guard !before.isEmpty else { return nil }
            let searched = before.last.map { endsSentence($0.text) } == true ? before.dropLast() : before[...]
            if let stop = searched.lastIndex(where: { endsSentence($0.text) }) {
                target = before[stop + 1].start
            } else {
                target = before.first?.start
            }
        case .dropFirstSentence:
            // Forward to the next sentence start inside the range.
            guard inside.count > 1 else { return nil }
            target = inside.indices.dropFirst().first(where: { endsSentence(inside[$0 - 1].text) }).map { inside[$0].start }
        case .dropLastSentence:
            // Back to the previous sentence end inside the range.
            guard inside.count > 1 else { return nil }
            target = inside.dropLast().last(where: { endsSentence($0.text) })?.end
        case .dropLastWord:
            guard inside.count > 1 else { return nil }
            target = inside.dropLast().last?.end
        case .wordAfter:
            target = after.first?.end
        case .pauseAfter:
            // A word starting exactly at the end counts as next, so a range
            // that already runs up to it has no pause left to take.
            let pauseEnd = min(limits.upperBound, after.first?.start ?? limits.upperBound)
            target = pauseEnd > range.upperBound + tolerance ? pauseEnd : nil
        case .sentenceAfter:
            target = after.first(where: { endsSentence($0.text) })?.end
        }
        guard let target else { return nil }
        return moved(setting(step.edge, at: target, in: range, limits: limits), from: range, edge: step.edge, tolerance: tolerance)
    }

    /// Start at the first word's start and end at the last word's end,
    /// dropping the silence at both edges. nil when nothing changes.
    static func trimmedSilence(_ range: ClosedRange<Double>, words: [Word], limits: ClosedRange<Double>,
                               tolerance: Double = 0.05) -> ClosedRange<Double>? {
        let inside = words.filter { $0.start >= range.lowerBound - tolerance && $0.end <= range.upperBound + tolerance }
        guard let first = inside.first, let last = inside.last else { return nil }
        let updated = clamped(first.start...max(first.start, last.end), limits: limits)
        let changed = abs(updated.lowerBound - range.lowerBound) > tolerance / 2 || abs(updated.upperBound - range.upperBound) > tolerance / 2
        return changed ? updated : nil
    }

    /// Move one edge by `delta` seconds (negative = earlier). nil when the
    /// limits or the minimum span stop it.
    static func nudged(_ range: ClosedRange<Double>, edge: Edge, by delta: Double,
                       limits: ClosedRange<Double>) -> ClosedRange<Double>? {
        let time = (edge == .start ? range.lowerBound : range.upperBound) + delta
        return moved(setting(edge, at: time, in: range, limits: limits), from: range, edge: edge, tolerance: 0.001)
    }

    /// Move one edge to a speaker-turn boundary: growing, to the boundary
    /// of the turn the edge sits in; shrinking, to the nearest boundary
    /// inside the range. nil when no turn applies or nothing would move.
    static func turned(_ range: ClosedRange<Double>, edge: Edge, grow: Bool, spans: [SpeakerSpan],
                       limits: ClosedRange<Double>, tolerance: Double = 0.05) -> ClosedRange<Double>? {
        let target: Double?
        if grow {
            let time = edge == .start ? range.lowerBound : range.upperBound
            let covering = spans.filter { $0.start - tolerance <= time && time <= $0.end + tolerance }
            // At a boundary two turns touch, prefer the one that extends the range.
            let turn = edge == .start
                ? covering.min(by: { $0.start < $1.start })
                : covering.max(by: { $0.end < $1.end })
            target = turn.map { edge == .start ? $0.start : $0.end }
        } else {
            let open = (range.lowerBound + tolerance)..<(range.upperBound - tolerance)
            target = edge == .start
                ? spans.map(\.start).filter { open.contains($0) }.min()
                : spans.map(\.end).filter { open.contains($0) }.max()
        }
        guard let target else { return nil }
        return moved(setting(edge, at: target, in: range, limits: limits), from: range, edge: edge, tolerance: tolerance)
    }

    /// Ends with . ? ! or … after closing quotes and brackets.
    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]»"))
        guard let last = trimmed.last else { return false }
        return ".?!…".contains(last)
    }

    private static func moved(_ updated: ClosedRange<Double>, from range: ClosedRange<Double>, edge: Edge,
                              tolerance: Double) -> ClosedRange<Double>? {
        let delta = edge == .start ? abs(updated.lowerBound - range.lowerBound) : abs(updated.upperBound - range.upperBound)
        return delta > tolerance / 2 ? updated : nil
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
