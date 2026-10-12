import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike stats summaries and copy")
struct StrikeStatsSummaryTests {
    private func attempt(_ kind: AttemptKind, _ outcome: String, time: Double = 0, detail: String? = nil) -> FightEventRecord {
        FightEventRecord(id: 1, videoID: 1, time: time, fighterKey: "a", action: kind.action,
                         points: FightScoring.points(for: kind.action, outcome: outcome), targetKey: "b",
                         endTime: time + 1, outcome: outcome, detail: detail, scoringVersion: 2)
    }

    private var outcome: FightOutcome {
        FightOutcome(id: 1, videoID: 1, runID: 1, method: "submission", winnerKey: "a", loserKey: "b")
    }

    @Test func pairRatesSumToOneHundredPerKind() throws {
        for kind in AttemptKind.allCases {
            let rows = [attempt(kind, "completed"), attempt(kind, "defended", time: 10), attempt(kind, "unresolved", time: 20)]
            let pair = try #require(StrikeStatsSummary.pairs(events: rows, outcomes: [outcome]).first)
            #expect(pair.completed == 1 && pair.defended == 1 && pair.unresolved == 1)
            #expect(try #require(pair.success) + #require(pair.defense) == 1)
            #expect(StrikeStatsCopy.attempt(pair).contains("1 unclear"))
            #expect(StrikeStatsCopy.attempt(pair).contains("1 of 2 resolved"))
        }
    }

    @Test func legacyRowsHaveNoInventedDenominator() throws {
        let rows = [FightEventRecord(id: 1, videoID: 1, time: 0, fighterKey: "a", action: "takedown", points: 4),
                    FightEventRecord(id: 2, videoID: 1, time: 5, fighterKey: "a", action: "submission_attempt", points: 5)]
        let pairs = StrikeStatsSummary.pairs(events: rows)
        #expect(StrikeStatsCopy.attempt(try #require(pairs.first { $0.kind == .takedown })).contains("attempts not scored"))
        #expect(StrikeStatsCopy.attempt(try #require(pairs.first { $0.kind == .submission })).contains("outcomes not scored"))
        #expect(pairs.allSatisfy { $0.success == nil && $0.defense == nil })
        #expect(rows.map(\.points) == [4, 5])
    }

    @Test func noPercentageUnderTwoResolved() {
        for kind in AttemptKind.allCases {
            let pair = StrikeStatsSummary.Pair(kind: kind, attacker: "a", defender: "b", completed: 1, unresolved: 2)
            #expect(!StrikeStatsCopy.attempt(pair).contains("%"))
            #expect(StrikeStatsCopy.attempt(pair).contains("1 of 1 resolved"))
            #expect(StrikeStatsCopy.attempt(.init(kind: kind, attacker: "a", defender: "b")).contains("No"))
        }
    }

    @Test func holdsGroupAndTransitionsCountOnce() throws {
        var first = attempt(.submission, "unresolved", detail: "triangle")
        first.endTime = 5
        let rows = [first, attempt(.submission, "defended", time: 4, detail: "armbar"),
                    attempt(.submission, "defended", time: 10, detail: "guillotine"),
                    attempt(.submission, "unresolved", time: 20, detail: "rear-naked choke")]
        let pair = try #require(StrikeStatsSummary.pairs(events: rows).first)
        #expect(pair.attempts == 3)
        #expect(pair.holds == ["armbar": 1, "chokes": 2])
        #expect(pair.defended == 2 && pair.unresolved == 1)
    }

    @Test func completedSubmissionRequiresMatchingOutcome() throws {
        let row = attempt(.submission, "completed")
        let invalid = try #require(StrikeStatsSummary.pairs(events: [row]).first)
        #expect(invalid.outcomeCheck && invalid.completed == 0 && invalid.unresolved == 1)
        let valid = try #require(StrikeStatsSummary.pairs(events: [row], outcomes: [outcome]).first)
        #expect(!valid.outcomeCheck && valid.completed == 1)
        let duplicate = try #require(StrikeStatsSummary.pairs(events: [row, attempt(.submission, "completed", time: 10)], outcomes: [outcome]).first)
        #expect(duplicate.outcomeCheck && duplicate.completed == 0)
        var wrong = outcome
        wrong.method = "decision"
        #expect(StrikeStatsSummary.pairs(events: [row], outcomes: [wrong]).first?.outcomeCheck == true)
    }

