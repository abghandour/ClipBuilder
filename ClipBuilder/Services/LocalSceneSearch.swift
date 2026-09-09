import Foundation

nonisolated enum LocalSceneSearch {
    static func vocabularyOnly(_ query: String, vocabulary: [String]) -> Bool {
        var remaining = LocalTextMatcher.tokens(query).joined(separator: " ")
        for phrase in vocabulary.map({ LocalTextMatcher.tokens($0).joined(separator: " ") }).sorted(by: { $0.count > $1.count }) where !phrase.isEmpty {
            remaining = (" " + remaining + " ").replacingOccurrences(of: " " + phrase + " ", with: " ").trimmingCharacters(in: .whitespaces)
        }
        return !query.isEmpty && remaining.isEmpty
    }
    static func narrow(query: String, rows: [LocalTextMatcher.Row], now: Date = Date()) -> [String] {
        let ranked = LocalTextMatcher.rank(query: query, rows: rows, useEmbedding: false)
        var ids = ranked.prefix(200).map(\.row.id)
        var seen = Set(ids)
        for row in rows where row.date >= now.addingTimeInterval(-30 * 86_400) {
            if seen.insert(row.id).inserted { ids.append(row.id) }
        }
        // Negations can exclude all ranked rows: the model must still see a useful inventory.
        for row in rows where ids.count < min(100, rows.count) {
            if seen.insert(row.id).inserted { ids.append(row.id) }
        }
        return ids
    }
}
