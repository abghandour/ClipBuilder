import Foundation

nonisolated enum TranscriptEmphasisRules {
    struct Edit: Sendable, Equatable {
        var text: String
        /// "automatic" clears the stored Optional; the other values are persisted.
        var marks: [Int: String]
    }

    static func applying(_ edit: Edit, text: String, words: [TranscriptWord]?,
                         start: Double, end: Double) -> [TranscriptWord]? {
        guard edit.text == text else { return nil }
        let tokens = TranscriptWordRules.tokens(text)
        guard !tokens.isEmpty, edit.marks.keys.allSatisfy(tokens.indices.contains),
              edit.marks.values.allSatisfy({ ["automatic", "none", "primary", "alternate"].contains($0) }) else { return nil }
        var result: [TranscriptWord]
        if let words {
            guard words.count == tokens.count,
                  zip(words, tokens).allSatisfy({ $0.word.trimmingCharacters(in: .whitespacesAndNewlines) == $1 }) else { return nil }
            result = words
        } else {
            // Translations and legacy untimed rows own their own evenly timed words.
            let step = max(0, end - start) / Double(tokens.count)
            result = tokens.enumerated().map {
                TranscriptWord(word: $0.element, start: start + Double($0.offset) * step,
                               end: start + Double($0.offset + 1) * step)
            }
        }
        for (index, mark) in edit.marks { result[index].emphasis = mark == "automatic" ? nil : mark }
        return result
    }
}
