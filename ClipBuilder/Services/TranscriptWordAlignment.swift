import Foundation

nonisolated enum TranscriptWordAlignment {
    /// Preserve matching clocks and divide unmatched runs between their neighbours.
    static func realign(text: String, original: [TranscriptWord]?,
                        start: Double, end: Double) -> [TranscriptWord]? {
        guard let original, !original.isEmpty else { return nil }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        func normalized(_ token: String) -> String {
            token.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        }
        let old = original.map { normalized($0.word) }
        let new = tokens.map(normalized)
        let width = new.count + 1
        var lengths = [Int](repeating: 0, count: (old.count + 1) * width)
        for i in old.indices.reversed() {
            for j in new.indices.reversed() {
                lengths[i * width + j] = old[i] == new[j]
                    ? 1 + lengths[(i + 1) * width + j + 1]
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var matches: [Int: Int] = [:]
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                matches[j] = i
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        let upper = max(start, end)
        func clamp(_ value: Double) -> Double { min(upper, max(start, value)) }
        var result: [TranscriptWord] = []
        var cursor = start
        j = 0
        while j < tokens.count {
            if let index = matches[j] {
                let word = original[index]
                let lower = max(cursor, clamp(word.start))
                let finish = max(lower, clamp(word.end))
                result.append(.init(word: tokens[j], start: lower, end: finish))
                cursor = finish
                j += 1
            } else {
                let first = j
                while j < tokens.count, matches[j] == nil { j += 1 }
                let finish = max(cursor, matches[j].map { clamp(original[$0].start) } ?? upper)
                let step = (finish - cursor) / Double(j - first)
                for index in first..<j {
                    result.append(.init(word: tokens[index], start: cursor + Double(index - first) * step,
                                        end: cursor + Double(index - first + 1) * step))
                }
                cursor = finish
            }
        }
        return result
    }
}
