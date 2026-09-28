import Foundation

/// Every AI task the app dispatches, in one place. The raw value is the key
/// stored in settings (`AIConfig.tasks`, `taskModels`) and stamped into
/// `AIProvenance.task`, so it never changes. Each case names where its
/// prompt is built and what the model answers with, so "what does the
/// critic do" is one lookup here rather than a grep across call sites.
///
/// Routing (default provider, recommended chain, label) stays in
/// `AICatalog`, keyed by `rawValue`; `AITaskRegistryTests` keeps the two in
/// step.
nonisolated enum AITask: String, CaseIterable, Sendable, Codable {
    // MARK: Analysis and library

    /// Tags sampled frames of a source video (visual analysis). Prompt:
    /// `Analyzer` (`callThinningFrames`); JSON of scene tags. Also used by
    /// `InstagramService` to analyze a studied reel into a template.
    case analysis
    /// Finds people in a handful of frames. Prompt: `Analyzer` people pass.
    case people
    /// One-off image or asset analysis with frames attached (asset
    /// browser, image library captions). Prompt inline at the call site.
    case analyze
    /// Trim suggestion: which start/end cut leaves the content and drops
    /// the filler. Prompt: `Analyzer` trim pass; JSON `{start, end, reason}`.
    case trim
    /// Finds duplicate videos from sampled frames. Prompt: `DuplicateFinder`.
    case dedupe
    /// Names a file from its stored metadata. Prompt: `RenameSuggestion` /
    /// File Name Wizard in `AppStore+AITools`.
    case naming
    /// Natural-language search over scenes or owned images. Prompts:
    /// `SceneSearch` (`AppStore+AITools`) and `AppStore+ImageSearch`.
    case search
    /// AI Favorites: judges scenes against the taste rubric. Prompt:
    /// `SceneCurator.prompt`; proposals with reasons.
    case curate
    /// Quote extraction from a transcript. Prompt: `SoundbiteFinder`.
    case soundbites
    /// Picks a cover frame from candidates. Prompt: `CoverFramePicker.prompt`.
    case cover
    /// Content gap report over the whole library. Prompt: `GapReporter`.
    case gap
    /// Reads overlay layout (positions, colors) from one reference image.
    /// Prompt: overlay wizard in `AppStore+AITools`.
    case overlay
    /// Translates transcript or caption text. Prompts: `TranslationBatch`,
    /// `TranscriptTranslator`.
    case translate

    // MARK: Podcast

    /// Groups a transcript into exchanges. Prompt: `PodcastAnalysisService`.
    case exchanges
    /// Scores exchanges as highlight candidates. Prompt:
    /// `PodcastHighlightFinder`; validated into `HighlightCandidate`.
    case highlights
    /// Places B-roll cutaways inside a highlight. Prompt:
    /// `PodcastHighlightBRollPlanner`, called from
    /// `PodcastHighlightBRollPlacement`.
    case broll

    // MARK: Reel generation (the Wizard)

    /// Parses a free-text video request into `ParsedWizardRequest`.
    /// Prompt: `WizardEngine.parseRequestPrompt`.
    case parse
    /// Routes a Builder script request to the right handler. Prompt:
    /// `ScriptRequestRouter`.
    case route
    /// Plans the reel: which clips, in what order, with what overlays.
    /// Prompt: `WizardEngine.planPrompt`; JSON validated by
    /// `WizardEngine.validatePlan` into `WizardPlan`. Strongest model first.
    case wizard
    /// Judges the rendered reel from sampled frames. Prompt:
    /// `ReelCritic.prompt`; answers `ReelCritique`. Routed to a different
    /// model than `wizard` so the planner never grades its own work.
    case critique
    /// Writes the Instagram caption for a rendered reel. Prompt:
    /// `WizardEngine.captionPrompt`; also caption fixes in `AppStore`.
    case captions
    /// Turns crawled fan chatter into the reel's story. Prompt:
    /// `FightResearchService`.
    case fightResearch = "fight_research"
    /// Legacy reels research. No live call site; kept so stored provenance
    /// and settings still resolve.
    case research

    // MARK: Learning and profile

    /// Distills text from evidence: house style from analyzed reels and
    /// lessons from reviews (`WizardEngine.distillHouseStyle`,
    /// `distillLessons`), performance lessons from Instagram insights
    /// (`PerformanceLessons.prompt` in `AppStore+AITools`).
    case distill
    /// Profile starter: writes a brand's founding rubric. Prompt:
    /// `ProfileStarter`.
    case onboard

    // MARK: Provenance-only tasks (not dispatched through `AIService.call`)

    /// Builder editing through an agent CLI. Runs via `BuilderAgentRun`.
    case builderAgent = "builder_agent"
    /// Apple speech transcription (`AIProvenance.appleSpeech`).
    case transcribe
    /// Apple speech analyzer runs recorded by `AIRunSettings`.
    case transcription
    /// Apple Vision framing / Center Stage paths (`AIProvenance.appleVision`).
    case framing

    /// Tasks the user can route in Settings (provider and model pickers).
    /// Order is the Settings order.
    static let configurable: [AITask] = [
        .analysis, .people, .exchanges, .highlights, .broll, .wizard, .critique, .research, .fightResearch,
        .parse, .captions, .distill, .overlay, .naming, .curate, .search, .soundbites, .cover, .dedupe, .trim,
        .gap, .onboard, .route,
    ]

    /// Human label from the catalog, falling back to the key.
    var label: String { AICatalog.taskLabels[rawValue] ?? rawValue }
}
