import Foundation

nonisolated enum LocalImageMatcher {
    static func match(query: String, rows: [LocalTextMatcher.Row], useEmbedding: Bool = true) -> [String] {
        let ranked = LocalTextMatcher.rank(query: query, rows: rows, useEmbedding: useEmbedding)
            .filter { $0.score >= 3 }
        guard let best = ranked.first,
              LocalTextMatcher.queryTokens(query).included.count < 3 || best.exactHits >= 2 else { return [] }
        return ranked.prefix(60).map(\.row.id)
    }
}
