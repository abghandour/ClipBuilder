import Foundation

/// Second opinion on the speaker turns from the words themselves. The
/// tracker follows the picture — the call app's active-speaker border and
/// mouth motion — and both hop to another tile for a couple of seconds
/// whenever someone laughs or nods along. A hop in the middle of a sentence
/// is not a handover: when the same person speaks before and after it and
/// the transcript runs on across it without a sentence ending or a pause,
/// the hop is folded back into that person's turn.
nonisolated enum SpeakerTurnCleanup {
    /// The longest hop a sentence can run across and still be a reaction.
    static let maximumInterjection = 3.0
    /// A pause at least this long before a hop means the sentence stopped:
    /// the hop may be a real, short handover.
    static let pause = 0.6

    /// `supported` says a hop's own speaker is backed by the voice (the
    /// tracker stores that as the turn's confidence once the voice is
    /// trusted): such a hop is a short answer and stands, whatever the
    /// words around it look like.
    static func absorbInterjections(_ turns: [SpeakerTurn], words: [TranscriptWord],
                                    maximumInterjection: Double = maximumInterjection,
                                    supported: (SpeakerTurn) -> Bool = { _ in false }) -> [SpeakerTurn] {
        guard turns.count >= 3 else { return turns }
        let sorted = turns.sorted { $0.start < $1.start }
        let timed = words.sorted { $0.start < $1.start }
        var result: [SpeakerTurn] = []
        var index = 0
        while index < sorted.count {
            let turn = sorted[index]
            guard index > 0, index + 1 < sorted.count,
                  let before = result.last,
                  let after = Optional(sorted[index + 1]),
                  speaker(before) == speaker(after), speaker(turn) != speaker(before),
                  turn.end - turn.start <= maximumInterjection,
                  !supported(turn),
                  sentenceRunsAcross(start: turn.start, end: turn.end, words: timed)
            else {
                result.append(turn)
                index += 1
                continue
            }
            // Fold the hop and the turn after it into the one before.
            var merged = before
            merged.end = max(before.end, after.end)
            result[result.count - 1] = merged
            index += 2
        }
        return result
    }

    /// True when the words show one sentence continuing through the hop:
    /// a word just before it that does not end a sentence, another word
    /// inside or just after it, and no pause between them. With no timed
    /// words at all there is nothing to say, so the hop stands.
    static func sentenceRunsAcross(start: Double, end: Double, words: [TranscriptWord]) -> Bool {
        guard let last = words.last(where: { $0.end <= start + 0.05 }) else { return false }
        guard let next = words.first(where: { $0.start >= last.end - 0.05 && $0.start < end + pause }) else { return false }
        let text = last.word.trimmingCharacters(in: .whitespacesAndNewlines)
        if let final = text.last, ".?!…".contains(final) { return false }
        return next.start - last.end < pause
    }

    private static func speaker(_ turn: SpeakerTurn) -> String { identity(turn) }

    /// Who a turn belongs to, as the transcript labels it: the named person,
    /// else the tile (the tracker tells tiles apart even when their voices
    /// share a cluster), else the voice cluster.
    static func identity(_ turn: SpeakerTurn) -> String {
        turn.personKey ?? (turn.tile.map { "tile:\($0)" } ?? "voice:\(turn.cluster)")
    }
}
