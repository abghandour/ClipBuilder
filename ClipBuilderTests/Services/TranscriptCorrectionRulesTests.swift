import Foundation
import Testing
@testable import Clip_Builder

struct TranscriptCorrectionRulesTests {
    private func row(_ text: String, translated: Bool = false) -> TranscriptRow {
        TranscriptRow(id: 1, videoID: 1, language: "pt", isTranslation: translated,
            startTime: 0, endTime: 10, text: text, originalText: nil, wordsJSON: nil, provider: nil, model: nil)
    }

    @Test func wholeWordsFoldCaseAndDiacriticsAndKeepPunctuation() {
        let rule = TranscriptCorrectionRules.Rule(from: "cafe", to: "coffee shop")
        let result = TranscriptCorrectionRules.applying([rule], to: [row("“Café,” café! cafeteria decafe cafe's")])
        #expect(result.count == 2)
        #expect(result.changes[1] == "“Coffee shop,” coffee shop! cafeteria decafe cafe's")
    }

    @Test func firstRuleWinsWithoutCascadesOrLoops() {
        let rules: [TranscriptCorrectionRules.Rule] = [.init(from: "a", to: "b c"),
            .init(from: "b", to: "a"), .init(from: "c", to: "d"), .init(from: "A", to: "wrong")]
        let result = TranscriptCorrectionRules.applying(rules, to: [row("a b c")])
        #expect(result.changes[1] == "b c a d")
        #expect(result.count == 3)
    }

    @Test func deletionCannotCreateAnAlsoFixOrAlwaysFixRule() {
        #expect(TranscriptCorrectionRules.rule(from: "um", to: "") == nil)
        #expect(TranscriptCorrectionRules.rule(from: "um", to: " \n ") == nil)
        #expect(TranscriptCorrectionRules.rule(from: "um", to: "…") == nil)
        #expect(TranscriptCorrectionRules.rule(from: "um", to: "yes") == TranscriptCorrectionRules.Rule(from: "um", to: "yes"))
        #expect(TranscriptCorrectionRules.rule(from: "two words", to: "one") == nil)
    }

    @Test func legacyDeletionRulesAndNoOpAndTranslations() {
        let rule = TranscriptCorrectionRules.Rule(from: "um", to: "")
        #expect(TranscriptCorrectionRules.applying([rule], to: [row("Um, yes um.")]).changes[1] == "yes")
        #expect(TranscriptCorrectionRules.applying([rule], to: [row("um", translated: true)]).count == 0)
        #expect(TranscriptCorrectionRules.applying([.init(from: "yes", to: "yes")], to: [row("Yes! yes")]).count == 0)
    }

    @Test func fixAllExcludesTheJustFixedReplacementEvenWhenItContainsTheSource() {
        let result = TranscriptCorrectionRules.applying([.init(from: "cat", to: "cat dog")],
            to: [row("cat dog cat")], excluding: [1: [0, 1]])
        #expect(result.count == 1)
        #expect(result.changes[1] == "cat dog cat dog")
    }

    @Test func newTranscriptionsAreCorrectedBeforeTheyAreStoredAndKeepWordTimes() {
        let words = [TranscriptWord(word: "Peace", start: 0, end: 1, confidence: 0.9),
                     TranscriptWord(word: "Rpper,", start: 1, end: 2, confidence: 0.2),
                     TranscriptWord(word: "oi", start: 2, end: 3, confidence: 0.9)]
        let segments = [TranscriptSegment(start: 0, end: 3, text: "Peace Rpper, oi", words: words),
                        TranscriptSegment(start: 3, end: 4, text: "nada aqui", words: nil)]
        let result = TranscriptCorrectionRules.applying([.init(from: "rpper", to: "Grappler")], to: segments)
        #expect(result[0].text == "Peace Grappler, oi")
        #expect(result[0].words?.map(\.word) == ["Peace", "Grappler,", "oi"])
        #expect(result[0].words?[1].start == 1)
        // The corrected word is no longer the recognizer's guess.
        #expect(result[0].words?[1].confidence == nil)
        #expect(result[0].words?[2].confidence == 0.9)
        #expect(result[1].text == "nada aqui")
    }

    @Test func profileRulesRoundTripButNeverEnterTeamDocument() throws {
        var profile = BrandProfile(name: "Word rules test")
        profile.transcriptCorrections = [.init(from: "cafe", to: "coffee")]
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(BrandProfile.self, from: data).transcriptCorrections == profile.transcriptCorrections)
        #expect(try !TeamProfileDocument.encode(profile).contains("transcript_corrections"))
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "transcript_corrections")
        let legacy = try JSONSerialization.data(withJSONObject: old)
        #expect(try JSONDecoder().decode(BrandProfile.self, from: legacy).transcriptCorrections == nil)
    }
}
