import Foundation

/// Source rows and turns are keyed by clip UID so repeated scenes and sources
/// cannot borrow another video's transcript. Callers resolve scene-only clips'
/// sourceStart/sourceEnd before planning, just as the renderer does.
nonisolated enum DubPlanning {
    static func lines(document: TimelineDocument, rows: [UUID: [TranscriptRow]],
                      turns: [UUID: [SpeakerTurn]], settings: DubSettings) -> [DubLine] {
        var result: [DubLine] = []
        for clip in document.videoTrack {
            guard !clip.muted, !clip.bumper, !clip.isCutaway, clip.duration > 0,
                  !(document.trackSettings.indices.contains(clip.track) && document.trackSettings[clip.track].muted)
            else { continue }
            let speed = clip.speed ?? 1
            guard speed.isFinite, speed > 0, let sourceStart = clip.sourceStart else { continue }
            let sourceEnd = min(clip.sourceEnd ?? (sourceStart + clip.duration * speed),
                                sourceStart + clip.duration * speed)
            for row in rows[clip.uid] ?? [] where row.isTranslation && row.language == settings.language {
                let start = max(sourceStart, row.startTime), end = min(sourceEnd, row.endTime)
                let span = row.endTime - row.startTime
                guard span > 0, end > start, (end - start) / span >= 0.4 - 1e-9 else { continue }
                let text = trimmedText(row, start: start, end: end)
                guard !text.isEmpty else { continue }
                let speaker: String
                switch row.speaker {
                case .person(let key): speaker = key
                case .unknown: speaker = "unknown"
                case .automatic:
                    let midpoint = (row.startTime + row.endTime) / 2
                    speaker = (turns[clip.uid] ?? []).first {
                        $0.videoID == row.videoID && $0.start <= midpoint && midpoint < $0.end
                    }?.personKey ?? "unknown"
                }
                result.append(DubLine(clipUID: clip.uid, speakerKey: speaker,
                    voice: settings.voices[speaker] ?? settings.voices["unknown"] ?? "", text: text,
                    sourceStart: start, sourceEnd: end,
                    start: clip.startTime + (start - sourceStart) / speed, duration: (end - start) / speed))
            }
        }
        // Stable input order breaks ties; overlapping speakers keep both lines.
        result = result.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        var furthest: Int?
        for index in result.indices {
            if let previous = furthest {
                let end = result[previous].start + result[previous].duration
                if result[index].start < end {
                    result[index].tight = true
                    result[previous].tight = true
                }
                if result[index].start + result[index].duration > end { furthest = index }
            } else {
                furthest = index
            }
        }
        return result
    }

    private static func trimmedText(_ row: TranscriptRow, start: Double, end: Double) -> String {
        guard start > row.startTime || end < row.endTime else {
            return row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let json = row.wordsJSON, let data = json.data(using: .utf8),
           let words = try? JSONDecoder().decode([TranscriptWord].self, from: data), !words.isEmpty {
            return words.filter { $0.start >= start && $0.end <= end }.map(\.word)
                .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Translations usually have no word times. Give each word an equal
        // portion of the row, then keep only whole words within the trim.
        let words = row.text.split(whereSeparator: \.isWhitespace)
        let span = row.endTime - row.startTime
        let lower = min(words.count, max(0, Int(ceil((start - row.startTime) / span * Double(words.count) - 1e-9))))
        let upper = min(words.count, max(lower, Int(floor((end - row.startTime) / span * Double(words.count) + 1e-9))))
        return words[lower..<upper].joined(separator: " ")
    }

    static func slot(for line: DubLine, next: DubLine?) -> Double {
        let span = max(0, line.duration)
        guard let next else { return span } // No known trailing silence.
        return span + min(0.6, max(0, next.start - line.start - span))
    }

    static func fit(duration: Double, slot: Double) -> (rate: Double, stretch: Double, tight: Bool) {
        guard duration.isFinite, slot.isFinite, slot > 0 else { return (1.25, 1.15, true) }
        let ratio = max(1, duration / slot)
        let rate = min(1.25, ratio)
        let stretch = min(1.15, max(1, ratio / rate))
        return (rate, stretch, duration / rate / stretch > slot + 1e-9)
    }

    /// Attack before the line and release after it. Max combines envelopes
    /// without double-ducking overlapping speakers or briefly raising gaps
    /// where two ramps cross. Commas are escaped for FFmpeg's filter parser.
    static func duckExpression(lines: [DubLine], level: Double, ramp: Double) -> String {
        let envelopes = lines.filter { $0.duration > 0 }.map { line in
            let start = number(line.start), end = number(line.start + line.duration)
            guard ramp > 0 else { return "between(t\\,\(start)\\,\(end))" }
            let attack = number(line.start - ramp), release = number(line.start + line.duration + ramp)
            return "max(0\\,min(1\\,min((t-\(attack))/\(number(ramp))\\,(\(release)-t)/\(number(ramp)))))"
        }
        guard !envelopes.isEmpty else { return "1.0" }
        return "1-\(number(1 - min(1, max(0, level))))*(\(balancedMax(envelopes[...])))"
    }

    /// Combines terms with `max()` as a balanced tree. A left fold nests one
    /// level per line and ffmpeg's expression parser rejects a few hundred
    /// levels deep ("Error when evaluating the volume expression"); a balanced
    /// tree stays about log2(n) deep.
    static func balancedMax(_ terms: ArraySlice<String>) -> String {
        if terms.count == 1 { return terms[terms.startIndex] }
        let middle = terms.startIndex + terms.count / 2
        return "max(\(balancedMax(terms[..<middle]))\\,\(balancedMax(terms[middle...])))"
    }

    static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
