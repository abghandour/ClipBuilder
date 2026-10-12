import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fight score digest")
struct FightScoreDigestTests {
    private func event(_ id: Int64, _ time: Double, _ fighter: String, _ action: String, target: String? = nil,
                       outcome: String? = nil, version: Int? = 2) -> FightEventRecord {
        FightEventRecord(id: id, videoID: 1, time: time, fighterKey: fighter, action: action, points: 1,
                         targetKey: target, endTime: time + 2, outcome: outcome, scoringVersion: version)
    }

    @Test func totalsPerFighterCollapseStrikeClustersAndCountAttempts() {
        let events = [
            event(1, 1.0, "a", "strike"), event(2, 1.2, "a", "significant_strike"), event(3, 5, "a", "strike"),
            event(4, 10, "a", "takedown_attempt", target: "b", outcome: "completed"),
            event(5, 20, "a", "takedown_attempt", target: "b", outcome: "defended"),
            event(6, 30, "b", "submission_attempt", target: "a", outcome: "defended"),
            event(7, 40, "b", "takedown", target: "a", version: 1),
        ]
        let rows = FightScoreDigest.fighters(events: events)
        #expect(rows.map(\.key) == ["a", "b"])
        #expect(rows[0] == .init(key: "a", strikes: 2, takedowns: 1, takedownAttempts: 2))
        #expect(rows[1] == .init(key: "b", takedowns: 1, takedownAttempts: 1, submissionAttempts: 1))
        #expect(FightScoreDigest.totalActions(events: events) == 6)
        #expect(FightScoreDigest.line(rows[0], name: "A") == "A: 2 strikes · 1/2 TD")
        #expect(FightScoreDigest.line(rows[1], name: "B") == "B: 0 strikes · 1/1 TD · 0/1 sub")
        #expect(FightScoreDigest.fighters(events: []).isEmpty)
    }
}

extension FightScoreDigestTests {
    @Test func entriesMatchTheCountsAndDescribeEachAction() {
        let events = [
            FightEventRecord(id: 1, videoID: 1, time: 1.0, fighterKey: "a", action: "strike", points: 1),
            FightEventRecord(id: 2, videoID: 1, time: 1.2, fighterKey: "a", action: "significant_strike", points: 2),
            FightEventRecord(id: 3, videoID: 1, time: 5, fighterKey: "a", action: "knockdown", points: 8),
            FightEventRecord(id: 4, videoID: 1, time: 10, fighterKey: "a", action: "takedown_attempt", points: 0,
                             targetKey: "b", endTime: 13, outcome: "defended", scoringVersion: 2),
            FightEventRecord(id: 5, videoID: 1, time: 20, fighterKey: "b", action: "submission_attempt", points: 5,
                             targetKey: "a", endTime: 20.4, outcome: "completed", detail: "armbar", scoringVersion: 2),
            FightEventRecord(id: 6, videoID: 1, time: 40, fighterKey: "b", action: "takedown", points: 4, targetKey: "a"),
        ]
        let strikes = FightScoreDigest.entries(events: events, fighter: "a", category: .strikes)
        #expect(strikes.map(\.id) == [2, 3])
        #expect(strikes.map(\.summary) == ["Significant strike", "Knockdown"])
        #expect(strikes[0].frameTimes == [1.2])

        let takedowns = FightScoreDigest.entries(events: events, fighter: "a", category: .takedowns)
        #expect(takedowns.map(\.summary) == ["Takedown attempt · defended"])
        #expect(takedowns[0].frameTimes == [10, 13])

        let subs = FightScoreDigest.entries(events: events, fighter: "b", category: .submissions)
        #expect(subs.map(\.summary) == ["Submission attempt · armbar · completed"])
        #expect(subs[0].frameTimes == [20])
        #expect(strikes[0].loopRange == 0.2...2.7)
        #expect(takedowns[0].loopRange == 9...13.5)
        #expect(subs[0].loopRange == 19...20.9)
        #expect(FightScoreDigest.entries(events: events, fighter: "b", category: .takedowns).map(\.label) == ["Takedown"])

        for fighter in FightScoreDigest.fighters(events: events) {
            for category in FightScoreDigest.Category.allCases {
                #expect(FightScoreDigest.entries(events: events, fighter: fighter.key, category: category).count
                        == FightScoreDigest.count(fighter, category))
            }
        }
    }
}
