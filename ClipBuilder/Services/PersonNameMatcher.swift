import Foundation

/// Shared name-only search for the People screen and reassignment picker.
nonisolated enum PersonNameMatcher {
    static func score(query: String, against names: [String]) -> Double? {
        let query = folded(query)
        guard !query.isEmpty else { return nil }
        let queryTokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var best: Double?
        for name in Set(names.map { folded($0) }) where !name.isEmpty {
            if name == query { return 1.0 }
            let nameTokens = name.split(whereSeparator: \.isWhitespace).map(String.init)
            let candidate: Double?
            if name.hasPrefix(query) {
                candidate = 0.9
            } else if nameTokens.contains(where: { $0.hasPrefix(query) }) {
                // A surname prefix ranks under a first-name prefix so the
                // reassignment picker keeps "José Silva" above "Maria José".
                candidate = 0.85
            } else if name.contains(query) {
                candidate = 0.8
            } else if queryTokens.allSatisfy({ queryToken in
                nameTokens.contains { $0.contains(queryToken) }
            }) {
                candidate = 0.7
            } else if queryTokens.allSatisfy({ queryToken in
                nameTokens.contains { token in
                    if token.contains(queryToken) { return true }
                    let characters = Array(queryToken)
                    let tolerance = characters.count <= 5 ? 1 : 2
                    return distance(characters, Array(token)) <= tolerance
                        || distance(characters, Array(token.prefix(characters.count))) <= tolerance
                }
            }) {
                candidate = 0.5
            } else if isConcentratedSubsequence(query, of: name) {
                candidate = 0.3
            } else {
                candidate = nil
            }
            if let candidate { best = max(best ?? 0, candidate) }
        }
        return best
    }

    static func rank(_ people: [PersonRecord], query: String) -> [PersonRecord] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return people }
        var matches: [(person: PersonRecord, score: Double, index: Int)] = []
        for (index, person) in people.enumerated() {
            let names = [person.displayName, person.name, person.keyName].compactMap { $0 }
            if let score = score(query: query, against: names) {
                matches.append((person, score, index))
            }
        }
        return matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.index < $1.index
        }.map(\.person)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Optimal string alignment distance, including adjacent transpositions.
    private static func distance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var twoRowsBack = previous
        for i in 1...lhs.count {
            var row = [Int](repeating: 0, count: rhs.count + 1)
            row[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                row[j] = min(previous[j] + 1, row[j - 1] + 1, substitution)
                if i > 1, j > 1, lhs[i - 1] == rhs[j - 2], lhs[i - 2] == rhs[j - 1] {
                    row[j] = min(row[j], twoRowsBack[j - 2] + 1)
                }
            }
            twoRowsBack = previous
            previous = row
        }
        return previous[rhs.count]
    }

    private static func isConcentratedSubsequence(_ query: String, of name: String) -> Bool {
        let query = Array(query)
        let name = Array(name)
        guard query.count <= name.count else { return false }
        var tokenIDs: [Int] = []
        var tokenID = 0
        for character in name {
            tokenIDs.append(character.isWhitespace ? -1 : tokenID)
            if character.isWhitespace { tokenID += 1 }
        }
        // For each token, retain the largest contribution to every matched
        // query prefix. Greedy matching could miss a later, better alignment.
        for focusedToken in Set(tokenIDs) where focusedToken >= 0 {
            var contributions = [Int](repeating: -1, count: query.count + 1)
            contributions[0] = 0
            for (index, character) in name.enumerated() {
                for length in stride(from: query.count, through: 1, by: -1) {
                    guard query[length - 1] == character, contributions[length - 1] >= 0 else { continue }
                    let contribution = tokenIDs[index] == focusedToken ? 1 : 0
                    contributions[length] = max(contributions[length], contributions[length - 1] + contribution)
                }
            }
            if Double(contributions[query.count]) / Double(query.count) >= 0.6 { return true }
        }
        return false
    }
}
