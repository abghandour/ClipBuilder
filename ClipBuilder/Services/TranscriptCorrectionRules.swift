import Foundation

nonisolated enum TranscriptCorrectionRules {
    struct Rule: Codable, Hashable, Sendable {
        var from: String
        var to: String
    }

    struct Result: Equatable, Sendable {
        var changes: [Int64: String] = [:]
        var count = 0
    }

    /// One whitespace-delimited source token; punctuation at its edges does
    /// not participate in matching. Internal apostrophes/hyphens are boundaries
    /// of the token itself, never a substring match ("cat" cannot change "cat's").
    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func rule(from: String, to: String) -> Rule? {
        let source = key(from)
        let target = to.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !source.isEmpty, !source.contains(where: \.isWhitespace), !target.isEmpty else { return nil }
        return Rule(from: from.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)),
                    to: target)
    }

    static func replacement(_ token: String, rule: Rule) -> String? {
        guard !key(rule.from).isEmpty, key(token) == key(rule.from) else { return nil }
        let punctuation = CharacterSet.punctuationCharacters
        let scalars = Array(token.unicodeScalars)
        let leading = scalars.prefix { punctuation.contains($0) }.count
        let trailing = scalars.dropFirst(leading).reversed().prefix { punctuation.contains($0) }.count
        let core = String(String.UnicodeScalarView(scalars[leading..<(scalars.count - trailing)]))
        var target = rule.to
        // Deleting an occurrence also deletes its punctuation, as in Fix Word.
        guard !target.isEmpty else { return "" }
        if let first = core.first, first.isUppercase, let targetFirst = target.first {
            target = targetFirst.uppercased() + target.dropFirst()
        }
        let prefix = String(String.UnicodeScalarView(scalars.prefix(leading)))
        let suffix = String(String.UnicodeScalarView(scalars.suffix(trailing)))
        return prefix + target + suffix
    }

    /// Each input token is visited once, against the original tokens. Outputs
    /// are never fed back through the rules, including multi-word targets.
    /// First rule wins if a legacy profile contains duplicate source keys.
    static func applying(_ rules: [Rule], to rows: [TranscriptRow], excluding: [Int64: Set<Int>] = [:]) -> Result {
        let lookup = lookup(rules)
        var result = Result()
        for row in rows where !row.isTranslation {
            var changed = false
            let tokens = TranscriptWordRules.tokens(row.text).enumerated().compactMap { index, token -> String? in
                guard excluding[row.id]?.contains(index) != true else { return token }
                guard let rule = lookup[key(token)], let replacement = replacement(token, rule: rule), replacement != token else { return token }
                changed = true
                result.count += 1
                return replacement.isEmpty ? nil : replacement
            }
            if changed { result.changes[row.id] = tokens.joined(separator: " ") }
        }
        return result
    }

    /// The rules on a transcription before it is stored: the corrected text
    /// is what the transcript starts as (no "edited" mark, so Fix Speakers
    /// can still split the line), and a replaced word keeps its place in time.
    static func applying(_ rules: [Rule], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let lookup = lookup(rules)
        guard !lookup.isEmpty else { return segments }
        return segments.map { segment in
            var changed = false
            // New position to old, for every word that stays one word: each
            // keeps its own clock, a repeated word included.
            var known: [Int: Int] = [:]
            var next = 0
            let old = TranscriptWordRules.tokens(segment.text)
            let tokens = old.enumerated().compactMap { index, token -> String? in
                guard let rule = lookup[key(token)], let replacement = replacement(token, rule: rule), replacement != token else {
                    known[next] = index
                    next += 1
                    return token
                }
                changed = true
                let count = TranscriptWordRules.tokens(replacement).count
                if count == 1 { known[next] = index }
                next += count
                return replacement.isEmpty ? nil : replacement
            }
            guard changed else { return segment }
            var segment = segment
            segment.text = tokens.joined(separator: " ")
            if let words = segment.words {
                segment.words = TranscriptWordAlignment.realign(text: segment.text, original: words,
                    start: segment.start, end: segment.end, known: words.count == old.count ? known : nil)
            }
            return segment
        }
    }

    private static func lookup(_ rules: [Rule]) -> [String: Rule] {
        var lookup: [String: Rule] = [:]
        for rule in rules where !key(rule.from).isEmpty && lookup[key(rule.from)] == nil {
            lookup[key(rule.from)] = rule
        }
        return lookup
    }
}
