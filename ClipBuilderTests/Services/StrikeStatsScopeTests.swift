import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike stat round scope")
struct StrikeStatsScopeTests {
    @Test func researchBoundariesRequireFullSpanAndRecapsStayAnalyzedFootage() {
        let json = #"{"story":{"rounds":[{"round":2,"start_time":10,"end_time":20}]}}"#
        #expect(StrikeStatsScope.round(type: .fight, start: 12, end: 18, scenes: [], researchJSON: json) == 2)
        #expect(StrikeStatsScope.round(type: .fight, start: 8, end: 18, scenes: [], researchJSON: json) == nil)
        #expect(StrikeStatsScope.round(type: .recap, start: 12, end: 18, scenes: [], researchJSON: json) == nil)
        #expect(StrikeStatsCopy.scope(.init(round: 2, isRecap: true)) == "in analyzed footage")
    }

    @Test func sceneRoundTagsMustCoverTheScopeWithoutGaps() {
        var first = Fixtures.scene(start: 0, end: 5); first.tags = ["round:3"]
        var next = Fixtures.scene(id: 2, start: 5, end: 10); next.tags = ["round:3"]
        #expect(StrikeStatsScope.round(type: .fight, start: 1, end: 9, scenes: [first, next], researchJSON: nil) == 3)
        next.startTime = 6
        #expect(StrikeStatsScope.round(type: .fight, start: 1, end: 9, scenes: [first, next], researchJSON: nil) == nil)
        first.tags = ["round:2", "round:3"]
        #expect(StrikeStatsScope.round(type: .fight, start: 1, end: 4, scenes: [first], researchJSON: nil) == nil)
    }

    @Test func scorerRangesAreBoundedAndInvalidRangesAreIgnored() {
        let ranges: [[String: Any]] = [["round": 1, "start_time": -1, "end_time": 10],
                                      ["round": 0, "start_time": 0, "end_time": 4],
                                      ["round": 2, "start_time": 4, "end_time": 3]]
        #expect(StrikeStatsScope.parseRanges(ranges, start: 0, end: 5) == [.init(round: 1, start: 0, end: 5)])
    }
}
