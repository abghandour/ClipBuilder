import Foundation
import Testing
@testable import Clip_Builder

struct LocalSceneSearchTests {
    @Test func vocabularyAndFloor() {
        #expect(LocalSceneSearch.vocabularyOnly("guard pass", vocabulary: ["guard-pass"]))
        #expect(!LocalSceneSearch.vocabularyOnly("someone getting swept", vocabulary: ["sweep"]))
        var rows = (0..<250).map { LocalTextMatcher.Row(id: String($0), fields: ["sweep"]) }
        rows.append(.init(id: "recent", fields: [], date: Date()))
        let ids = LocalSceneSearch.narrow(query: "someone getting swept", rows: rows)
        #expect(ids.count >= 100)
        #expect(ids.contains("recent"))
    }
}

extension LocalSceneSearchTests {
    @Test func negationThatEmptiesTheRankingStillFillsTheInventory() {
        let rows = (0..<150).map { LocalTextMatcher.Row(id: String($0), fields: ["sweep"]) }
        #expect(LocalTextMatcher.rank(query: "no sweep", rows: rows, useEmbedding: false).isEmpty)
        let ids = LocalSceneSearch.narrow(query: "no sweep", rows: rows)
        #expect(ids.count == 100)
        #expect(Set(ids).count == 100)
        #expect(LocalSceneSearch.narrow(query: "no sweep", rows: Array(rows.prefix(7))).count == 7)
    }
    @Test func vocabularyOnlyIsPhraseAware() {
        #expect(LocalSceneSearch.vocabularyOnly("José Silva guard pass", vocabulary: ["guard-pass", "José Silva"]))
        #expect(!LocalSceneSearch.vocabularyOnly("guard", vocabulary: ["guard-pass"]))
        #expect(!LocalSceneSearch.vocabularyOnly("", vocabulary: ["guard-pass"]))
        #expect(!LocalSceneSearch.vocabularyOnly("guard pass", vocabulary: []))
    }
}
