import Foundation

/// The source clock selects complete words; the voice clock supplies the cut.
/// Invalid or missing alignment must never be guessed into clipped speech.
nonisolated enum DubTakeCutter {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func wordRange(text: String, rowStart: Double, rowEnd: Double,
                          start: Double, end: Double, words: [TranscriptWord]? = nil) -> Range<Int>? {
        guard [rowStart, rowEnd, start, end].allSatisfy(\.isFinite), rowEnd > rowStart,
              end > start else { return nil }
        let count = normalized(text).split(separator: " ").count
        if let words, words.count == count,
           normalized(words.map(\.word).joined(separator: " ")) == normalized(text),
           words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
           start > rowStart || end < rowEnd {
            let selected = words.indices.filter { words[$0].start >= start && words[$0].end <= end }
            guard let first = selected.first, let last = selected.last,
                  selected.count == last - first + 1 else { return nil }
            return first..<(last + 1)
        }
        let lower = min(count, max(0, Int(ceil(max(0, min(1, (start - rowStart) / (rowEnd - rowStart))) * Double(count) - 1e-9))))
        let upper = min(count, max(lower, Int(floor(max(0, min(1, (end - rowStart) / (rowEnd - rowStart))) * Double(count) + 1e-9))))
        return lower < upper ? lower..<upper : nil
    }

    static func text(_ text: String, rowStart: Double, rowEnd: Double, start: Double, end: Double, words: [TranscriptWord]? = nil) -> String {
        guard let range = wordRange(text: text, rowStart: rowStart, rowEnd: rowEnd, start: start, end: end, words: words) else { return "" }
        return normalized(text).split(separator: " ")[range].joined(separator: " ")
    }

    static func timeRange(text: String, alignment: DubTakeAlignment?, rowStart: Double, rowEnd: Double,
                          start: Double, end: Double, words: [TranscriptWord]? = nil) -> Range<Double>? {
        guard let alignment, alignment.isValid,
              normalized(alignment.characters.joined()) == normalized(text),
              let selected = wordRange(text: text, rowStart: rowStart, rowEnd: rowEnd, start: start, end: end, words: words)
        else { return nil }
        var words: [Range<Int>] = []
        var first: Int?
        for (index, character) in alignment.characters.enumerated() {
            if character.allSatisfy(\.isWhitespace) {
                if let beginning = first { words.append(beginning..<index); first = nil }
            } else if first == nil { first = index }
        }
        if let first { words.append(first..<alignment.characters.count) }
        guard selected.upperBound <= words.count else { return nil }
        let lower = alignment.starts[words[selected.lowerBound].lowerBound]
        let upper = alignment.ends[words[selected.upperBound - 1].upperBound - 1]
        return upper > lower ? lower..<upper : nil
    }
}

nonisolated struct DubTakeAlignment: Codable, Sendable, Equatable {
    var characters: [String]
    var starts: [Double]
    var ends: [Double]

    enum CodingKeys: String, CodingKey {
        case characters
        case starts = "character_start_times_seconds"
        case ends = "character_end_times_seconds"
    }

    var isValid: Bool {
        guard !characters.isEmpty, characters.count == starts.count, starts.count == ends.count else { return false }
        for index in starts.indices {
            guard starts[index].isFinite, ends[index].isFinite, starts[index] >= 0,
                  ends[index] >= starts[index], index == 0 || starts[index] >= starts[index - 1] else { return false }
        }
        return true
    }
}
