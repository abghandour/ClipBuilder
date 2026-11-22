import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fight scoring lesson rules")
struct FightScoringLessonsTests {
    @Test func lessonsPromptRequestsGeneralReplacementRules() {
        let text = FightCorrections.lessonsPrompt(corrections: [], roster: [
            .init(videoID: 1, personID: 1, key: "a", name: "Alice", descriptor: "red shorts", portraitAt: 0)
        ], existing: [.init(id: 1, text: "Follow the initiating limb.", sourceCount: 5, enabled: false)])
        #expect(text.contains("at most 8") && text.contains("one sentence"))
        #expect(text.contains("No fighter names, timestamps, or fight-specific facts"))
        #expect(text.contains("FULL replacement list") && text.contains("red shorts"))
        #expect(text.contains("Disabled: Follow the initiating limb."))
        #expect(text.contains(#"{"lessons":"#))
    }

    @Test func parserRejectsMalformedAndMixedLists() {
        for value in ["nonsense", "{}", #"{"lessons":[1]}"#, #"{"lessons":["ok",null]}"#, #"{"lessons":[" "]}"#] {
            #expect(throws: (any Error).self) { try FightCorrections.parseLessons(value) }
        }
    }

    @Test func parserCapsDeduplicatesAndAllowsExplicitEmptyList() throws {
        let data = try JSONEncoder().encode(["lessons": (0..<12).map { "Rule \($0)." }])
        #expect(try FightCorrections.parseLessons(String(decoding: data, as: UTF8.self)).count == 8)
        #expect(try FightCorrections.parseLessons(#"{"lessons":[" Same rule. ","Same rule."]}"#) == ["Same rule."])
        #expect(try FightCorrections.parseLessons(#"{"lessons":[]}"#).isEmpty)
    }

    @Test func scoringPromptPlacesNotesAndOnlyEnabledLessonsInOrder() throws {
        let lessons = (0..<12).map { FightScoringLesson(id: Int64($0), text: "Rule \($0).", sourceCount: 5, enabled: $0 != 0) }
        let selected = FightCorrections.enabledLessons(lessons)
        #expect(selected.count == 8 && !selected.contains("Rule 0."))
        let event = FightEventRecord(id: 1, videoID: 1, time: 2, fighterKey: "a", action: "strike", points: 1)
        let prompt = Analyzer.fightScorePrompt(domain: "MMA", windowStart: 0, windowEnd: 12, roster: [], hasReferences: false,
            corrections: [.init(event: event, kind: .remove)], lessons: selected)
        let fighters = try #require(prompt.range(of: "FIGHTERS —"))
        let reviewed = try #require(prompt.range(of: "REVIEWED BY A PERSON"))
        let learned = try #require(prompt.range(of: "LESSONS FROM EARLIER REVIEWS"))
        let other = try #require(prompt.range(of: "OTHER RULES"))
        #expect(fighters.lowerBound < reviewed.lowerBound && reviewed.lowerBound < learned.lowerBound && learned.lowerBound < other.lowerBound)
        #expect(!prompt.contains("Rule 0.") && !prompt.contains("Rule 9."))
        #expect(FightCorrections.lessonsBlock([]).isEmpty)
        #expect(AnalysisPipeline.fightScorePass == 3)
    }

    @Test func lessonTaskMirrorsDistillRoute() {
        #expect(AITask.fightLessons.label == "Fight scoring lessons")
        #expect(AITask.configurable.contains(.fightLessons))
        #expect(AICatalog.taskDefaults["fight_lessons"] == AICatalog.taskDefaults["distill"])
        let lesson = AICatalog.recommendedChains["fight_lessons"] ?? []
        let distill = AICatalog.recommendedChains["distill"] ?? []
        #expect(lesson.map { $0.0 } == distill.map { $0.0 })
        #expect(lesson.map { $0.1 } == distill.map { $0.1 })
    }

    @Test func fingerprintTracksContentButNotScoringBindings() throws {
        let event = FightEventRecord(id: 1, videoID: 1, time: 2, fighterKey: "a", action: "strike", points: 1)
        let correction = FightCorrectionRecord(event: event, kind: .confirm)
        var updated = correction
        updated.generation = 100
        updated.eventID = 200
        #expect(try FightCorrections.learningFingerprint(correction) == FightCorrections.learningFingerprint(updated))
        updated.kind = .remove
        #expect(try FightCorrections.learningFingerprint(correction) != FightCorrections.learningFingerprint(updated))
        #expect(FightCorrections.learningThreshold == 5)
    }
}
