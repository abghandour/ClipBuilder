import Foundation

/// Find in the Transcript editor: every occurrence of the typed text in the
/// lines on show, ignoring case and accents, in reading order.
nonisolated enum TranscriptSearchRules {
    struct Match: Hashable, Sendable {
        /// The spoken line the match is under (a translation's own line).
        var lineID: Int64
        /// The row whose text holds it: the line itself or one translation.
        var rowID: Int64
        /// Which occurrence inside that row's text, from 0.
        var ordinal: Int
    }

    /// One line on show with the texts drawn under it, top to bottom.
    struct Line: Sendable {
        var id: Int64
        var texts: [(rowID: Int64, text: String)]
    }

    static func query(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let query = Self.query(query)
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            result.append(range)
            // An empty match cannot happen (the query is not empty), but never loop on one.
            from = range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound
        }
        return result
    }

    /// Each match of the query in a run of words read with one space between
    /// them, as the positions of the words it touches (a query of several
    /// words touches several).
    static func wordMatches(query: String, words: [String]) -> [[Int]] {
        guard !Self.query(query).isEmpty, !words.isEmpty else { return [] }
        let text = words.joined(separator: " ")
        var spans: [NSRange] = []
        var at = 0
        for word in words {
            let length = word.utf16.count
            spans.append(NSRange(location: at, length: length))
            at += length + 1
        }
        return ranges(of: query, in: text).compactMap { range in
            let found = NSRange(range, in: text)
            let touched = spans.indices.filter { NSIntersectionRange(spans[$0], found).length > 0 }
            return touched.isEmpty ? nil : touched
        }
    }

    static func matches(query: String, lines: [Line]) -> [Match] {
        guard !Self.query(query).isEmpty else { return [] }
        return lines.flatMap { line in
            line.texts.flatMap { entry in
                ranges(of: query, in: entry.text).indices.map { Match(lineID: line.id, rowID: entry.rowID, ordinal: $0) }
            }
        }
    }

    /// The match after (or before) the current one, wrapping at the ends.
    static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return forward ? 0 : count - 1 }
        return (current + (forward ? 1 : count - 1)) % count
    }

    /// Where to stand after the matches changed: on the same match when it
    /// is still there, else the first match at or after the old line.
    static func settle(previous: Match?, in matches: [Match], lineOrder: [Int64]) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let previous else { return 0 }
        if let same = matches.firstIndex(of: previous) { return same }
        let order = Dictionary(lineOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        guard let old = order[previous.lineID] else { return 0 }
        return matches.firstIndex { (order[$0.lineID] ?? -1) >= old } ?? 0
    }

    /// The position of the whitespace-separated token holding this place in the text.
    static func tokenIndex(in text: String, at position: String.Index) -> Int? {
        var index = 0
        var inToken = false
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let space = text[cursor].isWhitespace
            if !space, !inToken { inToken = true }
            if cursor == position { return space ? nil : index }
            if space, inToken { inToken = false; index += 1 }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    /// Replace works on one whole word: the match must be a token of its
    /// own (edge punctuation aside), so "cat" never rewrites "cats".
    static func replaceableToken(query: String, text: String, ordinal: Int) -> Int? {
        let ranges = ranges(of: query, in: text)
        guard ranges.indices.contains(ordinal), let index = tokenIndex(in: text, at: ranges[ordinal].lowerBound) else { return nil }
        let tokens = TranscriptWordRules.tokens(text)
        guard tokens.indices.contains(index),
              TranscriptCorrectionRules.key(tokens[index]) == TranscriptCorrectionRules.key(query) else { return nil }
        return index
    }
}
