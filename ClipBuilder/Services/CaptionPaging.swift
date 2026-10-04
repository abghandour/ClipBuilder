import Foundation

nonisolated struct CaptionPage: Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// Word-preserving pagination. Measurement belongs to the renderer, not this planner.
nonisolated enum CaptionPaging {
    static func pages(text: String, start: Double, end: Double, words: [TranscriptWord]? = nil,
                      fits: (String) -> Bool) -> [CaptionPage] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, start.isFinite, end.isFinite, end > start else { return [] }
        func joined(_ range: Range<Int>) -> String { tokens[range].joined(separator: " ") }
        var ranges: [Range<Int>] = []
        var cursor = 0
        while cursor < tokens.count {
            var limit = cursor + 1 // An indivisible word always gets a page.
            while limit < tokens.count, fits(joined(cursor..<(limit + 1))) { limit += 1 }
            if limit < tokens.count {
                let lower = cursor + max(1, Int(ceil(Double(limit - cursor) * 2 / 3)))
                let candidates = Array(lower...limit).reversed()
                func punctuation(_ index: Int) -> Character? {
                    tokens[index - 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}")).last
                }
                if let sentence = candidates.first(where: { punctuation($0).map { ".!?…。！？".contains($0) } ?? false }) {
                    limit = sentence
                } else if let comma = candidates.first(where: { punctuation($0).map { ",，;；".contains($0) } ?? false }) {
                    limit = comma
                }
            }
            ranges.append(cursor..<limit)
            cursor = limit
        }
        // Only use word clocks if they describe this exact text (never time a
        // translation with its original-language words).
        let timed = words.flatMap { values -> [TranscriptWord]? in
            guard values.count == tokens.count,
                  zip(values, tokens).allSatisfy({ $0.word.trimmingCharacters(in: .whitespacesAndNewlines) == $1 }),
                  values.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
                  zip(values, values.dropFirst()).allSatisfy({ $0.start <= $1.start }) else { return nil }
            return values
        }
        if let timed {
            return ranges.enumerated().compactMap { index, range in
                let pageStart = max(start, timed[range.lowerBound].start)
                let nextStart = index + 1 < ranges.count ? timed[ranges[index + 1].lowerBound].start : timed[range.upperBound - 1].end
                let pageEnd = min(end, max(timed[range.upperBound - 1].end, nextStart))
                guard pageEnd > pageStart else { return nil }
                return CaptionPage(text: joined(range), start: pageStart, end: pageEnd)
            }
        }
        let duration = end - start
        func weights() -> [Double] { ranges.map { Double(joined($0).count) } }
        if ranges.count > 1 {
            let counts = weights()
            if duration * counts.last! / counts.reduce(0, +) < 0.8 {
                let merged = ranges[ranges.count - 2].lowerBound..<ranges.last!.upperBound
                if fits(joined(merged)) { ranges.removeLast(2); ranges.append(merged) }
            }
        }
        let counts = weights()
        // Water-fill: short pages borrow from long ones. If the whole segment
        // cannot supply 0.8s each, share its available time without overrunning.
        let floor = min(0.8, duration / Double(ranges.count))
        var lengths = Array(repeating: 0.0, count: ranges.count)
        var remaining = Array(ranges.indices)
        var budget = duration
        while !remaining.isEmpty {
            let total = remaining.reduce(0.0) { $0 + counts[$1] }
            let short = remaining.filter { budget * counts[$0] / total < floor }
            if short.isEmpty {
                for index in remaining { lengths[index] = budget * counts[index] / total }
                break
            }
            for index in short { lengths[index] = floor; budget -= floor }
            remaining.removeAll { short.contains($0) }
        }
        var time = start
        return ranges.enumerated().map { index, range in
            let next = index == ranges.count - 1 ? end : time + lengths[index]
            defer { time = next }
            return CaptionPage(text: joined(range), start: time, end: next)
        }
    }
}
