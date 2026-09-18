import Foundation

/// Re-cuts transcript rows so each one belongs to a single speaker. The
/// transcriber cuts rows at pauses with no idea who is talking; the podcast
/// pass later works out the speaker turns. A row that straddles a turn
/// boundary is split there — at the nearest gap between its timed words —
/// so "Marcelo finishing, then guernuiel" becomes two rows, each labelled
/// with its own speaker. Local arithmetic only.
nonisolated enum TranscriptSpeakerRecut {
    /// One row of the re-cut transcript.
    struct Piece: Sendable, Equatable {
        var start: Double
        var end: Double
        var text: String
        var words: [TranscriptWord]?
        var sourceRowID: Int64
        /// The source row's manual attribution, carried onto every piece.
        var speakerKey: String?
        /// True when the source row was split (false: passed through).
        var split: Bool
    }

    struct Plan: Sendable, Equatable {
        var pieces: [Piece]
        /// Source rows that were split into two or more pieces.
        var splitRows: Int
        var hasChanges: Bool { splitRows > 0 }
    }

    /// A speaker change shorter than this inside a row is an interjection
    /// ("uh-huh"), not a handover: it stays with the neighbouring speaker.
    static let minimumTurn = 1.0

    /// The re-cut of a transcript's original-language rows (translations
    /// are left alone). Rows whose text was edited by hand are never split:
    /// their words no longer match their text.
    static func plan(rows: [TranscriptRow], turns rawTurns: [SpeakerTurn],
                     minimumTurn: Double = minimumTurn) -> Plan {
        // Hops the words show to be mid-sentence reactions are not cuts.
        let turns = SpeakerTurnCleanup.absorbInterjections(rawTurns, words: rows.flatMap { $0.words ?? [] })
        var pieces: [Piece] = []
        var splitRows = 0
        for row in rows.filter({ !$0.isTranslation }).sorted(by: { $0.startTime < $1.startTime }) {
            let cut = split(row, turns: turns, minimumTurn: minimumTurn)
            if cut.count > 1 { splitRows += 1 }
            pieces.append(contentsOf: cut)
        }
        return Plan(pieces: pieces, splitRows: splitRows)
    }

    /// One row into its per-speaker pieces; a single piece when nothing
    /// changes hands inside it.
    static func split(_ row: TranscriptRow, turns: [SpeakerTurn], minimumTurn: Double = minimumTurn) -> [Piece] {
        let passthrough = [Piece(start: row.startTime, end: row.endTime, text: row.text, words: row.words,
                                 sourceRowID: row.id, speakerKey: row.speakerKey, split: false)]
        guard row.originalText == nil else { return passthrough }
        let spans = speakerSpans(for: row, turns: turns, minimumTurn: minimumTurn)
        guard spans.count > 1 else { return passthrough }

        // Each word goes with the span holding its midpoint. Rows without
        // word timings are spread evenly over their range by token.
        let timed = row.words
        let tokens: [(text: String, start: Double, end: Double)]
        if let timed, !timed.isEmpty {
            tokens = timed.map { ($0.word, $0.start, $0.end) }
        } else {
            let parts = row.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count > 1 else { return passthrough }
            let step = (row.endTime - row.startTime) / Double(parts.count)
            tokens = parts.enumerated().map { index, part in
                (part, row.startTime + Double(index) * step, row.startTime + Double(index + 1) * step)
            }
        }
        var buckets = [[(text: String, start: Double, end: Double)]](repeating: [], count: spans.count)
        for token in tokens {
            let mid = (token.start + token.end) / 2
            let index = spans.firstIndex { mid >= $0.start && mid < $0.end }
                ?? (mid < spans[0].start ? 0 : spans.count - 1)
            buckets[index].append(token)
        }
        var pieces: [Piece] = []
        for (index, bucket) in buckets.enumerated() where !bucket.isEmpty {
            let start = index == 0 ? row.startTime : (bucket.map(\.start).min() ?? spans[index].start)
            let end = index == spans.count - 1 ? row.endTime : (bucket.map(\.end).max() ?? spans[index].end)
            let words = timed == nil ? nil : bucket.map { TranscriptWord(word: $0.text, start: $0.start, end: $0.end) }
            pieces.append(Piece(start: start, end: max(end, start + 0.01), text: joined(bucket.map(\.text)),
                                words: words, sourceRowID: row.id, speakerKey: row.speakerKey, split: true))
        }
        guard pieces.count > 1 else { return passthrough }
        // Pieces meet edge to edge: no gaps for captions to fall into.
        for index in 1..<pieces.count where pieces[index].start > pieces[index - 1].end {
            pieces[index - 1].end = pieces[index].start
        }
        return pieces
    }

    /// Who holds which part of the row: the overlapping turns in order,
    /// same-speaker neighbours merged, gaps given to the speaker before
    /// them, and spans shorter than `minimumTurn` folded into a neighbour —
    /// unless the span is short only because the row's edge clipped a
    /// longer turn, which is a real handover the next row continues.
    /// The first span starts at the row's start and the last ends at its end.
    static func speakerSpans(for row: TranscriptRow, turns: [SpeakerTurn],
                             minimumTurn: Double) -> [(start: Double, end: Double, speaker: String)] {
        var spans: [(start: Double, end: Double, speaker: String, whole: Double)] = []
        var cursor = row.startTime
        for turn in turns.sorted(by: { $0.start < $1.start })
            where turn.end > row.startTime && turn.start < row.endTime {
            let start = max(turn.start, cursor)
            let end = min(turn.end, row.endTime)
            guard end > start else { continue }
            let speaker = SpeakerTurnCleanup.identity(turn)
            if let last = spans.last, last.speaker == speaker {
                spans[spans.count - 1].end = end
                spans[spans.count - 1].whole = max(last.whole, turn.end - turn.start)
            } else {
                spans.append((start, end, speaker, turn.end - turn.start))
            }
            cursor = end
        }
        guard !spans.isEmpty else { return [] }
        spans[0].start = row.startTime
        spans[spans.count - 1].end = row.endTime
        // A silence between two turns stays with whoever spoke before it.
        for index in 1..<spans.count { spans[index - 1].end = spans[index].start }
        // Fold interjections into the longer neighbour, then re-merge.
        var changed = true
        while changed, spans.count > 1 {
            changed = false
            if let short = spans.indices.first(where: {
                spans[$0].end - spans[$0].start < minimumTurn && spans[$0].whole < minimumTurn
            }) {
                let previousLength = short > 0 ? spans[short - 1].end - spans[short - 1].start : -1
                let nextLength = short + 1 < spans.count ? spans[short + 1].end - spans[short + 1].start : -1
                if previousLength >= nextLength, short > 0 {
                    spans[short - 1].end = spans[short].end
                } else {
                    spans[short + 1].start = spans[short].start
                }
                spans.remove(at: short)
                changed = true
            }
            var merged: [(start: Double, end: Double, speaker: String, whole: Double)] = []
            for span in spans {
                if let last = merged.last, last.speaker == span.speaker {
                    merged[merged.count - 1].end = span.end
                    merged[merged.count - 1].whole = max(last.whole, span.whole)
                } else {
                    merged.append(span)
                }
            }
            if merged.count != spans.count { spans = merged; changed = true }
        }
        return spans.map { ($0.start, $0.end, $0.speaker) }
    }

    /// True when the current rows carry corrections the backup does not:
    /// text edited by hand (an original kept beside it that no backup row
    /// has) or a speaker set or cleared on a row whose backup source says
    /// otherwise. Such rows must not be thrown away for the backup.
    static func hasEdits(_ current: [TranscriptRow], beyond backup: [TranscriptRow]) -> Bool {
        let originals = backup.filter { !$0.isTranslation }
        let knownEdits = Set(originals.compactMap { row in row.originalText.map { [row.text, $0] } })
        for row in current where !row.isTranslation {
            if let original = row.originalText, !knownEdits.contains([row.text, original]) { return true }
            let mid = (row.startTime + row.endTime) / 2
            let source = originals.first { mid >= $0.startTime && mid < $0.endTime }
                ?? originals.first { $0.endTime > row.startTime && $0.startTime < row.endTime }
            if source?.speakerKey != row.speakerKey { return true }
        }
        return false
    }

    /// Word runs back into a line: runs keep their own spacing, so a space
    /// is added only where two runs would otherwise touch.
    static func joined(_ runs: [String]) -> String {
        var text = ""
        for run in runs {
            if let last = text.last, let first = run.first,
               !last.isWhitespace, !first.isWhitespace, !first.isPunctuation {
                text += " "
            }
            text += run
        }
        return text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated extension TranscriptRow {
    /// The row's timed words, when the transcriber recorded them.
    var words: [TranscriptWord]? {
        guard let data = wordsJSON?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([TranscriptWord].self, from: data)
    }
}
