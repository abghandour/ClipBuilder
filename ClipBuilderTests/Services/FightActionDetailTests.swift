import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fight Action detail")
struct FightActionDetailTests {
    private func event(_ id: Int64, _ time: Double, _ fighter: String = "a", _ action: String = "strike",
                       detail: String? = nil) -> FightEventRecord {
        .init(id: id, videoID: 1, time: time, fighterKey: fighter, action: action,
              points: FightScoring.points(for: action), detail: detail, scoringVersion: 2)
    }

    @Test func totalsAndRowsMatchInspector() {
        var sub = event(4, 20, "b", "submission_attempt", detail: "armbar")
        sub.endTime = 24
        sub.targetKey = "a"
        var continuing = sub
        continuing.id = 5
        continuing.time = 25
        continuing.endTime = 28
        continuing.outcome = "defended"
        let events = [event(1, 1), event(2, 1.2, "a", "significant_strike"),
                      event(3, 10, "a", "takedown_attempt"), sub, continuing]
        let model = FightActionDetail.build(events: events, people: [])
        #expect(model.rows.count == FightScoreDigest.totalActions(events: events))
        for fighter in FightScoreDigest.fighters(events: events) {
            #expect(model.fighters.first { $0.id == fighter.key }?.counts == fighter)
            #expect(model.rows.count { $0.event.fighterKey == fighter.key } == fighter.actions)
        }
        #expect(model.rows.last?.loopRange == 19...28.5)
        #expect(abs(model.fighters.reduce(0) { $0 + $1.share } - 1) < 1e-9)
    }

    @Test func scopesUseKnownHalfOpenBoundaries() {
        let events = [event(1, 1), event(2, 10), event(3, 19)]
        let rounds = [FightRoundRange(round: 1, start: 0, end: 10), .init(round: 2, start: 10, end: 20)]
        #expect(FightActionDetail.build(events: events, people: [], rounds: rounds, round: 1).rows.map(\.id) == [1])
        #expect(FightActionDetail.build(events: events, people: [], rounds: rounds, round: 2).rows.map(\.id) == [2, 3])
        #expect(FightActionDetail.build(events: events, people: [], round: 3).rows.isEmpty)
    }

    @Test func unattributedActionsRemainASeparateGroup() {
        let model = FightActionDetail.build(events: [event(1, 1), event(2, 2, "b"), event(3, 3, "")], people: [])
        #expect(model.fighters.count == 3)
        #expect(model.fighters.last?.name == "Unattributed")
        #expect(model.rows.last?.sentence == "Unattributed strike landed")
        #expect(model.markers.count == 3)
    }

    @Test func sentencesAndBreakdownsIncludeEveryStrike() {
        let events = [event(1, 1, detail: "punch|right|head|left"), event(2, 3, detail: "knee|left|body|right"),
                      event(3, 5, "b", detail: "elbow|right|head|left"), event(4, 7, "", detail: nil)]
        let model = FightActionDetail.build(events: events, people: [])
        #expect(model.rows.first?.sentence == "a right punch to the head")
        #expect(Set(model.breakdowns["Technique"]!.map(\.title)) == ["Punch", "Knee", "Elbow", "Unknown"])
        for title in ["Technique", "Landed on", "Impact", "Limb"] {
            #expect(model.breakdowns[title]!.flatMap { $0.values.values }.reduce(0, +) == 4)
        }
    }

    @Test func attemptCountsFollowTheRowsAndTheSavedResult() throws {
        var finish = event(1, 20, "a", "submission_attempt", detail: "armbar")
        finish.targetKey = "b"
        finish.endTime = 24
        finish.outcome = "completed"
        // An old takedown the reviewer marked as defended.
        var old = FightEventRecord(id: 2, videoID: 1, time: 5, fighterKey: "a", action: "takedown_attempt", points: 0)
        old.targetKey = "b"
        old.outcome = "defended"
        let untouched = FightEventRecord(id: 3, videoID: 1, time: 8, fighterKey: "a", action: "takedown", points: 4)
        let result = FightOutcome(id: 1, videoID: 1, runID: 1, method: "submission", winnerKey: "a", loserKey: "b")
        func counts(_ outcomes: [FightOutcome]) throws -> FightScoreDigest.Fighter {
            try #require(FightActionDetail.build(events: [finish, old, untouched], people: [], outcomes: outcomes)
                .fighters.first { $0.id == "a" }).counts
        }
        let checked = try counts([result])
        #expect(checked.submissions == 1 && checked.submissionAttempts == 1)
        #expect(checked.takedowns == 1 && checked.takedownAttempts == 2)
        // With no saved result the finish stays unclear, as in the inspector.
        #expect(try counts([]).submissions == 0)
    }
}
