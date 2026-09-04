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

    @Test("filename cleanup only accepts a spelling correction")
    func filenameSuggestion() {
        #expect(Analyzer.sanitizedFilenameSuggestion("Jon Jones", currentFilename: "Jonn Jones.mp4") == "Jon Jones")
        #expect(Analyzer.isSpellingFix(of: "Jonn Jones", candidate: "Jon Jones"))
        #expect(!Analyzer.isSpellingFix(of: "Sean", candidate: "Juan"))
        #expect(Analyzer.sanitizedFilenameSuggestion("same", currentFilename: "same.mp4") == nil)
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
