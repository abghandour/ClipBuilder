import Foundation

/// One Wizard recipe: the menu title and plain-language description a person
/// reads, and the format contract the planner prompt enforces. Both come
/// from the same entry so the caption never drifts from what the AI is told.
nonisolated struct ReelRecipe: Identifiable, Sendable, Equatable {
    /// Stable id persisted in `wizard.formatPreset` and `WizardOptions.formatPreset`.
    let id: String
    let title: String
    /// One or two sentences: what the reel is for, how it opens, how long it runs.
    let summary: String
    /// The "## FORMAT" block appended to the planner prompt; empty for Custom.
    let promptBlock: String

    static let customID = "custom"

    /// No format rules; the plan follows instructions, research, and taste.
    static let custom = ReelRecipe(
        id: customID,
        title: "Custom",
        summary: "No format rules. The plan follows your instructions, saved research, and learned taste.",
        promptBlock: "")

    /// Menu order: Custom, then the MMA recipes, then the general ones.
    /// Each inner array is one menu section.
    static let menuSections: [[ReelRecipe]] = [
        [custom],
        [mmaFinish, mmaSubmission, mmaExchange, mmaTechnique],
        [recap, compilation, interview, podcast],
    ]

    static let all: [ReelRecipe] = menuSections.flatMap(\.self)

    static func recipe(id: String) -> ReelRecipe? {
        all.first { $0.id == id }
    }

    /// The prompt block for a preset id; empty for Custom, learned
    /// "cat:" types (handled by the caller), and unknown ids.
    static func promptBlock(for id: String) -> String {
        recipe(id: id)?.promptBlock ?? ""
    }

    static let mmaFinish = ReelRecipe(
        id: "mma-finish",
        title: "MMA finish",
        summary: "Finish-first: opens on the impact or tap, then just enough lead-in and the reaction. About 8–15 seconds, one slow-motion replay at most.",
        promptBlock: """

        ## FORMAT: MMA FINISH (hard requirements)
        - Make an 8–15 second finish-first reel. The opening 1–1.5 seconds MUST show the cleanest impact, tap, or immediate reaction; then give only enough lead-in to make the payoff intelligible.
        - Preserve the referee/crowd/commentator reaction after the finish. Use at most one slow-motion replay, and only for the decisive impact.
        - Text should be factual and minimal: fighter name, round, or verified finish method only. Never imply a result not in FIGHT OUTCOMES.

        """)

    static let mmaSubmission = ReelRecipe(
        id: "mma-submission",
        title: "MMA submission sequence",
        summary: "A grappling story with a beginning: the entry, the control or escape attempt, then the tap or reaction. Slower, deliberate cuts with the original audio.",
        promptBlock: """

        ## FORMAT: MMA SUBMISSION SEQUENCE (hard requirements)
        - Tell a comprehensible technical arc: entry → control/escape attempt → tap or reaction. Do not open on a static hold without an immediate promise in text.
        - Favor source audio and commentary; use slower, deliberate cuts rather than aggressive transition effects.
        - Only call a submission/tap when FIGHT OUTCOMES or the analyzed scene explicitly confirms it.

        """)

    static let mmaExchange = ReelRecipe(
        id: "mma-exchange",
        title: "MMA exchange",
        summary: "An escalating striking exchange that reads on mute: starts on the most surprising strike or reaction, then returns to the setup. About 12–22 seconds, hard cuts.",
        promptBlock: """

        ## FORMAT: MMA EXCHANGE (hard requirements)
        - Build a 12–22 second escalating exchange: pressure → answer/counter → clearest reaction. Include both fighters when possible so the action reads instantly on mute.
        - Start with the most surprising strike or reaction, then return to the setup. Preserve crowd swell and commentator peak around the payoff.
        - Use hard cuts as the default; one action transition maximum for the decisive strike.

        """)

    static let mmaTechnique = ReelRecipe(
        id: "mma-technique",
        title: "MMA technique breakdown",
        summary: "An educational, save-worthy reel: the completed technique first, then the setup and the one detail that makes it work. About 20–45 seconds with up to three factual labels.",
        promptBlock: """

        ## FORMAT: MMA TECHNIQUE BREAKDOWN (hard requirements)
        - Make a save-worthy 20–45 second educational reel: show the completed technique first, then a concise setup and the decisive detail.
        - Use no more than three factual overlays: technique name, setup cue, and key detail. Do not invent technical terminology; use only what is visible or in user instructions.
        - Prefer clarity, clean framing, and source audio over rapid montage effects.

        """)

    static let recap = ReelRecipe(
        id: "recap",
        title: "Fight recap",
        summary: "The whole fight in order, building through the best exchanges to the finish or the hand raise. The result becomes the headline; little other text.",
        promptBlock: """

        ## FORMAT: FIGHT RECAP (hard requirements)
        - Tell the fight CHRONOLOGICALLY: build through the best exchanges to the finish, and END on the finishing sequence or the hand raise/celebration (tags: knockdown, knockout, submission-attempt, celebration).
        - Set "headline" to the result (e.g. "MILES JOHNS BEATS GIANNI VAZQUEZ") from the FIGHT OUTCOMES block; use last names when the full line exceeds ~6 words.
        - Keep per-clip text overlays minimal — the headline carries the story.

        """)

    static let compilation = ReelRecipe(
        id: "compilation",
        title: "Best-of compilation",
        summary: "The biggest moments across all your sources, ordered so the impact escalates and the best moment lands last. Adds a title card and a banner naming the fighters in each clip.",
        promptBlock: """

        ## FORMAT: BEST-OF COMPILATION (hard requirements)
        - Pick the highest-impact moments across ALL available sources; order for escalating impact, best moment last.
        - Set "intro_title" to a punchy 3-6 word ALL-CAPS compilation title (e.g. "BEST KO & TKO'S").
        - Label clips from different fights with a short banner overlay naming the fighters (use the person: tags to know who is who).

        """)

    static let interview = ReelRecipe(
        id: "interview",
        title: "Interview clip",
        summary: "Complete spoken moments, never cut mid-sentence, with a lower-third naming the speaker. The voice stays primary; music is quiet or off.",
        promptBlock: """

        ## FORMAT: INTERVIEW CLIP (hard requirements)
        - Pick coherent SPOKEN segments (interview/talking tags); never cut mid-sentence when the moments/dialog hints show sentence boundaries.
        - One "lower-third" overlay naming the speaker on their first clip; put their role in "kicker". No other text overlays.
        - Keep source audio primary: quiet music at most.

        """)

    static let podcast = ReelRecipe(
        id: "podcast",
        title: "Podcast highlights",
        summary: "One complete question-and-answer exchange from the conversation, trimmed only at sentence ends, with a lower-third for each speaker. The voices stay primary.",
        promptBlock: """

        ## FORMAT: PODCAST HIGHLIGHT (hard requirements)
        - Every available scene is already a reel-worthy, complete question-and-answer exchange. Choose exactly one scene and keep the entire exchange unless it exceeds the requested target length.
        - When trimming an overlong exchange, preserve complete sentences; validation snaps every boundary to transcript sentence ends.
        - Add one "lower-third" overlay for each named speaker's first appearance; keep source audio primary and music quiet or absent.

        """)
}
