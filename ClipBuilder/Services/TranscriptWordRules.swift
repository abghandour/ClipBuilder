import Foundation

/// Doubtful words of a transcript line and the edits made to them in the
/// Transcript editor. A word is named by its line and its position among
/// the line's whitespace-separated tokens, never by a text search, so a
/// repeated word is still the exact occurrence.
nonisolated enum TranscriptWordRules {
    /// Recognizer confidence under this is doubtful.
    static let doubtfulThreshold = 0.5

    struct WordID: Hashable, Sendable {
        var rowID: Int64
        /// Position among the line's tokens, which is also the index of
        /// its stored word (see `aligned`).
        var index: Int
    }

    struct Doubt: Equatable, Identifiable, Sendable {
        var id: WordID
        /// The token as the line shows it, punctuation included.
        var text: String
        var confidence: Double?
        var suggestion: TranscriptWordSuggestion?
        var start: Double
        var end: Double
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The line's stored words when there is exactly one per token of its
    /// text, in order. Anything else (no words, a hand-synced line, a
    /// translation) has no per-word marks: fail closed rather than
    /// underline the wrong word.
    static func aligned(_ row: TranscriptRow) -> [TranscriptWord]? {
        guard !row.isTranslation, let words = row.words, !words.isEmpty else { return nil }
        let tokens = tokens(row.text)
        guard tokens.count == words.count else { return nil }
        for (token, word) in zip(tokens, words) where fold(token) != fold(word.word) { return nil }
        return words
    }

    static func isDoubtful(_ word: TranscriptWord) -> Bool {
        if word.confidence == 1 { return false }
        if word.suggestion != nil { return true }
        return word.confidence.map { $0 < doubtfulThreshold } ?? false
    }

    /// The line's doubtful words, in reading order.
    static func doubts(in row: TranscriptRow) -> [Doubt] {
        guard let words = aligned(row) else { return [] }
        let tokens = tokens(row.text)
        return words.enumerated().compactMap { index, word in
            guard isDoubtful(word) else { return nil }
            return Doubt(id: .init(rowID: row.id, index: index), text: tokens[index], confidence: word.confidence,
                         suggestion: word.suggestion, start: word.start, end: word.end)
        }
    }

    /// Every doubtful word of these lines, in transcript order.
    static func doubts(in rows: [TranscriptRow]) -> [Doubt] {
        rows.filter { !$0.isTranslation }
            .sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
            .flatMap(doubts(in:))
    }

    /// A token as punctuation before, the word, punctuation after: the fix
    /// field edits the word and the punctuation stays where it was.
    static func parts(_ token: String) -> (prefix: String, core: String, suffix: String) {
        let punctuation = CharacterSet.punctuationCharacters
        let scalars = Array(token.unicodeScalars)
        let leading = scalars.prefix { punctuation.contains($0) }.count
        let trailing = scalars.dropFirst(leading).reversed().prefix { punctuation.contains($0) }.count
        func string(_ slice: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(slice)) }
        return (string(scalars.prefix(leading)), string(scalars[leading..<(scalars.count - trailing)]),
                string(scalars.suffix(trailing)))
    }

    /// The token with its word replaced; an empty replacement removes the
    /// token and its punctuation.
    static func replacement(for token: String, with text: String) -> String {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "" }
        let parts = parts(token)
        // Punctuation typed (or suggested) with the word is not doubled.
        return (text.hasPrefix(parts.prefix) ? "" : parts.prefix) + text + (text.hasSuffix(parts.suffix) ? "" : parts.suffix)
    }

    /// A replacement without the edge punctuation the heard token already
    /// carries ("Grappler," for "Rpper," is the word "Grappler").
    static func strippingPunctuation(of token: String, from text: String) -> String {
        let parts = parts(token)
        var text = Substring(text)
        if !parts.prefix.isEmpty, text.hasPrefix(parts.prefix) { text = text.dropFirst(parts.prefix.count) }
        if !parts.suffix.isEmpty, text.hasSuffix(parts.suffix) { text = text.dropLast(parts.suffix.count) }
        return String(text)
    }

    /// Where each token of the fixed text came from (new position to old),
    /// for the tokens the fixes left alone. `fixes` is old position to the
    /// new token or tokens ("" removes it), as `replacing` takes them.
    static func keptPositions(tokenCount: Int, fixes: [Int: String]) -> [Int: Int] {
        var kept: [Int: Int] = [:]
        var next = 0
        for old in 0..<max(0, tokenCount) {
            if let fix = fixes[old] {
                next += tokens(fix).count
            } else {
                kept[next] = old
                next += 1
            }
        }
        return kept
    }

    /// The stored word a token of the fixed text came from, and which of
    /// that word's replacement tokens it is (0 for a word left alone).
    static func origin(of index: Int, tokenCount: Int, fixes: [Int: String]) -> (position: Int, offset: Int)? {
        var next = 0
        for old in 0..<max(0, tokenCount) {
            let count = fixes[old].map { tokens($0).count } ?? 1
            if index >= next, index < next + count { return (old, index - next) }
            next += count
        }
        return nil
    }

    /// The line's text with these tokens replaced (token position to the
    /// whole new token; "" removes it). Positions are in the given text.
    static func replacing(text: String, fixes: [Int: String]) -> String {
        guard !fixes.isEmpty else { return text }
        return tokens(text).enumerated().compactMap { index, token -> String? in
            guard let fix = fixes[index] else { return token }
            return fix.isEmpty ? nil : fix
        }.joined(separator: " ")
    }

    /// The words with these positions marked right. Nil when any position
    /// no longer holds the expected word: the line changed underneath.
    static func confirming(_ expected: [Int: String], words: [TranscriptWord]) -> [TranscriptWord]? {
        var words = words
        for (index, text) in expected {
            guard words.indices.contains(index), fold(words[index].word) == fold(text) else { return nil }
            words[index].confidence = 1
            words[index].suggestion = nil
        }
        return words
    }

    /// After a text edit rebuilt the words from the transcriber's originals:
    /// a word the edit left alone keeps what the user and Proofread said
    /// about it since (marked right, suggestion, suggestion cleared).
    /// `keeping` (new position to old) names the exact word each one was
    /// when the edit is a list of word fixes; without it the words are
    /// matched by their text, which cannot tell a repeated word apart.
    static func carryingMarks(from current: [TranscriptWord]?, onto words: [TranscriptWord]?,
                              keeping: [Int: Int]? = nil) -> [TranscriptWord]? {
        guard var words, let current, !current.isEmpty else { return words }
        let matches = keeping ?? TranscriptWordAlignment.matches(tokens: words.map(\.word), original: current)
        for (new, old) in matches where words.indices.contains(new) && current.indices.contains(old) {
            let before = current[old]
            guard before.word.trimmingCharacters(in: .whitespacesAndNewlines) == words[new].word else { continue }
            words[new].confidence = before.confidence
            words[new].suggestion = before.suggestion
        }
        return words
    }

    /// The transcriber's rows going back over re-cut ones: a word still at
    /// the same time with the same text keeps what was marked on it since
    /// the backup was made.
    static func carryingMarks(fromRecut current: [TranscriptWord], onto words: [TranscriptWord]) -> [TranscriptWord] {
        let marks = Dictionary(current.map { (wordKey($0.word, start: $0.start), $0) }, uniquingKeysWith: { first, _ in first })
        return words.map { word in
            guard let now = marks[wordKey(word.word, start: word.start)] else { return word }
            var word = word
            word.confidence = now.confidence
            word.suggestion = now.suggestion
            return word
        }
    }

    /// A word by what it says and when: the same word across a re-cut, a
    /// revert or an edit made while Proofread was out.
    static func wordKey(_ text: String, start: Double) -> String {
        "\(Int((start * 1000).rounded()))|\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Proofread's suggestions written onto the words it read. Every word
    /// in `covered` first loses its old suggestion, so a second run
    /// replaces the first. A suggestion lands only where the word still
    /// reads as Proofread heard it and the user has not marked it right.
    /// `read` is the word Proofread saw at each covered position (its
    /// `wordKey`): when any of them is another word now, the line was
    /// edited while the request was out and positions no longer name the
    /// same words, so nothing on it is touched.
    static func suggesting(_ suggestions: [Int: (heard: String, suggestion: TranscriptWordSuggestion)],
                           covered: Set<Int>, read: [Int: String]? = nil,
                           words: [TranscriptWord]) -> (words: [TranscriptWord], count: Int) {
        if let read {
            for (index, text) in read {
                guard words.indices.contains(index),
                      wordKey(words[index].word, start: words[index].start) == text else { return (words, 0) }
            }
        }
        var words = words
        var count = 0
        for index in covered where words.indices.contains(index) { words[index].suggestion = nil }
        for (index, item) in suggestions {
            guard words.indices.contains(index), covered.contains(index), words[index].confidence != 1,
                  words[index].word.trimmingCharacters(in: .whitespacesAndNewlines) == item.heard else { continue }
            words[index].suggestion = item.suggestion
            count += 1
        }
        return (words, count)
    }

    /// Two seconds around the word, for hearing it in context.
    static func listenRange(start: Double, end: Double, duration: Double) -> ClosedRange<Double> {
        let lower = max(0, start - 1)
        let upper = max(lower + 0.2, end + 1)
        return lower...(duration > lower ? min(duration, upper) : upper)
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
