import Foundation
import Testing
@testable import Clip_Builder

struct CriticExemplarsTests {
    private func row(_ id: String, favorite: Bool = false, percentile: Int? = nil,
                     reference: Bool = false, date: String = "2026-09-01", batch: String? = nil) -> CriticExemplars.Candidate {
        .init(id: id, path: "/\(id)", date: date, duration: 20,
              favorite: favorite, percentile: percentile, reference: reference, batchID: batch)
    }

    @Test func tiersAndNewestFirst() {
        let rows = [row("reference", reference: true), row("performance", percentile: 80),
                    row("star", favorite: true), row("both-old", favorite: true, percentile: 90),
                    row("both-new", favorite: true, percentile: 80, date: "2026-09-29")]
        let result = CriticExemplars.select(rows: rows, existingPaths: Set(rows.map(\.path)))
        #expect(result.exemplars.map(\.id) == ["both-new", "both-old", "star", "performance", "reference"])
    }

    @Test func exclusionsAndMissingFiles() {
        let rows = [row("target", favorite: true, batch: "run"), row("sibling", favorite: true, batch: "run"),
                    row("missing", favorite: true), row("keep", favorite: true), row("other", favorite: true)]
        let result = CriticExemplars.select(rows: rows,
            excluding: .init(ids: ["target"], batchIDs: ["run"]),
            existingPaths: Set(rows.filter { $0.id != "missing" }.map(\.path)))
        #expect(Set(result.exemplars.map(\.id)) == ["keep", "other"])
        #expect(result.missingPaths == ["/missing"])
        let withoutBatch = CriticExemplars.select(rows: rows, excluding: .init(ids: ["target"]),
                                                 existingPaths: Set(rows.map(\.path)))
        #expect(!withoutBatch.exemplars.contains { $0.id == "target" })
        #expect(withoutBatch.exemplars.contains { $0.id == "sibling" })
    }

    @Test func belowTwoExplainsFallback() {
        let one = row("one", favorite: true)
        let result = CriticExemplars.select(rows: [one], existingPaths: [one.path])
        #expect(result.exemplars.isEmpty)
        #expect(result.reason == "Critic brief: 1 exemplar, need 2. Star a generated reel or import reference reels.")
    }

    @Test func aliasesDoNotBecomeTwoTeachers() {
        let first = row("first", reference: true)
        var alias = first
        alias.id = "alias"
        #expect(CriticExemplars.select(rows: [first, alias], existingPaths: [first.path]).exemplars.isEmpty)
    }
}
