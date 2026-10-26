import Foundation

nonisolated enum CaptionSpeakerColors {
    /// None of these is the default highlight or emphasis colour (#ffd60a),
    /// so a lit or emphasised word always differs from its speaker's text.
    static let palette = ["#ffffff", "#64d2ff", "#ff9f80", "#b8e986"]

    private static func key(for turn: SpeakerTurn) -> String {
        if let person = turn.personKey { return "person:" + person }
        if let tile = turn.tile { return "feed:\(tile)" }
        return "cluster:\(turn.cluster)"
    }

    /// Assign palette slots from the whole video's ordered turns, so cuts and
    /// translations retain the same colours. Explicit line attribution wins;
    /// a line crossing speakers uses the first overlapping turn, not the longest.
    static func speakerKey(for segment: TranscriptSegment, turns: [SpeakerTurn], rows: [TranscriptRow]) -> String? {
        speakerKey(for: segment, sorted: Sorted(turns: turns, rows: rows, paletteKeys: false))
    }

    /// One video's evidence sorted once, for callers that ask at every
    /// boundary or every frame. Same order the per-call overloads sort into.
    struct Sorted: Sendable {
        let originals: [TranscriptRow]
        let turns: [SpeakerTurn]
        /// Palette slot order: turn keys first, then hand-attributed people.
        let paletteKeys: [String]

        init(turns: [SpeakerTurn], rows: [TranscriptRow]) {
            self.init(turns: turns, rows: rows, paletteKeys: true)
        }

        fileprivate init(turns: [SpeakerTurn], rows: [TranscriptRow], paletteKeys: Bool) {
            originals = rows.filter { !$0.isTranslation }.sorted { $0.startTime < $1.startTime }
            self.turns = turns.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
            var keys: [String] = []
            if paletteKeys {
                for turn in self.turns {
                    let key = CaptionSpeakerColors.key(for: turn)
                    if !keys.contains(key) { keys.append(key) }
                }
                for row in originals {
                    if case .person(let person) = row.speaker, !keys.contains("person:" + person) { keys.append("person:" + person) }
                }
            }
            self.paletteKeys = keys
        }
    }

    static func speakerKey(for segment: TranscriptSegment, sorted: Sorted) -> String? {
        let line = sorted.originals.first { $0.endTime > segment.start && $0.startTime < segment.end }
        // A hand attribution counts even without diarized turns.
        if let line, case .person(let person) = line.speaker { return "person:" + person }
        let ordered = sorted.turns
        guard !ordered.isEmpty else { return nil }
        let selected: String?
        if let line, case .unknown = line.speaker {
            selected = nil
        } else {
            let start = line?.startTime ?? segment.start
            let end = line?.endTime ?? segment.end
            selected = ordered.first { $0.end > start && $0.start < end }.map { key(for: $0) }
        }
        return selected
    }

    static func personKey(_ speakerKey: String?) -> String? {
        guard let speakerKey, speakerKey.hasPrefix("person:") else { return nil }
        return String(speakerKey.dropFirst("person:".count))
    }

    static func color(for segment: TranscriptSegment, turns: [SpeakerTurn], rows: [TranscriptRow]) -> String? {
        color(for: segment, sorted: Sorted(turns: turns, rows: rows))
    }

    static func color(for segment: TranscriptSegment, sorted: Sorted) -> String? {
        guard let selected = speakerKey(for: segment, sorted: sorted),
              let index = sorted.paletteKeys.firstIndex(of: selected) else { return nil }
        return palette[index % palette.count]
    }
}
