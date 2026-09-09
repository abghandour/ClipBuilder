import Foundation
import NaturalLanguage

nonisolated enum LocalTextMatcher {
    struct Row: Sendable {
        var id: String
        var fields: [String]
        var date: Date = .distantPast
    }
    struct Match: Sendable {
        var row: Row
        var score: Double
        var exactHits: Int
    }
    static let stopWords: Set<String> = ["a", "an", "the", "of", "in", "on", "with", "and", "or", "for", "photos", "images", "de", "da", "do", "das", "dos", "em", "com", "e", "o", "os", "as", "um", "uma", "fotos", "imagens"]
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func queryTokens(_ text: String) -> (included: [String], excluded: [String]) {
        var included: [String] = [], excluded: [String] = []
        var negate = false
        for token in tokens(text) {
            if ["no", "sem", "without"].contains(token) { negate = true; continue }
            if stopWords.contains(token) { continue }
            if negate { excluded.append(token); negate = false } else { included.append(token) }
        }
        return (Array(Set(included)).sorted(), excluded)
    }
    static func rank(query: String, rows: [Row], useEmbedding: Bool = true) -> [Match] {
        let terms = queryTokens(query)
        let embedding = useEmbedding ? NLEmbedding.sentenceEmbedding(for: .english) : nil
        return rows.compactMap { row -> Match? in
            let words = Set(tokens(row.fields.joined(separator: " ")))
            guard !terms.excluded.contains(where: words.contains) else { return nil }
            let exact = terms.included.filter(words.contains).count
            let prefixes = terms.included.filter { term in !words.contains(term) && words.contains { $0.hasPrefix(term) } }.count
            var score = Double(3 * exact + 2 * prefixes)
            if let embedding {
                let distance = embedding.distance(between: query, and: row.fields.joined(separator: " "))
                if distance.isFinite { score += max(0, min(1, 1 - distance)) }
            }
            return Match(row: row, score: score, exactHits: exact)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.row.date != $1.row.date { return $0.row.date > $1.row.date }
            return $0.row.id < $1.row.id
        }
    }
}
