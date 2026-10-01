import Foundation
import Testing
@testable import Clip_Builder

struct ReelCritiqueParsingTests {
    @Test func referenceGapAndProvenance() throws {
        let critique = try ReelCritic.parse(#"{"score":70,"regenerate":true,"reference_gap":["Open on the action"]}"#,
            options: WizardOptions(), briefKey: "brief-one")
        #expect(critique.notes == ["Reference gap: Open on the action"])
        #expect(critique.regenerate)
        #expect(critique.briefKey == "brief-one")
        let roundTrip = try JSONDecoder().decode(ReelCritique.self, from: JSONEncoder().encode(critique))
        #expect(roundTrip == critique)
    }

    @Test func missingKeysAndLegacyDecoding() throws {
        let critique = try ReelCritic.parse(#"{"score":70}"#, options: WizardOptions())
        #expect(critique.notes.isEmpty && critique.briefKey == nil && !critique.regenerate)
        let legacy = #"{"score":70,"summary":"old","strengths":[],"issues":[],"notes":[],"regenerate":false}"#
        #expect(try JSONDecoder().decode(ReelCritique.self, from: Data(legacy.utf8)).briefKey == nil)
    }
}
