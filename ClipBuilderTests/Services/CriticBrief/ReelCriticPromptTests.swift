import Foundation
import Testing
@testable import Clip_Builder

struct ReelCriticPromptTests {
    private func prompt(brief: CriticBrief? = nil, options: WizardOptions = WizardOptions()) -> String {
        var profile = Fixtures.brand()
        profile.tasteRubric = "Taste fixture"
        profile.houseStyle = "House fixture"
        return ReelCritic.prompt(duration: 4, plan: Fixtures.plan(clips: []), sceneMap: [:],
            options: options, profile: profile, attempt: 1, previous: [], brief: brief)
    }

    @Test func withoutBriefMatchesOriginalBytes() {
        #expect(Array(prompt().utf8) == Array(Self.originalPrompt.utf8))
    }

    @Test func referenceSectionAndSchema() {
        let brief = CriticBriefFixtures.brief()
        let text = prompt(brief: brief)
        #expect(text.contains("COMPARE, do not reward copying"))
        #expect(text.contains(brief.rules))
        for exemplar in brief.exemplars { #expect(text.contains(exemplar.summary)) }
        #expect(text.contains("\"reference_gap\""))
        #expect(!prompt().contains("\"reference_gap\""))
    }

    // Captured from 7341799 before any critic changes.
    private static let originalPrompt = """
    You are a ruthless short-form editor reviewing a rendered Instagram fight reel before it ships. The attached images are frames sampled from the FINAL rendered video (labels are timestamps). Judge the rendered result, not the intent: hook impact in the first 2 seconds, pacing and cut rhythm, 9:16 framing (are the fighters fully in frame?), text overlay legibility over the footage, escalation toward a payoff, and the ending. Be specific and be strict — a mediocre reel should not score above 70.

    ## The reel
    - Rendered duration: 4.0s
    - Music: none · Captions: off · Text overlays: off
    - Planner's strategy: fixture

    ## Planned clips (what each moment is supposed to be)

    ## The owner's taste (judge against THIS, not your own)
    Taste fixture

    ## House style
    House fixture

    ## Answer with STRICT JSON only — no prose outside the JSON
    {
      "score": <0-100>,
      "summary": "<one sentence verdict>",
      "strengths": ["<what genuinely works>"],
      "issues": ["<specific problems visible in the rendered frames>"],
      "notes": ["<concrete, actionable instructions for the planner's next attempt — name clips by number>"],
      "regenerate": <true only if score < 85 AND the issues are fixable by re-planning from the same footage>,
      "engagement_forecast": <0-100: how THIS account's audience will respond (saves, shares, watch-through), judged against the account benchmarks above — 50 = a typical reel for the account, 75+ = top quartile; omit when no benchmarks were given>,
      "forecast_reasons": ["<what in the rendered reel drives or drags the forecast, tied to the top/bottom-quartile traits — specific, actionable for the planner>"]
    }
    """
}

extension ReelCriticPromptTests {
    @Test func targetScoreAppearsAndClampsRegeneration() throws {
        var options = WizardOptions()
        options.critiqueTargetScore = 80
        let text = prompt(options: options)
        #expect(text.contains("score < 80 AND"))
        #expect(!text.contains("score < 85 AND"))
        let approved = try ReelCritic.parse(#"{"score":80,"regenerate":true,"notes":["Try a stronger hook"]}"#, options: options)
        #expect(!approved.regenerate)
        let below = try ReelCritic.parse(#"{"score":79,"regenerate":true,"notes":["Try a stronger hook"]}"#, options: options)
        #expect(below.regenerate)
    }
}
