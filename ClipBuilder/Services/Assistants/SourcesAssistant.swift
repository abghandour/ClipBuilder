import Foundation

/// Ask AI on Sources (AnalyzeView). Missing-step counts come from the page's
/// own "Analyze missing steps" footer through its published state; the
/// actions are the page's footer, preview and toolbar controls.
nonisolated struct SourcesAssistant: PageAssistant {
    static let pageName = "Sources"
    let page = Self.pageName
    let examples = ["Analyze everything that is missing",
                    "Transcribe the sources without a transcript",
                    "Suggest better file names for the selected videos"]

    struct Snapshot: Equatable, Sendable {
        var sourceCount = 0
        var presentCount = 0
        var transcribedCount = 0
        /// Files on this Mac with any missing or outdated step (the footer).
        var missingFiles = 0
        /// `AnalysisSteps.Step` raw value → files missing that step.
        var missingSteps: [String: Int] = [:]
        /// Sources whose length matches another source's within a second.
        var durationTwins = 0
        /// Sources still named like a camera file (IMG_1234, C0001, …).
        var cameraNamed = 0
        var selected: [String] = []
        var selectedCount = 0
        /// The previewed source is fight footage (research and story apply).
        var selectedIsFight = false
        var sort = "default"
    }

    // MARK: - Pure helpers

    /// How many durations sit within `tolerance` seconds of another one.
    static func durationTwins(_ durations: [Double], tolerance: Double = 1) -> Int {
        let sorted = durations.filter { $0 > 0 }.sorted()
        guard sorted.count > 1 else { return 0 }
        var count = 0
        for (index, value) in sorted.enumerated() {
            let before = index > 0 && value - sorted[index - 1] <= tolerance
            let after = index < sorted.count - 1 && sorted[index + 1] - value <= tolerance
            if before || after { count += 1 }
        }
        return count
    }

    private static let cameraPattern =
        #"^((dscf|dscn|dsc|img|mvi|gopr|gx|gh|gp|pxl|vid|mov|dji|clip|c)[_-]?\d{3,}|\d{8}[_-]\d{6}|screen recording)"#

    /// True for names a camera or phone gave the file.
    static func isCameraName(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension
        return stem.range(of: cameraPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Context

    static func context(_ s: Snapshot) -> AssistantContext {
        var facts = [
            AssistantFact("sources", "Sources", s.sourceCount),
            AssistantFact("present", "On this Mac", s.presentCount),
            AssistantFact("transcribed", "Transcribed", s.transcribedCount),
            AssistantFact("missing.files", "Files missing steps", s.missingFiles),
        ]
        for step in AnalysisSteps.Step.allCases {
            facts.append(AssistantFact("missing.\(step.rawValue)", "Missing: \(step.title)", s.missingSteps[step.rawValue] ?? 0))
        }
        facts += [AssistantFact("duplicates", "Same-length sources", s.durationTwins),
                  AssistantFact("names.camera", "Camera file names", s.cameraNamed),
                  AssistantFact("selected", "Selected", s.selectedCount),
                  AssistantFact("selected.fight", "Selected is fight footage", on: s.selectedIsFight)]
        var summary = [AssistantText.count(s.sourceCount, "source")]
        if s.missingFiles > 0 { summary.append("\(s.missingFiles) need analysis") }
        if s.selectedCount > 0 { summary.append("\(s.selectedCount) selected") }
        return AssistantContext(page: pageName, facts: facts, settings: [AssistantFact("sort", "Sort", s.sort)],
                                selection: s.selectedCount > 0 ? s.selected : [], summary: summary)
    }

    @MainActor
    func snapshot(store: AppStore) -> Snapshot {
        let state = store.assistant.state(page)
        var s = Snapshot()
        s.sourceCount = store.videos.count
        s.presentCount = store.videos.count(where: \.isPresent)
        s.transcribedCount = store.videos.count { (store.transcriptCounts[$0.id] ?? 0) > 0 }
        s.missingFiles = state.count("missing.files")
        for step in AnalysisSteps.Step.allCases { s.missingSteps[step.rawValue] = state.count("missing.\(step.rawValue)") }
        s.durationTwins = Self.durationTwins(store.videos.map(\.duration))
        s.cameraNamed = store.videos.count { Self.isCameraName($0.filename) }
        s.selectedCount = state.count("selected")
        s.selected = state.selection ?? []
        s.selectedIsFight = state.flag("selected.fight")
        s.sort = state.value("sort") ?? "default"
        return s
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        var context = Self.context(snapshot(store: store))
        if let summary = LanguageReadiness.summary(store.languageAssets) {
            context.facts.append(AssistantFact("languages.missing", "Languages on this Mac", summary))
        }
        context.fingerprint = AssistantContext.fingerprint(page: context.page, subpage: context.subpage,
            facts: context.facts, settings: context.settings, selection: context.selection)
        return context
    }

    // MARK: - Suggestions

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        var rows: [AssistantSuggestion] = []
        if let summary = context.value("languages.missing") {
            rows.append(.init(id: "languages.missing", kind: .insight, title: "Project languages need setup",
                              reason: summary, actionID: "languages.install"))
        }
        let sources = context.int("sources") ?? 0
        if sources == 0 {
            rows.append(.init(id: "sources.add.none", kind: .action, title: "Add source videos",
                              reason: "This project has no sources yet", actionID: "sources.add"))
            return rows
        }
        let noScenes = context.int("missing.\(AnalysisSteps.Step.scenes.rawValue)") ?? 0
        if noScenes > 0 {
            rows.append(.init(id: "sources.analyze.missing", kind: .action, title: "Analyze missing steps",
                              reason: "\(AssistantText.count(noScenes, "source")) \(noScenes == 1 ? "has" : "have") no scenes yet",
                              actionID: "sources.analyze.missing"))
        }
        let noTranscript = context.int("missing.\(AnalysisSteps.Step.transcript.rawValue)") ?? 0
        if noTranscript > 0 {
            rows.append(.init(id: "sources.transcribe.missing", kind: .action, title: "Transcribe",
                              reason: "\(AssistantText.count(noTranscript, "source")) with speech \(noTranscript == 1 ? "has" : "have") no transcript",
                              actionID: "sources.transcribe.missing"))
        }
        let unnamed = context.int("missing.\(AnalysisSteps.Step.speakerNames.rawValue)") ?? 0
        if unnamed > 0 {
            rows.append(.init(id: "sources.speakers.unnamed", kind: .action, title: "Name speakers",
                              reason: "\(AssistantText.count(unnamed, "transcript")) \(unnamed == 1 ? "has" : "have") speakers without names",
                              actionID: "sources.speakers.name"))
        }
        let twins = context.int("duplicates") ?? 0
        if twins >= 2 {
            rows.append(.init(id: "sources.duplicates.scan", kind: .action, title: "Scan for duplicates",
                              reason: "\(twins) sources share a length within a second",
                              actionID: "sources.duplicates.scan"))
        }
        let camera = context.int("names.camera") ?? 0
        if camera > 0 {
            rows.append(.init(id: "sources.names.messy", kind: .action, title: "Suggest file names",
                              reason: "\(AssistantText.count(camera, "source")) still \(camera == 1 ? "has" : "have") a camera file name",
                              actionID: "sources.names.suggest"))
        }
        return rows
    }

    // MARK: - Actions

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let page = page
        // The footer's "Analyze N steps" guard: a batch started while people
        // detection (or transcription, scoring, speaker mapping) runs would
        // skip those steps and never retry them.
        let idle: @MainActor @Sendable (AppStore) -> Bool = { !$0.isMissingStepsBatchBusy }
        let selected: @MainActor @Sendable (AppStore) -> Bool = { $0.assistant.state(page).count("selected") > 0 }
        let fight: @MainActor @Sendable (AppStore) -> Bool = { $0.assistant.state(page).flag("selected.fight") }
        return [
            AssistantAction(id: "languages.install", title: "Install Project Languages", systemImage: "arrow.down.circle",
                            isAvailable: { $0.activeProject != nil }) { store in
                store.selectSection(.sources)
                store.installLanguageAssets()
                return .started(jobTitle: "Language Assets")
            },
            .command("sources.add", "Add Videos", "plus", message: "Choose videos to add."),
            .command("sources.analyze.missing", "Analyze missing steps", "sparkles",
                     message: "Analyzing every missing step.", available: idle),
            .command("sources.transcribe.missing", "Transcribe", "text.quote",
                     message: "Transcribing the sources without a transcript.", available: idle),
            .command("sources.speakers.name", "Name speakers", "person.2.fill",
                     message: "Naming speakers.", available: idle),
            .command("sources.duplicates.scan", "Scan for duplicates", "rectangle.on.rectangle",
                     message: "Opened the duplicate scan."),
            .command("sources.names.suggest", "File Name Wizard", "wand.and.sparkles",
                     message: "Opened the File Name Wizard."),
            .command("sources.wizard.open", "Generate with AI Wizard", "wand.and.stars",
                     message: "Opened the AI Wizard on the selection.", available: selected),
            .command("sources.fight.research", "Fight Research", "text.magnifyingglass",
                     message: "Opened Fight Research.", available: fight),
            .command("sources.fight.story", "Fight Story", "text.magnifyingglass",
                     message: "Opened Fight Story.", available: fight),
            .command("sources.soundbites", "Find Soundbites", "text.quote",
                     message: "Opened Find Soundbites.", available: selected),
        ]
    }

    // MARK: - Free text

    /// Keyword routing to an action id; nil when nothing matches.
    static func route(_ text: String) -> String? {
        let t = AssistantText.normalized(text)
        if t.isEmpty { return nil }
        if AssistantText.mentions(t, ["language", "recognizer", "translation pack"]) { return "languages.install" }
        if AssistantText.mentions(t, ["duplicate", "copies", "same video"]) { return "sources.duplicates.scan" }
        if AssistantText.mentions(t, ["file name", "filename", "rename", "better name"]) { return "sources.names.suggest" }
        if AssistantText.mentions(t, ["speaker", "who is talking", "who's talking"]) { return "sources.speakers.name" }
        if AssistantText.mentions(t, ["transcri"]) { return "sources.transcribe.missing" }
        if AssistantText.mentions(t, ["soundbite", "quote"]) { return "sources.soundbites" }
        if AssistantText.mentions(t, ["fight story", "story"]) { return "sources.fight.story" }
        if AssistantText.mentions(t, ["research", "fan reaction"]) { return "sources.fight.research" }
        if AssistantText.mentions(t, ["analy", "missing", "scene"]) { return "sources.analyze.missing" }
        if AssistantText.mentions(t, ["wizard", "generate", "reel", "make a video"]) { return "sources.wizard.open" }
        if AssistantText.mentions(t, ["add", "import"]) { return "sources.add" }
        return nil
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.run(Self.route(text), actions: actions(store: store), store: store,
                          fallback: AssistantText.unrecognized(page: page, examples: examples))
    }
}
