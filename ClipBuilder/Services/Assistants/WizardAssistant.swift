import Foundation

/// A request typed into Ask AI on the AI Wizard page. The visible wizard form
/// (Express or Full) consumes it: it writes the text into its instructions
/// field and presses its own Generate.
nonisolated struct WizardAssistantRequest: Equatable, Sendable {
    var id = UUID()
    var text: String
}

nonisolated struct WizardAssistant: PageAssistant {
    let page = "AI Wizard"
    let examples = ["Vertical 30 s reel of the best counters, Portuguese captions, music, no source audio",
                    "Find the three best highlights about fight strategy",
                    "Square canvas, name tags on, keep the watermark"]

    enum Decision: Equatable, Sendable {
        case send
        case unavailable(String)
    }

    /// Pure gate so the view never receives a request it cannot run.
    static func decide(text: String, mode: WizardMode, hasVideo: Bool, hasScenes: Bool, running: Bool) -> Decision {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable("Describe the reel you want.")
        }
        if running { return .unavailable("The Wizard is already working.") }
        switch mode {
        case .express:
            return hasVideo ? .send : .unavailable("Choose a source video in Express first.")
        case .full:
            return hasScenes ? .send : .unavailable("Analyze a source first so the Wizard has scenes to pick from.")
        }
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.wizardMode == .express {
            guard !text.isEmpty else { return .unavailable("Describe the reel you want.") }
            // "Regenerate it with more jokes": the selected candidate, with that note.
            if let note = Self.regenerateNote(text) {
                guard let action = actions(store: store).first(where: { $0.id == "wizard.regenerate" }),
                      action.isAvailable(store) else {
                    return .unavailable(store.isWizardRunning ? "The Wizard is already working."
                                        : "Select a Highlights candidate in Footage first, then ask to regenerate it.")
                }
                store.assistant.sendCommand("wizard.regenerate", text: note, namespace: Self.expressNamespace)
                return .handled(note.isEmpty ? "Sent Regenerate to Express." : "Sent Regenerate to Express with your note.")
            }
            // Everything else is read by the AI against the Express form: a
            // described reel sets the picture and audio controls, its "which
            // moments" part becomes the instructions, and
            // `express.findHighlights` runs when asked (`understandingGuidance`).
            return AssistantText.unrecognized(page: page, examples: examples)
        }
        // "make it 30 seconds", "turn on captions": a settings change, not a
        // reel to generate. `AssistantModel.send` gives it to the AI, which
        // reads it against the settings whitelist below.
        if Self.isSettingsRequest(text) { return AssistantText.unrecognized(page: page, examples: examples) }
        let profile = store.activeProfile.profileName
        let videoPath = UserDefaults.standard.string(forKey: MiniWizardMemory.key(for: .videoPath, profileName: profile)) ?? ""
        switch Self.decide(text: text, mode: store.wizardMode, hasVideo: !videoPath.isEmpty,
                           hasScenes: !store.scenes.isEmpty, running: store.isWizardRunning) {
        case .unavailable(let message):
            return .unavailable(message)
        case .send:
            // The visible form consumes this and decides whether it can run
            // now; only it knows (Full mode needs chosen sources too), so this
            // reports a hand-off, not a started job.
            store.pendingWizardAssistantRequest = WizardAssistantRequest(text: text)
            return .handled(store.wizardMode == .express ? "Sent to Express." : "Sent to the Wizard.")
        }
    }

    // MARK: - Context

    /// Raw platform ids as the user sees them ("Instagram, TikTok").
    static func platformLabels(_ raw: [String]) -> String {
        raw.map { SocialPlatform(rawValue: $0)?.label ?? $0 }.joined(separator: ", ")
    }

    static let expressSubpage = "Express"
    static let fullSubpage = "Full"

    /// Express on/off settings the assistant can show and flip, by
    /// `MiniWizardSettings` field name. Each flip is `express.set.<field>.<on|off>`.
    static var expressToggles: [(field: String, label: String, keyPath: WritableKeyPath<MiniWizardSettings, Bool>)] {
        [("captions", "Captions", \.captions), ("nameTags", "Name tags", \.nameTags),
         ("safeAreaOnly", "Safe area only", \.safeAreaOnly), ("watermark", "Watermark", \.watermark),
         ("overlay", "Overlay", \.overlay), ("introVideo", "Intro", \.introVideo), ("outroVideo", "Outro", \.outroVideo)]
    }

    /// Full wizard on/off settings, by `@AppStorage` key in WizardView, with
    /// the default the view uses when the key is unset.
    static let fullToggles: [(field: String, label: String, defaultsKey: String, defaultValue: Bool)] = [
        ("nameTags", "Name tags", "wizard.nameTags", false),
        ("safeAreaOnly", "Safe area only", "wizard.safeAreaOnly", false),
        ("useBRoll", "B-roll", "wizard.useBRoll", true),
        ("critiqueLoop", "Critique loop", "wizard.critiqueLoop", true),
    ]

    static func setActionID(_ field: String, on: Bool, express: Bool) -> String {
        "\(express ? "express" : "full").set.\(field).\(on ? "on" : "off")"
    }

    /// The Express form as MiniWizardView resolves it, published on every
    /// change (`AssistantModel.expressPage`): the footage kind the page
    /// shows (`MiniWizardFlow.effectiveFootageKind`, not the remembered
    /// preference), the run on screen only when it matches the source, kind
    /// and length, and the settings the render will apply.
    struct ExpressPage: Equatable, Sendable {
        var projectID: Int64?
        var sourceName: String?
        var sourceSeconds: Double?
        var hasTranscript = false
        var footageKind: MiniWizardFlow.FootageKind = .highlights
        var length: MiniWizardFlow.Length = .automatic
        /// `MiniWizardSettings.effective(for:...)`.
        var settings = MiniWizardSettings()
        var keptCount = 0
        /// The Generate footer would run now (kept footage, Settings open-able, idle).
        var canGenerate = false
        /// The Highlights candidate selected in Footage, for Regenerate with note.
        var selectedCandidate: String?
    }

    /// The full Wizard form as WizardView resolves it (`AssistantModel.fullPage`).
    struct FullPage: Equatable, Sendable {
        var projectID: Int64?
        /// The Source card's own summary ("Choose Analyze batches", "2 Analyze batches").
        var sourceSummary = "All analyzed scenes"
        /// Scenes and videos in the page's source pool (empty when a
        /// restricted selection chose nothing).
        var poolScenes = 0
        var poolVideos = 0
        /// This project's saved selections the page shows with a kept take.
        var keptTakes = 0
        var presentation = FullPresentation()
        /// Generate and Open in Editor are enabled on the page now.
        var canGenerate = false
        var canOpenInEditor = false
    }

    /// The full Wizard's presentation choices as the run will apply them.
    struct FullPresentation: Equatable, Sendable {
        var captions = false
        var headlines = false
        var nameTags = false
        var safeAreaOnly = false
        var safeAreaPlatforms: [String] = []
        var useBRoll = true
        var critiqueLoop = true
        var music = true
        var muteSource = false
        var musicTrack: String?
        var captionStyle: String?
        var captionPosition: String?
        var captionLanguage: String?
        var dubLanguage: String?
        var overlayStyle: String?
        var branding: String?
        var format: String?
        var strikeStats = false
        var fightResearch = true
        var favoritesOnly = false
        var people: [String] = []
    }

    /// Everything Express knows that the context line and the rules use.
    struct ExpressSnapshot: Equatable, Sendable {
        var sourceName: String?
        var sourceSeconds: Double?
        var hasTranscript = false
        var footageKind: MiniWizardFlow.FootageKind = .highlights
        var length: MiniWizardFlow.Length = .automatic
        var settings = MiniWizardSettings()
        /// Display name for `settings.captionStyleID`.
        var captionStyleName: String?
        var keptCount = 0
        var historyCount = 0
        var regeneratedCount = 0
        var sourceCount = 0
        var sceneCount = 0
        /// Platforms the profile's exports clear (empty = platform safe area off).
        var platforms: [String] = []
        var instructions = ""
        var canGenerate = false
        var selectedCandidate: String?
    }

    /// Everything the full Wizard knows that the context line and the rules use.
    struct FullSnapshot: Equatable, Sendable {
        var sourceCount = 0
        var sceneCount = 0
        /// What the Source card says it uses.
        var sourceSummary = "All analyzed scenes"
        /// Scenes in the chosen sources; nil when the page has not said.
        var poolScenes: Int?
        var recipe = "Custom"
        var duration = "Auto"
        var outputMode: MiniWizardFlow.OutputMode = .separateVideos
        /// This project's selections with a kept take.
        var keptSelections = 0
        var historyCount = 0
        var regeneratedCount = 0
        var presentation = FullPresentation()
        var instructions = ""
        var canGenerate = false
        var canOpenInEditor = false
    }

    static func excerpt(_ text: String, limit: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Express settings for the context: the on/off switches always, every
    /// other field only when on or not at its default, so two materially
    /// different forms never share a fingerprint.
    static func expressSettingFacts(_ m: MiniWizardSettings, captionStyleName: String? = nil) -> [AssistantFact] {
        let defaults = MiniWizardSettings()
        var facts = expressToggles.map { AssistantFact($0.field, $0.label, on: m[keyPath: $0.keyPath]) }
        func add(_ key: String, _ label: String, _ value: String?) {
            if let value, !value.isEmpty { facts.append(AssistantFact(key, label, value)) }
        }
        if m.captions {
            add("captionStyle", "Caption style", captionStyleName ?? m.captionStyleID)
            add("captionPosition", "Caption position", m.captionPosition)
            if let speakers = m.speakerCaptionPositions, !speakers.isEmpty {
                add("speakerCaptionPositions", "Per-speaker caption positions",
                    speakers.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
            if m.englishCaptions { add("captionLanguage", "Caption language", "English") }
        }
        if m.nameTags {
            add("nameTagContent", "Name tag content", m.nameTagContent)
            add("nameTagStyle", "Name tag style", m.nameTagStyleID ?? m.nameTagStyle)
            add("nameTagPosition", "Name tag position", m.nameTagPosition)
        }
        if m.safeAreaOnly, let platforms = m.safeAreaPlatforms, !platforms.isEmpty {
            add("safeAreaPlatforms", "Safe area platforms", Self.platformLabels(platforms))
        }
        if m.watermark {
            add("watermarkOverlay", "Watermark design", m.watermarkOverlay)
            if let opacity = m.watermarkOpacity { add("watermarkOpacity", "Watermark strength", "\(Int((opacity * 100).rounded()))%") }
        }
        if m.overlay {
            add("overlayTemplate", "Overlay design", m.overlayTemplate)
            if m.overlayStart != defaults.overlayStart { add("overlayStart", "Overlay start (s)", String(format: "%g", m.overlayStart)) }
            if let duration = m.overlayDuration { add("overlayDuration", "Overlay duration (s)", String(format: "%g", duration)) }
            if !m.overlayTexts.isEmpty { add("overlayTexts", "Overlay texts", excerpt(m.overlayTexts.joined(separator: " / "))) }
        }
        if m.introVideo { add("introBumper", "Intro bumper", m.introBumper) }
        if m.outroVideo { add("outroBumper", "Outro bumper", m.outroBumper) }
        if m.framing != defaults.framing { add("framing", "Framing", m.framing.joined) }
        if m.transition != defaults.transition { add("transition", "Transition", m.transition) }
        if !m.look.isEmpty { add("look", "Look", m.look) }
        if m.music { add("music", "Music", m.musicTrack ?? "random by length") }
        if m.muteSourceAudio { add("muteSourceAudio", "Source audio", "muted") }
        if m.dub { add("dub", "Dubbing", m.dubLanguage ?? "on") }
        if m.includesBRoll { add("broll", "B-roll", AssistantContext.on) }
        if m.resolvedInterviewCuts {
            add("interviewCuts", "Interview cuts", m.resolvedInterviewPunchIn)
        }
        if m.interviewZoom != defaults.interviewZoom { add("interviewZoom", "Interview zoom", String(format: "%.2f", m.interviewZoom)) }
        if m.interviewZoomMoves { add("interviewZoomMoves", "VIP focus", "zooms in place") }
        if !m.cameraFocus.isEmpty { add("cameraFocus", "Camera focus", m.cameraFocus) }
        if m.quality != defaults.quality { add("quality", "Quality", m.quality.rawValue) }
        if m.preset != defaults.preset { add("format", "Format", m.preset.label) }
        if m.outputMode != .separateVideos { add("outputMode", "Output", m.outputMode.label) }
        return facts
    }

    /// Full Wizard settings for the context, in the same spirit.
    static func fullSettingFacts(_ p: FullPresentation, duration: String, outputMode: MiniWizardFlow.OutputMode) -> [AssistantFact] {
        var facts = [AssistantFact("duration", "Target duration", duration),
                     AssistantFact("outputMode", "Output", outputMode.label),
                     AssistantFact("nameTags", "Name tags", on: p.nameTags),
                     AssistantFact("safeAreaOnly", "Safe area only", on: p.safeAreaOnly),
                     AssistantFact("useBRoll", "B-roll", on: p.useBRoll),
                     AssistantFact("critiqueLoop", "Critique loop", on: p.critiqueLoop),
                     AssistantFact("captions", "Captions", on: p.captions),
                     AssistantFact("headlines", "Headlines", on: p.headlines),
                     AssistantFact("music", "Music", on: p.music)]
        func add(_ key: String, _ label: String, _ value: String?) {
            if let value, !value.isEmpty { facts.append(AssistantFact(key, label, value)) }
        }
        if p.captions {
            add("captionStyle", "Caption style", p.captionStyle)
            add("captionPosition", "Caption position", p.captionPosition)
        }
        add("captionLanguage", "Caption language", p.captionLanguage)
        add("dubLanguage", "Dub language", p.dubLanguage)
        if p.music { add("musicTrack", "Music track", p.musicTrack) }
        if p.muteSource { add("muteSource", "Source audio", "muted") }
        add("overlayStyle", "Overlay style", p.overlayStyle)
        add("branding", "Branding", p.branding)
        add("format", "Format", p.format)
        if p.safeAreaOnly, !p.safeAreaPlatforms.isEmpty {
            add("safeAreaPlatforms", "Safe area platforms", Self.platformLabels(p.safeAreaPlatforms))
        }
        if p.strikeStats { add("strikeStats", "Strike stats", AssistantContext.on) }
        if !p.fightResearch { add("fightResearch", "Fight research", AssistantContext.off) }
        if p.favoritesOnly { add("favoritesOnly", "Favorite scenes only", AssistantContext.on) }
        if !p.people.isEmpty { add("people", "People", p.people.joined(separator: ", ")) }
        return facts
    }

    static func context(express s: ExpressSnapshot) -> AssistantContext {
        let flag = { (on: Bool) in on ? "yes" : "no" }
        var facts = [
            AssistantFact("source", "Source", s.sourceName ?? "none"),
            AssistantFact("source.transcript", "Source transcript", flag(s.hasTranscript)),
            AssistantFact("footage", "Footage", s.footageKind.label),
            AssistantFact("kept", "Kept footage", s.keptCount),
            AssistantFact("sources", "Sources in project", s.sourceCount),
            AssistantFact("scenes", "Scenes", s.sceneCount),
            AssistantFact("history", "Earlier highlights", s.historyCount),
            AssistantFact("history.regenerated", "Regenerated highlights", s.regeneratedCount),
            AssistantFact("platforms", "Platform safe areas", s.platforms.isEmpty ? "none" : s.platforms.joined(separator: ", ")),
        ]
        if let seconds = s.sourceSeconds { facts.insert(AssistantFact("source.seconds", "Source length (s)", Int(seconds.rounded())), at: 1) }
        if let candidate = s.selectedCandidate { facts.append(AssistantFact("candidate", "Selected candidate", candidate)) }
        var settings = [AssistantFact("length", "Length", s.length.label)]
        settings += expressSettingFacts(s.settings, captionStyleName: s.captionStyleName)
        if !s.instructions.isEmpty { settings.append(AssistantFact("instructions", "Instructions", excerpt(s.instructions))) }
        var summary = [s.footageKind.label]
        if s.footageKind == .highlights { summary.append(s.length.label) }
        summary.append("captions \(s.settings.captions ? "on" : "off")")
        summary.append(s.sourceName == nil ? "no source" : "1 source")
        if s.historyCount > 0 { summary.append(s.historyCount == 1 ? "1 earlier highlight" : "\(s.historyCount) earlier highlights") }
        return AssistantContext(page: "AI Wizard", subpage: expressSubpage, facts: facts, settings: settings,
                                selection: s.sourceName.map { [$0] } ?? [], summary: summary)
    }

    static func context(full s: FullSnapshot) -> AssistantContext {
        var facts = [
            AssistantFact("sources", "Sources in project", s.sourceCount),
            AssistantFact("scenes", "Scenes", s.sceneCount),
            AssistantFact("sourceChoice", "Chosen sources", s.sourceSummary),
        ]
        if let pool = s.poolScenes { facts.append(AssistantFact("pool.scenes", "Scenes in the chosen sources", pool)) }
        facts += [
            AssistantFact("kept", "Kept takes", s.keptSelections),
            AssistantFact("history", "Earlier highlights", s.historyCount),
            AssistantFact("history.regenerated", "Regenerated highlights", s.regeneratedCount),
            AssistantFact("recipe", "Recipe", s.recipe),
        ]
        var settings = fullSettingFacts(s.presentation, duration: s.duration, outputMode: s.outputMode)
        if !s.instructions.isEmpty { settings.append(AssistantFact("instructions", "Instructions", excerpt(s.instructions))) }
        var summary = [s.recipe, s.duration, s.outputMode.label,
                       s.sourceCount == 1 ? "1 source" : "\(s.sourceCount) sources"]
        if s.historyCount > 0 { summary.append(s.historyCount == 1 ? "1 earlier highlight" : "\(s.historyCount) earlier highlights") }
        return AssistantContext(page: "AI Wizard", subpage: fullSubpage, facts: facts, settings: settings, summary: summary)
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        if store.wizardMode == .express { store.loadDubVoicesForAssistant() }
        return store.wizardMode == .express ? Self.context(express: expressSnapshot(store: store))
            : Self.context(full: fullSnapshot(store: store))
    }

    @MainActor
    private func history(store: AppStore, scope: HighlightHistoryScope?) -> (count: Int, regenerated: Int) {
        guard let scope else { return (0, 0) }
        let entries = store.highlightHistory(scope)
        return (entries.count, entries.filter { $0.parentID != nil }.count)
    }

    /// The page's published form (`expressPage`) when it is for this
    /// project; before Express is first on screen, the remembered answers.
    @MainActor
    func expressSnapshot(store: AppStore, defaults: UserDefaults = .standard) -> ExpressSnapshot {
        let profile = store.activeProfile
        func stored(_ field: MiniWizardMemory.Field) -> String? {
            defaults.string(forKey: MiniWizardMemory.key(for: field, profileName: profile.profileName))
        }
        let path = stored(.videoPath) ?? ""
        let video = path.isEmpty ? nil : store.videos.first { $0.path == path }
        var s = ExpressSnapshot()
        s.sourceName = video?.filename
        s.sourceSeconds = video?.duration
        s.hasTranscript = video.map { (store.transcriptCounts[$0.id] ?? 0) > 0 } ?? false
        s.footageKind = MiniWizardFlow.FootageKind(rawValue: stored(.footageKind) ?? "") ?? .highlights
        s.length = MiniWizardFlow.Length(rawValue: stored(.length) ?? "") ?? .automatic
        s.settings = MiniWizardSettings.remembered(profile: profile, defaults: defaults)
        if let video, let run = store.miniRuns[s.footageKind], run.video.id == video.id,
           run.projectID == store.activeProjectID, s.footageKind != .highlights || run.length == s.length {
            s.keptCount = run.keptCount
        }
        if let page = store.assistant.expressPage, page.projectID == store.activeProjectID {
            s.sourceName = page.sourceName
            s.sourceSeconds = page.sourceSeconds
            s.hasTranscript = page.hasTranscript
            s.footageKind = page.footageKind
            s.length = page.length
            s.settings = page.settings
            s.keptCount = page.keptCount
            s.canGenerate = page.canGenerate
            s.selectedCandidate = page.selectedCandidate
        }
        s.captionStyleName = s.settings.captionStyleID.flatMap { id in
            (profile.captionStyles ?? []).first { $0.id.uuidString == id }?.name
        }
        let scope = store.activeProjectID.flatMap { project in
            video.flatMap { $0.hash.isEmpty ? nil : HighlightHistoryScope.express(projectID: project, videoHash: $0.hash) }
        }
        (s.historyCount, s.regeneratedCount) = history(store: store, scope: scope)
        s.sourceCount = store.videos.count
        s.sceneCount = store.scenes.count
        let safeArea = profile.defaultRenderSettings.platformSafeArea
        s.platforms = safeArea.isActive ? safeArea.platforms.map(\.label) : []
        s.instructions = profile.miniInstructions ?? ""
        return s
    }

    /// Batches the saved selection names that belong to this project (the
    /// selection is a global preference, as WizardView treats it).
    static func sourceSummary(limitToSelection: Bool, savedRunIDs: Set<Int64>, projectRunIDs: Set<Int64>,
                              favoritesOnly: Bool) -> String {
        if limitToSelection {
            let count = savedRunIDs.intersection(projectRunIDs).count
            return count == 0 ? "Choose Analyze batches" : "\(count) Analyze batch\(count == 1 ? "" : "es")"
        }
        return favoritesOnly ? "Favorite scenes" : "All analyzed scenes"
    }

    /// The page's published form (`fullPage`) when it is for this project;
    /// before the Wizard is first on screen, its @AppStorage answers.
    @MainActor
    func fullSnapshot(store: AppStore, defaults: UserDefaults = .standard) -> FullSnapshot {
        var s = FullSnapshot()
        s.sourceCount = store.videos.count
        s.sceneCount = store.scenes.count
        let recipeID = defaults.string(forKey: "wizard.formatPreset") ?? "custom"
        s.recipe = ReelRecipe.recipe(id: recipeID)?.title ?? recipeID
        let mode = WizardDurationMode(rawValue: defaults.string(forKey: WizardDefaults.durationModeKey) ?? "") ?? .automatic
        let custom = defaults.object(forKey: WizardDefaults.customDurationKey) == nil
            ? 20 : WizardDefaults.clampedCustomDuration(defaults.integer(forKey: WizardDefaults.customDurationKey))
        s.duration = mode == .custom ? "\(custom) s" : mode.title
        s.outputMode = MiniWizardFlow.OutputMode(rawValue: defaults.string(forKey: "wizard.outputMode") ?? "") ?? .separateVideos
        (s.historyCount, s.regeneratedCount) = history(store: store,
            scope: store.activeProjectID.map { HighlightHistoryScope.fullWizard(projectID: $0) })
        s.instructions = defaults.string(forKey: "wizard.aiInstructions") ?? ""
        if let page = store.assistant.fullPage, page.projectID == store.activeProjectID {
            s.sourceSummary = page.sourceSummary
            s.poolScenes = page.poolScenes
            s.keptSelections = page.keptTakes
            s.presentation = page.presentation
            s.canGenerate = page.canGenerate
            s.canOpenInEditor = page.canOpenInEditor
            return s
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        let limited = flag("wizard.limitToSelection", true)
        let saved = Set((defaults.string(forKey: "wizard.selectedRunIDs") ?? "").split(separator: ",").compactMap { Int64($0) })
        s.sourceSummary = Self.sourceSummary(limitToSelection: limited, savedRunIDs: saved,
                                             projectRunIDs: Set(store.analysisRuns.map(\.id)),
                                             favoritesOnly: flag("wizard.favoritesOnly", false))
        s.keptSelections = store.wizardSelections.count {
            $0.selection.projectID == store.activeProjectID && $0.selection.bestTakeID != nil
        }
        for toggle in Self.fullToggles {
            let on = flag(toggle.defaultsKey, toggle.defaultValue)
            switch toggle.field {
            case "nameTags": s.presentation.nameTags = on
            case "safeAreaOnly": s.presentation.safeAreaOnly = on
            case "useBRoll": s.presentation.useBRoll = on
            case "critiqueLoop": s.presentation.critiqueLoop = on
            default: break
            }
        }
        s.canGenerate = !store.isWizardRunning
        return s
    }

    // MARK: - Suggestions

    /// Express sources over this long default to Auto only by accident.
    static let longSourceSeconds = 20 * 60

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        let express = context.subpage == Self.expressSubpage
        var rows: [AssistantSuggestion] = []
        let sources = context.int("sources") ?? 0
        let scenes = context.int("scenes") ?? 0
        if sources == 0 {
            rows.append(.init(id: "wizard.sources.none", kind: .action, title: "Add source videos",
                              reason: "This project has no sources for the Wizard to cut from", actionID: "wizard.goto.sources"))
        } else if scenes == 0 {
            rows.append(.init(id: "wizard.analyze.first", kind: .insight, title: "Analyze a source first",
                              reason: sources == 1 ? "1 source, not analyzed yet: the Wizard picks from scenes"
                                  : "\(sources) sources, none analyzed yet: the Wizard picks from scenes"))
        } else if !express, context.int("pool.scenes") == 0 {
            rows.append(.init(id: "wizard.sources.empty", kind: .insight, title: "Choose sources",
                              reason: "The Source card has no scenes to pick from: \(context.value("sourceChoice") ?? "nothing chosen")"))
        }
        if express {
            if context.value("source.transcript") == "yes", context.isOff("captions") {
                rows.append(.init(id: "express.captions.on", kind: .setting, title: "Turn on captions",
                                  reason: "This source has a transcript and captions are off",
                                  actionID: Self.setActionID("captions", on: true, express: true)))
            }
            if context.value("footage") == MiniWizardFlow.FootageKind.highlights.label,
               context.value("length") == MiniWizardFlow.Length.automatic.label,
               let seconds = context.int("source.seconds"), seconds > Self.longSourceSeconds {
                rows.append(.init(id: "express.length.shorter", kind: .setting, title: "Set Length to 30 s",
                                  reason: "This source runs \(seconds / 60) min and Length is Auto",
                                  actionID: "express.length.30"))
            }
            if let platforms = context.value("platforms"), platforms != "none", context.isOff("safeAreaOnly") {
                rows.append(.init(id: "express.safearea.on", kind: .setting, title: "Keep text inside the safe area",
                                  reason: "Exports clear \(platforms) and Safe area only is off",
                                  actionID: Self.setActionID("safeAreaOnly", on: true, express: true)))
            }
        }
        let history = context.int("history") ?? 0
        if history >= 2, (context.int("history.regenerated") ?? 0) == 0 {
            rows.append(.init(id: "wizard.history.compare", kind: .action, title: "Compare earlier highlights",
                              reason: express ? "\(history) highlights of this source, none regenerated yet"
                                  : "\(history) highlights in this project, none regenerated yet",
                              actionID: "wizard.history"))
        }
        return rows
    }

    // MARK: - Actions

    /// The view that runs the Wizard's page commands in each mode, as its
    /// `onAssistantCommand` prefix without the dot.
    static let expressNamespace = "express"
    static let fullNamespace = "full"

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let express = store.wizardMode == .express
        let idle: @MainActor @Sendable (AppStore) -> Bool = { !$0.isWizardRunning }
        // Sent to the form of the mode it was offered in, never the other.
        let namespace = express ? Self.expressNamespace : Self.fullNamespace
        func command(_ id: String, _ title: String, _ symbol: String, message: String,
                     available: (@MainActor @Sendable (AppStore) -> Bool)? = nil) -> AssistantAction {
            .command(id, title, symbol, message: message, namespace: namespace, available: available ?? idle)
        }
        // What the visible form says its Generate and Open in Editor would do.
        let canGenerate: @MainActor @Sendable (AppStore) -> Bool = { store in
            guard !store.isWizardRunning else { return false }
            if store.wizardMode == .express {
                guard let page = store.assistant.expressPage, page.projectID == store.activeProjectID else { return false }
                return page.canGenerate
            }
            guard let page = store.assistant.fullPage, page.projectID == store.activeProjectID else { return true }
            return page.canGenerate
        }
        let canOpenInEditor: @MainActor @Sendable (AppStore) -> Bool = { store in
            guard !store.isWizardRunning else { return false }
            if store.wizardMode == .express {
                guard let page = store.assistant.expressPage, page.projectID == store.activeProjectID else { return false }
                return page.canGenerate
            }
            return store.assistant.fullPage.map { $0.projectID == store.activeProjectID && $0.canOpenInEditor } ?? false
        }
        let target = express ? "Express" : "the Wizard"
        var actions = [
            command("wizard.generate", "Generate", SidebarSection.wizard.systemImage, message: "Sent Generate to \(target).",
                    available: canGenerate),
            command("wizard.openInEditor", "Open in Editor", "hammer", message: "Sent Open in Editor to \(target).",
                    available: canOpenInEditor),
            command("wizard.history", "Show highlight history", "clock.arrow.circlepath", message: "Opened the highlight history.",
                    available: { _ in true }),
            AssistantAction(id: "wizard.goto.sources", title: "Open Sources", systemImage: SidebarSection.sources.systemImage) { store in
                store.requestedSection = .sources
                return .handled("Opened Sources.")
            },
        ]
        if express {
            // The old Ask AI hand-off: instructions in, Highlights found.
            actions.append(command(Self.findHighlightsAction, "Find highlights from the instructions", "sparkles",
                                   message: "Sent to Express.", available: { store in
                guard !store.isWizardRunning, let page = store.assistant.expressPage,
                      page.projectID == store.activeProjectID else { return false }
                return page.sourceName != nil
            }))
            // The Footage card's per-candidate Regenerate, on the selected candidate.
            actions.append(command("wizard.regenerate", "Regenerate with note", "arrow.clockwise",
                                   message: "Sent Regenerate to Express.", available: { store in
                guard !store.isWizardRunning, let page = store.assistant.expressPage,
                      page.projectID == store.activeProjectID else { return false }
                return page.selectedCandidate != nil
            }))
            let settings = MiniWizardSettings.remembered(profile: store.activeProfile)
            for toggle in Self.expressToggles {
                let on = !settings[keyPath: toggle.keyPath]
                actions.append(command(Self.setActionID(toggle.field, on: on, express: true),
                                       "Turn \(on ? "on" : "off") \(toggle.label.lowercased())", "slider.horizontal.3",
                                       message: "\(toggle.label) \(on ? "on" : "off") in Express."))
            }
            actions.append(command("express.length.30", "Set Length to 30 s", "slider.horizontal.3",
                                   message: "Length set to 30 s in Express."))
        } else {
            for toggle in Self.fullToggles {
                let current = UserDefaults.standard.object(forKey: toggle.defaultsKey) == nil
                    ? toggle.defaultValue : UserDefaults.standard.bool(forKey: toggle.defaultsKey)
                let key = toggle.defaultsKey
                let label = toggle.label
                actions.append(AssistantAction(id: Self.setActionID(toggle.field, on: !current, express: false),
                                               title: "Turn \(!current ? "on" : "off") \(label.lowercased())",
                                               systemImage: "slider.horizontal.3", isAvailable: idle) { _ in
                    // WizardView reads these through @AppStorage, so the form follows.
                    UserDefaults.standard.set(!current, forKey: key)
                    return .handled("\(label) \(!current ? "on" : "off") in the Wizard.")
                })
            }
        }
        return actions
    }

    /// The note in "regenerate (it) with <note>"; "" for a bare
    /// "regenerate"; nil when the text is not a regenerate request.
    static func regenerateNote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"(?i)^(regenerate|redo|re-do|retry)\b"#, options: .regularExpression) != nil else { return nil }
        return AssistantText.remainder(of: trimmed, after: ["with the note ", "with note ", "note:", " with ", ": "]) ?? ""
    }

    // MARK: - Settings Ask AI may change (Phase 3)

    /// True for a short request that changes a setting rather than
    /// describing a reel: it starts like a settings change ("make it",
    /// "turn on", "set") or names a setting in a few words, and does not
    /// name a reel, video, highlight or moment.
    static func isSettingsRequest(_ text: String) -> Bool {
        let t = AssistantText.normalized(text)
        guard !t.isEmpty else { return false }
        if AssistantText.mentions(t, ["reel", "video", "highlight", "moment", "clip", "story", "montage", "compilation"]) {
            return false
        }
        let openers = ["make it ", "set ", "turn ", "switch ", "use ", "enable ", "disable ", "change ", "no ",
                       "add ", "remove ", "keep ", "without ", "with ", "shorter", "longer"]
        if openers.contains(where: t.hasPrefix) { return true }
        let settingWords = ["caption", "subtitle", "name tag", "safe area", "watermark", "transition", "length",
                            "duration", "second", "headline", "recipe", "format"]
        return AssistantText.mentions(t, settingWords) && t.split(separator: " ").count <= 6
    }

    static let instructionsLimit = 2000
    static let findHighlightsAction = "express.findHighlights"
    /// The rough cut sheet's Apply: `text` carries `Framing.joined`, and the
    /// page it came from (by namespace) makes it its framing.
    static let applyFramingAction = "wizard.applyFraming"
    /// The sheet's Generate: apply its framing, then the page's Generate.
    static let generateWithFramingAction = "wizard.generateWithFraming"

    /// Choice values a picker shows as "nothing chosen" (profile default,
    /// brand logo, any bumper).
    static let defaultChoice = "default"

    /// Express: every control of the Settings card the AI may set from a
    /// described reel. B-roll stays manual; music track and bumper names
    /// are chosen in the card (their lists load asynchronously there).
    static func expressSettings(profile: BrandProfile, overlays: [String], sourceType: VideoType? = nil,
                                dubVoices: [DubSynthesizer.Voice] = [], dubLanguage: String? = nil) -> [AssistantSetting] {
        func choice(_ key: String, _ label: String, _ values: [(String, String)]) -> AssistantSetting {
            AssistantSetting(key, label, .choice(values.map(\.0)),
                             choiceLabels: Dictionary(values, uniquingKeysWith: { first, _ in first }))
        }
        let kinds = MiniWizardFlow.FootageKind.allCases.map { ($0.rawValue, $0.label) }
        let lengths = MiniWizardFlow.Length.allCases.map { ($0.rawValue, $0.label) }
        let qualities = EncodeQuality.allCases.filter { $0 != .custom }.map { ($0.rawValue, $0.rawValue.capitalized) }
        let canvases = RenderPreset.allCases.filter { $0 != .custom }.map { ($0.rawValue, $0.label) }
        // The card's Effect menu: looks and film stocks only; the catalogue's
        // adjustment presets need parameters Express never sets.
        let looks = [("", "None")] + EffectCatalog.presets.filter { $0.group == "looks" || $0.group == "film" }.map { ($0.id, $0.name) }
        // Only the subjects the source's type allows: the render swaps any
        // other back to the type's default.
        let framings = FramingMenu.allowed(type: sourceType ?? .other).map { ($0.rawValue, $0.rawValue) }
        let captionStyles = [(defaultChoice, "Profile default")] + (profile.captionStyles ?? []).map { ($0.id.uuidString, $0.name) }
        let tagStyles = [(defaultChoice, "Profile default")] + (profile.tagStyles ?? []).map { ($0.id.uuidString, $0.name) }
        let watermarks = [(defaultChoice, "Brand logo")] + overlays.map { ($0, $0) }
        let dubLanguages = [(defaultChoice, "Default (\(DubLanguageChoices.name(DubLanguageChoices.defaultLanguage)))")]
            + DubLanguageChoices.languages(voices: dubVoices, selected: dubLanguage).map { ($0, DubLanguageChoices.name($0)) }
        var settings: [AssistantSetting] = [
            choice("footageKind", "Footage", kinds),
            choice("length", "Length (Highlights)", lengths),
            choice("quality", "Quality", qualities),
            choice("canvas", "Canvas (aspect and resolution)", canvases),
            choice("look", "Effect (look graded into the footage)", looks),
            AssistantSetting("transition", "Transition", .choice([WizardPlanRules.randomTransitionChoice] + RenderEngine.allTransitions)),
            choice("framing", "Framing subject", framings),
        ]
        settings += expressToggles.filter { $0.field == "captions" }.map { AssistantSetting($0.field, $0.label, .bool) }
        settings += [
            choice("captionPosition", "Caption position", [(defaultChoice, "Auto"), ("bottom", "Bottom"), ("middle", "Middle"), ("top", "Top")]),
            choice("captionStyle", "Caption style", captionStyles),
            choice("captionLanguage", "Caption language", [("native", "Native (spoken language)"), ("english", "English")]),
            AssistantSetting("nameTags", "Name tags", .bool),
            choice("nameTagPosition", "Name tag position", [(defaultChoice, "Auto"), ("topLeading", "Top left"), ("topTrailing", "Top right"),
                                                            ("bottomLeading", "Bottom left"), ("bottomTrailing", "Bottom right")]),
            choice("nameTagStyle", "Name tag style", tagStyles),
            AssistantSetting("safeAreaOnly", "Safe area only (keep text clear of platform buttons)", .bool),
            AssistantSetting("watermark", "Watermark", .bool),
            choice("watermarkDesign", "Watermark design", watermarks),
            AssistantSetting("watermarkOpacity", "Watermark opacity (percent)", .integer(5...100)),
            AssistantSetting("overlay", "Overlay (a saved design over the video)", .bool),
        ]
        if !overlays.isEmpty { settings.append(choice("overlayDesign", "Overlay design", overlays.map { ($0, $0) })) }
        settings += [
            AssistantSetting("introVideo", "Intro bumper", .bool),
            AssistantSetting("outroVideo", "Outro bumper", .bool),
            AssistantSetting("muteSourceAudio", "Mute source audio (fight and training footage)", .bool),
            AssistantSetting("music", "Music from the library (fight and training footage)", .bool),
            AssistantSetting("dub", "Dub the speech", .bool),
            choice("dubLanguage", "Dub language", dubLanguages),
            AssistantSetting("aiInstructions", "AI instructions (which moments to pick)", .text(maxLength: instructionsLimit)),
        ]
        return settings
    }

    /// How the model reads a described reel against the Express form.
    static let expressGuidance = """
    This page is a form for one reel from one source. Translate every picture requirement (canvas, \
    quality, effect, transition, framing, captions and their position, style and language, name tags, \
    watermark, overlay, intro, outro) and every audio requirement (mute source audio, music, dub and \
    its language) into the matching settings. Words like "vertical", "portrait", "TikTok" or "Reels" \
    mean a 9:16 canvas; "square" 1:1; "landscape", "YouTube" or "widescreen" 16:9. captionLanguage \
    has two values: native (captions in the language spoken in the footage) and english (captions \
    translated to English). Captions asked in the footage's own language are native; English captions \
    on footage in another language are english; captions asked in any other language cannot be set \
    here, so leave captionLanguage out and say so in "reply". A language named for the voice is a dub \
    (dub plus dubLanguage). The part of the request that says which moments or topics to pick goes into \
    aiInstructions, in the user's words, without the settings already applied. Choose \
    \(findHighlightsAction) only when the request asks to find, make, build or generate the reel now; \
    otherwise leave "action" null so the user reviews the form first. Leave out settings the request \
    does not mention.
    """

    /// Full wizard: `targetDurationSeconds`, `addCaptions`, `includeHeadline`,
    /// `formatPreset`, `aiInstructions`.
    static var fullSettings: [AssistantSetting] {
        [AssistantSetting("targetDurationSeconds", "Target duration (seconds)", .integer(WizardDefaults.customDurationRange)),
         AssistantSetting("addCaptions", "Captions", .bool),
         AssistantSetting("includeHeadline", "Headline and outro branding", .bool),
         AssistantSetting("formatPreset", "Recipe", .choice(ReelRecipe.all.map(\.id)),
                          choiceLabels: Dictionary(ReelRecipe.all.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })),
         AssistantSetting("aiInstructions", "AI instructions", .text(maxLength: instructionsLimit))]
    }

    @MainActor
    func assistSettings(store: AppStore) -> [AssistantSetting] {
        guard store.wizardMode == .express else { return Self.fullSettings }
        let snapshot = expressSnapshot(store: store)
        let source = snapshot.sourceName.flatMap { name in store.videos.first { $0.filename == name } }
        return Self.expressSettings(profile: store.activeProfile,
                                    overlays: OverlayTemplateStore.list().filter { !$0.composition.isEmpty }.map(\.name),
                                    sourceType: source?.type, dubVoices: store.dubVoicesForAssistant,
                                    dubLanguage: snapshot.settings.dubLanguage)
    }

    @MainActor
    func understandingGuidance(store: AppStore) -> String? {
        store.wizardMode == .express ? Self.expressGuidance : nil
    }

    @MainActor
    func apply(settings: [String: String], store: AppStore) -> AskAIOutcome {
        if store.isWizardRunning { return .unavailable("The Wizard is already working.") }
        if store.wizardMode == .express {
            // Express keeps its settings in the form's state: the form applies it.
            return store.assistant.sendSettings(settings, namespace: "express", message: "Updated Express settings.")
        }
        Self.applyFull(settings)
        return .handled("Updated the Wizard's settings.")
    }

    /// The full Wizard's settings are its @AppStorage keys, so writing them
    /// here is what its own controls do; the form follows.
    static func applyFull(_ patch: [String: String], defaults: UserDefaults = .standard) {
        for (key, value) in patch {
            let on = value == AssistantSetting.true
            switch key {
            case "targetDurationSeconds":
                // The whitelist already refuses values outside the page's
                // range; clamp anyway so this matches the Stepper exactly.
                guard let seconds = Int(value) else { continue }
                defaults.set(WizardDurationMode.custom.rawValue, forKey: WizardDefaults.durationModeKey)
                defaults.set(WizardDefaults.clampedCustomDuration(seconds), forKey: WizardDefaults.customDurationKey)
            case "addCaptions":
                let current = WizardTextMode(rawValue: defaults.string(forKey: WizardDefaults.textModeKey) ?? "") ?? .automatic
                let headlines = current == .headlines || current == .both
                let mode: WizardTextMode = on ? (headlines ? .both : .captions) : (headlines ? .headlines : .none)
                defaults.set(mode.rawValue, forKey: WizardDefaults.textModeKey)
            case "includeHeadline":
                defaults.set((on ? WizardBrandingOverride.standard : .minimal).rawValue,
                             forKey: WizardDefaults.brandingOverrideKey)
            case "formatPreset":
                defaults.set(value, forKey: "wizard.formatPreset")
            case "aiInstructions":
                defaults.set(value, forKey: "wizard.aiInstructions")
            default:
                continue
            }
        }
    }

    /// Express: the same writes as its own controls, on the form's state.
    static func applyExpress(_ patch: [String: String], settings: inout MiniWizardSettings,
                             length: inout MiniWizardFlow.Length, instructions: inout String?) {
        var kind = MiniWizardFlow.FootageKind.highlights
        applyExpress(patch, settings: &settings, length: &length, instructions: &instructions, footageKind: &kind)
    }

    /// Every whitelisted key into the form's state; "default" clears a
    /// choice back to the card's own default.
    static func applyExpress(_ patch: [String: String], settings: inout MiniWizardSettings,
                             length: inout MiniWizardFlow.Length, instructions: inout String?,
                             footageKind: inout MiniWizardFlow.FootageKind) {
        func optional(_ value: String) -> String? { value == defaultChoice || value.isEmpty ? nil : value }
        for (key, value) in patch {
            if let toggle = expressToggles.first(where: { $0.field == key }) {
                settings[keyPath: toggle.keyPath] = value == AssistantSetting.true
                continue
            }
            let on = value == AssistantSetting.true
            switch key {
            case "footageKind": if let wanted = MiniWizardFlow.FootageKind(rawValue: value) { footageKind = wanted }
            case "length": if let wanted = MiniWizardFlow.Length(rawValue: value) { length = wanted }
            case "quality": if let wanted = EncodeQuality(rawValue: value) { settings.quality = wanted }
            case "canvas": if let wanted = RenderPreset(rawValue: value) { settings.preset = wanted }
            case "look": settings.look = value
            case "transition": settings.transition = value
            case "framing": if let wanted = Framing.Subject(rawValue: value) { settings.framing.subject = wanted }
            case "captionPosition": settings.captionPosition = optional(value)
            case "captionStyle": settings.captionStyleID = optional(value)
            case "captionLanguage": settings.englishCaptions = value == "english"
            case "nameTagPosition": settings.nameTagPosition = optional(value)
            case "nameTagStyle": settings.nameTagStyleID = optional(value)
            case "watermarkDesign": settings.watermarkOverlay = optional(value)
            case "watermarkOpacity": if let percent = Int(value) { settings.watermarkOpacity = Double(percent) / 100 }
            case "overlayDesign":
                // As the card's picker: a new design starts from its own
                // texts and placements, never the previous design's.
                settings.overlayTemplate = optional(value)
                settings.overlayTexts = []
                settings.overlayEdits = OverlayEdits()
            case "muteSourceAudio": settings.muteSourceAudio = on
            case "music": settings.music = on
            case "dub": settings.dub = on
            case "dubLanguage": settings.dubLanguage = optional(value)
            case "aiInstructions": instructions = value
            default: continue
            }
        }
    }
}
