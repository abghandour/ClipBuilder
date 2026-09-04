import CoreGraphics
import Foundation

nonisolated struct WizardOptions: Sendable {
    var muteSource = false
    var addCaptions = false
    var enableTextOverlays = false
    var useMusic = true
    var aiInstructions = ""
    /// Inject each in-play video's saved fight research (crawled fan
    /// reactions, run from the Analyze page) into planning and captions.
    /// On by default — the research is free story context when it exists.
    var useFightResearch = true
    /// Restrict scene selection to these analyze batches (empty = all).
    var selectedRunIDs: Set<Int64> = []
    /// Only pick from scenes the user promoted to the Curated set.
    var curatedOnly = false
    /// Which taste steers the plan: nil = the profile's main taste rubric,
    /// "none" = no taste block, "cat:<key>" = that learned category's rubric.
    var tastePreset: String?
    /// Person keys the footage must feature: when set, only scenes tagged
    /// with at least one of these people are eligible (empty = everyone).
    /// Combines with the batch filter above.
    var sourcePeople: [String] = []
    var modelOverride: String?
    /// Structural analysis of a reference reel (ReelTemplate JSON) the plan
    /// should replicate, plus a human-readable label for logs.
    var templateJSON: String?
    var templateLabel: String?
    /// Hard duration the user asked for (e.g. "a 15s video") — overrides the
    /// research/template numbers instead of merely suggesting them.
    var targetDurationSeconds: Int?
    /// Screen-crop layouts may need a live camera because their aspect ratio
    /// differs from the scene's saved 9:16 framing. Ordinary clips always
    /// replay their saved scene path when one exists.
    var framingCamera = "balanced"
    /// Screen-crop layouts (by name) the planner may use to show several
    /// scenes at once, each area framed by its own tracking camera. Empty =
    /// the feature is off and "screen_crop"/"layout" in a plan are ignored.
    var screenCropLayouts: [String] = []
    /// Transition names the planner may use; nil = any. "cut" is always
    /// allowed.
    var allowedTransitions: [String]? = nil

    /// What performs on the connected Instagram account (measured from its
    /// reels) — steers the planner's numbers, the caption's hashtags, and
    /// the critic's engagement forecast. Nil until report data exists.
    var accountBenchmarks: AccountBenchmarks? = nil

    // The AI Wizard form persists these in UserDefaults; the pipeline and
    // the form read them through the same helpers.
    static let useScreenCropsKey = WizardDefaults.useScreenCropsKey
    static let screenCropLayoutsKey = WizardDefaults.screenCropLayoutsKey
    static let limitTransitionsKey = WizardDefaults.limitTransitionsKey
    static let allowedTransitionsKey = WizardDefaults.allowedTransitionsKey

    /// Layouts the form allows: none when the toggle is off; every layout
    /// when it's on but nothing is picked.
    static func screenCropLayoutsFromDefaults() -> [String] {
        WizardDefaults.approvedScreenCropLayouts()
    }

    /// nil = any transition; otherwise the checked names (possibly empty =
    /// hard cuts only).
    static func allowedTransitionsFromDefaults() -> [String]? {
        WizardDefaults.allowedTransitions()
    }
    /// Overlay choices the user named explicitly. The template is forced onto
    /// every planned overlay; the text is guaranteed to appear on one clip.
    var pinnedOverlayTemplate: String?
    var pinnedOverlayText: String?
    /// Reel format recipe: generic types plus MMA-specific editorial recipes.
    var formatPreset = "custom"
    /// After each render, an AI critic reviews the rendered reel; when it
    /// recommends a retry the wizard re-plans with the critic's notes and
    /// renders again — up to 3 versions total, all kept with their reviews.
    var critiqueLoop = true
    /// Brand-kit elements burned into the render (need profile assets).
    var includeWatermark = true
    var includeHeadline = true
    var includeOutro = true
}

/// A plain-language request ("action-packed 15s, fight footage only, use the
/// Sample 1 overlay saying 'Porrada day!'") decomposed into wizard settings.
/// nil/empty fields mean the user didn't specify.
nonisolated struct ParsedWizardRequest: Sendable, Equatable {
    var targetDurationSeconds: Int?
    /// Restrict footage to scenes carrying at least one of these tags
    /// (validated against the profile's tag vocabulary).
    var contentTags: [String] = []
    /// Exact saved overlay-template name (validated against the store).
    var overlayTemplate: String?
    /// Exact text the user wants displayed on screen.
    var overlayText: String?
    var enableTextOverlays: Bool?
    var addCaptions: Bool?
    var useMusic: Bool?
    /// Everything that maps to no setting — fed to the planner as
    /// highest-priority instructions so no intent is lost.
    var residualInstructions = ""
}

/// A "Generate Video" request handed from the Analyze/Scenes/People screens
/// to the Wizard; `parsed` and `statusMessage` update in place while
/// analysis/parsing runs.
nonisolated struct WizardPromptHandoff: Sendable, Equatable {
    var description: String
    var videoIDs: Set<Int64>
    /// Exact analyze batches to draw from (Scenes/People hand-offs) — takes
    /// precedence over `videoIDs`, which resolves to each video's latest batch.
    var runIDs: Set<Int64> = []
    /// Source-people filter to apply in the Wizard (person keys).
    var personKeys: Set<String> = []
    /// Content tags the displayed scenes were filtered by — ride into the
    /// Wizard's instructions so only matching footage is used.
    var tags: [String] = []
    var parsed: ParsedWizardRequest?
    /// Non-nil while the request is still being prepared.
    var statusMessage: String?
    /// AI interpretation failed — the raw description rides as instructions.
    var parseFailed = false
}

nonisolated struct WizardPlanClip: Sendable {
    var sceneID: Int64
    var start: Double
    var end: Double
    var textOverlay: String?
    var overlayStyle: String?
    var overlayAnimation: String?
    var overlayKicker: String?
    var overlayAccent: String?
    /// Vertical overlay placement from the plan/reference template:
    /// "top" (default), "center", or "bottom".
    var overlayPlacement: String?
    /// "as_written" keeps the overlay text's casing (reference templates
    /// with sentence-case text); default uppercases.
    var overlayCase: String?
    /// The model's stated reason for this pick — kept through validation so
    /// reviews can be correlated with intent.
    var reason: String?
    /// Playback speed: 1 = normal, 0.5–0.75 = slow motion, 1.25–2 =
    /// speed-up. Screen time is (end - start) / speed.
    var speed: Double = 1
    /// Instantly replay this moment in slow motion right after it plays —
    /// expanded into a second slowed clip during validation.
    var replay: Bool = false
    /// Screen Crop reference ("Layout/Area") from the library: only that
    /// area of the frame shows for this clip (the footage is framed INTO
    /// the area by a tracking camera).
    var screenCrop: String? = nil
    /// A multi-scene block: this clip's scene fills `screenCrop`'s area and
    /// `areaClips` fill the layout's other areas, all for this clip's
    /// duration.
    var layout: String? = nil
    var areaClips: [WizardPlanAreaClip] = []
}

/// One extra scene inside a layout block, in the named area.
nonisolated struct WizardPlanAreaClip: Sendable {
    var area: String
    var sceneID: Int64
    var start: Double
    var end: Double
}

/// Hand-tuned text overlay looks the wizard's AI picks from by name. The AI
/// does creative direction (which words, which style, which animation); the
/// rendering stays deterministic.
nonisolated enum WizardTextStyle: String, CaseIterable {
    case impact       // huge condensed type, black outline, hard shadow
    case highlight    // black outline + accent color on *starred* words
    case banner       // bold type on a solid full-width bar
    case minimal      // clean bold type with a soft shadow

    static let animations = ["fade", "slide_up", "pop", "word_reveal"]
    static let placements = ["top", "center", "bottom"]
    static let textCases = ["upper", "as_written"]

    /// Accept only #rgb/#rrggbb(aa)-style accents from the model.
    static func sanitizedAccent(_ accent: String?) -> String? {
        guard let accent = accent?.trimmingCharacters(in: .whitespacesAndNewlines),
              accent.hasPrefix("#"), (4...9).contains(accent.count),
              accent.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return accent
    }

    /// The overlay template for this style: auto-fit box placed per
    /// `placement` (upper third by default); the caller sets text/timing.
    /// `accent` (a #hex from a reference template) overrides the default
    /// yellow on kicker chips, starred words, and tag stripes; `textCase`
    /// "as_written" keeps the text's casing for sentence-case references.
    func overlayItem(text: String, kicker: String? = nil, accent: String? = nil,
                     placement: String? = nil, textCase: String? = nil) -> TextOverlayItem {
        var item = TextOverlayItem()
        item.text = textCase == "as_written" ? text : text.uppercased()
        item.xFrac = 0.5
        switch placement {
        case "center": item.yFrac = 0.5
        case "bottom": item.yFrac = 0.76
        default: item.yFrac = 0.2
        }
        item.wFrac = 0.82
        item.hFrac = 0.12
        item.boxOpacity = 0
        switch self {
        case .impact:
            item.design = "hero"
            item.fontfamily = "Anton"
            item.strokeColor = "black"
            item.strokeWidthEm = 0.05
            item.kicker = kicker
        case .highlight:
            item.design = "hero"
            item.fontfamily = "Anton"
            item.highlightColor = "#FFD400"
            item.strokeColor = "black"
            item.strokeWidthEm = 0.05
            item.kicker = kicker
        case .banner:
            item.design = "tag"
            item.fontfamily = "Archivo Black"
            item.hFrac = 0.06
        case .minimal:
            item.fontfamily = "Helvetica Neue"
            item.bold = true
            item.shadowOpacity = 0.45
        }
        if let accent = Self.sanitizedAccent(accent) {
            item.accentColor = accent
            if item.highlightColor != nil { item.highlightColor = accent }
        }
        return item
    }
}

/// Resolve a plan clip's style name to an overlay composition. A user
/// template (matched by name) applies its saved design: the AI's text goes
/// into every text marked dynamic, everything else — static texts, images,
/// per-item timing, transitions — renders verbatim, so `isTemplate` tells
/// callers to skip the AI's animation/kicker choices. Otherwise the built-in
/// WizardTextStyle renders as a single full-clip text (default impact).
nonisolated func wizardPlanOverlay(for clip: WizardPlanClip, text: String)
    -> (composition: OverlayComposition, isTemplate: Bool) {
    if var composition = OverlayTemplateStore.composition(named: clip.overlayStyle) {
        for index in composition.texts.indices {
            composition.texts[index].uid = UUID()
            if composition.texts[index].isDynamic {
                composition.texts[index].text = text
            }
        }
        for index in composition.images.indices {
            composition.images[index].uid = UUID()
        }
        return (composition, true)
    }
    let style = WizardTextStyle(rawValue: clip.overlayStyle ?? "") ?? .impact
    let item = style.overlayItem(text: text, kicker: clip.overlayKicker,
                                 accent: clip.overlayAccent,
                                 placement: clip.overlayPlacement,
                                 textCase: clip.overlayCase)
    return (OverlayComposition(texts: [item]), false)
}

nonisolated struct WizardPlan: Sendable {
    var targetDuration: Double
    var rationale: String
    var musicName: String?
    var musicVolume: Int
    var clips: [WizardPlanClip]
    var transitions: [String]
    /// Result headline for the full-video branded lower-third.
    var headline: String?
    /// Typographic intro-card title (compilation format).
    var introTitle: String?
    /// The planner's kebab-case name for the output file ("du-plessis-
    /// strickland-split-decision"); nil falls back to the headline/title.
    var fileName: String?
    /// The provider/model that wrote this plan (after any failover).
    var provenance: AIProvenance? = nil

    /// A filesystem-safe slug: lowercase ASCII letters/digits joined by
    /// single hyphens, capped at 60 characters; nil when nothing survives.
    static func slug(_ text: String?) -> String? {
        guard let text else { return nil }
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        var result = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
            } else if result.last != "-" {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if result.count > 60 {
            result = String(result.prefix(60))
            if let cut = result.lastIndex(of: "-"), result.distance(from: cut, to: result.endIndex) < 12 {
                result = String(result[..<cut])
            }
        }
        return result.isEmpty ? nil : result
    }

    /// The name the rendered file gets: the planner's own, else one built
    /// from the headline or intro title, else "reel".
    var outputBaseName: String {
        fileName ?? Self.slug(headline) ?? Self.slug(introTitle) ?? "reel"
    }
}

