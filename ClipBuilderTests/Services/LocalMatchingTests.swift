import Foundation
import Testing
@testable import Clip_Builder

struct LocalMatchingTests {
    let rows: [LocalTextMatcher.Row] = [
        .init(id: "1", fields: ["José Silva", "Jiu-Jitsu"]),
        .init(id: "2", fields: ["Ana", "training"]),
        .init(id: "3", fields: ["crowd", "arena"]),
        .init(id: "4", fields: ["José Silva", "portrait"]),
        .init(id: "5", fields: ["graphic", "logo"]),
        .init(id: "6", fields: ["walkout", "arena"]),
    ]
    @Test func inventory() {
        #expect(LocalImageMatcher.match(query: "Jose Silva", rows: rows, useEmbedding: false) == ["1", "4"])
        #expect(LocalImageMatcher.match(query: "training", rows: rows, useEmbedding: false) == ["2"])
        #expect(LocalImageMatcher.match(query: "jiu jítsu", rows: rows, useEmbedding: false) == ["1"])
        #expect(LocalImageMatcher.match(query: "nonsense", rows: rows, useEmbedding: false).isEmpty)
        #expect(LocalImageMatcher.match(query: "Jose without portrait", rows: rows, useEmbedding: false) == ["1"])
        #expect(LocalImageMatcher.match(query: "someone getting swept", rows: rows, useEmbedding: false).isEmpty)
    }
    @Test func metadataNames() {
        #expect(MetadataFileNamer.stem(people: ["Ana", "José"], hasResearch: true, fightDate: "September 7, 2026") == "Ana vs José - 2026-09-07")
        #expect(MetadataFileNamer.stem(people: ["Ana"], hasResearch: false, fightDate: nil) == "Ana")
        #expect(MetadataFileNamer.stem(people: ["Ana"], hasResearch: true, fightDate: "sometime") == "Ana")
        #expect(MetadataFileNamer.stem(people: [""], hasResearch: false, fightDate: nil) == nil)
    }
}

extension LocalMatchingTests {
    @Test(arguments: ["2026-09-07", "2026/09/07", "Sep 7, 2026", "September 7 2026", "09/07/2026", "7 September 2026", " 7 Sep 2026 "])
    func normalizedDates(_ text: String) {
        #expect(MetadataFileNamer.normalizedDate(text) == "2026-09-07")
    }
    @Test(arguments: ["sometime", "13/07/2026", "2026-13-07", "", "next Friday"])
    func unparseableDates(_ text: String) {
        #expect(MetadataFileNamer.normalizedDate(text) == nil)
    }
    @Test func stemSurvivesTheRenameSanitizer() {
        let stem = MetadataFileNamer.stem(people: [" Ana ", "José"], hasResearch: true, fightDate: "2026-09-07")
        #expect(stem == "Ana vs José - 2026-09-07")
        #expect(Analyzer.sanitizedFilenameSuggestion(stem!, currentFilename: "IMG_0001.mp4") == "Ana vs José - 2026-09-07")
        #expect(Analyzer.sanitizedFilenameSuggestion(stem!, currentFilename: "ana vs josé - 2026-09-07.mov") == nil)
        #expect(MetadataFileNamer.stem(people: ["Ana", "José"], hasResearch: false, fightDate: nil) == "Ana & José")
        #expect(MetadataFileNamer.stem(people: [], hasResearch: true, fightDate: "2026-09-07") == nil)
    }
    @Test func negationAndPrefixes() {
        #expect(LocalTextMatcher.queryTokens("photos of José without portrait").included == ["jose"])
        #expect(LocalTextMatcher.queryTokens("photos of José without portrait").excluded == ["portrait"])
        #expect(LocalTextMatcher.queryTokens("fotos sem logo do José").excluded == ["logo"])
        // A prefix hit ranks below an exact one, and alone is not enough for a result.
        let ranked = LocalTextMatcher.rank(query: "train", rows: rows, useEmbedding: false)
        #expect(ranked.first?.row.id == "2")
        #expect(ranked.first?.exactHits == 0)
        #expect(LocalImageMatcher.match(query: "train", rows: rows, useEmbedding: false).isEmpty)
        // Three or more terms need two exact hits.
        #expect(LocalImageMatcher.match(query: "jose silva arena crowd", rows: rows, useEmbedding: false) == ["1", "3", "4", "6"])
        #expect(LocalImageMatcher.match(query: "jose walkout logo", rows: rows, useEmbedding: false).isEmpty)
    }
}