    @Test func strikeFamilyDeduplicatesWithinPointFourSeconds() {
        let rows = [(0.0, "strike", 1.0), (0.2, "hurt", 5.0), (0.4, "knockdown", 8.0), (0.6, "strike", 1.0)]
            .map { FightEventRecord(id: 1, videoID: 1, time: $0.0, fighterKey: "a", action: $0.1, points: $0.2) }
        #expect(StrikeStatsSummary.deduplicatedStrikes(rows).map(\.action) == ["knockdown", "strike"])
        var other = rows[0]; other.fighterKey = "b"
        #expect(StrikeStatsSummary.deduplicatedStrikes(rows + [other]).count == 3)
    }

    @Test func attemptParserAndPointsPreserveScoring() throws {
        for kind in AttemptKind.allCases {
            for resolution in ["completed", "defended", "unresolved"] {
                let row = try #require(FightAttemptParser.parse(
                    ["at_time": 1, "end_time": 4, "fighter": "Alice", "target_key": "b", "action": kind.action,
                     "outcome": resolution, "detail": "armbar"], videoID: 1, start: 0, end: 10,
                    validKeys: ["a", "b"], keyByName: ["alice": "a"]))
                #expect(row.fighterKey == "a" && row.targetKey == "b" && row.endTime == 4)
                #expect(row.points == (kind == .submission ? 5 : resolution == "completed" ? 4 : 0))
            }
        }
        #expect(FightScoring.points(for: "takedown") == 4)
        #expect(FightScoring.points(for: "submission_attempt") == 5)
        #expect(FightAttemptParser.parse(["t": 1, "end_time": 1, "action": "takedown_attempt"], videoID: 1,
                                       start: 0, end: 10, validKeys: [], keyByName: [:]) == nil)
    }

    @Test func forbiddenWordsAcrossEveryStateUnitAndKind() {
        // Single-letter units are tokens, not substrings of ordinary English words.
        let forbidden: Set<String> = ["force", "n", "lbf", "psi", "energy", "j", "hardest", "power"]
        for state in StrikeStatPayload.State.allCases {
            for unit in StrikeStatPayload.Unit.allCases {
                for kind in StrikeStatPayload.Kind.allCases {
                    for attemptKind in AttemptKind.allCases {
                        for hold in SubmissionHold.allCases {
                            for count in [0, 1, 2] {
                                let pair = StrikeStatsSummary.Pair(kind: attemptKind, attacker: "a", defender: "b",
                                    completed: count, defended: count, unresolved: count, legacy: state == .legacy ? 2 : 0,
                                    holds: [hold.group: count], outcomeCheck: state == .outcomeCheck)
                                let payload = StrikeStatPayload(kind: kind, values: .init(
                                    fighters: [.init(key: "a", name: "Alice", strikes: 2), .init(key: "b", name: "Bob")],
                                    attempts: [.init(pair)]), states: [state], unit: unit)
                                let text = StrikeStatsCopy.text(payload)
                                let tokens = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
                                #expect(tokens.isDisjoint(with: forbidden))
                                if state != .unavailable { #expect(text.contains("AI-scored") && text.contains("in analyzed footage")) }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func analyzedDurationUnionsOverlaps() {
        var a = Fixtures.scene(start: 0, end: 8); a.tags = ["striking"]
        var b = Fixtures.scene(id: 2, start: 5, end: 10); b.tags = a.tags
        a.tags = [SmartSampling.actionTags.sorted().first!]; b.tags = a.tags
        #expect(StrikeStatsSummary.analyzedSeconds(scenes: [a, b], start: 2, end: 9) == 7)
    }
    @Test func legacyEmptyAttemptsAndOutOfScopeFinishesStayQualified() {
        var video = Fixtures.video(); video.videoType = VideoType.fight.rawValue
        let original = StrikeStatPayload(kind: .roundCard, sourceVideoID: video.id, sourceTime: 0,
                                         scope: .init(start: 0, end: 5))
        let legacyPass = AnalysisPassRecord(videoID: video.id, pass: .fightScore, version: 1,
                                            status: .completed, startedAt: "1")
        let legacy = StrikeStatsSummary.snapshot(original, video: video, events: [], scenes: [],
                                                 outcomes: [], roster: [], passes: [legacyPass])
        #expect(StrikeStatsCopy.text(legacy).contains("attempts not scored"))
        #expect(StrikeStatsCopy.text(legacy).contains("outcomes not scored"))
        let rows = [attempt(.submission, "completed"), attempt(.submission, "completed", time: 10)]
        let snapshot = StrikeStatsSummary.snapshot(original, video: video, events: rows, scenes: [],
                                                   outcomes: [outcome], roster: [], passes: [])
        #expect(snapshot.states?.contains(.outcomeCheck) == true)
        #expect(snapshot.values?.attempts?.first?.completed == 0)
    }

}
