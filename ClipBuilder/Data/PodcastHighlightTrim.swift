import Foundation

/// Word-snapped trimming of a highlight candidate against the recording's
/// transcript. Both trim surfaces (the filmstrip handles and clicks on
/// transcript words) go through here so a cut never lands mid-word.
nonisolated struct PodcastHighlightTrim: Sendable, Equatable {
    /// One timed token of the transcript: a transcriber word when the
    /// provider recorded them, else a whole segment.
    struct Word: Sendable, Equatable, Identifiable {
        var id: Int
        var text: String
        var start: Double
        var end: Double
        var mid: Double { (start + end) / 2 }
    }

    /// One transcript segment with its words, for the panel.
    struct Line: Sendable, Equatable, Identifiable {
        var id: Int
        var start: Double
        var end: Double
        var speaker: String?
        var words: [Word]
    }

    static let minimumSpan = 1.0
    /// A cut sits this far before the first word / after the last so the
    /// word is not clipped by a frame.
    static let cutPadding = 0.08

    let lines: [Line]
    let words: [Word]
    let duration: Double

    init(segments: [TranscriptSegment], turns: [SpeakerTurn] = [], roster: [VideoPersonRecord] = [],
         duration: Double) {
        var lines: [Line] = []
        var words: [Word] = []
        var previousSpeaker: String?
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            var lineWords: [Word] = []
            let timed = (segment.words ?? []).filter { $0.end > $0.start && !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }
            if timed.isEmpty {
                guard segment.end > segment.start else { continue }
                lineWords.append(Word(id: words.count, text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                      start: segment.start, end: segment.end))
            } else {
                for word in timed.sorted(by: { $0.start < $1.start }) {
                    lineWords.append(Word(id: words.count + lineWords.count,
                                          text: word.word.trimmingCharacters(in: .whitespaces),
                                          start: word.start, end: word.end))
                }
            }
            words.append(contentsOf: lineWords)
            let speaker = Self.speaker(start: segment.start, end: segment.end, turns: turns, roster: roster)
            lines.append(Line(id: lines.count, start: segment.start, end: segment.end,
                              speaker: speaker == previousSpeaker ? nil : speaker, words: lineWords))
            if let speaker { previousSpeaker = speaker }
        }
        self.lines = lines
        self.words = words
        self.duration = max(duration, words.last?.end ?? 0)
    }

    /// Who the speaker turns say is talking over most of [start, end].
    static func speaker(start: Double, end: Double, turns: [SpeakerTurn], roster: [VideoPersonRecord]) -> String? {
        var best: (turn: SpeakerTurn, overlap: Double)?
        for turn in turns {
            let overlap = min(turn.end, end) - max(turn.start, start)
            guard overlap > 0, overlap > (best?.overlap ?? 0) else { continue }
            best = (turn, overlap)
        }
        guard let turn = best?.turn else { return nil }
        if let key = turn.personKey {
            return roster.first { $0.key == key }?.displayName ?? key
        }
        return "Speaker \(turn.cluster + 1)"
    }

    // MARK: - Snapping

    /// The word whose start is nearest `time`.
    func wordStarting(nearest time: Double) -> Word? {
        words.min { abs($0.start - time) < abs($1.start - time) }
    }

    /// The word whose end is nearest `time`.
    func wordEnding(nearest time: Double) -> Word? {
        words.min { abs($0.end - time) < abs($1.end - time) }
    }

    /// A cut just before the word nearest `time` (no words: `time` itself).
    func snappedStart(_ time: Double) -> Double {
        guard let word = wordStarting(nearest: time) else { return max(0, time) }
        return max(0, word.start - Self.cutPadding)
    }

    /// A cut just after the word nearest `time`.
    func snappedEnd(_ time: Double) -> Double {
        guard let word = wordEnding(nearest: time) else { return min(duration, time) }
        return min(duration, word.end + Self.cutPadding)
    }

    /// Both ends snapped to words, kept in order and at least a second apart.
    func snapped(start: Double, end: Double) -> ClosedRange<Double> {
        var lower = snappedStart(min(start, end))
        var upper = snappedEnd(max(start, end))
        if upper - lower < Self.minimumSpan {
            // Too short for a reel: grow toward the side with room.
            if lower + Self.minimumSpan <= duration {
                upper = snappedEnd(lower + Self.minimumSpan)
                if upper - lower < Self.minimumSpan { upper = min(duration, lower + Self.minimumSpan) }
            } else {
                lower = max(0, upper - Self.minimumSpan)
            }
        }
        return lower...max(lower, upper)
    }

    /// Which end a click on `word` moves: the nearer one. A word outside the
    /// selection extends the end on its side; a word inside trims the end
    /// it is closer to.
    enum Edge: Sendable { case start, end }

    func edge(for word: Word, in range: ClosedRange<Double>) -> Edge {
        if word.mid < range.lowerBound { return .start }
        if word.mid > range.upperBound { return .end }
        return word.mid - range.lowerBound <= range.upperBound - word.mid ? .start : .end
    }

    /// The selection after clicking `word`: the nearer end moves to it.
    func range(_ range: ClosedRange<Double>, selecting word: Word) -> ClosedRange<Double> {
        switch edge(for: word, in: range) {
        case .start:
            return snapped(start: word.start, end: max(range.upperBound, word.end))
        case .end:
            return snapped(start: min(range.lowerBound, word.start), end: word.end)
        }
    }

    /// True when the word is spoken inside the selection.
    func contains(_ word: Word, in range: ClosedRange<Double>) -> Bool {
        word.mid >= range.lowerBound && word.mid <= range.upperBound
    }

    /// The line spoken at `time`, for following playback.
    func lineID(at time: Double) -> Int? {
        lines.last { $0.start <= time + 0.05 }?.id
    }
}

extension HighlightCandidate {
    /// True when the ends differ from `original` by more than a frame.
    func isTrimmed(from original: HighlightCandidate) -> Bool {
        abs(sourceStart - original.sourceStart) > 0.02 || abs(sourceEnd - original.sourceEnd) > 0.02
    }
}
