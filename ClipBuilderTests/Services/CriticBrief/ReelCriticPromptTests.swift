import Foundation
import Testing
@testable import Clip_Builder

struct ReelCriticPromptTests {
    private func prompt(scope: ReelCritic.Scope, brief: CriticBrief? = nil,
                        options: WizardOptions = WizardOptions()) -> String {
        var profile = Fixtures.brand()
        profile.tasteRubric = "Selection: choose the decisive action.\nStory: resolve the exchange.\nCaptions: use large type.\nBranding: show the logo.\nOverlays: contrast over footage."
        profile.houseStyle = "Hook: open on the answer.\nWatermark: bottom right."
        return ReelCritic.prompt(duration: 4, plan: Fixtures.plan(clips: []), sceneMap: [:],
            options: options, profile: profile, attempt: 1, previous: [], brief: brief, scope: scope)
    }

    @Test func contentPromptHasOnlyContentRubric() {
        let text = prompt(scope: .content)
        #expect(text.contains("reduced-quality proxy"))
        #expect(text.contains("Selection:") && text.contains("Story:") && text.contains("Hook:"))
        for line in ["Captions:", "Branding:", "Overlays:", "Watermark:", "Framing:", "Finish:"] {
            #expect(!text.contains(line))
        }
        #expect(text.contains("planner's next take"))
    }

    @Test func presentationPromptHasOnlyPresentationRubric() {
        let text = prompt(scope: .presentation)
        #expect(text.contains("FINAL rendered reel"))
        for line in ["Captions:", "Branding:", "Overlays:", "Watermark:", "Framing:", "Finish:"] {
            #expect(text.contains(line))
        }
        for line in ["Selection:", "Story:", "Hook:", "Selected moments", "Planner's strategy", "planner's next take"] {
            #expect(!text.contains(line))
        }
        #expect(text.contains("\"regenerate\": false"))
    }

    @Test(arguments: [ReelCritic.Scope.content, .presentation])
    func referencesAreFilteredToTheScope(scope: ReelCritic.Scope) {
        var brief = CriticBriefFixtures.brief()
        brief.rules = "Story: retain the payoff.\nOverlays: use high contrast."
        let text = prompt(scope: scope, brief: brief)
        #expect(text.contains("COMPARE, do not reward copying"))
        #expect(text.contains("\"reference_gap\""))
        #expect(text.contains("Story: retain the payoff.") == (scope == .content))
        #expect(text.contains("Overlays: use high contrast.") == (scope == .presentation))
        #expect(!prompt(scope: scope).contains("\"reference_gap\""))
    }

    @Test func mixedRubricLinesDoNotLeakOtherScope() {
        let mixed = "Hook and captions should match.\nNeutral taste."
        #expect(ReelCritic.Scope.content.filtered(mixed) == "Neutral taste.")
        #expect(ReelCritic.Scope.presentation.filtered(mixed) == "Neutral taste.")
    }

    @Test func targetScoreAppearsAndClampsRegeneration() throws {
        var options = WizardOptions()
        options.critiqueTargetScore = 80
        #expect(prompt(scope: .content, options: options).contains("score < 80 AND"))
        let approved = try ReelCritic.parse(#"{"score":80,"regenerate":true,"notes":["Try a stronger hook"]}"#,
            options: options, scope: .content)
        #expect(!approved.regenerate)
        let below = try ReelCritic.parse(#"{"score":79,"regenerate":true,"notes":["Try a stronger hook"]}"#,
            options: options, scope: .content)
        #expect(below.regenerate)
    }

    @Test func presentationCanNeverRequestReplanning() throws {
        let critique = try ReelCritic.parse(#"{"score":20,"regenerate":true,"notes":["Fix placement"],"engagement_forecast":10,"forecast_reasons":["Weak opening"]}"#,
            options: WizardOptions(), scope: .presentation)
        #expect(critique.score == 20 && critique.notes.contains("Fix placement"))
        #expect(!critique.regenerate)
    }
}
