import CoreGraphics
import Foundation

nonisolated struct WizardOptions: Sendable {
    var muteSource = false
    var addCaptions = false
    var autoCropWide = true
    /// Let the plan stack a wide scene's halves top/bottom. Off by default —
    /// the split reads as a weird montage on action footage; auto-crop keeps
    /// the frame filled with the real composition instead.
    var allowWideSplit = false
    var enableTextOverlays = false
    var useMusic = true
    var aiInstructions = ""
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
    /// Reframe wide scenes with the tracking camera (Center Stage) instead
    /// of the static auto-crop.
    var centerStageWide = false
    /// Camera preset for the tracking camera: "smooth", "balanced", "fast"
    /// (fast action — reacts hard and zooms out so quick movers stay framed).
    var centerStageCamera = "balanced"
    /// Person keys to focus on: when set, only wide clips whose scene
    /// features one of them get the tracking camera (others auto-crop);
    /// empty = every wide clip, tracking all people on screen.
    var centerStagePeople: [String] = []
    /// Overlay choices the user named explicitly. The template is forced onto
    /// every planned overlay; the text is guaranteed to appear on one clip.
    var pinnedOverlayTemplate: String?
    var pinnedOverlayText: String?
    /// Reel format recipe: "custom", "recap", "compilation", "interview".
    var formatPreset = "custom"
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
    var wideSplit: Bool
    var textOverlay: String?
    var overlayStyle: String?
    var overlayAnimation: String?
    var overlayKicker: String?
    var overlayAccent: String?
    /// Playback speed: 1 = normal, 0.5–0.75 = slow motion. Screen time is
    /// (end - start) / speed.
    var speed: Double = 1
    /// Instantly replay this moment in slow motion right after it plays —
    /// expanded into a second slowed clip during validation.
    var replay: Bool = false
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

    /// Accept only #rgb/#rrggbb(aa)-style accents from the model.
    static func sanitizedAccent(_ accent: String?) -> String? {
        guard let accent = accent?.trimmingCharacters(in: .whitespacesAndNewlines),
              accent.hasPrefix("#"), (4...9).contains(accent.count),
              accent.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return accent
    }

    /// The overlay template for this style: upper-third auto-fit box; the
    /// caller sets text/timing. `accent` (a #hex from a reference template)
    /// overrides the default yellow on kicker chips, starred words, and
    /// tag stripes.
    func overlayItem(text: String, kicker: String? = nil, accent: String? = nil) -> TextOverlayItem {
        var item = TextOverlayItem()
        item.text = text.uppercased()
        item.xFrac = 0.5
        item.yFrac = 0.2
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
                                 accent: clip.overlayAccent)
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
}

