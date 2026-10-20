import Foundation
import NaturalLanguage

nonisolated enum CaptionEmphasis {
    /// Priority: numeric facts, named entities, then the highest-confidence
    /// noun. Ties use transcript order, never randomized hashing.
    static func indices(for page: CaptionPage, language: String) -> [Int] {
        let text = page.text
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        if !language.isEmpty {
            tagger.setLanguage(NLLanguage(rawValue: String(language.prefix(2))), range: text.startIndex..<text.endIndex)
        }
        var candidates: [(index: Int, priority: Int, score: Double)] = []
        var nouns: [(index: Int, priority: Int, score: Double)] = []
        for (index, token) in tokens.enumerated() {
            if token.contains(where: \.isNumber) || token.unicodeScalars.contains(where: { CharacterSet(charactersIn: "$€£¥₹₽₩%٪").contains($0) }) {
                candidates.append((index, 3, 1))
                continue
            }
            let (name, _) = tagger.tag(at: token.startIndex, unit: .word, scheme: .nameType)
            if let name, [.personalName, .placeName, .organizationName].contains(name) {
                candidates.append((index, 2, 1))
                continue
            }
            let (hypotheses, _) = tagger.tagHypotheses(at: token.startIndex, unit: .word,
                                                      scheme: .lexicalClass, maximumCount: 3)
            if let score = hypotheses[NLTag.noun.rawValue], score > 0.25 { nouns.append((index, 1, score)) }
        }
        if let best = nouns.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }).first {
            candidates.append(best)
        }
        candidates.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.index < $1.index
        }
        var selected: [Int] = []
        for candidate in candidates where selected.count < 2 {
            if selected.allSatisfy({ abs($0 - candidate.index) > 1 }) { selected.append(candidate.index) }
        }
        return selected.sorted()
    }

    /// Small, predictable English/Portuguese vocabulary; unknown words and
    /// languages simply get no decoration. Never calls an AI provider.
    static func emoji(for page: CaptionPage, language: String) -> String? {
        let words = LocalTextMatcher.tokens(page.text)
        let table: [(Set<String>, String)] = [
            (["money", "cash", "dinheiro", "grana"], "💰"),
            (["fire", "fogo"], "🔥"),
            (["win", "wins", "winner", "victory", "vitoria", "vencer", "ganhar"], "🏆"),
            (["time", "clock", "tempo", "relogio"], "⏰"),
            (["strong", "strength", "forte", "forca"], "💪"),
            (["love", "amor", "amar"], "❤️"),
            (["laugh", "laughing", "rir", "risada"], "😂"),
            (["warning", "danger", "aviso", "perigo", "cuidado"], "⚠️"),
        ]
        for word in words {
            if let match = table.first(where: { $0.0.contains(word) }) { return match.1 }
        }
        return nil
    }
}
