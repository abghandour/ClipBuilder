import Foundation

nonisolated struct BuilderAssistant: PageAssistant {
    let page = "Builder"
    let examples = ["Put a duck face on the fighter on the left", "Add a crown sticker", "Make a 30-second reel"]

    enum Route: Equatable, Sendable {
        case image(String)
        case wizard(String)
    }

    /// An image request starts with a making verb and names a sticker, image
    /// or picture outright, or names a prop (face, hat, crown…) without also
    /// talking about a reel, video or clip. "Make a reel of the face off" is
    /// a reel; "Add a sticker to the clip" is an image.
    static func route(_ text: String) -> Route {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        guard matches(#"(?i)^(add|put|give|draw|generate|make)\b"#) else { return .wizard(text) }
        if matches(#"(?is)\b(sticker|image|picture)\b"#) { return .image(text) }
        let namesProp = matches(#"(?is)\b(face|hat|nose|glasses|crown|beak|mask)\b"#)
        let aboutFootage = matches(#"(?is)\b(reels?|videos?|clips?|timeline|highlights?|cut|edit|montage)\b"#)
        return namesProp && !aboutFootage ? .image(text) : .wizard(text)
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        guard store.openTimelineID != nil else { return .unavailable("Open a timeline first.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable("Describe what you want to make.")
        }
        switch Self.route(text) {
        case .image(let prompt):
            store.builder.pendingGenerateImagePrompt = prompt
            return .handled("Choose a face and generate the image.")
        case .wizard(let request):
            if store.builderWizard?.identityMatches != true {
                store.builderWizard?.dismiss()
                store.builderWizard = WizardSheetModel(store: store)
            }
            guard let wizard = store.builderWizard, !wizard.busy,
                  !store.jobs.hasLiveTask(kind: .builderAssistant) else {
                return .unavailable("The Builder Wizard is already working.")
            }
            wizard.request = request
            store.builder.pendingAssistantWizard = UUID()
            store.jobs.start(.builderAssistant, title: "Builder — Ask AI", project: store.activeProject,
                             profileGeneration: store.profileGeneration,
                             subjectID: "builder-assistant-\(store.openTimelineID ?? 0)") { _ in
                try Task.checkCancellation()
                guard wizard.identityMatches else { throw CancellationError() }
                await withTaskCancellationHandler {
                    await wizard.run()
                } onCancel: {
                    Task { @MainActor in wizard.cancelRun() }
                }
                return nil
            }
            return .started(jobTitle: "Builder Wizard")
        }
    }

    // MARK: - Context

    /// What the open timeline holds that the context line and the rules use.
    struct Snapshot: Equatable, Sendable {
        var timelineName: String?
        var durationSeconds: Double = 0
        var clipCount = 0
        var trackCount = 1
        /// Some clip draws captions once per-clip overrides are resolved
        /// (`captionsVisible`).
        var captionsOn = false
        var captionPosition: String?
        var captionStyle: String?
        var musicCount = 0
        var brandLayers = 0
        var reviewFlags = 0
        /// Accepted cleanup cuts in this timeline at its current revision,
        /// as `BuilderCleanupCutsPublisher` counted them; nil = not counted yet.
        var cleanupCuts: Int?
        var speechPolish = false
        /// A clip's source is talk: it has a transcript, or it is a podcast or interview.
        var hasSpeech = false
        var hasTranscript = false
    }

    /// Page-state keys for the cleanup count: the count, and the timeline
    /// and document revision it was counted for (`cleanupCutsKey`). The
    /// count is read only while the key matches the open document, so an
    /// edit or another timeline never shows a stale count.
    static let cleanupCutsCount = "cleanupCuts"
    static let cleanupCutsFor = "cleanupCuts.for"

    static func cleanupCutsKey(timelineID: Int64?, revision: Int) -> String { "\(timelineID ?? 0)@\(revision)" }

    /// The count published for exactly this timeline and revision, else nil.
    static func cleanupCuts(in state: AssistantPageState, timelineID: Int64?, revision: Int) -> Int? {
        guard state.values[cleanupCutsFor] == cleanupCutsKey(timelineID: timelineID, revision: revision) else { return nil }
        return state.counts[cleanupCutsCount]
    }

    static func cleanupCutsState(_ count: Int, timelineID: Int64?, revision: Int) -> AssistantPageState {
        AssistantPageState(counts: [cleanupCutsCount: count],
                           values: [cleanupCutsFor: cleanupCutsKey(timelineID: timelineID, revision: revision)])
    }

    // MARK: - Captions

    /// The caption a clip draws once its override is resolved the way the
    /// renderer does it: "inherit" takes its track's setting.
    static func resolvedCaptions(_ clip: TimelineClip, in document: TimelineDocument) -> String {
        clip.captions == "inherit" ? (document.trackSettings[safe: clip.track]?.captions ?? "none") : clip.captions
    }

    /// True when some main-track or visible-track clip draws captions.
    /// Wizard clips carry an explicit "none" when captions were off, so a
    /// track setting alone does not make them visible.
    static func captionsVisible(_ document: TimelineDocument) -> Bool {
        document.videoTrack.contains { clip in
            !clip.bumper && clip.track < max(1, document.trackCount) && resolvedCaptions(clip, in: document) != "none"
        }
    }

    /// "Turn on captions": track 1 shows them at `position` when it shows
    /// none, and every main-track clip that switches them off itself (the
    /// Wizard writes "none" per clip) follows the track again. Bumpers and
    /// cutaways keep theirs, as the Wizard leaves them uncaptioned.
    static func turningCaptionsOn(_ document: TimelineDocument, position: String = "bottom") -> TimelineDocument {
        var updated = document
        if !updated.trackSettings.isEmpty, updated.trackSettings[0].captions == "none" {
            updated.trackSettings[0].captions = position
        }
        for index in updated.videoTrack.indices {
            let clip = updated.videoTrack[index]
            guard clip.track == 0, !clip.bumper, !clip.isCutaway, clip.captions == "none" else { continue }
            updated.videoTrack[index].captions = "inherit"
        }
        return updated
    }

    static func durationLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func context(_ s: Snapshot) -> AssistantContext {
        let flag = { (on: Bool) in on ? "yes" : "no" }
        let facts = [
            AssistantFact("timeline", "Timeline", s.timelineName ?? "none"),
            AssistantFact("duration", "Duration", durationLabel(s.durationSeconds)),
            AssistantFact("clips", "Clips", s.clipCount),
            AssistantFact("tracks", "Video tracks", s.trackCount),
            AssistantFact("music", "Music items", s.musicCount),
            AssistantFact("brandLayers", "Brand layers", s.brandLayers),
            AssistantFact("reviewFlags", "Review flags", s.reviewFlags),
            AssistantFact("cleanupCuts", "Accepted cleanup cuts", s.cleanupCuts.map(String.init) ?? "unknown"),
            AssistantFact("speech", "Speech in footage", flag(s.hasSpeech)),
            AssistantFact("transcript", "Transcript", flag(s.hasTranscript)),
        ]
        var settings = [AssistantFact("captions", "Captions", on: s.captionsOn)]
        if let position = s.captionPosition { settings.append(AssistantFact("captionPosition", "Caption position", position)) }
        if let style = s.captionStyle { settings.append(AssistantFact("captionStyle", "Caption style", style)) }
        settings.append(AssistantFact("speechPolish", "Speech Polish", on: s.speechPolish))
        var summary = [s.timelineName ?? "No timeline open"]
        if s.timelineName != nil {
            summary += [durationLabel(s.durationSeconds), s.clipCount == 1 ? "1 clip" : "\(s.clipCount) clips",
                        "captions \(s.captionsOn ? "on" : "off")"]
            if s.reviewFlags > 0 { summary.append(s.reviewFlags == 1 ? "1 flag" : "\(s.reviewFlags) flags") }
        }
        return AssistantContext(page: "Builder", facts: facts, settings: settings, summary: summary)
    }

    @MainActor
    func snapshot(store: AppStore) -> Snapshot {
        var s = Snapshot()
        guard let timelineID = store.openTimelineID else { return s }
        let model = store.builder
        let document = model.document
        s.timelineName = store.openTimeline?.name ?? "Timeline"
        s.durationSeconds = model.totalDuration
        s.clipCount = document.videoTrack.count
        s.trackCount = document.trackCount
        s.captionsOn = Self.captionsVisible(document)
        s.captionPosition = document.captionPosition
        s.captionStyle = document.captionStyleID.flatMap { id in
            (store.activeProfile.captionStyles ?? []).first { $0.id.uuidString == id }?.name ?? id
        }
        s.musicCount = document.soundTrack.count
        s.brandLayers = document.brandLayers?.count ?? 0
        s.reviewFlags = model.reviewFlags.count
        s.cleanupCuts = Self.cleanupCuts(in: store.assistant.state(page), timelineID: timelineID, revision: model.revision)
        s.speechPolish = document.renderSettings.speechPolish?.enabled == true
        let videoIDs = store.builderVideoIDs()
        s.hasTranscript = videoIDs.contains { (store.transcriptCounts[$0] ?? 0) > 0 }
        s.hasSpeech = s.hasTranscript || store.videos.contains {
            videoIDs.contains($0.id) && ($0.type == .podcast || $0.type == .interview)
        }
        return s
    }

    @MainActor
    func context(store: AppStore) -> AssistantContext { Self.context(snapshot(store: store)) }

    // MARK: - Suggestions

    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        guard context.value("timeline") != "none" else { return [] }
        var rows: [AssistantSuggestion] = []
        if let flags = context.int("reviewFlags"), flags > 0 {
            rows.append(.init(id: "builder.flags.review", kind: .action,
                              title: flags == 1 ? "Check the flagged moment" : "Check \(flags) flagged moments",
                              reason: flags == 1 ? "The pipeline was unsure about one moment of this video"
                                  : "The pipeline was unsure about \(flags) moments of this video",
                              actionID: "builder.flags.jump"))
        }
        if let cuts = context.int("cleanupCuts"), cuts > 0 {
            rows.append(.init(id: "builder.cleanup.apply", kind: .action, title: "Apply cleanup cuts",
                              reason: cuts == 1 ? "1 accepted filler or pause cut is waiting"
                                  : "\(cuts) accepted filler, stutter and pause cuts are waiting",
                              actionID: "builder.cleanup.apply"))
        }
        if context.value("speech") == "yes", context.isOff("speechPolish") {
            rows.append(.init(id: "builder.polish.on", kind: .setting, title: "Turn on Speech Polish",
                              reason: "This timeline has speech and Speech Polish is off",
                              actionID: "builder.polish.on"))
        }
        if context.value("transcript") == "yes", context.isOff("captions") {
            rows.append(.init(id: "builder.captions.on", kind: .setting, title: "Turn on captions",
                              reason: "The footage has a transcript and no track shows captions",
                              actionID: "builder.captions.on"))
        }
        return rows
    }

    // MARK: - Actions

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        let open: @MainActor @Sendable (AppStore) -> Bool = { $0.openTimelineID != nil }
        let firstFlagIcon = store.builder.reviewFlags.first.map { ReviewFlagsInspector.icon(for: $0.kind) }
            ?? "exclamationmark.triangle"
        return [
            AssistantAction(id: "builder.flags.jump", title: "Jump to the first review flag", systemImage: firstFlagIcon,
                            isAvailable: { $0.openTimelineID != nil && !$0.builder.reviewFlags.isEmpty }) { store in
                guard let flag = store.builder.reviewFlags.first else { return .unavailable("No review flags left.") }
                store.builder.jump(to: flag)
                return .handled("Jumped to \(ReviewFlagBuilder.timeLabel(flag.time)). The Review section lists the rest.")
            },
            AssistantAction(id: "builder.cleanup.apply", title: "Apply cleanup cuts", systemImage: "scissors",
                            isAvailable: { $0.openTimelineID != nil && !$0.isBuilderRendering }) { store in
                Task { await store.applyAcceptedCleanupCuts() }
                return .handled("Applying cleanup cuts. Undo puts them back.")
            },
            AssistantAction(id: "builder.polish.on", title: "Turn on Speech Polish", systemImage: "slider.horizontal.3",
                            isAvailable: open) { store in
                var render = store.builder.document.renderSettings
                var polish = render.speechPolish ?? SpeechPolishSettings(enabled: false)
                polish.enabled = true
                render.speechPolish = polish
                store.builder.setRenderSettings(render)
                return .handled("Speech Polish is on for exports.")
            },
            AssistantAction(id: "builder.captions.on", title: "Turn on captions", systemImage: SidebarSection.captions.systemImage,
                            isAvailable: open) { store in
                guard store.builder.turnOnCaptions() else {
                    return Self.captionsVisible(store.builder.document)
                        ? .handled("Captions are already on.")
                        : .unavailable("No clip on track 1 can show captions.")
                }
                return .handled("Captions on for track 1. Undo turns them off again.")
            },
        ]
    }
}
