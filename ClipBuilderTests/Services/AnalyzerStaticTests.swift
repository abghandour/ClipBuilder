import CoreGraphics
import Testing
@testable import Clip_Builder

@Suite("Analyzer static logic")
struct AnalyzerStaticTests {
    @Test("frame sampling covers short and long windows")
    func frameTimestamps() {
        #expect(Analyzer.frameTimestamps(duration: 0.4) == [0.2])
        let short = Analyzer.frameTimestamps(duration: 5)
        #expect(short.first == 0.5)
        #expect(short.last == 4.5)

        let dense = Analyzer.frameTimestamps(start: 10, end: 310, interval: 0.2)
        #expect((Analyzer.maxCustomFrames - 1)...Analyzer.maxCustomFrames ~= dense.count)
        #expect(dense.first == 10.5)
        #expect((dense.last ?? 0) > 300)
    }

    @Test("model budget uses rounded image tokens and both request limits")
    func frameBudget() {
        let wideTokens = Analyzer.estimatedImageTokens(width: 1536, height: 864)
        #expect(wideTokens == 1770)
        #expect(Analyzer.estimatedImageTokens(width: 864, height: 1536) == wideTokens)
        #expect(Analyzer.estimatedImageTokens(width: 1, height: 1) == 1)
        let dense = Analyzer.budgetedFrameIndices(tokens: Array(repeating: wideTokens, count: 112))
        #expect(dense.count == 84)
        #expect(dense.first == 0 && dense.last == 111)
        #expect(dense.count * wideTokens <= 150_000)
        let stretched = Analyzer.frameTimestamps(start: 0, end: 223, interval: 2, frameLimit: dense.count)
        #expect((83...84).contains(stretched.count))
        #expect((stretched.last ?? 0) > 219)
        let step = stretched[1] - stretched[0]
        #expect(step > 2)
        #expect(zip(stretched, stretched.dropFirst()).allSatisfy { abs(($0.1 - $0.0) - step) < 0.000_001 })
        #expect(Analyzer.budgetedFrameIndices(tokens: Array(repeating: 100, count: 120)).count == 100)
        #expect(Analyzer.budgetedFrameIndices(tokens: Array(repeating: 1500, count: 100)).count == 100)
        #expect(Analyzer.budgetedFrameIndices(tokens: Array(repeating: 1501, count: 100)).count == 99)
    }

    @Test("analysis timeouts increase only above thirty sampled frames")
    func analysisTimeouts() {
        #expect(Analyzer.analysisTimeout(sampledFrameCount: 0) == 300)
        #expect(Analyzer.analysisTimeout(sampledFrameCount: 16) == 300)
        #expect(Analyzer.analysisTimeout(sampledFrameCount: 30) == 300)
        #expect(Analyzer.analysisTimeout(sampledFrameCount: 31) == 600)
        #expect(Analyzer.analysisTimeout(sampledFrameCount: 84) == 600)
    }

    @Test("model budget reserves references and preserves automatic grids")
    func referenceBudget() {
        let automatic = Analyzer.frameTimestamps(duration: 223)
        #expect(automatic.count <= 30)
        #expect(Analyzer.budgetedFrameIndices(tokens: Array(repeating: 1770, count: automatic.count))
            == Array(automatic.indices))
        #expect(Analyzer.budgetedFrameIndices(tokens: Array(repeating: 1770, count: 100),
                                              referenceTokens: [1770, 1770]).count == 82)
        #expect(Analyzer.budgetedFrameIndices(tokens: Array(repeating: 100, count: 100),
                                              referenceTokens: [100, 100]).count == 98)
        #expect(Analyzer.budgetedFrameIndices(tokens: [1], referenceTokens: [150_000]).isEmpty)
        #expect(Analyzer.budgetedFrameIndices(tokens: [150_001]).isEmpty)
        #expect(Analyzer.budgetedFrameIndices(tokens: []).isEmpty)
        let mixed = [100, 40_000, 100, 80_000, 100, 40_000, 100]
        let indices = Analyzer.budgetedFrameIndices(tokens: mixed)
        #expect(indices.reduce(0) { $0 + mixed[$1] } <= 150_000)
        #expect(indices.first == 0 && indices.last == 6)
    }

    @Test("filename cleanup only accepts a spelling correction")
    func filenameSuggestion() {
        #expect(Analyzer.sanitizedFilenameSuggestion("Jon Jones", currentFilename: "Jonn Jones.mp4") == "Jon Jones")
        #expect(Analyzer.isSpellingFix(of: "Jonn Jones", candidate: "Jon Jones"))
        #expect(!Analyzer.isSpellingFix(of: "Sean", candidate: "Juan"))
        #expect(Analyzer.sanitizedFilenameSuggestion("same", currentFilename: "same.mp4") == nil)
    }

    @Test("Smart Sampling window map clamps to its window and keeps only known tags")
    func windowMap() {
        let json = """
            {"activity": 8.4, "tags": {"striking": [{"start": 290, "end": 320}, {"start": 400, "end": 390}],
             "made-up": [{"start": 300, "end": 310}]},
             "sequences": [{"start": 305, "end": 312, "narrative": "A lands a combo", "score": 12}],
             "moments": [{"at": 301.5, "note": "bell"}, {"at": 700, "note": "late"}]}
            """
        let map = Analyzer.parseWindowMap(json, window: (300, 600), allTags: ["striking"])
        #expect(map.activity == 8.4)
        #expect(map.tags.keys.sorted() == ["striking"])
        #expect(map.tags["striking"]?.count == 1)
        #expect(map.tags["striking"]?.first?.start == 300 && map.tags["striking"]?.first?.end == 320)
        #expect(map.sequences.count == 1 && map.sequences.first?.score == 10)
        #expect(map.moments.count == 1 && map.moments.first?.at == 301.5)
        let garbage = Analyzer.parseWindowMap("not json", window: (0, 10), allTags: [])
        #expect(garbage.activity == 0 && garbage.tags.isEmpty)
        let prompt = Analyzer.windowMapPrompt(domain: "MMA", start: 300, end: 600,
                                              tags: ["action": ["striking"]], instructions: "")
        #expect(prompt.contains("300.0s to 600.0s") && prompt.contains("\"activity\"") && prompt.contains("striking"))
    }

    @Test("primary people boxes discard contained faces")
    func primaryPeopleBoxes() {
        let large = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let contained = CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)
        let separate = CGRect(x: 0.7, y: 0.2, width: 0.2, height: 0.3)
        let result = Analyzer.primaryPeopleBoxes([contained, separate, large])
        #expect(result.contains(large))
        #expect(result.contains(separate))
        #expect(!result.contains(contained))
    }
}
