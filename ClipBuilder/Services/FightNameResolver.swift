import Foundation

nonisolated enum FightNameResolver {
    static func names(_ label: String) -> [String] {
        label.components(separatedBy: " vs ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func resolve(_ name: String, known: [String]) -> (name: String, resolved: Bool) {
        let ranked = known.filter { !$0.isEmpty }.map { ($0, WizardRequestParser.similarity(name, $0)) }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 0.85 else { return (name, false) }
        return (best.0, true)
    }
    static func savedPlan(for fighters: [String], records: [FightResearchRecord]) -> (queries: [String], subreddits: [String])? {
        let wanted = Set(fighters.map { LocalTextMatcher.tokens($0).joined(separator: " ") })
        for row in records {
            guard Set(names(row.fightLabel).map { LocalTextMatcher.tokens($0).joined(separator: " ") }) == wanted,
                  let plan = row.summary["query_plan"] as? [String: Any],
                  let queries = plan["queries"] as? [String], !queries.isEmpty,
                  let subreddits = plan["subreddits"] as? [String], !subreddits.isEmpty else { continue }
            return (queries, subreddits)
        }
        return nil
    }
}