/// Autonomous Reels generator — the Swift port of wizard.py: cached research
/// → AI plan → validation → linear assembly → AI caption.
actor WizardEngine {
    private let ai: AIService
    private let render: RenderEngine
    private let centerStage = CenterStageService()

    init(ai: AIService, render: RenderEngine) {
        self.ai = ai
        self.render = render
    }

    /// Music library: ~/Documents/ClipBuilder/assets/music (per-user, shared
    /// across profiles — the app-tree equivalent of the repo's assets/music).
    static var musicDirectory: URL {
        AssetKind.music.rootURL
    }

    /// Recursive: the Music section lets users organize tracks into
    /// subfolders. Names are root-relative (extension dropped) so same-named
    /// tracks in different folders stay distinguishable.
    static func availableMusic() -> [(name: String, url: URL)] {
        AssetStore.allFiles(of: .music)
    }

    // MARK: - Editorial playbook

    /// Curated combat-sports Reels playbook. This app is specialized for
    /// MMA/grappling content, so a hand-written, versioned playbook replaces
    /// the old AI "research" call: it is more reliable than re-asking a model
    /// for generic best practices, works offline, and never goes stale in a
    /// cache. Keys mirror the old research JSON so downstream plumbing
    /// (duration/cadence extraction, prompt injection) is unchanged.
    static let mmaPlaybook: [String: Any] = [
        "ideal_duration_range": ["min": 8, "max": 30],
        "optimal_duration": 18,
        "aspect_ratio": "9:16",
        "hook_strategy": "The first 1-2 seconds decide everything. Open on the single most violent or "
            + "surprising visual: the knockdown landing, the tap, a flying technique mid-air, or a raw "
            + "crowd/corner reaction. Payoff-first beats build-up-first — show the ending, then earn it.",
        "hook_types": ["finish-first (KO/tap lands in the first second, then rewind to the build-up)",
                       "reaction-first (crowd eruption or corner losing it, then the moment that caused it)",
                       "mid-action (drop the viewer inside an exchange already underway)",
                       "freeze-and-promise (paused frame + bold text promising the payoff)"],
        "pacing_cuts_per_minute": 24,
        "content_structure": ["hook (0-2s)", "context/build (2-40%)", "escalation", "payoff", "reaction/outro"],
        "music_strategy": "High-energy track that matches the action's rhythm; cuts land on beats. Keep "
            + "real fight audio audible under the music — crowd noise and glove impacts sell authenticity.",
        "transition_strategy": "Hard cuts as the backbone; one aggressive action transition (impact_shake, "
            + "zoom_punch, knife_slash) as an accent on the biggest strike; a slow crossfade only into a "
            + "slow-motion replay.",
        "engagement_tips": ["End within a beat of the payoff reaction — dead air after the finish kills replays",
                            "One slow-motion replay of the decisive moment earns saves",
                            "Name fighters in text — searchers and casuals both need it",
                            "Loop-friendly endings (cut just before the hook's moment recurs) lift watch time"],
        "avoid": ["Slow walkout/staredown intros", "More than one replay", "Overlays covering the action",
                  "Passing off training footage as a real fight", "Claiming results the outcomes don't confirm"],
        "opening_types": ["knockdown impact", "submission tap", "flying technique", "crowd eruption"],
        "closing_strategy": "Close on the reaction to the payoff — referee waving it off, corner storming in, "
            + "opponent's face — not on a fade-out. The last frame should make a viewer replay or share.",
    ]

    // MARK: - Request parsing

    private func parseRequestPrompt(description: String, templateNames: [String],
                                    tagVocabulary: [String]) -> String {
        let templates = templateNames.isEmpty
            ? "None saved."
            : templateNames.map { "\"\($0)\"" }.joined(separator: ", ")
        let tags = tagVocabulary.isEmpty ? "None." : tagVocabulary.joined(separator: ", ")
        return """
        You are configuring an AI video-generation wizard from a user's plain-language request.

        ## User request
        "\(description)"

        ## Saved overlay templates (the only templates that exist)
        \(templates)

        ## Content tag vocabulary (the only tags that exist)
        \(tags)

        Return a JSON object with EXACTLY this structure:
        {
          "target_duration_seconds": <int, or null if the user gave no duration>,
          "content_tags": ["<tag from the vocabulary>", ...],
          "overlay_template": "<exact template name from the list, or null>",
          "overlay_text": "<exact text the user wants displayed on the video, or null>",
          "enable_text_overlays": <true|false|null>,
          "add_captions": <true|false|null>,
          "use_music": <true|false|null>,
          "residual_instructions": "<every remaining creative requirement, imperative voice; \"\" if none>"
        }

        Rules:
        - null (or [] for content_tags) means the user did not specify it. Never guess or invent defaults.
        - "content_tags": when the user restricts WHAT footage to use (e.g. "fight footage only"), pick EVERY vocabulary tag matching that restriction. Empty when they don't restrict content.
        - "overlay_template": the user may refer to a template loosely (e.g. 'the text overlays "Sample 1"'). Match by meaning but return the EXACT listed name; null when nothing matches.
        - "overlay_text": text the user wants shown ON the video — often a quoted phrase they call a caption, title, or overlay (e.g. 'with the caption "Porrada day!"' → "Porrada day!"). Copy it verbatim; never invent text.
        - "add_captions" is ONLY for burned-in spoken-word transcript subtitles, not overlay text.
        - "enable_text_overlays": true whenever the user asks for any on-screen text, overlay template, or overlay text.
        - "residual_instructions": everything not captured above (style, pacing, mood, hook ideas...). Do NOT repeat anything you already captured in a field.
        - Return ONLY the JSON object.
        """
    }

    /// Turn a free-text "generate a sample video" description into wizard
    /// settings. Template and tag answers are validated against what actually
    /// exists; anything else the model claims is dropped, not trusted.
    func parseRequest(description: String, profile: BrandProfile,
                      emit: @escaping @Sendable (String) -> Void) async throws -> ParsedWizardRequest {
        let templateNames = OverlayTemplateStore.list().map(\.name)
        let tagVocabulary = profile.effectiveTags.values.flatMap(\.self).sorted()
        let prompt = parseRequestPrompt(description: description,
                                        templateNames: templateNames,
                                        tagVocabulary: tagVocabulary)
        let response = try await ai.call(prompt: prompt, task: "parse", timeout: 120, log: emit)
        guard let object = AIResponseParser.jsonObject(from: response.text) else {
            throw AIError.emptyResponse("request parsing (unparseable JSON)")
        }

        var parsed = ParsedWizardRequest()
        if let duration = (object["target_duration_seconds"] as? NSNumber)?.intValue, duration > 0 {
            parsed.targetDurationSeconds = min(180, max(3, duration))
        }
        let knownTags = Set(tagVocabulary.map { $0.lowercased() })
        parsed.contentTags = (object["content_tags"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { knownTags.contains($0.lowercased()) }
        if let name = object["overlay_template"] as? String,
           let match = templateNames.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            parsed.overlayTemplate = match
        }
        let overlayText = (object["overlay_text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        parsed.overlayText = overlayText?.isEmpty == false ? overlayText : nil
        parsed.enableTextOverlays = object["enable_text_overlays"] as? Bool
        if parsed.overlayTemplate != nil || parsed.overlayText != nil {
            parsed.enableTextOverlays = true
        }
        parsed.addCaptions = object["add_captions"] as? Bool
        parsed.useMusic = object["use_music"] as? Bool
        parsed.residualInstructions = (object["residual_instructions"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return parsed
    }

    // MARK: - Planning phase

    /// The tags the prompt's RULES key on must survive truncation — sort
    /// highlight/portrait-fit/person tags to the front before capping.
    private func prioritizedTags(_ tags: [String], limit: Int = 10) -> [String] {
        func priority(_ tag: String) -> Int {
            if tag == "highlight" || tag.hasPrefix("highlight:") { return 0 }
            if tag.hasPrefix("portrait-fit:") { return 1 }
            if tag.hasPrefix("person:") { return 2 }
            if tag == "low-quality" { return 3 }
            return 4
        }
        // Stable within each priority band so the analyzer's ordering holds.
        return Array(tags.enumerated()
            .sorted { (priority($0.element), $0.offset) < (priority($1.element), $1.offset) }
            .map(\.element)
            .prefix(limit))
    }

    private func sceneLine(_ scene: SceneRecord, type: VideoType? = nil,
                           note: String? = nil) -> String {
        var line = "#\(scene.id): \(scene.videoFilename) " +
            String(format: "[%.1f-%.1f] %.1fs", scene.startTime, scene.endTime, scene.duration) +
            (type.map { " (\($0.rawValue) video)" } ?? "") +
            " tags:\(prioritizedTags(scene.tags).joined(separator: ","))"
        if scene.wide { line += " WIDE" }
        if let score = scene.score {
            line += String(format: " score:%.1f/10", score)
        }
        if let excitement = scene.excitement, excitement >= 0.35 {
            line += " CROWD-POP"
        }
        if let average = scene.gradeAverage, scene.gradeCount > 0 {
            line += String(format: " grade:%.1f/5", average)
        }
        if scene.favorite { line += " ♥FAVORITE" }
        if scene.curated { line += " CURATED" }
        if let parent = scene.parentSceneID {
            line += " (action within sequence #\(parent))"
        }
        if let note { line += " " + note }
        if let narrative = scene.narrative, !narrative.isEmpty {
            line += "\n    story: " + String(narrative.prefix(220))
        }
        return line
    }

    /// Scenes are tag ranges, so one can sit entirely inside another from the
    /// same video. Spelled out per line because the model follows explicit
    /// pointers far more reliably than interval arithmetic over a long list.
    private func containmentNotes(_ scenes: [SceneRecord]) -> [Int64: String] {
        var notes: [Int64: String] = [:]
        for group in Dictionary(grouping: scenes, by: \.videoID).values {
            for scene in group {
                let contains = group.filter {
                    $0.id != scene.id && $0.startTime >= scene.startTime && $0.endTime <= scene.endTime
                }.map { "#\($0.id)" }
                let within = group.filter {
                    $0.id != scene.id && scene.startTime >= $0.startTime && scene.endTime <= $0.endTime
                }.map { "#\($0.id)" }
                var parts: [String] = []
                if !contains.isEmpty { parts.append("contains:" + contains.prefix(8).joined(separator: ",")) }
                if !within.isEmpty { parts.append("within:" + within.prefix(8).joined(separator: ",")) }
                if !parts.isEmpty { notes[scene.id] = parts.joined(separator: " ") }
            }
        }
        return notes
    }

    /// One review as prompt lines: whole-video verdict, dimension thumbs,
    /// then only the clips the user reacted to.
    private func reviewLines(_ summary: ReviewSummary) -> String {
        var verdictWord = summary.review.verdict > 0 ? "LIKED" : (summary.review.verdict < 0 ? "DISLIKED" : "MIXED")
        if summary.videoDeleted { verdictWord += " (user deleted this reel)" }
        var lines = ["- \(summary.videoFilename): \(verdictWord)"]
        let dimensions = summary.review.dimensions
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value > 0 ? "good" : "bad")" }
        if !dimensions.isEmpty { lines.append("  aspects — " + dimensions.joined(separator: ", ")) }
        for clip in summary.clips where clip.verdict != 0 {
            var line = "  clip \(clip.clipIndex + 1)"
            if let sceneID = clip.sceneID { line += " (scene #\(sceneID))" }
            line += clip.verdict > 0 ? ": good pick" : ": bad — \(clip.reasons.joined(separator: ", "))"
            // The planner's own reason for the pick — so a bad verdict
            // teaches WHICH intent misfired, not just which scene.
            if let reason = summary.clipReasons[clip.clipIndex] {
                line += " (planner's intent was: \"\(String(reason.prefix(140)))\")"
            }
            lines.append(line)
        }
        if !summary.review.note.isEmpty { lines.append("  note: \"\(summary.review.note)\"") }
        return lines.joined(separator: "\n")
    }

    /// Everything the user has taught the wizard, compact: distilled lessons,
    /// structured review signals, A/B choices, and the latest raw notes —
    /// instead of an unbounded dump of every feedback entry ever written.
    /// One approved reel's SHAPE (never its scenes): clip count, screen-time
    /// stats, and the hook's intent, from the stored plan clips.
    private func winnerLine(_ winner: WinningRecipeRecord) -> String {
        var parts = [String(format: "%.1fs", winner.duration)]
        if let data = winner.planClipsJSON?.data(using: .utf8),
           let clips = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !clips.isEmpty {
            let screenSeconds = clips.map { clip -> Double in
                let start = (clip["start"] as? NSNumber)?.doubleValue ?? 0
                let end = (clip["end"] as? NSNumber)?.doubleValue ?? 0
                let speed = (clip["speed"] as? NSNumber)?.doubleValue ?? 1
                return max(0, end - start) / max(0.1, speed)
            }
            parts.append("\(clips.count) clips")
            parts.append(String(format: "avg %.1fs/clip", screenSeconds.reduce(0, +) / Double(clips.count)))
            if let hook = clips.first, let reason = hook["reason"] as? String, !reason.isEmpty {
                parts.append("hook: \"\(String(reason.prefix(120)))\"")
            }
        }
        if let stats = winner.stats {
            parts.append(ReelPerformance.label(stats, duration: winner.duration))
        }
        var line = "- \(winner.filename): " + parts.joined(separator: " · ")
        if let rationale = winner.rationale, !rationale.isEmpty {
            line += "\n  strategy: \(String(rationale.prefix(300)))"
        }
        return line
    }

    private func trainingBlock(_ signals: TrainingSignals) -> String {
        var sections: [String] = []

        if !signals.winners.isEmpty {
            sections.append("### Reels This User APPROVED (your strongest signal — replicate the SHAPE and strategy, never the same scenes)\n"
                + signals.winners.map(winnerLine).joined(separator: "\n"))
        }

        let learned = signals.lessons.filter { !$0.pinned }
        if !learned.isEmpty {
            sections.append("### Learned Lessons (distilled from this user's past reviews — apply every one)\n"
                + learned.map { "- \($0.text)\($0.evidence.isEmpty ? "" : " [\($0.evidence)]")" }
                    .joined(separator: "\n"))
        }

        if !signals.reviews.isEmpty {
            sections.append("### Recent Review Signals (newest first)\n"
                + signals.reviews.map(reviewLines).joined(separator: "\n"))
        }

        if !signals.preferences.isEmpty {
            sections.append("### A/B Choices (the user compared variations — replicate what wins)\n"
                + signals.preferences.map {
                    "- CHOSE \"\($0.chosenRationale)\" OVER \"\($0.rejectedRationale)\""
                }.joined(separator: "\n"))
        }

        if !signals.publishedPerformance.isEmpty {
            let ranked = signals.publishedPerformance.sorted {
                ReelPerformance.score($0.stats) > ReelPerformance.score($1.stats)
            }
            sections.append("### Published-Reel Performance (normalized by reach; replicate the strongest editorial patterns)\n"
                + ranked.map { record in
                    let rationale = record.rationale.map { " · strategy: \($0)" } ?? ""
                    return "- \(record.filename): \(ReelPerformance.label(record.stats, duration: record.duration))\(rationale)"
                }.joined(separator: "\n"))
        }

        let recentFeedback = signals.feedback.prefix(5)
        if !recentFeedback.isEmpty {
            sections.append("### Recent Feedback Notes\n"
                + recentFeedback.map { entry in
                    let file = entry.videoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
                    return "- \"\(entry.feedback)\" (on \(file))"
                }.joined(separator: "\n"))
        }

        guard !sections.isEmpty else {
            return "No training signals yet — this is the first generation."
        }
        return sections.joined(separator: "\n\n")
    }

    private func planPrompt(profile: BrandProfile,
                            research: [String: Any],
                            scenes: [SceneRecord],
                            musicNames: [String],
                            signals: TrainingSignals,
                            people: [PersonRecord],
                            outcomes: [FightOutcome],
                            fightResearch: [FightResearchRecord] = [],
                            videoTypes: [Int64: VideoType] = [:],
                            options: WizardOptions) -> String {
        // Fight results the analyzer extracted — the ground truth behind
        // "headline" and recap storytelling.
        let namesByKey = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.displayName) })
        var outcomesBlock = ""
        if !outcomes.isEmpty {
            let lines = outcomes.map { outcome in
                let winner = outcome.winnerKey.map { namesByKey[$0] ?? $0 } ?? "unknown winner"
                let loser = outcome.loserKey.map { namesByKey[$0] ?? $0 } ?? "unknown opponent"
                return "- \(winner) beat \(loser) by \(outcome.method.uppercased())"
                    + (outcome.event.map { " at \($0)" } ?? "")
            }.joined(separator: "\n")
            outcomesBlock = """

            ## FIGHT OUTCOMES (extracted from the footage — ground truth)
            \(lines)
            Base the "headline" and any result claims ONLY on these. Never invent a result.

            """
        }
        var presetBlock = ""
        switch options.formatPreset {
        case "mma-finish":
            presetBlock = """

            ## FORMAT: MMA FINISH (hard requirements)
            - Make an 8–15 second finish-first reel. The opening 1–1.5 seconds MUST show the cleanest impact, tap, or immediate reaction; then give only enough lead-in to make the payoff intelligible.
            - Preserve the referee/crowd/commentator reaction after the finish. Use at most one slow-motion replay, and only for the decisive impact.
            - Text should be factual and minimal: fighter name, round, or verified finish method only. Never imply a result not in FIGHT OUTCOMES.

            """
        case "mma-submission":
            presetBlock = """

            ## FORMAT: MMA SUBMISSION SEQUENCE (hard requirements)
            - Tell a comprehensible technical arc: entry → control/escape attempt → tap or reaction. Do not open on a static hold without an immediate promise in text.
            - Favor source audio and commentary; use slower, deliberate cuts rather than aggressive transition effects.
            - Only call a submission/tap when FIGHT OUTCOMES or the analyzed scene explicitly confirms it.

            """
        case "mma-exchange":
            presetBlock = """

            ## FORMAT: MMA EXCHANGE (hard requirements)
            - Build a 12–22 second escalating exchange: pressure → answer/counter → clearest reaction. Include both fighters when possible so the action reads instantly on mute.
            - Start with the most surprising strike or reaction, then return to the setup. Preserve crowd swell and commentator peak around the payoff.
            - Use hard cuts as the default; one action transition maximum for the decisive strike.

            """
        case "mma-technique":
            presetBlock = """

            ## FORMAT: MMA TECHNIQUE BREAKDOWN (hard requirements)
            - Make a save-worthy 20–45 second educational reel: show the completed technique first, then a concise setup and the decisive detail.
            - Use no more than three factual overlays: technique name, setup cue, and key detail. Do not invent technical terminology; use only what is visible or in user instructions.
            - Prefer clarity, clean framing, and source audio over rapid montage effects.

            """
        case "recap":
            presetBlock = """

            ## FORMAT: FIGHT RECAP (hard requirements)
            - Tell the fight CHRONOLOGICALLY: build through the best exchanges to the finish, and END on the finishing sequence or the hand raise/celebration (tags: knockdown, knockout, submission-attempt, celebration).
            - Set "headline" to the result (e.g. "MILES JOHNS BEATS GIANNI VAZQUEZ") from the FIGHT OUTCOMES block; use last names when the full line exceeds ~6 words.
            - Keep per-clip text overlays minimal — the headline carries the story.

            """
        case "compilation":
            presetBlock = """

            ## FORMAT: BEST-OF COMPILATION (hard requirements)
            - Pick the highest-impact moments across ALL available sources; order for escalating impact, best moment last.
            - Set "intro_title" to a punchy 3-6 word ALL-CAPS compilation title (e.g. "BEST KO & TKO'S").
            - Label clips from different fights with a short banner overlay naming the fighters (use the person: tags to know who is who).

            """
        case "interview":
            presetBlock = """

            ## FORMAT: INTERVIEW CLIP (hard requirements)
            - Pick coherent SPOKEN segments (interview/talking tags); never cut mid-sentence when the moments/dialog hints show sentence boundaries.
            - One banner overlay naming the speaker on the first clip; no other text overlays.
            - Keep source audio primary: quiet music at most.

            """
        default:
            // Learned video types: "cat:<key>" injects that category's
            // rubric as the format contract.
            if options.formatPreset.hasPrefix("cat:") {
                let key = String(options.formatPreset.dropFirst(4))
                if let category = profile.tasteCategories.first(where: { $0.key == key }) {
                    presetBlock = """

                    ## VIDEO TYPE: \(category.label.uppercased()) (learned from the user's Instagram exemplars)
                    This reel must be a \(category.label) video. What a keeper moment looks like for this type:
                    \(category.rubric)
                    STRONGLY prefer scenes tagged "highlight:\(category.key)" — they matched this type's rubric during analysis. Build the reel's arc from moments of this kind.

                    """
                }
            }
        }
        let domain = profile.effectiveDomain
        let brand = profile.brandName

        let range = research["ideal_duration_range"] as? [String: Any]
        var durationMin = (range?["min"] as? NSNumber)?.intValue ?? 15
        var durationMax = (range?["max"] as? NSNumber)?.intValue ?? 30
        var targetDuration = (research["optimal_duration"] as? NSNumber)?.intValue ?? 22
        var cutsPerMinute = (research["pacing_cuts_per_minute"] as? NSNumber)?.intValue ?? 20

        // A reference template overrides the research's generic numbers.
        let template = options.templateJSON.flatMap { AIResponseParser.jsonObject(from: $0) }
        if let template {
            if let duration = (template["duration"] as? NSNumber)?.doubleValue, duration > 0 {
                targetDuration = Int(duration.rounded())
                durationMin = min(durationMin, targetDuration - 3)
                durationMax = max(durationMax, targetDuration + 3)
            }
            if let cadence = (template["cuts_per_minute"] as? NSNumber)?.doubleValue, cadence > 0 {
                cutsPerMinute = Int(cadence.rounded())
            }
        }

        // The account's own measurements outrank the playbook's generic
        // numbers; a reference template and an explicit duration still win.
        var benchmarksBlock = ""
        if let benchmarks = options.accountBenchmarks {
            if template == nil, let min = benchmarks.durationSweetSpotMin, let max = benchmarks.durationSweetSpotMax,
               let target = benchmarks.durationTopMedian, min < max {
                targetDuration = target
                durationMin = min
                durationMax = max
            }
            if template == nil, let cuts = benchmarks.cutsPerMinuteTop, cuts > 0 {
                cutsPerMinute = cuts
            }
            benchmarksBlock = """


            ## THIS ACCOUNT'S BENCHMARKS (measured from its Instagram insights — outranks the generic playbook)
            \(benchmarks.plannerBlock())
            """
        }

        // An explicit user duration beats research and template alike. It
        // bounds the FINISHED file: each crossfade eats ~0.5s of overlap in
        // the render, so the planned clip total is padded by the expected
        // transition count or the output lands short of what the user asked.
        var durationDirective = ""
        let xfadeDuration = SettingsStore.loadSettings().transitions.xfadeDuration
        if let requested = options.targetDurationSeconds {
            let expectedClips = max(1, Int((Double(requested) / 60 * Double(cutsPerMinute)).rounded()))
            // Assume roughly half the gaps get an overlapping transition —
            // hard cuts and most action transitions consume no time.
            let padded = Double(requested) + xfadeDuration * 0.5 * Double(expectedClips - 1)
            targetDuration = Int(padded.rounded())
            durationMin = max(3, targetDuration - 2)
            durationMax = targetDuration + 2
            durationDirective = """


            ## REQUIRED DURATION (HARD CONSTRAINT)
            The user requires the FINISHED reel to run ~\(requested)s. Transitions overlap the clips they join: each crossfade consumes ~\(String(format: "%.2f", xfadeDuration))s, whip_left/whip_right ~0.15s, speed_ramp ~0.3s; "cut" and all other action transitions consume ~0s. You MUST plan more clip time than \(requested)s: total clip duration = \(requested) + the summed overlap of the transitions you pick (~\(String(format: "%.1f", padded))s at ~\(expectedClips) clips with a typical mix). Set "target_duration" to that padded total, never to \(requested).
            """
        }

        let researchJSON = (try? JSONSerialization.data(withJSONObject: research, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var userInstructions = ""
        if !options.aiInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInstructions = """


            ## USER AI INSTRUCTIONS (HIGHEST PRIORITY — OVERRIDES ALL OTHER GUIDANCE BELOW)
            \(options.aiInstructions)
            These are hard requirements. Follow them even when they conflict with the research, feedback, or rules below.
            """
        }

        var pinnedRules = ""
        let pinned = signals.lessons.filter(\.pinned)
        if !pinned.isEmpty {
            pinnedRules = """


            ## PINNED STYLE RULES (HARD CONSTRAINTS — the user pinned these; NEVER violate them)
            \(pinned.map { "- \($0.text)" }.joined(separator: "\n"))
            """
        }

        var templateBlock = ""
        if let templateJSON = options.templateJSON, let template {
            let label = options.templateLabel.map { " (\($0))" } ?? ""
            // Turn the template's structure phases into an explicit slot
            // contract — the model fills slots instead of eyeballing JSON.
            var slotContract = ""
            if let phases = template["structure"] as? [[String: Any]], !phases.isEmpty {
                let slots = phases.enumerated().map { index, phase -> String in
                    let name = phase["phase"] as? String ?? "phase \(index + 1)"
                    let start = (phase["start"] as? NSNumber)?.doubleValue
                    let end = (phase["end"] as? NSNumber)?.doubleValue
                    let range = (start != nil && end != nil)
                        ? String(format: " %.1f–%.1fs", start!, end!) : ""
                    let description = phase["description"] as? String ?? ""
                    return "- Slot \(index + 1) \"\(name)\"\(range): \(description)"
                }.joined(separator: "\n")
                slotContract = """

                SLOT CONTRACT derived from the template's structure — fill EVERY slot, in order, keeping each slot's share of the total duration within ±30% of the reference:
                \(slots)
                """
            }
            templateBlock = """


            ## REFERENCE TEMPLATE (HIGH PRIORITY — replicate this reel's STRUCTURE)
            The user picked a high-performing reel\(label) as the model for this video. Its structural analysis:
            \(templateJSON)
            \(slotContract)
            Replicate the STRUCTURE, never the content: match its hook type and timing, cut rhythm, pacing curve, phase structure, text overlay usage, and overall duration using the scenes available below. When the template conflicts with the playbook or the key principles, the template wins (user AI instructions still outrank everything).
            Also replicate its TEXT DESIGN and EFFECTS with the tools available here:
            - Map "text_style.font_class" to the closest overlay style: condensed-poster/heavy-sans → "impact" (or "highlight" when the reference colors key words), clean-sans → "banner" for labels or "minimal" for quiet text.
            - Match "text_style.animation": word_reveal/karaoke → "word_reveal", pop → "pop", slide → "slide_up", fade/none → "fade".
            - Copy its accent color: set each overlay's "accent" to the reference's text_style.accent hex; use kickers if has_kicker is true.
            - Match "text_style.placement": set each overlay's "placement" to "top", "center", or "bottom" per the reference; when its text_case is sentence/mixed case, set "text_case" to "as_written".
            - Match "effects.transitions" with the closest names from the available transitions list; mirror its cut rhythm even where an exact effect (whip-pan, flash) is unavailable.
            """
        }

        // House style: what ALL the reels this user studies have in common —
        // always-on background taste; a specific reference template above
        // overrides it where they conflict.
        var houseStyleBlock = ""
        let houseStyle = profile.houseStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !houseStyle.isEmpty {
            houseStyleBlock = """


            ## HOUSE STYLE (distilled from every Instagram reel this user studied, weighted by performance)
            \(houseStyle)
            Follow this house style by default. A REFERENCE TEMPLATE (if present) outranks it; user AI instructions outrank both.
            """
        }

        var pinnedOverlayDirective = ""
        if options.enableTextOverlays {
            if let name = options.pinnedOverlayTemplate {
                pinnedOverlayDirective += """

                - USER REQUIREMENT: set "style" to exactly "\(name)" for EVERY text overlay in this reel — never use a different style.
                """
            }
            if let text = options.pinnedOverlayText {
                pinnedOverlayDirective += """

                - USER REQUIREMENT: one overlay (prefer the hook on the first clip) must display exactly this text, verbatim: "\(text)".
                """
            }
        }

        let textOverlayInstruction: String
        if options.enableTextOverlays {
            // User-saved overlay templates join the built-in palette; their
            // saved look (including transitions) is applied verbatim, so
            // kicker/animation guidance doesn't apply to them.
            let templateNames = OverlayTemplateStore.list().map(\.name)
            let templateStyles = templateNames.isEmpty ? "" : """

            - The user also saved custom overlay templates. Pick one BY EXACT NAME as the "style" when its look fits the moment; it renders the user's saved design with your text ("animation" and "kicker" are ignored for these): \(templateNames.map { "\"\($0)\"" }.joined(separator: ", ")).
            """
            textOverlayInstruction = """
            - Text overlays are ENABLED. Insert punchy ALL-CAPS text ONLY where it improves engagement: the hook (first clip), a payoff/reveal, the climax, or an ending CTA. 2-6 words max, one line each, about 3-5 overlays across the whole reel.
            - Each text overlay is an object: {"text": "...", "style": "...", "animation": "...", "kicker": "..." or null}.
            - Styles: "impact" (poster headline: huge condensed type, outline, gradient — hooks, climaxes), "highlight" (like impact, plus wrap the 1-2 most important words in *stars* to color them accent yellow — e.g. "HE *DROPS* HIM"), "banner" (angled dark plate with an accent stripe — names, stats, CTAs), "minimal" (clean and quiet — context, captions). Vary styles with intent; don't use one style everywhere.\(templateStyles)
            - "kicker": optional 1-3 word label rendered small on an angled accent chip above an impact/highlight headline (e.g. kicker "ROUND 2" above "THE COMEBACK"). Use when a moment deserves context; null otherwise. Ignored by banner/minimal.
            - "accent": leave null for the default yellow. Set a #hex only when a reference template or the user's instructions call for a specific accent color, and use the same accent on every overlay in the reel.
            - Animations: "pop" (snappy rise-settle — punchy moments), "word_reveal" (words appear one by one — building tension, hooks), "slide_up" (energetic entrance), "fade" (calm). Match the animation to the moment's energy.\(pinnedOverlayDirective)
            """
        } else {
            textOverlayInstruction = "- Text overlays are DISABLED. Set \"text_overlay\" to null for every clip."
        }

        // People roster: lets instructions reference detected people by name
        // ("only include scenes with George") and resolves them to scene tags.
        var subjectsBlock = ""
        if !people.isEmpty {
            subjectsBlock = """


            ## PEOPLE (detected across the footage; the user may reference them by name)
            \(people.map { person in
                let named = person.name.isEmpty ? "unnamed" : "\"\(person.name)\""
                return "- \(named): \(person.descriptor) — scenes featuring them are tagged \"\(person.tag)\""
            }.joined(separator: "\n"))
            When the user's instructions mention a person by name, resolve the name with these tags: "only include scenes with <name>" is a HARD FILTER — pick ONLY scenes carrying that person's tag. "Keep <name> in focus / centered" means prefer scenes tagged with them and frame every choice (crops, split-screens, overlay placement) around that person. Never substitute footage of a different person for a named subject.
            """
        }

        let notes = containmentNotes(scenes)
        let sceneList = scenes.map {
            sceneLine($0, type: videoTypes[$0.videoID], note: notes[$0.id])
        }.joined(separator: "\n")
        let musicList = musicNames.isEmpty ? "No music available" : musicNames.joined(separator: ", ")
        let beatInfo = SettingsStore.loadSettings().transitions.beatSnap && !musicNames.isEmpty
            ? "After planning, every cut boundary is automatically snapped to the nearest strong beat "
              + "of the selected music (within ±0.35s). Plan clip durations freely in the 1.5-5s range — "
              + "exact beat alignment is handled for you."
            : "Beat detection found no clear beats. Use your judgment for cut timing."

        // Which taste steers this plan: the profile's main rubric by default,
        // a learned category's rubric when the user picked one, or none.
        // Skipped when the same category already rides in as the format
        // contract — its rubric would appear twice. A stale pick (category
        // since deleted) falls back to the profile's rubric.
        let profileTasteBlock = profile.tasteRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : """
        ## Taste Rubric (distilled from reels this user picked as exemplars)
        A keeper moment looks like this — strongly prefer scenes matching these rules, especially for the hook. Scenes tagged "highlight" already matched them during analysis:
        \(profile.tasteRubric)

        """
        let tasteRubricBlock: String
        switch options.tastePreset {
        case "none":
            tasteRubricBlock = ""
        case let preset? where preset == options.formatPreset:
            tasteRubricBlock = ""
        case let preset? where preset.hasPrefix("cat:"):
            let key = String(preset.dropFirst(4))
            if let category = profile.tasteCategories.first(where: { $0.key == key }) {
                tasteRubricBlock = """
                ## Taste Rubric — \(category.label) (picked for this video)
                A keeper moment looks like this — strongly prefer scenes matching these rules, especially for the hook. Scenes tagged "highlight:\(category.key)" already matched them during analysis:
                \(category.rubric)

                """
            } else {
                tasteRubricBlock = profileTasteBlock
            }
        default:
            tasteRubricBlock = profileTasteBlock
        }

        // Saved fight research (crawled fan reactions, run from Analyze and
        // possibly edited by the user): the story the plan should tell.
        var buzzBlock = ""
        if !fightResearch.isEmpty {
            let blocks = fightResearch.compactMap { record -> String? in
                guard let data = try? JSONSerialization.data(withJSONObject: record.summary,
                                                             options: [.prettyPrinted, .sortedKeys]),
                      let json = String(data: data, encoding: .utf8) else { return nil }
                return "### \(record.fightLabel)\(record.event.isEmpty ? "" : " — \(record.event)")\n\(json)"
            }
            if !blocks.isEmpty {
                buzzBlock = """


                ## FIGHT RESEARCH (fan reactions crawled from the web, reviewed by the user)
                \(blocks.joined(separator: "\n\n"))
                Fans are already telling this fight's story — make the reel join that conversation:
                - Build the reel around "story.angle" and unfold it per "story.arc" (when several fights are in play, each clip follows ITS fight's research).
                - Open on the moment the research centers on; "story.hook_line" is a strong hook overlay candidate.
                - Feature the "talking_points" moments prominently — match them to scenes via tags, story lines, and outcomes.
                - Text overlays may riff on "story.overlay_lines" and the fan sentiment, ALWAYS paraphrased in the brand's voice — never verbatim comments, never usernames.
                - When this research conflicts with the generic guidance above, the research wins for narrative choices (structure, hook, overlay copy). Hard facts still come ONLY from FIGHT OUTCOMES below.
                """
            }
        }

        // The layouts the user allowed (Use custom crops): the planner can
        // show several scenes at once, one per area, or mask one clip to a
        // single area.
        let screenCropLayouts = options.screenCropLayouts
            .compactMap { ScreenCropStore.layout(named: $0) }
            .filter { !$0.areas.isEmpty }
        let screenCropBlock = screenCropLayouts.isEmpty ? "" : """
        ## Available Screen Crops (layouts)
        A layout splits the 9:16 frame into named areas; each area gets its OWN scene, and a tracking camera frames that scene's people inside the area (pan + zoom follow the fighters, so the area shape is filled with the action). Use a layout block when simultaneous footage tells the story better — two angles of the same exchange, a reaction next to the action, before/after, two fighters' walkouts side by side. 1-3 blocks per reel at most, at meaningful moments; never on every clip.
        \(screenCropLayouts.map { layout in
            "- layout \"\(layout.name)\" — areas: " + layout.areas.map {
                "\"\($0.name)\" (\($0.summary))"
            }.joined(separator: ", ")
        }.joined(separator: "\n"))
        To use one: on a clip set "layout" to the layout name, "screen_crop" to "<layout>/<area>" for the clip's own scene, and "areas" to one entry per REMAINING area of that layout — every area filled, all playing for this clip's duration (the area scenes are trimmed to it). A "screen_crop" without "layout" masks that single clip to one area (the rest of the frame is black) — use sparingly.

        """

        return """
        You are an expert combat-sports video editor creating an Instagram Reel for \(brand), a \(domain) channel. You know MMA and grappling: what a knockdown, a submission chain, a scramble, and a real crowd pop look like — and you edit like the best fight-highlight accounts. Your ONLY goal: MAXIMIZE ENGAGEMENT (views, likes, shares, saves).
        \(userInstructions)\(pinnedRules)\(durationDirective)\(templateBlock)\(houseStyleBlock)\(benchmarksBlock)

        ## MMA Reels Playbook (curated editorial baseline)
        \(researchJSON)\(buzzBlock)

        ## Available Scenes
        \(videoTypes.isEmpty ? "" : "Scenes are annotated with their source video's type (fight, training, interview, recap, other) — match the footage to the reel's intent: fight/recap footage for action reels, interview footage for talking moments, and don't pass off training footage as a real fight.\n")\(sceneList)\(subjectsBlock)

        ## Available Music
        \(musicList)

        ## Available Transitions
        \(TransitionCatalog.promptBlock(allowed: options.allowedTransitions))
        GUIDANCE: match transition energy to content energy. For fast-paced action, use "cut" for most gaps and an action transition as an accent at the biggest moments (roughly every 2-4 cuts, varied — e.g. knife_slash or zoom_punch on a knockdown, impact_shake when a hit lands, speed_ramp into a payoff); reserve crossfades for deliberate slowdowns like the moment before a slow-motion replay. For calm content prefer crossfades throughout.

        ## Music Beat Analysis
        \(beatInfo)
        \(screenCropBlock)
        \(tasteRubricBlock)## Training Signals (CRITICAL — what this user has taught you)
        \(trainingBlock(signals))
        \(outcomesBlock)\(presetBlock)
        ## Instructions
        Create a video plan optimized for maximum Instagram Reel engagement.

        THE TRAINING SIGNALS ABOVE ARE YOUR MOST IMPORTANT INPUT — they are this user's accumulated judgments of your previous work. You MUST:
        - Apply every Learned Lesson; never repeat a mistake a review flagged
        - Never reuse a scene a clip review called a bad pick in a similar position; favor scenes marked good picks
        - In A/B choices, the CHOSEN approach won — build on winning strategies, avoid rejected ones
        - Amplify what reviews rated good; recent signals outrank older ones when they conflict
        - In your "rationale" field, explicitly mention which lessons and review signals shaped your decisions

        KEY PRINCIPLES:
        1. HOOK — First 1-2 seconds must grab attention (most explosive/dramatic moment)
        2. PACING — Tight cuts, no dead time. Target ~\(cutsPerMinute) cuts per minute
        3. ARC — Even a 20-second video needs rising action
        4. MUSIC — Choose music that amplifies energy. SYNC cuts to beat positions when possible.
        5. ENDING — Strong close that makes viewers replay or share
        6. DURATION — Target \(targetDuration)s (within \(durationMin)-\(durationMax)s range)
        7. BEATS — If beat positions are provided, align clip start/end times to land on or near beat positions. Viewers subconsciously feel beat-synced cuts as more professional.

        For each clip, specify a sub-range within the scene. Keep clips tight (1.5-5s each).
        Prefer scenes tagged "high-energy" or with action/impact tags from the available list.

        Output a JSON object with EXACTLY this structure:
        {
          "target_duration": <seconds>,
          "rationale": "<brief creative strategy explanation>",
          "headline": "<ALL-CAPS result headline for the branded lower-third, from FIGHT OUTCOMES (e.g. \"MILES JOHNS BEATS GIANNI VAZQUEZ\"), or null when no outcome applies>",
          "intro_title": "<3-6 word ALL-CAPS opening title card (compilation format only), or null>",
          "file_name": "<3-6 word lowercase kebab-case name for the output file saying what the reel IS — the fighters/people or event plus the story angle, e.g. \"du-plessis-strickland-split-decision\" or \"negao-pad-work-highlights\"; letters, digits and hyphens only, no extension>",
          "music": {"name": "<music name from list, or null>", "volume": <1-5>},
          "clips": [
            {
              "scene_id": <id>,
              "start": <start seconds>,
              "end": <end seconds>,
              "speed": <playback speed: 1.0 normal; 0.5-0.75 = slow motion for a big payoff moment; 1.25-2.0 = speed-up for a slow build-up, walkout, or grappling stretch worth keeping but not at full length. Use sparingly — at most 1-2 slowed and 1-2 sped-up clips, everything else 1.0>,
              "replay": <true to instantly replay this moment in slow motion right after it plays — reserve for the single best payoff (knockdown/finish); at most one replay per reel>,
              "screen_crop": <"Layout/Area" from Available Screen Crops when listed and it deliberately fits the clip, else null — most clips are null>,
              "layout": <a layout name from Available Screen Crops to show several scenes at once in this clip's slot, else null>,
              "areas": <when "layout" is set: [{"area": "<remaining area name>", "scene_id": <id>, "start": <seconds>, "end": <seconds>}, ...] covering every other area of the layout; else null>,
              "text_overlay": {"text": "<2-6 word line>", "style": "<impact|highlight|banner|minimal>", "animation": "<fade|slide_up|pop|word_reveal>", "kicker": "<1-3 word label or null>", "accent": "<#hex accent color or null for default yellow>", "placement": "<top|center|bottom, or null for top>", "text_case": "<as_written to keep your casing, or null for ALL CAPS>"} or null,
              "reason": "<why this clip, why this position>"
            }
          ],
          "transitions": ["<transition name>", ...]
        }

        RULES:
        - "transitions" array must have exactly len(clips) - 1 elements
        - clip start/end must be within the scene's time range
        - Scenes from the same video OVERLAP in time (see the contains:/within: notes in the scene list). Every second of source footage may appear in the reel AT MOST ONCE: never pick two clips whose video time ranges overlap, even through different scene IDs. Overlapping clips get trimmed or dropped.
        - each clip duration should be 1.5-5 seconds
        - total clip duration should approximate target_duration
        - only use scene IDs from the list above
        - only use music names from the list above (or null)
        - only use transition names from the list above
        - "screen_crop" and "layout" must be null unless Available Screen Crops lists them; area names must belong to the chosen layout, and area scenes follow the same no-overlap rule as clips
        - WIDE scenes use their saved 9:16 framing when available; otherwise they are automatically cropped to fill the frame. Never plan around letterboxing.
        - Scenes with "score:X/10" were rated for ENTERTAINMENT (escalation → payoff, boosted by real crowd noise). STRONGLY prefer high-scoring scenes, put the highest-scoring payoff early as the hook, and use the "story:" lines to build a reel with an arc — setup, escalation, payoff — instead of disconnected action.
        - "grade:X/5" is the USER'S OWN vote on that scene: treat ≥4/5 as must-consider footage, and avoid ≤2.5/5 scenes unless nothing else covers a needed story beat.
        - "♥FAVORITE" scenes were hand-marked by the user — they love these moments. Strongly prefer them, especially for the hook and the payoff. "CURATED" scenes were hand-trimmed as keepers — prefer them over untouched footage of the same moment.
        - "CROWD-POP" marks scenes where the real crowd audibly erupted — prime hook and payoff material.
        - A scene marked "(action within sequence #N)" is one beat of that sequence. Pick EITHER the whole sequence OR its individual beats — never both, they cover the same footage.
        - A clip's screen time is (end - start) / speed; a replay adds another (end - start) / 0.5 on top. Account for both when hitting target_duration.
        - The finished reel is VERTICAL 9:16. WIDE scenes may carry a portrait-fit tag: "portrait-fit:good" means the people stand close enough together that the vertical crop holds them all; "portrait-fit:poor" means they are spread out and someone WILL be cut out of frame. STRONGLY prefer portrait-fit:good WIDE scenes; pick a portrait-fit:poor one only when nothing else covers the moment.
        - "text_overlay": only include if text overlays are enabled (see below). Use short punchy text (max 6 words) for impact moments, fighter names, or engagement hooks. null if no text needed for this clip. Only use style/animation names from the lists below.
        \(textOverlayInstruction)
        - Return ONLY the JSON object
        """
    }

    /// The longest sub-range of [start, end] not covered by any used range,
    /// or nil when the whole range is covered.
    private func longestFreeGap(start: Double, end: Double,
                                used: [(start: Double, end: Double)]) -> (start: Double, end: Double)? {
        let blockers = used.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
        var best: (start: Double, end: Double)?
        var cursor = start
        for blocker in blockers {
            if blocker.start > cursor, best == nil || blocker.start - cursor > best!.end - best!.start {
                best = (cursor, blocker.start)
            }
            cursor = max(cursor, blocker.end)
        }
        if cursor < end, best == nil || end - cursor > best!.end - best!.start {
            best = (cursor, end)
        }
        return best
    }

    /// Parse + validate the AI's plan per wizard.py rules: clamp clips to
    /// scene bounds, drop sub-0.5s clips, drop or trim clips that re-cover
    /// footage an earlier clip already uses, sanitize music and transitions.
    func validatePlan(_ raw: [String: Any],
                      scenes: [Int64: SceneRecord],
                      musicNames: Set<String>,
                      options: WizardOptions) -> WizardPlan? {
        var musicName: String?
        var musicVolume = 3
        if let music = raw["music"] as? [String: Any] {
            if let name = music["name"] as? String, musicNames.contains(name) {
                musicName = name
            }
            musicVolume = (music["volume"] as? NSNumber)?.intValue ?? 3
        }

        var clips: [WizardPlanClip] = []
        var usedRanges: [Int64: [(start: Double, end: Double)]] = [:]
        // Screen-crop layouts the user allowed, matched case-insensitively
        // and stored in their canonical spelling (nothing when the feature
        // is off, so stray plan fields are dropped).
        let allowedLayouts = Dictionary(
            options.screenCropLayouts.compactMap { ScreenCropStore.layout(named: $0) }
                .map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        let screenCropReferences = Dictionary(
            allowedLayouts.values.flatMap(\.references).map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        for clipObject in raw["clips"] as? [[String: Any]] ?? [] {
            guard let sceneID = (clipObject["scene_id"] as? NSNumber)?.int64Value,
                  let scene = scenes[sceneID] else { continue }
            var start = max(scene.startTime, (clipObject["start"] as? NSNumber)?.doubleValue ?? scene.startTime)
            var end = min(scene.endTime, (clipObject["end"] as? NSNumber)?.doubleValue ?? scene.endTime)
            if end - start < 0.5 {
                start = scene.startTime
                end = min(scene.endTime, start + 3.0)
            }
            guard end - start >= 0.5 else { continue }
            // Scenes overlap (they're tag ranges), so two scene IDs can cover
            // the same footage — dedupe by absolute video time, not scene ID:
            // trim a clip that re-covers accepted footage to its unseen
            // remainder, drop it when too little survives.
            let used = usedRanges[scene.videoID] ?? []
            let overlap = used.reduce(0.0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
            if overlap > 0.5 {
                guard let gap = longestFreeGap(start: start, end: end, used: used),
                      gap.end - gap.start >= 1.5 else { continue }
                (start, end) = gap
            }
            start = start.rounded(toPlaces: 2)
            end = end.rounded(toPlaces: 2)
            usedRanges[scene.videoID, default: []].append((start, end))
            // "text_overlay" is {text, style, animation}; a bare string
            // (older prompt / stubborn model) still works with defaults.
            var overlayText: String?
            var overlayStyle: String?
            var overlayAnimation: String?
            var overlayKicker: String?
            var overlayAccent: String?
            var overlayPlacement: String?
            var overlayCase: String?
            if let overlayObject = clipObject["text_overlay"] as? [String: Any] {
                if let placement = overlayObject["placement"] as? String,
                   WizardTextStyle.placements.contains(placement) {
                    overlayPlacement = placement
                }
                if let textCase = overlayObject["text_case"] as? String,
                   WizardTextStyle.textCases.contains(textCase) {
                    overlayCase = textCase
                }
                overlayText = (overlayObject["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let style = overlayObject["style"] as? String,
                   WizardTextStyle(rawValue: style) != nil
                    || OverlayTemplateStore.composition(named: style) != nil {
                    overlayStyle = style
                }
                if let animation = overlayObject["animation"] as? String,
                   WizardTextStyle.animations.contains(animation) {
                    overlayAnimation = animation
                }
                let kicker = (overlayObject["kicker"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                overlayKicker = kicker?.isEmpty == false ? kicker : nil
                overlayAccent = WizardTextStyle.sanitizedAccent(overlayObject["accent"] as? String)
            } else {
                overlayText = (clipObject["text_overlay"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Clamp to the renderer's usable atempo band (0.5–2×), snapping
            // near-normal values to exactly 1.
            var speed = (clipObject["speed"] as? NSNumber)?.doubleValue ?? 1
            speed = abs(speed - 1) < 0.05 ? 1 : min(2, max(0.5, speed))
            let reason = (clipObject["reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var screenCrop = (clipObject["screen_crop"] as? String)
                .flatMap { screenCropReferences[$0.trimmingCharacters(in: .whitespaces).lowercased()] }
            // Layout block: the clip's own scene takes `screen_crop`'s area
            // (or the layout's first), the "areas" entries fill the rest.
            var layoutName: String?
            var areaClips: [WizardPlanAreaClip] = []
            if let rawLayout = clipObject["layout"] as? String,
               let layout = allowedLayouts[rawLayout.trimmingCharacters(in: .whitespaces).lowercased()] {
                let prefix = layout.name.lowercased() + "/"
                if screenCrop?.lowercased().hasPrefix(prefix) != true { screenCrop = layout.references.first }
                var usedAreas = Set<String>()
                if let own = screenCrop { usedAreas.insert(String(own.dropFirst(prefix.count)).lowercased()) }
                for raw in clipObject["areas"] as? [[String: Any]] ?? [] {
                    guard let areaName = (raw["area"] as? String)?.trimmingCharacters(in: .whitespaces),
                          let areaDef = layout.areas.first(where: { $0.name.caseInsensitiveCompare(areaName) == .orderedSame }),
                          !usedAreas.contains(areaDef.name.lowercased()),
                          let areaSceneID = (raw["scene_id"] as? NSNumber)?.int64Value,
                          let areaScene = scenes[areaSceneID] else { continue }
                    var areaStart = max(areaScene.startTime,
                                        (raw["start"] as? NSNumber)?.doubleValue ?? areaScene.startTime)
                    var areaEnd = min(areaScene.endTime,
                                      (raw["end"] as? NSNumber)?.doubleValue ?? areaScene.endTime)
                    if areaEnd - areaStart < 0.5 {
                        areaStart = areaScene.startTime
                        areaEnd = min(areaScene.endTime, areaStart + (end - start))
                    }
                    guard areaEnd - areaStart >= 0.5 else { continue }
                    // Same footage-once rule as the main clips.
                    let areaUsed = usedRanges[areaScene.videoID] ?? []
                    let areaOverlap = areaUsed.reduce(0.0) { $0 + max(0, min(areaEnd, $1.end) - max(areaStart, $1.start)) }
                    guard areaOverlap <= 0.5 else { continue }
                    usedRanges[areaScene.videoID, default: []].append((areaStart, areaEnd))
                    usedAreas.insert(areaDef.name.lowercased())
                    areaClips.append(WizardPlanAreaClip(area: areaDef.name, sceneID: areaSceneID,
                                                        start: areaStart.rounded(toPlaces: 2),
                                                        end: areaEnd.rounded(toPlaces: 2)))
                }
                layoutName = areaClips.isEmpty ? nil : layout.name
            }
            clips.append(WizardPlanClip(sceneID: sceneID,
                                        start: start,
                                        end: end,
                                        textOverlay: overlayText?.isEmpty == false ? overlayText : nil,
                                        overlayStyle: overlayStyle,
                                        overlayAnimation: overlayAnimation,
                                        overlayKicker: overlayKicker,
                                        overlayAccent: overlayAccent,
                                        overlayPlacement: overlayPlacement,
                                        overlayCase: overlayCase,
                                        reason: reason?.isEmpty == false ? reason : nil,
                                        speed: speed,
                                        replay: clipObject["replay"] as? Bool ?? false,
                                        screenCrop: screenCrop,
                                        layout: layoutName,
                                        areaClips: areaClips))
        }
        guard !clips.isEmpty else { return nil }

        // Replay directives expand into a second, slowed pass of the same
        // moment — done after the overlap dedupe so the intentional
        // repetition isn't trimmed away. One replay per reel.
        var expanded: [WizardPlanClip] = []
        var replayUsed = false
        for clip in clips {
            expanded.append(clip)
            if clip.replay, !replayUsed {
                replayUsed = true
                var slow = clip
                slow.replay = false
                slow.speed = 0.5
                slow.textOverlay = nil
                slow.overlayStyle = nil
                slow.overlayAnimation = nil
                slow.overlayKicker = nil
                slow.overlayAccent = nil
                slow.overlayPlacement = nil
                slow.overlayCase = nil
                slow.reason = nil
                expanded.append(slow)
            }
        }
        clips = expanded

        let needed = max(0, clips.count - 1)
        let validTransitions = Set((options.allowedTransitions ?? RenderEngine.allTransitions) + ["cut"])
        var transitions = (raw["transitions"] as? [String] ?? []).map {
            validTransitions.contains($0) ? $0 : "cut"
        }
        if transitions.count > needed { transitions = Array(transitions.prefix(needed)) }
        while transitions.count < needed { transitions.append("cut") }

        func cleanLine(_ value: Any?, maxWords: Int) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text.split(separator: " ").prefix(maxWords).joined(separator: " ")
        }
        return WizardPlan(targetDuration: (raw["target_duration"] as? NSNumber)?.doubleValue ?? 22,
                          rationale: raw["rationale"] as? String ?? "",
                          musicName: musicName,
                          musicVolume: musicVolume,
                          clips: clips,
                          transitions: transitions,
                          headline: cleanLine(raw["headline"], maxWords: 8),
                          introTitle: cleanLine(raw["intro_title"], maxWords: 7),
                          fileName: WizardPlan.slug(raw["file_name"] as? String))
    }

    // MARK: - Caption phase

    /// Flag emoji per caption language, for the channel's bilingual format.
    private static let languageFlags: [String: String] = [
        "en": "🇺🇸", "pt": "🇧🇷", "es": "🇪🇸", "fr": "🇫🇷", "de": "🇩🇪",
        "it": "🇮🇹", "ja": "🇯🇵", "ko": "🇰🇷", "ru": "🇷🇺", "ar": "🇸🇦",
    ]

    /// Fan-narrative lines for the caption prompt, from the saved fight
    /// research: the caption should ride the conversation fans are having.
    private func captionResearchLines(_ research: [FightResearchRecord]) -> String {
        let lines = research.compactMap { record -> String? in
            let summary = record.summary
            let story = summary["story"] as? [String: Any]
            let angle = story?["angle"] as? String ?? ""
            let sentiment = summary["sentiment"] as? String ?? ""
            guard !angle.isEmpty || !sentiment.isEmpty else { return nil }
            return "- Fan buzz on \(record.fightLabel): \(sentiment) Story angle: \(angle) — write the caption to join that conversation (paraphrase, no usernames)."
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private func captionPrompt(profile: BrandProfile, plan: WizardPlan,
                               duration: Double, tags: [String],
                               fightResearch: [FightResearchRecord] = [],
                               captionStyleReference: String? = nil,
                               benchmarks: AccountBenchmarks? = nil) -> String {
        let handle = profile.socials["instagram"]?.handle ?? ""
        let domain = profile.effectiveDomain
        let languages = profile.captionLanguages.isEmpty ? ["en"] : profile.captionLanguages
        let languageRule: String
        if languages.count > 1 {
            let spec = languages.map { code in
                "\(Self.languageFlags[code] ?? "") \(code)"
            }.joined(separator: ", then ")
            languageRule = "- Write the SAME caption in each of these languages, in this order: \(spec). Start each language block with its flag emoji, separate blocks with a blank line, and put the hashtags ONCE at the very end."
        } else {
            languageRule = "- Format: caption text first, then hashtags on a new line"
        }
        return """
        You are a social media expert for a \(domain) Instagram channel called \(profile.brandName) (\(handle)).

        Generate an Instagram Reel caption + hashtags for a video with these details:
        - Duration: \(String(format: "%.0f", duration))s
        - Creative strategy: \(plan.rationale)
        \(plan.headline.map { "- Result headline shown on the video: \($0) — the caption must tell this result accurately.\n" } ?? "")- Tags/content: \(tags.joined(separator: ", "))
        - Music: \(plan.musicName ?? "none")
        \(captionResearchLines(fightResearch))\(captionStyleReference.map { "- Caption style of the reel the user picked as reference — match its voice and structure: \($0)\n" } ?? "")\(benchmarks?.captionBlock() ?? "")
        Requirements:
        - Caption should be 1-3 punchy lines that drive engagement (likes, comments, saves, shares)
        - Include a hook or question to encourage comments
        - Add 5-10 relevant hashtags (mix of broad \(domain) hashtags + niche + trending); when measured hashtags are listed above, lead with the ones that fit this reel
        \(languageRule)
        - Keep it authentic to \(domain) culture
        - Do NOT use emojis excessively (max 2-3 per language block)

        Return ONLY the caption text + hashtags, nothing else.
        """
    }

    // MARK: - Run

    /// Full wizard run. Emits progress lines (same formats as wizard.py's
    /// SSE stream, ending with "DONE:ok"/"DONE:error").
    func run(options: WizardOptions,
             profile: BrandProfile,
             database: Database,
             emit: @escaping @Sendable (String) -> Void) async {
        do {
            try await runThrowing(options: options, profile: profile, database: database, emit: emit)
            emit("DONE:ok")
        } catch is CancellationError {
            emit("Cancelled.")
            emit("DONE:error")
        } catch {
            emit("Error: \(error.userMessage)")
            emit("DONE:error")
        }
    }

    /// Everything the user has taught the wizard, loaded once per run.
    struct TrainingSignals: Sendable {
        var lessons: [WizardLesson] = []
        var reviews: [ReviewSummary] = []
        var preferences: [PreferenceRecord] = []
        var feedback: [FeedbackRecord] = []
        var publishedPerformance: [GeneratedPerformanceRecord] = []
        /// Thumbs-up reels with their plan shapes — positive exemplars.
        var winners: [WinningRecipeRecord] = []
    }

    /// Everything the planning phase needs, loaded once per run.
    private struct PlanningInputs {
        var research: [String: Any]
        var scenes: [SceneRecord]
        var sceneMap: [Int64: SceneRecord]
        var music: [(name: String, url: URL)]
        var signals: TrainingSignals
        /// The People registry — so instructions can reference detected
        /// people by name.
        var people: [PersonRecord] = []
        /// Fight results the analyzer extracted, for headline composition.
        var outcomes: [FightOutcome] = []
        /// Saved fight research for the videos in play (empty = off/none).
        var fightResearch: [FightResearchRecord] = []
        /// Source-video types, so scene lines can say what footage they
        /// come from (fight vs training vs interview…).
        var videoTypes: [Int64: VideoType] = [:]
    }

    /// Rank the candidate pool (entertainment score, crowd excitement,
    /// highlight tags, and the user's grades/favorites/curation) and keep
    /// only enough footage to plan from — small pools pass through whole.
    /// Kept scenes return in stable source order; parents of kept sequence
    /// beats ride along so "(action within sequence #N)" notes stay valid.
    private func shortlistScenes(_ scenes: [SceneRecord], targetSeconds: Int?,
                                 emit: @escaping @Sendable (String) -> Void) -> [SceneRecord] {
        let minimumKept = 40
        guard scenes.count > minimumKept else { return scenes }
        // Enough footage for the model to choose freely: 6× the requested
        // duration, and never less than 3 minutes of source.
        let budget = max(Double((targetSeconds ?? 30) * 6), 180)

        func rank(_ scene: SceneRecord) -> Double {
            var rank = scene.score ?? scene.excitement.map { $0 * 10 } ?? -1
            if scene.tags.contains(where: { $0 == "highlight" || $0.hasPrefix("highlight:") }) { rank += 5 }
            if scene.favorite { rank += 4 }
            if scene.curated { rank += 2 }
            if let grade = scene.gradeAverage, scene.gradeCount > 0 { rank += grade - 3 }
            if scene.tags.contains("low-quality") { rank -= 4 }
            return rank
        }

        var kept: [SceneRecord] = []
        var keptIDs = Set<Int64>()
        var footage = 0.0
        for scene in scenes.sorted(by: { rank($0) > rank($1) }) {
            let mustKeep = scene.favorite || scene.curated
                || (scene.gradeCount > 0 && (scene.gradeAverage ?? 0) >= 4)
            guard footage < budget || kept.count < minimumKept || mustKeep else { continue }
            if keptIDs.insert(scene.id).inserted {
                kept.append(scene)
                footage += scene.duration
            }
        }
        // Sequence parents of kept beats stay resolvable.
        let byID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        for scene in kept {
            if let parentID = scene.parentSceneID, !keptIDs.contains(parentID),
               let parent = byID[parentID] {
                keptIDs.insert(parentID)
                kept.append(parent)
            }
        }
        guard kept.count < scenes.count else { return scenes }
        kept.sort {
            ($0.videoFilename, $0.startTime) < ($1.videoFilename, $1.startTime)
        }
        emit("Shortlisted \(kept.count) of \(scenes.count) scenes "
             + "(~\(Int(footage))s of top-ranked footage; favorites, curated, and top-graded scenes always kept)")
        return kept
    }

    private func loadTrainingSignals(database: Database) async -> TrainingSignals {
        TrainingSignals(lessons: (try? await database.fetchLessons()) ?? [],
                        reviews: (try? await database.fetchReviewSummaries(limit: 10)) ?? [],
                        preferences: (try? await database.fetchPreferences(limit: 10)) ?? [],
                        feedback: (try? await database.fetchAllFeedback()) ?? [],
                        publishedPerformance: (try? await database.recentGeneratedPerformance()) ?? [],
                        winners: (try? await database.fetchWinningRecipes()) ?? [])
    }

    private func loadPlanningInputs(options: WizardOptions,
                                    profile: BrandProfile,
                                    database: Database,
                                    emit: @escaping @Sendable (String) -> Void) async throws -> PlanningInputs {
        emit("Phase 1: Loading the MMA Reels playbook...")
        let research = Self.mmaPlaybook

        emit("Loading scenes and music...")
        let people = (try? await database.fetchPeople()) ?? []
        var scenes = try await database.fetchScenes(includeExcluded: false).filter { !$0.ignored }
        if options.curatedOnly {
            let before = scenes.count
            scenes = scenes.filter(\.curated)
            emit("Curated scenes only: \(scenes.count) of \(before) scene(s)")
        }
        if !options.selectedRunIDs.isEmpty {
            let before = scenes.count
            scenes = scenes.filter { scene in
                scene.runID.map { options.selectedRunIDs.contains($0) } ?? false
            }
            emit("Filtered to \(scenes.count) scenes from \(options.selectedRunIDs.count) selected analyze batch(es) (was \(before))")
        }
        if !options.sourcePeople.isEmpty {
            let before = scenes.count
            let requiredTags = Set(options.sourcePeople.map { "person:\($0)" })
            scenes = scenes.filter { scene in scene.tags.contains(where: requiredTags.contains) }
            let names = people.filter { options.sourcePeople.contains($0.key) }.map(\.displayName)
            emit("Filtered to \(scenes.count) scenes featuring \(names.isEmpty ? options.sourcePeople.joined(separator: ", ") : names.joined(separator: ", ")) (was \(before))")
        }
        guard !scenes.isEmpty else {
            throw AIError.notConfigured(options.sourcePeople.isEmpty
                ? "No analyzed scenes available. Analyze some videos first."
                : "No scenes feature the selected people within the current source selection.")
        }
        // The user's own downvotes are a hard signal: scenes graded ≤2/5
        // never reach the planner.
        let gradeFiltered = scenes.filter { scene in
            !(scene.gradeCount > 0 && (scene.gradeAverage ?? 5) <= 2)
        }
        if gradeFiltered.count < scenes.count, !gradeFiltered.isEmpty {
            emit("Dropped \(scenes.count - gradeFiltered.count) scene(s) the user graded ≤2/5")
            scenes = gradeFiltered
        }
        // Shortlist: rank by analyzed quality and user signals, cap the
        // candidate pool so the strong scenes aren't diluted by hundreds of
        // filler lines (and the prompt stays fast and cheap).
        scenes = shortlistScenes(scenes, targetSeconds: options.targetDurationSeconds, emit: emit)
        if options.templateJSON != nil {
            emit("Using reference template: \(options.templateLabel ?? "Instagram reel")")
        }
        let music = options.useMusic ? Self.availableMusic() : []
        if !options.useMusic { emit("No-music mode: original audio only.") }
        if options.muteSource { emit("Source audio will be muted (music only)") }
        if options.enableTextOverlays { emit("Text overlays enabled") }
        let signals = await loadTrainingSignals(database: database)
        let named = people.filter { !$0.name.isEmpty }
        if !named.isEmpty {
            emit("People available by name: \(named.map(\.name).joined(separator: ", "))")
        }
        emit("Found \(scenes.count) scenes, \(music.count) music tracks, "
             + "\(signals.lessons.count) lesson(s), \(signals.reviews.count) review(s), "
             + "\(signals.feedback.count) feedback entries")
        // Fight results scoped to the videos actually in play.
        let videoIDs = Set(scenes.map(\.videoID))
        let outcomes = ((try? await database.fetchOutcomes()) ?? [])
            .filter { videoIDs.contains($0.videoID) }
        if !outcomes.isEmpty {
            emit("Fight outcomes available for \(outcomes.count) video(s)")
        }
        var fightResearch: [FightResearchRecord] = []
        if options.useFightResearch {
            fightResearch = ((try? await database.fetchFightResearch()) ?? [])
                .filter { videoIDs.contains($0.videoID) }
            emit(fightResearch.isEmpty
                 ? "Fight research: none saved for the selected footage — run it from Analyze → Fight Research"
                 : "Fight research loaded for \(fightResearch.count) fight(s) — the plan follows the fan narrative")
        }
        var videoTypes: [Int64: VideoType] = [:]
        for video in (try? await database.fetchVideos()) ?? [] where videoIDs.contains(video.id) {
            if let type = video.type { videoTypes[video.id] = type }
        }
        return PlanningInputs(research: research, scenes: scenes,
                              sceneMap: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }),
                              music: music, signals: signals, people: people,
                              outcomes: outcomes, fightResearch: fightResearch,
                              videoTypes: videoTypes)
    }

    /// Visual definitions of "a keeper moment" for the planner: exemplar
    /// frames from the taste category steering this run (or a spread across
    /// categories), attached to the plan call for multimodal providers.
    private func tasteExemplarFrames(profile: BrandProfile, options: WizardOptions) -> [AIFrame] {
        var entries: [(path: String, label: String)] = []
        if let preset = options.tastePreset, preset.hasPrefix("cat:"),
           let category = profile.tasteCategories.first(where: { $0.key == String(preset.dropFirst(4)) }) {
            entries = category.exemplarFrames.suffix(4).map { ($0, "TASTE EXAMPLE (\(category.label))") }
        } else if options.tastePreset != "none" {
            entries = profile.tasteExemplarFrames.prefix(2).map { ($0, "TASTE EXAMPLE") }
            for category in profile.tasteCategories {
                entries += category.exemplarFrames.suffix(1)
                    .map { ($0, "TASTE EXAMPLE (\(category.label))") }
            }
        }
        var frames: [AIFrame] = []
        for (index, entry) in entries.prefix(4).enumerated() {
            let url = URL(fileURLWithPath: (entry.path as NSString).expandingTildeInPath)
            if let data = try? Data(contentsOf: url) {
                frames.append(AIFrame(jpeg: data,
                                      label: "\(entry.label) \(index + 1) — hooks and payoffs should look like this"))
            }
        }
        return frames
    }

    /// Deterministic template-adherence checks: planned footage duration and
    /// cut cadence against the reference reel. An explicit user duration
    /// outranks the template, so the duration check skips then.
    private func templateAdherenceFindings(_ plan: WizardPlan, options: WizardOptions) -> [String] {
        guard let template = options.templateJSON.flatMap({ AIResponseParser.jsonObject(from: $0) })
        else { return [] }
        var findings: [String] = []
        if options.targetDurationSeconds == nil,
           let duration = (template["duration"] as? NSNumber)?.doubleValue, duration > 3 {
            let screen = plan.clips.reduce(0.0) { $0 + ($1.end - $1.start) / max(0.1, $1.speed) }
            if abs(screen - duration) / duration > 0.25 {
                findings.append(String(format: "Planned footage runs %.1fs but the reference template runs %.1fs — match it within ~25%%.",
                                       screen, duration))
            }
        }
        if let cuts = (template["cut_count"] as? NSNumber)?.intValue, cuts > 1 {
            let ratio = Double(plan.clips.count) / Double(cuts)
            if ratio < 0.6 || ratio > 1.67 {
                findings.append("The plan has \(plan.clips.count) clips but the reference template cuts \(cuts) times — match its cut cadence.")
            }
        }
        return findings
    }

    /// One prompt → AI call → validated plan, then a deterministic quality
    /// check with at most ONE corrective re-plan (weak hook, low-quality or
    /// badly-fitting footage, template drift). Nil plan when the response is
    /// unusable. Prompt and raw response ride along for the run report.
    private func makePlan(inputs: PlanningInputs, options: WizardOptions, profile: BrandProfile,
                          critiqueFeedback: String? = nil,
                          emit: @escaping @Sendable (String) -> Void) async throws
        -> (plan: WizardPlan?, prompt: String, response: String) {
        var prompt = planPrompt(profile: profile, research: inputs.research, scenes: inputs.scenes,
                                musicNames: inputs.music.map(\.name), signals: inputs.signals,
                                people: inputs.people, outcomes: inputs.outcomes,
                                fightResearch: inputs.fightResearch,
                                videoTypes: inputs.videoTypes, options: options)
        // A critic reviewed the previous rendered version — its notes become
        // binding instructions for this plan.
        if let critiqueFeedback {
            prompt += critiqueFeedback
        }
        let frames = tasteExemplarFrames(profile: profile, options: options)
        if !frames.isEmpty {
            emit("Attached \(frames.count) taste exemplar frame(s) to the plan call")
        }

        func requestPlan(_ prompt: String) async throws -> (plan: WizardPlan?, response: String) {
            let reply = try await ai.call(prompt: prompt, task: "wizard",
                                          frames: frames.isEmpty ? nil : frames,
                                          model: options.modelOverride, timeout: 300, log: emit)
            let response = reply.text
            guard let rawPlan = AIResponseParser.jsonObject(from: response) else {
                emit("The planner's response was not valid JSON — raw response:")
                emit("──── response ────\n\(String(response.prefix(2000)))\n──── end response ────")
                return (nil, response)
            }
            var plan = validatePlan(rawPlan, scenes: inputs.sceneMap,
                                    musicNames: Set(inputs.music.map(\.name)), options: options)
                .map { enforcePinnedOverlays($0, options: options) }
            plan?.provenance = reply.provenance
            return (plan, response)
        }

        var (plan, response) = try await requestPlan(prompt)
        if plan == nil {
            emit("The planner returned JSON, but no usable clips survived validation — raw response:")
            emit("──── response ────\n\(String(response.prefix(2000)))\n──── end response ────")
            emit("This usually means the constraints can't be met by the available scenes — e.g. instructions that filter by tags none of the selected footage carries.")
        }

        // Pre-render quality gate: catch a weak plan BEFORE the render and
        // give the model one shot at fixing exactly what the gate flagged.
        if let validated = plan {
            let report = ReelQualityGate.evaluatePlan(validated, scenes: inputs.sceneMap,
                                                     options: options)
            var findings = report.failures + report.warnings
            let templateFindings = templateAdherenceFindings(validated, options: options)
            findings += templateFindings
            if report.verdict != .publishable || !templateFindings.isEmpty {
                emit("Plan quality check: \(report.summary) — asking the planner to fix:")
                findings.forEach { emit("  • \($0)") }
                let retryPrompt = prompt + """


                ## YOUR PREVIOUS PLAN FAILED THE QUALITY CHECK — FIX IT AND RE-PLAN
                Your previous plan (below) was rejected for these reasons:
                \(findings.map { "- \($0)" }.joined(separator: "\n"))
                Previous plan JSON:
                \(response.prefix(4000))

                Produce a corrected COMPLETE plan (same JSON schema as above) that fixes every finding — keep what already worked.
                """
                if let retry = try? await requestPlan(retryPrompt), let retryPlan = retry.plan {
                    let retryReport = ReelQualityGate.evaluatePlan(retryPlan, scenes: inputs.sceneMap,
                                                                  options: options)
                    let retryFindings = templateAdherenceFindings(retryPlan, options: options)
                    if retryReport.score + (retryFindings.isEmpty ? 0 : -10)
                        >= report.score + (templateFindings.isEmpty ? 0 : -10) {
                        emit("Re-plan accepted: \(retryReport.summary)")
                        plan = retryPlan
                        response = retry.response
                    } else {
                        emit("Re-plan scored worse (\(retryReport.summary)) — keeping the first plan")
                    }
                } else {
                    emit("Re-plan failed to produce a usable plan — keeping the first plan")
                }
            } else {
                emit("Plan quality check: \(report.summary)")
            }
        }

        if let validated = plan {
            plan = await snapCutsToBeats(validated, music: inputs.music,
                                         sceneMap: inputs.sceneMap, emit: emit)
        }
        return (plan, prompt, response)
    }

    /// Retime the plan's cut boundaries onto the music's detected onsets:
    /// each clip's end nudges (±0.35s) so the cut lands exactly on a beat —
    /// the thing that makes fast-paced edits feel professionally synced.
    /// Replay pairs keep their source range so the slow-motion echo matches
    /// the moment it replays.
    private func snapCutsToBeats(_ plan: WizardPlan, music: [(name: String, url: URL)],
                                 sceneMap: [Int64: SceneRecord],
                                 emit: @escaping @Sendable (String) -> Void) async -> WizardPlan {
        let settings = SettingsStore.loadSettings().transitions
        guard settings.beatSnap, plan.clips.count > 1,
              let name = plan.musicName,
              let track = music.first(where: { $0.name == name }) else { return plan }
        let beats = await BeatDetector.shared.onsets(in: track.url)
        guard beats.count >= 4 else {
            emit("Beat sync: no clear beats detected in \(name) — keeping planned cut times")
            return plan
        }

        var plan = plan
        var cursor = 0.0        // summed screen time of the clips so far
        var overlapSum = 0.0    // timeline seconds eaten by transition overlaps
        var snapped = 0
        let tolerance = 0.35
        for index in plan.clips.indices.dropLast() {
            let clip = plan.clips[index]
            cursor += (clip.end - clip.start) / clip.speed
            // Where this cut lands in the finished video.
            let boundary = cursor - overlapSum
            overlapSum += RenderEngine.consumedOverlap(plan.transitions[safe: index] ?? "cut",
                                                       xfadeDuration: settings.xfadeDuration)
            // The slowed echo of a replay pair must keep the source range.
            let next = plan.clips[index + 1]
            let isReplayPair = next.sceneID == clip.sceneID
                && abs(next.start - clip.start) < 0.01 && next.speed < 1
            guard !isReplayPair else { continue }

            guard let beat = beats.min(by: { abs($0 - boundary) < abs($1 - boundary) }),
                  abs(beat - boundary) <= tolerance, abs(beat - boundary) > 0.02 else { continue }
            let delta = beat - boundary
            let newEnd = clip.end + delta * clip.speed
            let sceneEnd = sceneMap[clip.sceneID]?.endTime ?? newEnd
            guard newEnd > clip.start + 0.8, newEnd <= sceneEnd else { continue }
            plan.clips[index].end = newEnd
            cursor += delta
            snapped += 1
        }
        if snapped > 0 {
            emit("Beat sync: snapped \(snapped)/\(plan.clips.count - 1) cut(s) onto \(name)'s beats")
        }
        return plan
    }

    /// The prompt asks for the user's pinned overlay choices; this guarantees
    /// them. The named template replaces whatever style the model picked, and
    /// the required text lands on the first overlay clip (or the first clip
    /// when the model planned no overlays at all).
    private func enforcePinnedOverlays(_ plan: WizardPlan, options: WizardOptions) -> WizardPlan {
        guard options.enableTextOverlays,
              options.pinnedOverlayTemplate != nil || options.pinnedOverlayText != nil,
              !plan.clips.isEmpty else { return plan }
        var plan = plan
        if let name = options.pinnedOverlayTemplate {
            for index in plan.clips.indices where plan.clips[index].textOverlay != nil {
                plan.clips[index].overlayStyle = name
            }
        }
        if let text = options.pinnedOverlayText {
            let index = plan.clips.firstIndex { $0.textOverlay != nil } ?? 0
            plan.clips[index].textOverlay = text
            if let name = options.pinnedOverlayTemplate {
                plan.clips[index].overlayStyle = name
            }
        }
        return plan
    }

    /// Plan-only entry for the Builder pre-fill path — research → AI plan →
    /// validation, no assembly, no captions.
    func plan(options: WizardOptions,
              profile: BrandProfile,
              database: Database,
              emit: @escaping @Sendable (String) -> Void) async throws
        -> (plan: WizardPlan, sceneMap: [Int64: SceneRecord]) {
        let inputs = try await loadPlanningInputs(options: options, profile: profile,
                                                  database: database, emit: emit)
        emit("\nPhase 2: Planning the timeline...")
        guard let plan = try await makePlan(inputs: inputs, options: options, profile: profile,
                                            emit: emit).plan else {
            throw AIError.unusableResponse("Reel planning failed: the AI did not produce a usable plan — its raw response is in the log above. If your instructions filter footage by tags, check that the selected footage actually carries those tags.")
        }
        emit("Plan: \(plan.clips.count) clips, ~\(Int(plan.targetDuration))s, music: \(plan.musicName ?? "none")")
        emit("Strategy: \(plan.rationale)")
        return (plan, inputs.sceneMap)
    }

    private func runThrowing(options: WizardOptions,
                             profile: BrandProfile,
                             database: Database,
                             emit rawEmit: @escaping @Sendable (String) -> Void) async throws {
        // Every log line is also recorded for the per-video run report.
        let recorder = LogRecorder()
        let emit: @Sendable (String) -> Void = { line in
            recorder.append(line)
            rawEmit(line)
        }
        let inputs = try await loadPlanningInputs(options: options, profile: profile,
                                                  database: database, emit: emit)
        let sceneMap = inputs.sceneMap

        // The critique loop: render, have the critic watch the result, and
        // when it recommends a retry re-plan with its notes — up to 3
        // versions total. Every version is kept with its review.
        let maxVersions = options.critiqueLoop ? 3 : 1
        var critiques: [ReelCritique] = []
        var critiqueFeedback: String?
        var producedCount = 0

        for attempt in 1...maxVersions {
            try Task.checkCancellation()
            if attempt > 1 {
                emit("\n══════ Version \(attempt) — rebuilding from the critique ══════")
            }
            emit("\nPhase 2: Planning the timeline...")
            let outcome = try await makePlan(inputs: inputs, options: options, profile: profile,
                                             critiqueFeedback: critiqueFeedback, emit: emit)
            guard let plan = outcome.plan else {
                if producedCount > 0 {
                    emit("Re-plan failed — keeping the \(producedCount) version(s) already rendered.")
                    break
                }
                throw AIError.unusableResponse("Reel planning failed: the AI did not produce a usable plan — its raw response is in the log above. If your instructions filter footage by tags, check that the selected footage actually carries those tags.")
            }
            emit("Plan: \(plan.clips.count) clips, ~\(Int(plan.targetDuration))s, music: \(plan.musicName ?? "none")")
            emit("Strategy: \(plan.rationale)")

            emit("\nPhase 3: Assembling the video...")
            let result: AssemblyResult
            do {
                result = try await assemble(plan: plan, music: inputs.music, options: options,
                                            profile: profile, database: database,
                                            sceneMap: sceneMap, emit: emit)
            } catch where producedCount > 0 && !(error is CancellationError) {
                // A later version failing to render shouldn't discard the
                // versions already produced.
                emit("Version \(attempt) failed to render (\(error.userMessage)) — keeping the earlier version(s).")
                break
            }

            emit("Generating Instagram caption...")
            let tagsUsed = Array(Set(plan.clips.flatMap { sceneMap[$0.sceneID]?.tags ?? [] })).sorted()
            // The reference reel's caption style rides into the caption call so
            // "replicate this reel" covers the caption too.
            let captionStyleReference = options.templateJSON
                .flatMap { AIResponseParser.jsonObject(from: $0) }
                .flatMap { $0["caption_style"] as? String }
            var captionText: String?
            do {
                let caption = try await ai.call(
                    prompt: captionPrompt(profile: profile, plan: plan,
                                          duration: result.duration, tags: tagsUsed,
                                          fightResearch: inputs.fightResearch,
                                          captionStyleReference: captionStyleReference,
                                          benchmarks: options.accountBenchmarks),
                    task: "captions", timeout: 60, log: emit)
                captionText = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
                try await database.updateGeneratedCaption(id: result.recordID,
                                                          caption: captionText ?? "",
                                                          provider: caption.provider,
                                                          model: caption.model)
                emit("Caption generated!")
            } catch {
                emit("Caption generation failed: \(error)")
            }

            // Everything a model needs to diagnose this reel, next to it.
            let planAttribution = (provider: plan.provenance?.provider ?? "unknown",
                                   model: plan.provenance?.model)
            writeRunReport(for: result, profile: profile,
                           options: options, inputs: inputs, plan: plan,
                           planPrompt: outcome.prompt, planResponse: outcome.response,
                           planAttribution: planAttribution, caption: captionText,
                           logLines: recorder.lines(), sceneMap: sceneMap,
                           emit: emit)

            emit("VIDEO:\(result.url.lastPathComponent):\(String(format: "%.1f", result.duration))")
            emit("Video complete! \(String(format: "%.1f", result.duration))s -> \(result.url.lastPathComponent)")
            producedCount += 1

            guard options.critiqueLoop else { break }
            emit("\nPhase 4: AI critique of version \(attempt)...")
            let critique: ReelCritique
            do {
                critique = try await ReelCritic.critique(video: result.url,
                                                         duration: result.duration,
                                                         plan: plan, sceneMap: sceneMap,
                                                         options: options, profile: profile,
                                                         attempt: attempt, previous: critiques,
                                                         ai: ai, emit: emit)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                emit("Critique failed (\(error.userMessage)) — keeping this version and stopping the loop.")
                break
            }
            if let json = (try? JSONEncoder().encode(critique))
                .flatMap({ String(data: $0, encoding: .utf8) }) {
                try? await database.updateGeneratedCritique(id: result.recordID, critiqueJSON: json)
            }
            emit("Critique: \(critique.score)/100 — \(critique.summary)")
            critique.issues.forEach { emit("  • issue: \($0)") }
            critiques.append(critique)

            if critique.regenerate, attempt < maxVersions {
                critique.notes.forEach { emit("  → note: \($0)") }
                emit("The critic requests another version — re-planning with its notes.")
                critiqueFeedback = Self.critiqueFeedbackBlock(critique, attempt: attempt,
                                                              previousPlanJSON: outcome.response)
            } else if critique.regenerate {
                emit("The critic would try again, but the \(maxVersions)-version cap is reached.")
                break
            } else {
                emit("The critic is satisfied — no further versions.")
                break
            }
        }

        emit("\nAll done! Generated \(producedCount) video\(producedCount == 1 ? "" : "s")")
    }

    /// The critic's review, phrased as binding instructions for the next
    /// plan attempt — appended to the standard planning prompt.
    private static func critiqueFeedbackBlock(_ critique: ReelCritique, attempt: Int,
                                              previousPlanJSON: String) -> String {
        var lines = ["\n\n## A CRITIC REVIEWED THE RENDERED VERSION \(attempt) — BUILD A BETTER ONE"]
        lines.append("It watched the actual rendered frames and scored the reel \(critique.score)/100: \(critique.summary)")
        if !critique.issues.isEmpty {
            lines.append("Issues visible in the rendered video:")
            lines.append(contentsOf: critique.issues.map { "- \($0)" })
        }
        if !critique.notes.isEmpty {
            lines.append("Apply every one of these improvement notes:")
            lines.append(contentsOf: critique.notes.map { "- \($0)" })
        }
        if !critique.strengths.isEmpty {
            lines.append("Keep what already worked:")
            lines.append(contentsOf: critique.strengths.map { "- \($0)" })
        }
        lines.append("Previous plan JSON (yours):")
        lines.append(String(previousPlanJSON.prefix(4000)))
        lines.append("Produce a NEW complete plan (same JSON schema as above) that fixes every issue — do not repeat the previous plan unchanged.")
        return lines.joined(separator: "\n")
    }

    /// Thread-safe accumulating log — the run's full emit stream, replayed
    /// into the run report.
    private final class LogRecorder: @unchecked Sendable {
        private var storage: [String] = []
        private let lock = NSLock()

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        func lines() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - Run report

    /// Markdown debug report saved next to the rendered video: profile,
    /// every option, the verbatim planning prompt and model response, the
    /// validated plan with per-clip source details, caption, and the log —
    /// made to be handed to an AI along with "here's what's wrong".
    private func writeRunReport(for result: AssemblyResult,
                                profile: BrandProfile, options: WizardOptions,
                                inputs: PlanningInputs, plan: WizardPlan,
                                planPrompt: String, planResponse: String,
                                planAttribution: (provider: String, model: String?),
                                caption: String?, logLines: [String],
                                sceneMap: [Int64: SceneRecord],
                                emit: @Sendable (String) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let formatter = ISO8601DateFormatter()

        func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

        var clipsTable = "| # | Scene | Source video | Range | Duration | Tags | Overlay |\n|---|---|---|---|---|---|---|\n"
        for (index, clip) in plan.clips.enumerated() {
            let scene = sceneMap[clip.sceneID]
            let overlay = clip.textOverlay.map { "\"\($0)\" (\(clip.overlayStyle ?? "default"), \(clip.overlayAnimation ?? "-"))" } ?? "—"
            clipsTable += "| \(index + 1) | #\(clip.sceneID) | \(scene?.videoFilename ?? "?") | "
                + String(format: "%.1f–%.1fs", clip.start, clip.end)
                + String(format: " | %.1fs | ", clip.end - clip.start)
                + (scene?.tags.prefix(6).joined(separator: ", ") ?? "?")
                + " | \(overlay) |\n"
        }

        let peopleLines = inputs.people.isEmpty ? "None detected yet." :
            inputs.people.map { "- \($0.displayName) (`\($0.tag)`): \($0.descriptor)" }.joined(separator: "\n")

        let report = """
        # Clip Builder — AI Wizard run report

        - **Video:** `\(result.url.lastPathComponent)` (\(String(format: "%.1f", result.duration))s final)
        - **Generated:** \(formatter.string(from: Date())) · Clip Builder \(version) (build \(build))
        - **Profile:** \(profile.profileName) · brand "\(profile.brandName)" · domain "\(profile.effectiveDomain)"
        - **Planning model:** \(planAttribution.provider) / \(planAttribution.model ?? "default")

        ## Issue description

        _Describe what is wrong with this reel here, then hand this whole file to an AI assistant working on the app._

        ## Options

        - Music: \(yesNo(options.useMusic)), mute source: \(yesNo(options.muteSource))
        - Captions: \(yesNo(options.addCaptions)), text overlays: \(yesNo(options.enableTextOverlays))
        - Wide footage: saved scene framing when available; automatic portrait crop otherwise
        - Target duration: \(options.targetDurationSeconds.map { "\($0)s" } ?? "model's choice")
        - Pinned overlay: \(options.pinnedOverlayTemplate ?? "none")\(options.pinnedOverlayText.map { ", text \"\($0)\"" } ?? "")
        - Analyze-batch filter: \(options.selectedRunIDs.isEmpty ? "all batches" : options.selectedRunIDs.sorted().map(String.init).joined(separator: ", "))
        - People filter: \(options.sourcePeople.isEmpty ? "everyone" : options.sourcePeople.joined(separator: ", "))
        - Reference template: \(options.templateLabel ?? "none")
        - Format preset: \(options.formatPreset) · watermark: \(yesNo(options.includeWatermark)), headline: \(yesNo(options.includeHeadline)), outro: \(yesNo(options.includeOutro))
        - AI instructions: \(options.aiInstructions.isEmpty ? "none" : options.aiInstructions)

        ## People registry at run time

        \(peopleLines)

        ## Validated plan

        - Target duration: \(String(format: "%.1f", plan.targetDuration))s planned, \(String(format: "%.1f", result.duration))s rendered
        - Music: \(plan.musicName ?? "none") (volume \(plan.musicVolume))
        - Transitions: \(plan.transitions.joined(separator: ", "))
        - Headline: \(plan.headline ?? "none") · Intro title: \(plan.introTitle ?? "none")
        - Rationale: \(plan.rationale)

        \(clipsTable)
        ## Caption

        \(caption ?? "_caption generation failed_")

        ## Planning prompt (verbatim)

        ~~~~
        \(planPrompt)
        ~~~~

        ## Model response (verbatim)

        ~~~~
        \(planResponse)
        ~~~~

        ## Run log for this video

        ~~~~
        \(logLines.joined(separator: "\n"))
        ~~~~
        """

        let reportURL = result.url.deletingPathExtension().appendingPathExtension("md")
        do {
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
            emit("Run report saved: \(reportURL.lastPathComponent)")
        } catch {
            emit("Could not save the run report: \(error)")
        }
    }

    // MARK: - House style distillation

    /// Distill a house style from EVERY cached reel template analysis,
    /// weighted by each reel's performance stats — the always-on aggregate
    /// the plan prompt injects on every run (a picked reference template
    /// still outranks it). Merge semantics: patterns the new pass still
    /// supports survive, new ones join, contradictions resolve toward the
    /// better-performing reels.
    func distillHouseStyle(database: Database, existing: String,
                           emit: @escaping @Sendable (String) -> Void) async throws -> AIOutcome<String> {
        let templates = try await database.fetchAllIGTemplates()
        guard !templates.isEmpty else {
            throw AIError.notConfigured("No analyzed reels yet — analyze some Instagram reels first (Instagram → open a reel → Analyze Reel), then distill.")
        }
        emit("Distilling house style from \(templates.count) analyzed reel(s)...")
        let entries = templates.prefix(30).map { entry -> String in
            var block = entry.templateJSON
            if let statsJSON = entry.statsJSON, let data = statsJSON.data(using: .utf8),
               let stats = try? JSONDecoder().decode(IGStats.self, from: data) {
                block += "\nPERFORMANCE: \(ReelPerformance.label(stats, duration: 0))"
            }
            return block
        }.joined(separator: "\n\n---\n\n")
        let existingBlock = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : """

            ## CURRENT HOUSE STYLE (merge: keep rules the reels still support, sharpen wording, add what they newly teach, drop only on contradiction)
            \(existing)
            """
        let prompt = """
        You are distilling a combat-sports Instagram channel's HOUSE STYLE from structural analyses of the reels its editor studies. Each block below is one analyzed reel (JSON) — reels with a PERFORMANCE line performed measurably; weight their patterns more heavily.

        ## ANALYZED REELS
        \(entries)
        \(existingBlock)
        Produce the house style as plain text with EXACTLY these five sections, each a header line followed by 2-4 "- " bullets of concrete, checkable rules (no vague advice):
        HOOK: (typical hook types and first-2-second choices)
        DURATION & PACING: (duration band, cuts/min, cut rhythm)
        STRUCTURE: (typical phase arc)
        TEXT & OVERLAYS: (usage, style, casing, placement)
        MUSIC & AUDIO: (music role vs source audio)

        Return ONLY that text — no preamble, no markdown fences, no JSON.
        """
        let response = try await ai.call(prompt: prompt, task: "distill", timeout: 180, log: emit)
        let style = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty else { throw AIError.emptyResponse("house style distillation") }
        return AIOutcome(value: style, provenance: response.provenance)
    }

    // MARK: - Lessons distillation

    /// Compress everything the user has said about past generations into at
    /// most 10 imperative style rules, replacing the previous machine-learned
    /// set (pinned rules are user-owned and untouched). Returns the new count.
    func distillLessons(database: Database, emit: @escaping @Sendable (String) -> Void) async throws -> Int {
        // Wider windows than a generation prompt: distillation is rare and
        // benefits from the full history.
        let reviews = (try? await database.fetchReviewSummaries(limit: 50)) ?? []
        let preferences = (try? await database.fetchPreferences(limit: 50)) ?? []
        let feedback = (try? await database.fetchAllFeedback()) ?? []
        let lessons = (try? await database.fetchLessons()) ?? []
        guard !reviews.isEmpty || !preferences.isEmpty || !feedback.isEmpty else {
            throw AIError.notConfigured("Nothing to distill yet — review a few generated videos first.")
        }

        emit("Distilling lessons from \(reviews.count) review(s), \(preferences.count) A/B choice(s), "
             + "\(feedback.count) feedback note(s)...")
        let current = lessons.filter { !$0.pinned }
        let pinned = lessons.filter(\.pinned)
        let prompt = """
        You are distilling a user's reactions to AI-generated Instagram reels into a compact set of editing rules ("lessons") that all future generations must follow.

        ## Structured Reviews (newest first; verdict per video, per aspect, per clip)
        \(reviews.isEmpty ? "None." : reviews.map(reviewLines).joined(separator: "\n"))

        ## A/B Choices (the user picked one variation over another)
        \(preferences.isEmpty ? "None." : preferences.map { "- CHOSE \"\($0.chosenRationale)\" OVER \"\($0.rejectedRationale)\"" }.joined(separator: "\n"))

        ## Free-Text Feedback (newest first)
        \(feedback.isEmpty ? "None." : feedback.map { "- \"\($0.feedback)\"" }.joined(separator: "\n"))

        ## Current Lessons (your previous output — carry over the ones still supported)
        \(current.isEmpty ? "None." : current.map { "- \($0.text)" }.joined(separator: "\n"))

        ## Pinned Rules (user-authored — do NOT duplicate or contradict these)
        \(pinned.isEmpty ? "None." : pinned.map { "- \($0.text)" }.joined(separator: "\n"))

        Instructions:
        - Produce AT MOST 10 lessons. Each is ONE imperative sentence a video editor can act on (e.g. "Open with the single most explosive moment, never a wide establishing shot").
        - Only state lessons the signals support; prefer patterns that recur. A one-off complaint becomes a lesson only when emphatic.
        - Newer signals outrank older ones when they conflict.
        - "evidence" is a terse justification, e.g. "flagged in 3 reviews" or "won 2 A/B picks".

        Return ONLY JSON: {"lessons": [{"text": "...", "evidence": "..."}]}
        """

        let response = try await ai.call(prompt: prompt, task: "distill", timeout: 180, log: emit)
        guard let object = AIResponseParser.jsonObject(from: response.text),
              let rawLessons = object["lessons"] as? [[String: Any]] else {
            throw AIError.emptyResponse("lesson distillation (unparseable JSON)")
        }
        let distilled = rawLessons.prefix(10).compactMap { raw -> (text: String, evidence: String)? in
            guard let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return (text, (raw["evidence"] as? String) ?? "")
        }
        try await database.replaceLearnedLessons(distilled, provenance: response.provenance)
        return distilled.count
    }

    // MARK: - Builder pre-fill

    /// Map a validated plan onto a Builder timeline document: sequential clips
    /// on track 0 with planner transitions as transIn, music spanning the
    /// whole timeline, per-clip text overlays. No rendering — the user edits
    /// from here. (Auto-crop covers wide scenes.)
    nonisolated static func timelineDocument(from plan: WizardPlan,
                                             sceneMap: [Int64: SceneRecord]) -> TimelineDocument {
        var document = TimelineDocument()
        var cursor = 0.0
        for clip in plan.clips {
            guard let scene = sceneMap[clip.sceneID] else { continue }
            // Screen time — slow motion stretches it beyond the source span.
            let duration = ((clip.end - clip.start) / clip.speed * 10).rounded() / 10
            guard duration > 0 else { continue }

            var timelineClip = TimelineClip()
            timelineClip.sceneID = clip.sceneID
            timelineClip.videoFile = scene.videoPath
            timelineClip.sourceStart = clip.start
            timelineClip.sourceEnd = clip.end
            timelineClip.startTime = cursor
            timelineClip.duration = duration
            timelineClip.speed = clip.speed == 1 ? nil : clip.speed
            timelineClip.sceneFullDuration = (scene.duration * 10).rounded() / 10
            timelineClip.wide = scene.wide
            timelineClip.cropXFrac = scene.cropXFrac
            timelineClip.screenCrop = clip.screenCrop
            let index = document.videoTrack.filter { $0.track == 0 }.count
            if index > 0 {
                let name = plan.transitions[safe: index - 1] ?? "cut"
                timelineClip.transIn = name == "cut" ? nil : name
            }
            document.videoTrack.append(timelineClip)
            // A layout block's other areas become muted clips on their own
            // (free-form) tracks, stacked over the same slot.
            if let layoutName = clip.layout {
                for (slot, areaClip) in clip.areaClips.enumerated() {
                    guard let areaScene = sceneMap[areaClip.sceneID] else { continue }
                    let track = min(TimelineDocument.maxTracks - 1, slot + 1)
                    var extra = TimelineClip()
                    extra.sceneID = areaClip.sceneID
                    extra.videoFile = areaScene.videoPath
                    extra.sourceStart = areaClip.start
                    extra.sourceEnd = areaClip.end
                    extra.startTime = cursor
                    extra.duration = duration
                    extra.speed = timelineClip.speed
                    extra.sceneFullDuration = (areaScene.duration * 10).rounded() / 10
                    extra.wide = areaScene.wide
                    extra.cropXFrac = areaScene.cropXFrac
                    extra.track = track
                    extra.muted = true
                    extra.screenCrop = ScreenCropStore.reference(layout: layoutName, area: areaClip.area)
                    document.videoTrack.append(extra)
                    document.trackCount = max(document.trackCount, track + 1)
                    document.trackSequential[track] = false
                }
            }

            if let text = clip.textOverlay, !text.isEmpty {
                let (composition, isTemplate) = wizardPlanOverlay(for: clip, text: text)
                if isTemplate {
                    // A template overlay lands in the Builder as one block —
                    // the same unit the Builder's Overlay menu inserts.
                    var block = OverlayBlockItem()
                    block.name = clip.overlayStyle ?? "Overlay"
                    block.composition = composition
                    block.startTime = cursor
                    block.duration = duration
                    document.overlayBlocks.append(block)
                } else if var overlay = composition.texts.first {
                    overlay.startTime = cursor
                    overlay.endTime = cursor + duration
                    // Builder's renderer has no word_reveal; degrade to fade.
                    let animation = clip.overlayAnimation ?? "fade"
                    overlay.transIn = animation == "word_reveal" ? "fade" : animation
                    overlay.transOut = "fade"
                    document.textOverlays.append(overlay)
                }
            }
            cursor += duration
        }
        if let musicName = plan.musicName, cursor > 0 {
            var sound = SoundItem()
            sound.name = musicName
            sound.volume = min(5, max(1, plan.musicVolume))
            sound.startTime = 0
            sound.duration = (cursor * 10).rounded() / 10
            document.soundTrack.append(sound)
        }
        return document
    }

    /// Best-effort Builder document from the legacy flat timeline JSON
    /// (`[{type: music|transition|clip}, ...]`) that wizard renders stored
    /// before documents were persisted. Clips, order, transitions, and music
    /// survive; burned-in overlays and captions were never recorded and
    /// can't be recovered.
    nonisolated static func legacyTimelineDocument(fromFlat json: String,
                                                   scenes: [Int64: SceneRecord]) -> TimelineDocument? {
        guard let data = json.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var document = TimelineDocument()
        var cursor = 0.0
        var pendingTransition: String?
        var music: (name: String, volume: Int)?
        for entry in entries {
            switch entry["type"] as? String {
            case "music":
                if let name = entry["name"] as? String, !name.isEmpty {
                    music = (name, (entry["volume"] as? NSNumber)?.intValue ?? 3)
                }
            case "transition":
                pendingTransition = entry["name"] as? String
            case "clip":
                guard let start = (entry["start"] as? NSNumber)?.doubleValue,
                      let end = (entry["end"] as? NSNumber)?.doubleValue, end > start else { continue }
                var clip = TimelineClip()
                clip.sceneID = (entry["id"] as? NSNumber)?.int64Value
                clip.videoFile = entry["video_file"] as? String
                clip.sourceStart = start
                clip.sourceEnd = end
                clip.startTime = cursor
                clip.duration = ((end - start) * 10).rounded() / 10
                if let sceneID = clip.sceneID, let scene = scenes[sceneID] {
                    clip.sceneFullDuration = (scene.duration * 10).rounded() / 10
                    clip.wide = scene.wide
                    clip.cropXFrac = scene.cropXFrac
                    if clip.videoFile?.isEmpty != false { clip.videoFile = scene.videoPath }
                }
                if !document.videoTrack.isEmpty {
                    clip.transIn = pendingTransition ?? "fade"
                }
                pendingTransition = nil
                document.videoTrack.append(clip)
                cursor += clip.duration
            default:
                continue
            }
        }
        guard !document.videoTrack.isEmpty else { return nil }
        if let music, cursor > 0 {
            var sound = SoundItem()
            sound.name = music.name
            sound.volume = min(5, max(1, music.volume))
            sound.startTime = 0
            sound.duration = (cursor * 10).rounded() / 10
            document.soundTrack.append(sound)
        }
        return document
    }

    // MARK: - Assembly

    private struct AssemblyResult {
        var url: URL
        var duration: Double
        var recordID: Int64
    }

    private func assemble(plan: WizardPlan,
                          music: [(name: String, url: URL)],
                          options: WizardOptions,
                          profile: BrandProfile,
                          database: Database,
                          sceneMap: [Int64: SceneRecord],
                          emit: @escaping @Sendable (String) -> Void) async throws -> AssemblyResult {
        let scratch = try await render.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        var clipURLs: [URL] = []
        var clipTransitions: [String] = []

        // Brand-kit layers burned onto EVERY clip: the corner watermark and
        // the full-video result headline. Rendered once, reused per clip.
        let accent = profile.accentColor.isEmpty ? BrandRenderer.defaultAccent : profile.accentColor
        var brandOverlays: [URL] = []
        if options.includeWatermark, let logoURL = profile.logoURL,
           let png = BrandRenderer.watermark(logoURL: logoURL, to: scratch) {
            brandOverlays.append(png)
        }
        if options.includeHeadline, let headline = plan.headline,
           let png = BrandRenderer.headline(headline, brandName: profile.brandName,
                                            accent: accent, to: scratch) {
            brandOverlays.append(png)
            emit("Headline: \(headline)")
        }

        // Extract every planned clip concurrently — captions, text overlay
        // and mute are burned in ONE encode pass per clip (they used to be
        // up to three extra full re-encodes each).
        let jobs: [(index: Int, clip: WizardPlanClip, scene: SceneRecord)] =
            plan.clips.enumerated().compactMap { index, clip in
                sceneMap[clip.sceneID].map { (index, clip, $0) }
            }
        let clipCount = plan.clips.count
        let captionStyle = profile.captions
        let extracted = try await BoundedConcurrency.map(jobs, limit: FFmpeg.jobLimit) { _, job in
            try await self.extractPlannedClip(job.clip, index: job.index, of: clipCount,
                                              scene: job.scene, sceneMap: sceneMap, options: options,
                                              captionStyle: captionStyle,
                                              brandOverlays: brandOverlays,
                                              database: database, scratch: scratch,
                                              emit: emit)
        }

        for url in extracted {
            if clipURLs.count > clipTransitions.count && !clipURLs.isEmpty {
                // Boundary after a previous clip: planner transition if
                // available, else hard fade.
                clipTransitions.append(plan.transitions[safe: clipURLs.count - 1] ?? "fade")
            }
            clipURLs.append(url)
        }

        guard !clipURLs.isEmpty else {
            throw AIError.notConfigured("No clips could be extracted for this plan")
        }

        // Brand cards: typographic intro for compilations, branded outro for
        // everything (given brand assets to draw with).
        if options.formatPreset == "compilation", let title = plan.introTitle,
           let png = BrandRenderer.titleCard(title, brandName: profile.brandName, accent: accent,
                                             logoURL: profile.logoURL, to: scratch) {
            let card = scratch.appendingPathComponent("intro_card.mp4")
            try await BrandRenderer.cardClip(png: png, duration: 2.0, output: card)
            clipURLs.insert(card, at: 0)
            clipTransitions.insert("fade", at: 0)
            emit("Intro card: \(title)")
        }
        if options.includeOutro,
           profile.logoURL != nil || !(profile.socials["instagram"]?.handle ?? "").isEmpty,
           let png = BrandRenderer.outroCard(profile: profile, to: scratch) {
            let card = scratch.appendingPathComponent("outro_card.mp4")
            try await BrandRenderer.cardClip(png: png, duration: 2.5, output: card)
            clipTransitions.append("fadeblack")
            clipURLs.append(card)
            emit("Branded outro card appended")
        }

        emit("Assembling \(clipURLs.count) segments...")
        let assembled = scratch.appendingPathComponent("assembled.mp4")
        try await render.concatenate(clips: clipURLs, transitions: clipTransitions.map { Optional($0) },
                                     output: assembled)

        let outputURL = try outputFile(profile: profile, plan: plan)
        if let musicName = plan.musicName,
           let track = music.first(where: { $0.name == musicName }) {
            emit("Adding music (\(musicName))...")
            try await render.overlayMusic(video: assembled, music: track.url, output: outputURL)
        } else {
            try FileManager.default.copyItemReplacing(at: assembled, to: outputURL)
        }

        let finalDuration = await FFmpeg.duration(of: outputURL)
        let quality = ReelQualityGate.evaluate(plan: plan, scenes: sceneMap, output: outputURL,
                                               duration: finalDuration, options: options)
        emit("Quality gate: \(quality.summary)")
        for warning in quality.warnings { emit("Quality warning: \(warning)") }
        for failure in quality.failures { emit("Quality failure: \(failure)") }

        // Persist the Builder-editable document for this render — clips with
        // their source ranges and transitions, overlay items with timing,
        // and the music block — so "Open in Builder" can load any wizard
        // video for editing. (Replaces the legacy flat Python format.)
        var editPlan = plan
        if !options.enableTextOverlays {
            // A stray overlay the model emitted anyway wasn't burned in;
            // keep the document faithful to the rendered video.
            for index in editPlan.clips.indices { editPlan.clips[index].textOverlay = nil }
        }
        let document = Self.timelineDocument(from: editPlan, sceneMap: sceneMap)
        let timelineJSON = (try? JSONEncoder().encode(document))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        // The planner that actually answered — not a prediction of the
        // dispatcher's first choice.
        let attribution = (provider: plan.provenance?.provider, model: plan.provenance?.model)
        let qualityJSON = (try? JSONEncoder().encode(quality))
            .flatMap { String(data: $0, encoding: .utf8) }
        // The plan's clips with the model's per-clip reasons: reviews show
        // them, and review signals quote them back ("planner's intent was…").
        let planClips: [[String: Any]] = plan.clips.enumerated().map { index, clip in
            var entry: [String: Any] = ["clip_index": index,
                                        "scene_id": clip.sceneID,
                                        "start": clip.start.rounded(toPlaces: 2),
                                        "end": clip.end.rounded(toPlaces: 2),
                                        "speed": clip.speed]
            if let reason = clip.reason { entry["reason"] = reason }
            return entry
        }
        let planClipsJSON = (try? JSONSerialization.data(withJSONObject: planClips))
            .flatMap { String(data: $0, encoding: .utf8) }
        let recordID = try await database.insertGeneratedVideo(path: outputURL.path,
                                                               duration: finalDuration.rounded(toPlaces: 1),
                                                               timelineJSON: timelineJSON,
                                                               wizardProvider: attribution.provider,
                                                               wizardModel: attribution.model,
                                                               rationale: plan.rationale,
                                                               qualityJSON: qualityJSON,
                                                               planClipsJSON: planClipsJSON)
        return AssemblyResult(url: outputURL, duration: finalDuration, recordID: recordID)
    }

    /// One planned clip → one normalized file in a single decode→encode pass:
    /// wide handling, caption overlays, text overlay and mute all ride the
    /// same ffmpeg filter graph.
    /// Identity references for the tracking camera: the source video's
    /// named person markers (focus) and ignored ones (avoid).
    private func markerPortraits(scene: SceneRecord, database: Database) async -> (focus: [Data], avoid: [Data]) {
        let allMarkers = (try? await database.personMarkers(videoID: scene.videoID)) ?? []
        let named = allMarkers.filter { $0.personID != nil && !$0.ignored }
        let ignored = allMarkers.filter(\.ignored)
        let focus = named.isEmpty ? []
            : await Analyzer.markerPortraits(url: scene.videoURL, markers: named, duration: scene.videoDuration)
        let avoid = ignored.isEmpty ? []
            : await Analyzer.markerPortraits(url: scene.videoURL, markers: ignored, duration: scene.videoDuration)
        return (focus, avoid)
    }

    private func extractPlannedClip(_ clip: WizardPlanClip, index: Int, of total: Int,
                                    scene: SceneRecord, sceneMap: [Int64: SceneRecord] = [:],
                                    options: WizardOptions,
                                    captionStyle: CaptionStyle,
                                    brandOverlays: [URL] = [],
                                    database: Database, scratch: URL,
                                    emit: @escaping @Sendable (String) -> Void) async throws -> URL {
        // Source seconds consumed vs seconds on screen — slow motion
        // stretches the latter. Everything time-positioned in the OUTPUT
        // (overlays, captions, -t) uses `duration`; everything reading the
        // SOURCE (content box, Center Stage, hints) uses `sourceDuration`.
        let sourceDuration = clip.end - clip.start
        let duration = sourceDuration / clip.speed
        // Screen crop: the named area's mask rides into every render path.
        let mask = ScreenCropStore.maskFile(reference: clip.screenCrop, in: scratch)
        if clip.screenCrop != nil, mask == nil {
            emit("Clip \(index + 1): screen crop \"\(clip.screenCrop ?? "")\" not found — rendering unmasked")
        }
        // Screen recordings and reposts bake black bars into the pixels, so
        // the file's aspect lies about the footage. Crop to the detected
        // content box and treat the CONTENT's aspect as the wide signal —
        // otherwise a landscape fight inside a portrait recording letterboxes
        // no matter what the user asks for.
        let contentBox = await render.detectContentBox(source: scene.videoURL,
                                                       start: clip.start, duration: sourceDuration)
        let contentIsWide = contentBox?.isWide ?? scene.wide
        let usesSavedFraming = contentIsWide && scene.centerStagePath != nil
        var mode = usesSavedFraming ? "saved framing" : (contentIsWide ? "auto-crop" : "")
        if contentBox != nil { mode = mode.isEmpty ? "bars removed" : mode + ", bars removed" }
        emit("Extracting clip \(index + 1)/\(total) " +
             String(format: "[%.1fs +%.1fs]", clip.start, duration) +
             " from \(scene.videoFilename)\(mode.isEmpty ? "" : " (\(mode))")")

        // Brand layers (watermark, headline) ride every clip start-to-end.
        var overlays: [RenderEngine.ClipOverlay] = brandOverlays.map {
            RenderEngine.ClipOverlay(png: $0, x: 0, y: 0, start: 0, end: duration)
        }
        if options.addCaptions {
            // Transcript times are in source-video time; shift into clip time.
            let renderer = CaptionRenderer(videoWidth: RenderEngine.outputWidth,
                                           videoHeight: RenderEngine.outputHeight,
                                           style: captionStyle)
            let sourceSegments = (try? await database.transcriptSegments(
                videoID: scene.videoID, start: clip.start, end: clip.end)) ?? []
            for segment in sourceSegments {
                let start = max(0, segment.start - clip.start)
                let end = min(duration, segment.end - clip.start)
                guard end > start + 0.1 else { continue }
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard let rendered = try? renderer.render(text: text, to: scratch) else { continue }
                let (x, y) = renderer.position(for: rendered)
                overlays.append(RenderEngine.ClipOverlay(png: rendered.pngURL, x: x, y: y,
                                                         start: start, end: end))
            }
        }
        if let overlayText = clip.textOverlay, options.enableTextOverlays {
            // Punchy text overlay — styled preset or user template
            // composition (full-frame PNGs, so x/y are 0).
            let (composition, isTemplate) = wizardPlanOverlay(for: clip, text: overlayText)
            let renderer = TextOverlayRenderer(videoWidth: RenderEngine.outputWidth,
                                               videoHeight: RenderEngine.outputHeight)
            if isTemplate {
                // Template items keep their own windows within the clip;
                // enable windows can't animate here, so they hard-cut.
                let imageRenderer = ImageOverlayRenderer(videoWidth: RenderEngine.outputWidth,
                                                         videoHeight: RenderEngine.outputHeight)
                for item in composition.images {
                    let end = item.unbounded ? duration : min(item.endTime, duration)
                    guard end > item.startTime,
                          let png = try? imageRenderer.render(item, to: scratch) else { continue }
                    overlays.append(RenderEngine.ClipOverlay(png: png, x: 0, y: 0,
                                                             start: item.startTime, end: end))
                }
                for item in composition.texts {
                    let end = item.unbounded ? duration : min(item.endTime, duration)
                    guard end > item.startTime,
                          let png = try? renderer.render(item, to: scratch) else { continue }
                    // A single full-length item can use the animated path.
                    if item.startTime == 0, end >= duration - 0.05 {
                        let animation = ["fade", "pop", "slide_up"].contains(item.transIn)
                            ? item.transIn : "fade"
                        overlays.append(RenderEngine.ClipOverlay(png: png, x: 0, y: 0,
                                                                 start: nil, end: nil,
                                                                 animation: animation))
                    } else {
                        overlays.append(RenderEngine.ClipOverlay(png: png, x: 0, y: 0,
                                                                 start: item.startTime, end: end))
                    }
                }
            } else if let item = composition.texts.first {
                let animation = clip.overlayAnimation ?? "fade"
                let wordCount = TextOverlayRenderer.wordCount(item.text)
                if animation == "word_reveal", wordCount > 1 {
                    // One progressive PNG per word, hard-cut on staggered
                    // windows; the full-text PNG holds from the last reveal
                    // to the end.
                    let step = min(0.3, max(0.1, duration / 3 / Double(wordCount)))
                    for wordIndex in 1...wordCount {
                        guard let png = try? renderer.render(item, to: scratch,
                                                             visibleWords: wordIndex) else { continue }
                        overlays.append(RenderEngine.ClipOverlay(
                            png: png, x: 0, y: 0,
                            start: Double(wordIndex - 1) * step,
                            end: wordIndex == wordCount ? duration : Double(wordIndex) * step))
                    }
                } else if let png = try? renderer.render(item, to: scratch) {
                    overlays.append(RenderEngine.ClipOverlay(
                        png: png, x: 0, y: 0, start: nil, end: nil,
                        animation: animation == "word_reveal" ? "fade" : animation))
                }
            }
        }

        let output = scratch.appendingPathComponent("clip_\(index).mp4")
        // Screen crop: the footage is framed INTO the area (tracking camera
        // at the area's aspect) so the people fill it, then masked. A
        // layout block also frames every other area's scene and stacks
        // them all into one composite clip.
        if let area = ScreenCropStore.area(reference: clip.screenCrop) {
            let portraits = await markerPortraits(scene: scene, database: database)
            let tuning = CenterStageService.Tuning.named(options.framingCamera)
            let framed = try await AreaFramer.frame(source: scene.videoURL, start: clip.start,
                                                    duration: sourceDuration, area: area,
                                                    focusPortraits: portraits.focus,
                                                    avoidPortraits: portraits.avoid,
                                                    tuning: tuning, centerStage: centerStage,
                                                    scratch: scratch, log: emit)
            if let layoutName = clip.layout, let layout = ScreenCropStore.layout(named: layoutName),
               !clip.areaClips.isEmpty, let mask {
                let main = scratch.appendingPathComponent("clip_\(index)_main.mp4")
                try await render.extractClip(source: framed, start: 0, duration: duration,
                                             overlays: overlays, mute: options.muteSource,
                                             speed: clip.speed, output: main)
                var entries: [(clip: URL, mask: URL)] = [(main, mask)]
                for (areaIndex, areaClip) in clip.areaClips.enumerated() {
                    guard let areaScene = sceneMap[areaClip.sceneID],
                          let areaDef = layout.areas.first(where: { $0.name == areaClip.area }),
                          let areaMask = ScreenCropStore.maskFile(
                              reference: ScreenCropStore.reference(layout: layout.name, area: areaDef.name),
                              in: scratch) else { continue }
                    let areaPortraits = await markerPortraits(scene: areaScene, database: database)
                    let areaSourceDuration = min(areaClip.end - areaClip.start, sourceDuration)
                    let areaFramed = try await AreaFramer.frame(
                        source: areaScene.videoURL, start: areaClip.start,
                        duration: areaSourceDuration, area: areaDef,
                        focusPortraits: areaPortraits.focus, avoidPortraits: areaPortraits.avoid,
                        tuning: tuning, centerStage: centerStage, scratch: scratch, log: emit)
                    let areaOutput = scratch.appendingPathComponent("clip_\(index)_area\(areaIndex).mp4")
                    try await render.extractClip(source: areaFramed, start: 0,
                                                 duration: areaSourceDuration / clip.speed,
                                                 mute: true, speed: clip.speed, output: areaOutput)
                    entries.append((areaOutput, areaMask))
                }
                try await render.compositeAreas(entries, duration: duration, output: output)
                emit("Clip \(index + 1): layout \"\(layout.name)\" — \(entries.count) scene(s) on screen")
                return output
            }
            try await render.extractClip(source: framed, start: 0, duration: duration,
                                         overlays: overlays, mute: options.muteSource,
                                         speed: clip.speed, mask: mask, output: output)
            return output
        }
        // Framing belongs to the scene, not to this run. Replay the saved
        // camera path exactly as it was reviewed in Analyze or Curated; never
        // silently replace it with a new live tracking pass here.
        if contentIsWide, let stored = scene.centerStagePath {
            let sliced = CenterStageService.slice(
                stored.keyframes,
                from: max(0, clip.start - scene.startTime),
                duration: sourceDuration)
            if sliced.count >= 2 {
                do {
                    let reframed = try await centerStage.reframeClip(
                        source: scene.videoURL, start: clip.start,
                        duration: sourceDuration, path: sliced, log: emit)
                    defer { try? FileManager.default.removeItem(at: reframed) }
                    emit("Clip \(index + 1) reframed with its saved scene framing")
                    try await render.extractClip(source: reframed, start: 0,
                                                 duration: duration,
                                                 overlays: overlays, mute: options.muteSource,
                                                 speed: clip.speed,
                                                 mask: mask,
                                                 output: output)
                    return output
                } catch {
                    emit("Saved framing failed for clip \(index + 1) (\(error)) — falling back to auto-crop")
                }
            }
        }
        if contentIsWide {
            let xFraction = await render.autoCropXFraction(source: scene.videoURL,
                                                           start: clip.start, duration: sourceDuration,
                                                           contentBox: contentBox)
            do {
                try await render.extractClip(source: scene.videoURL, start: clip.start,
                                             duration: duration, wide: .autoCrop(xFraction),
                                             contentBox: contentBox,
                                             overlays: overlays, mute: options.muteSource,
                                             speed: clip.speed,
                                             mask: mask,
                                             output: output)
            } catch {
                try await render.extractClip(source: scene.videoURL, start: clip.start,
                                             duration: duration,
                                             contentBox: contentBox,
                                             overlays: overlays, mute: options.muteSource,
                                             speed: clip.speed,
                                             mask: mask,
                                             output: output)
            }
        } else {
            try await render.extractClip(source: scene.videoURL, start: clip.start,
                                         duration: duration,
                                         contentBox: contentBox,
                                         overlays: overlays, mute: options.muteSource,
                                         speed: clip.speed,
                                         mask: mask,
                                         output: output)
        }
        return output
    }

    /// Output naming per wizard.py: <output>/<YYYY-MM-DD>/wiz-<dur>-<n>.mp4.
    private func outputFile(profile: BrandProfile, plan: WizardPlan) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = profile.outputFolderURL.appendingPathComponent(formatter.string(from: Date()),
                                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // "<what-it-is>-<duration>s.mp4", e.g. du-plessis-strickland-split-
        // decision-18s.mp4 — the planner names the reel as part of the plan;
        // a second render of the same name gets -2, -3, … (the .md run
        // report sits next to the mp4 under the same base name).
        let totalDuration = Int(plan.clips.reduce(0) { $0 + ($1.end - $1.start) }.rounded())
        let base = "\(plan.outputBaseName)-\(totalDuration)s"
        var url = directory.appendingPathComponent("\(base).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(counter).mp4")
            counter += 1
        }
        return url
    }
}