/// Autonomous Reels generator — the Swift port of wizard.py: cached research
/// → AI plan → validation → linear assembly → AI caption.
actor WizardEngine {
    static let researchTopic = "instagram_reels"
    static let researchTTL: TimeInterval = 7 * 24 * 3600

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

    // MARK: - Research phase

    private static let researchDefaults: [String: Any] = [
        "ideal_duration_range": ["min": 15, "max": 30],
        "optimal_duration": 22,
        "aspect_ratio": "9:16",
        "hook_strategy": "Open with the most explosive moment in the first 1-2 seconds.",
        "pacing_cuts_per_minute": 20,
        "content_structure": ["hook", "rising action", "payoff"],
        "music_strategy": "High-energy track that matches the action.",
        "transition_strategy": "Fast cuts with occasional fades.",
        "engagement_tips": ["Keep it short", "End strong"],
        "avoid": ["Dead time", "Slow intros"],
        "opening_types": ["explosive action"],
        "closing_strategy": "End on a high note that invites a replay.",
    ]

    private func researchPrompt(domain: String) -> String {
        """
        You are an expert social media strategist specializing in Instagram Reels for \(domain) content.

        Based on your knowledge of the current Instagram Reels algorithm and best practices (2025-2026), provide detailed, actionable recommendations for creating \(domain) highlight reels that MAXIMIZE engagement (views, likes, shares, saves, and follows).

        Consider: optimal video duration, pacing, hook strategy (first 1-3s), content structure, music usage, transition style, and what makes \(domain) content go viral on Reels.

        Return a JSON object with EXACTLY this structure:
        {
          "ideal_duration_range": {"min": <seconds>, "max": <seconds>},
          "optimal_duration": <seconds>,
          "aspect_ratio": "9:16",
          "hook_strategy": "<detailed strategy for first 1-3 seconds>",
          "pacing_cuts_per_minute": <number>,
          "content_structure": ["<phase1>", "<phase2>", ...],
          "music_strategy": "<how to use music for maximum engagement>",
          "transition_strategy": "<recommended transition approach for \(domain) content>",
          "engagement_tips": ["<tip1>", "<tip2>", ...],
          "avoid": ["<thing to avoid 1>", ...],
          "opening_types": ["<best hook types for \(domain)>", ...],
          "closing_strategy": "<how to end for max engagement>"
        }

        Return ONLY the JSON object. No explanation, no markdown fences.
        """
    }

    private func getResearch(profile: BrandProfile, database: Database, model: String?,
                             emit: @escaping @Sendable (String) -> Void) async -> [String: Any] {
        if let cached = try? await database.latestResearch(topic: Self.researchTopic),
           let researchedAt = cached.researchedAt,
           Date().timeIntervalSince(researchedAt) <= Self.researchTTL,
           let object = AIResponseParser.jsonObject(from: cached.resultJSON) {
            emit("Using cached Instagram Reels research (less than 7 days old)")
            return object
        }
        emit("Researching Instagram Reels best practices...")
        do {
            let response = try await ai.call(prompt: researchPrompt(domain: profile.effectiveDomain),
                                             task: "research", model: model, timeout: 300, log: emit)
            if let object = AIResponseParser.jsonObject(from: response),
               let data = AIResponseParser.jsonData(from: response),
               let json = String(data: data, encoding: .utf8) {
                let attribution = await ai.resolveProviderModel(task: "research", model: model)
                try? await database.saveResearch(topic: Self.researchTopic, resultJSON: json,
                                                 provider: attribution.provider, model: attribution.model)
                emit("Research complete — cached for future runs")
                return object
            }
        } catch {
            emit("Research failed (\(error)) — using built-in defaults")
        }
        return Self.researchDefaults
    }

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
        guard let object = AIResponseParser.jsonObject(from: response) else {
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

    private func sceneLine(_ scene: SceneRecord, note: String? = nil) -> String {
        var line = "#\(scene.id): \(scene.videoFilename) " +
            String(format: "[%.1f-%.1f] %.1fs", scene.startTime, scene.endTime, scene.duration) +
            " tags:\(scene.tags.prefix(8).joined(separator: ","))"
        if scene.wide { line += " WIDE" }
        if let score = scene.score {
            line += String(format: " score:%.1f/10", score)
        }
        if let average = scene.gradeAverage, scene.gradeCount > 0 {
            line += String(format: " grade:%.1f/5", average)
        }
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
            lines.append(line)
        }
        if !summary.review.note.isEmpty { lines.append("  note: \"\(summary.review.note)\"") }
        return lines.joined(separator: "\n")
    }

    /// Everything the user has taught the wizard, compact: distilled lessons,
    /// structured review signals, A/B choices, and the latest raw notes —
    /// instead of an unbounded dump of every feedback entry ever written.
    private func trainingBlock(_ signals: TrainingSignals) -> String {
        var sections: [String] = []

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

        // An explicit user duration beats research and template alike. It
        // bounds the FINISHED file: each crossfade eats ~0.5s of overlap in
        // the render, so the planned clip total is padded by the expected
        // transition count or the output lands short of what the user asked.
        var durationDirective = ""
        if let requested = options.targetDurationSeconds {
            let expectedClips = max(1, Int((Double(requested) / 60 * Double(cutsPerMinute)).rounded()))
            let padded = Double(requested) + 0.5 * Double(expectedClips - 1)
            targetDuration = Int(padded.rounded())
            durationMin = max(3, targetDuration - 2)
            durationMax = targetDuration + 2
            durationDirective = """


            ## REQUIRED DURATION (HARD CONSTRAINT)
            The user requires the FINISHED reel to run ~\(requested)s. Crossfade transitions each consume ~0.5s of overlap in the final render, so you MUST plan more clip time than \(requested)s: total clip duration = \(requested) + 0.5 × (number of clips − 1). At ~\(expectedClips) clips that is ~\(String(format: "%.1f", padded))s of clips. Set "target_duration" to that padded total, never to \(requested).
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
        if let templateJSON = options.templateJSON, template != nil {
            let label = options.templateLabel.map { " (\($0))" } ?? ""
            templateBlock = """


            ## REFERENCE TEMPLATE (HIGH PRIORITY — replicate this reel's STRUCTURE)
            The user picked a high-performing reel\(label) as the model for this video. Its structural analysis:
            \(templateJSON)

            Replicate the STRUCTURE, never the content: match its hook type and timing, cut rhythm, pacing curve, phase structure, text overlay usage, and overall duration using the scenes available below. When the template conflicts with the research or the key principles, the template wins (user AI instructions still outrank everything).
            Also replicate its TEXT DESIGN and EFFECTS with the tools available here:
            - Map "text_style.font_class" to the closest overlay style: condensed-poster/heavy-sans → "impact" (or "highlight" when the reference colors key words), clean-sans → "banner" for labels or "minimal" for quiet text.
            - Match "text_style.animation": word_reveal/karaoke → "word_reveal", pop → "pop", slide → "slide_up", fade/none → "fade".
            - Copy its accent color: set each overlay's "accent" to the reference's text_style.accent hex; use kickers if has_kicker is true.
            - Match "effects.transitions" with the closest names from the available transitions list; mirror its cut rhythm even where an exact effect (whip-pan, flash) is unavailable.
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
        let sceneList = scenes.map { sceneLine($0, note: notes[$0.id]) }.joined(separator: "\n")
        let musicList = musicNames.isEmpty ? "No music available" : musicNames.joined(separator: ", ")
        let beatInfo = "Beat detection found no clear beats. Use your judgment for cut timing."

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

        return """
        You are an expert video editor creating an Instagram Reel for a \(domain) channel called \(brand). Your ONLY goal: MAXIMIZE ENGAGEMENT (views, likes, shares, saves).
        \(userInstructions)\(pinnedRules)\(durationDirective)\(templateBlock)

        ## Instagram Reels Research
        \(researchJSON)

        ## Available Scenes
        \(sceneList)\(subjectsBlock)

        ## Available Music
        \(musicList)

        ## Available Transitions
        \(RenderEngine.transitions.joined(separator: ", "))

        ## Music Beat Analysis
        \(beatInfo)

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
          "music": {"name": "<music name from list, or null>", "volume": <1-5>},
          "clips": [
            {
              "scene_id": <id>,
              "start": <start seconds>,
              "end": <end seconds>,
              "wide_split": <true if this WIDE scene should use split-screen>,
              "speed": <1.0 normal; 0.5-0.75 = slow motion for a big payoff moment — use sparingly, at most 1-2 slowed clips>,
              "replay": <true to instantly replay this moment in slow motion right after it plays — reserve for the single best payoff (knockdown/finish); at most one replay per reel>,
              "text_overlay": {"text": "<2-6 word ALL-CAPS line>", "style": "<impact|highlight|banner|minimal>", "animation": "<fade|slide_up|pop|word_reveal>", "kicker": "<1-3 word label or null>", "accent": "<#hex accent color or null for default yellow>"} or null,
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
        \(options.allowWideSplit
            ? "- For WIDE scenes: set \"wide_split\": true to display as split-screen (top + bottom halves, filling the full 9:16 frame with no black bars)"
            : "- Set \"wide_split\" to false for every clip. WIDE scenes are automatically zoomed to a full-height 9:16 window positioned on the action, so they fill the frame — never plan around letterboxing.")
        - Scenes with "score:X/10" were rated for ENTERTAINMENT (escalation → payoff, boosted by real crowd noise). STRONGLY prefer high-scoring scenes, put the highest-scoring payoff early as the hook, and use the "story:" lines to build a reel with an arc — setup, escalation, payoff — instead of disconnected action.
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
    private func validatePlan(_ raw: [String: Any],
                              scenes: [Int64: SceneRecord],
                              musicNames: Set<String>) -> WizardPlan? {
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
            if let overlayObject = clipObject["text_overlay"] as? [String: Any] {
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
            // Slow motion: clamp to the renderer's usable atempo band.
            var speed = (clipObject["speed"] as? NSNumber)?.doubleValue ?? 1
            speed = speed >= 0.99 ? 1 : min(0.99, max(0.5, speed))
            clips.append(WizardPlanClip(sceneID: sceneID,
                                        start: start,
                                        end: end,
                                        wideSplit: (clipObject["wide_split"] as? Bool ?? false) && scene.wide,
                                        textOverlay: overlayText?.isEmpty == false ? overlayText : nil,
                                        overlayStyle: overlayStyle,
                                        overlayAnimation: overlayAnimation,
                                        overlayKicker: overlayKicker,
                                        overlayAccent: overlayAccent,
                                        speed: speed,
                                        replay: clipObject["replay"] as? Bool ?? false))
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
                expanded.append(slow)
            }
        }
        clips = expanded

        let needed = max(0, clips.count - 1)
        var transitions = (raw["transitions"] as? [String] ?? []).map {
            RenderEngine.transitions.contains($0) ? $0 : "fade"
        }
        if transitions.count > needed { transitions = Array(transitions.prefix(needed)) }
        while transitions.count < needed { transitions.append("fade") }

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
                          introTitle: cleanLine(raw["intro_title"], maxWords: 7))
    }

    // MARK: - Caption phase

    /// Flag emoji per caption language, for the channel's bilingual format.
    private static let languageFlags: [String: String] = [
        "en": "🇺🇸", "pt": "🇧🇷", "es": "🇪🇸", "fr": "🇫🇷", "de": "🇩🇪",
        "it": "🇮🇹", "ja": "🇯🇵", "ko": "🇰🇷", "ru": "🇷🇺", "ar": "🇸🇦",
    ]

    private func captionPrompt(profile: BrandProfile, plan: WizardPlan,
                               duration: Double, tags: [String]) -> String {
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

        Requirements:
        - Caption should be 1-3 punchy lines that drive engagement (likes, comments, saves, shares)
        - Include a hook or question to encourage comments
        - Add 5-10 relevant hashtags (mix of broad \(domain) hashtags + niche + trending)
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
    }

    private func loadTrainingSignals(database: Database) async -> TrainingSignals {
        TrainingSignals(lessons: (try? await database.fetchLessons()) ?? [],
                        reviews: (try? await database.fetchReviewSummaries(limit: 10)) ?? [],
                        preferences: (try? await database.fetchPreferences(limit: 10)) ?? [],
                        feedback: (try? await database.fetchAllFeedback()) ?? [])
    }

    private func loadPlanningInputs(options: WizardOptions,
                                    profile: BrandProfile,
                                    database: Database,
                                    emit: @escaping @Sendable (String) -> Void) async throws -> PlanningInputs {
        emit("Phase 1: Instagram Reels research...")
        let research = await getResearch(profile: profile, database: database,
                                         model: options.modelOverride, emit: emit)

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
        return PlanningInputs(research: research, scenes: scenes,
                              sceneMap: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }),
                              music: music, signals: signals, people: people,
                              outcomes: outcomes)
    }

    /// One prompt → AI call → validated plan; nil plan when the response is
    /// unusable. Prompt and raw response ride along for the run report.
    private func makePlan(inputs: PlanningInputs, options: WizardOptions, profile: BrandProfile,
                          emit: @escaping @Sendable (String) -> Void) async throws
        -> (plan: WizardPlan?, prompt: String, response: String) {
        let prompt = planPrompt(profile: profile, research: inputs.research, scenes: inputs.scenes,
                                musicNames: inputs.music.map(\.name), signals: inputs.signals,
                                people: inputs.people, outcomes: inputs.outcomes, options: options)
        let response = try await ai.call(prompt: prompt, task: "wizard",
                                         model: options.modelOverride, timeout: 300, log: emit)
        guard let rawPlan = AIResponseParser.jsonObject(from: response) else {
            return (nil, prompt, response)
        }
        let plan = validatePlan(rawPlan, scenes: inputs.sceneMap, musicNames: Set(inputs.music.map(\.name)))
            .map { enforcePinnedOverlays($0, options: options) }
        return (plan, prompt, response)
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
            throw AIError.emptyResponse("wizard planning (unparseable JSON)")
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

        try Task.checkCancellation()
        emit("\nPhase 2: Planning the timeline...")
        let outcome = try await makePlan(inputs: inputs, options: options, profile: profile,
                                         emit: emit)
        guard let plan = outcome.plan else {
            throw AIError.emptyResponse("wizard planning (unparseable JSON)")
        }
        emit("Plan: \(plan.clips.count) clips, ~\(Int(plan.targetDuration))s, music: \(plan.musicName ?? "none")")
        emit("Strategy: \(plan.rationale)")

        emit("\nPhase 3: Assembling the video...")
        let result = try await assemble(plan: plan, music: inputs.music, options: options,
                                        profile: profile, database: database,
                                        sceneMap: sceneMap, emit: emit)

        emit("Generating Instagram caption...")
        let tagsUsed = Array(Set(plan.clips.flatMap { sceneMap[$0.sceneID]?.tags ?? [] })).sorted()
        var captionText: String?
        do {
            let caption = try await ai.call(
                prompt: captionPrompt(profile: profile, plan: plan,
                                      duration: result.duration, tags: tagsUsed),
                task: "captions", timeout: 60, log: emit)
            captionText = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let attribution = await ai.resolveProviderModel(task: "captions")
            try await database.updateGeneratedCaption(id: result.recordID,
                                                      caption: captionText ?? "",
                                                      provider: attribution.provider,
                                                      model: attribution.model)
            emit("Caption generated!")
        } catch {
            emit("Caption generation failed: \(error)")
        }

        // Everything a model needs to diagnose this reel, next to it.
        let planAttribution = await ai.resolveProviderModel(task: "wizard",
                                                            model: options.modelOverride)
        writeRunReport(for: result, profile: profile,
                       options: options, inputs: inputs, plan: plan,
                       planPrompt: outcome.prompt, planResponse: outcome.response,
                       planAttribution: planAttribution, caption: captionText,
                       logLines: recorder.lines(), sceneMap: sceneMap,
                       emit: emit)

        emit("VIDEO:\(result.url.lastPathComponent):\(String(format: "%.1f", result.duration))")
        emit("Video complete! \(String(format: "%.1f", result.duration))s -> \(result.url.lastPathComponent)")
        emit("\nAll done! Generated 1 video")
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
        - Auto-crop wide: \(yesNo(options.autoCropWide)), Center Stage wide: \(yesNo(options.centerStageWide))\(options.centerStageWide ? " (camera: \(options.centerStageCamera))" : "")\(options.centerStagePeople.isEmpty ? "" : " (people: \(options.centerStagePeople.joined(separator: ", ")))")
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
        guard let object = AIResponseParser.jsonObject(from: response),
              let rawLessons = object["lessons"] as? [[String: Any]] else {
            throw AIError.emptyResponse("lesson distillation (unparseable JSON)")
        }
        let distilled = rawLessons.prefix(10).compactMap { raw -> (text: String, evidence: String)? in
            guard let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return (text, (raw["evidence"] as? String) ?? "")
        }
        try await database.replaceLearnedLessons(distilled)
        return distilled.count
    }

    // MARK: - Builder pre-fill

    /// Map a validated plan onto a Builder timeline document: sequential clips
    /// on track 0 with planner transitions as transIn, music spanning the
    /// whole timeline, per-clip text overlays. No rendering — the user edits
    /// from here. (wideSplit hints are dropped; auto-crop covers wide scenes.)
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
            let index = document.videoTrack.count
            if index > 0 {
                timelineClip.transIn = plan.transitions[safe: index - 1] ?? "fade"
            }
            document.videoTrack.append(timelineClip)

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
                                              scene: job.scene, options: options,
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

        let attribution = await ai.resolveProviderModel(task: "wizard", model: options.modelOverride)
        let recordID = try await database.insertGeneratedVideo(path: outputURL.path,
                                                               duration: finalDuration.rounded(toPlaces: 1),
                                                               timelineJSON: timelineJSON,
                                                               wizardProvider: attribution.provider,
                                                               wizardModel: attribution.model,
                                                               rationale: plan.rationale)
        return AssemblyResult(url: outputURL, duration: finalDuration, recordID: recordID)
    }

    /// One planned clip → one normalized file in a single decode→encode pass:
    /// wide handling, caption overlays, text overlay and mute all ride the
    /// same ffmpeg filter graph.
    private func extractPlannedClip(_ clip: WizardPlanClip, index: Int, of total: Int,
                                    scene: SceneRecord, options: WizardOptions,
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
        // Screen recordings and reposts bake black bars into the pixels, so
        // the file's aspect lies about the footage. Crop to the detected
        // content box and treat the CONTENT's aspect as the wide signal —
        // otherwise a landscape fight inside a portrait recording letterboxes
        // no matter what the user asks for.
        let contentBox = await render.detectContentBox(source: scene.videoURL,
                                                       start: clip.start, duration: sourceDuration)
        let contentIsWide = contentBox?.isWide ?? scene.wide
        let useSplit = options.allowWideSplit && clip.wideSplit && scene.wide
        var mode = useSplit ? "split-screen"
            : (options.autoCropWide && contentIsWide ? "auto-crop" : "")
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
        // Center Stage: reframe the wide sub-range with the tracking camera,
        // then burn overlays/captions/mute into the portrait intermediate
        // through the normal (non-wide) path. With chosen people, only
        // scenes featuring one of them get the camera; others auto-crop.
        if options.centerStageWide && contentIsWide && !useSplit {
            let focused = options.centerStagePeople.isEmpty
                || options.centerStagePeople.contains { scene.tags.contains("person:\($0)") }
            if focused {
                do {
                    // A path recorded at analyze time with the same camera
                    // preset skips the tracking pass — the render is just
                    // the export. A static framing from the framing pass is
                    // the user's explicit choice, so it always wins; other
                    // preset mismatches (or slicing failure) fall through to
                    // live tracking.
                    var portrait: URL?
                    if let stored = scene.centerStagePath,
                       stored.camera == options.centerStageCamera
                        || stored.camera == FramingService.staticCamera {
                        let sliced = CenterStageService.slice(
                            stored.keyframes,
                            from: max(0, clip.start - scene.startTime),
                            duration: sourceDuration)
                        if sliced.count >= 2,
                           let reframed = try? await centerStage.reframeClip(
                               source: scene.videoURL, start: clip.start,
                               duration: sourceDuration, path: sliced, log: emit) {
                            emit("Clip \(index + 1) reframed with the camera path recorded at analysis")
                            portrait = reframed
                        }
                    }
                    let reframed: URL
                    if let portrait {
                        reframed = portrait
                    } else {
                        // Person markers on the source video make the live
                        // tracker identity-aware — only the marked people
                        // are framed, never referees or staff.
                        let allMarkers = (try? await database.personMarkers(videoID: scene.videoID)) ?? []
                        let named = allMarkers.filter { $0.personID != nil && !$0.ignored }
                        let ignored = allMarkers.filter(\.ignored)
                        let focusPortraits = named.isEmpty ? [] :
                            await Analyzer.markerPortraits(url: scene.videoURL, markers: named,
                                                           duration: scene.videoDuration)
                        let avoidPortraits = ignored.isEmpty ? [] :
                            await Analyzer.markerPortraits(url: scene.videoURL, markers: ignored,
                                                           duration: scene.videoDuration)
                        // User-framed hints pin the camera at their moments.
                        let hints = ((try? await database.centerStageHints(videoID: scene.videoID)) ?? [])
                            .filter { $0.atTime >= clip.start - 0.25 && $0.atTime <= clip.end + 0.25 }
                            .map { hint in
                                (time: min(max(0, hint.atTime - clip.start), sourceDuration),
                                 crop: CGRect(x: hint.x, y: hint.y,
                                              width: hint.width, height: hint.height))
                            }
                        reframed = try await centerStage.reframeClip(
                            source: scene.videoURL, start: clip.start, duration: sourceDuration,
                            focusPortraits: focusPortraits,
                            avoidPortraits: avoidPortraits,
                            hints: hints,
                            tuning: .named(options.centerStageCamera),
                            log: emit)
                        emit("Clip \(index + 1) reframed with Center Stage"
                             + (focusPortraits.isEmpty ? "" : " (focused on the marked people)"))
                    }
                    defer { try? FileManager.default.removeItem(at: reframed) }
                    try await render.extractClip(source: reframed, start: 0,
                                                 duration: duration,
                                                 overlays: overlays, mute: options.muteSource,
                                                 speed: clip.speed,
                                                 output: output)
                    return output
                } catch {
                    emit("Center Stage failed for clip \(index + 1) (\(error)) — falling back to auto-crop")
                }
            }
        }
        if useSplit {
            try await render.extractClip(source: scene.videoURL, start: clip.start,
                                         duration: duration, wide: .split,
                                         contentBox: contentBox,
                                         overlays: overlays, mute: options.muteSource,
                                         speed: clip.speed,
                                         output: output)
        } else if options.autoCropWide && contentIsWide {
            let xFraction = await render.autoCropXFraction(source: scene.videoURL,
                                                           start: clip.start, duration: sourceDuration,
                                                           contentBox: contentBox)
            do {
                try await render.extractClip(source: scene.videoURL, start: clip.start,
                                             duration: duration, wide: .autoCrop(xFraction),
                                             contentBox: contentBox,
                                             overlays: overlays, mute: options.muteSource,
                                             speed: clip.speed,
                                             output: output)
            } catch {
                try await render.extractClip(source: scene.videoURL, start: clip.start,
                                             duration: duration,
                                             contentBox: contentBox,
                                             overlays: overlays, mute: options.muteSource,
                                             speed: clip.speed,
                                             output: output)
            }
        } else {
            try await render.extractClip(source: scene.videoURL, start: clip.start,
                                         duration: duration,
                                         contentBox: contentBox,
                                         overlays: overlays, mute: options.muteSource,
                                         speed: clip.speed,
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

        let totalDuration = Int(plan.clips.reduce(0) { $0 + ($1.end - $1.start) }.rounded())
        let existing = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        let counter = (existing
            .filter { $0.lastPathComponent.hasPrefix("wiz-") }
            .compactMap { Int($0.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "") }
            .max() ?? 0) + 1
        return directory.appendingPathComponent("wiz-\(totalDuration)-\(counter).mp4")
    }
}
