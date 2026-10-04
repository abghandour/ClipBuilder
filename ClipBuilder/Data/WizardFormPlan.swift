import Foundation

/// Pure form policy. Persisted choices survive switching recipes; only the
/// controls and the options dispatched to the engine change.
nonisolated struct WizardFormPlan: Sendable {
    let capabilities: ReelRecipe.Capabilities

    init(recipe: ReelRecipe) {
        capabilities = recipe.capabilities
    }

    enum Control: String, CaseIterable, Sendable {
        case sources, outcome, recipe, length, brief, styleReference, fightResearch, layouts, iteration, planningModels
        case output, pacing, audio, musicTrack, text, overlayStyle, transitions, cameraFocus, framingCamera
        case nameTags, nameTagContent, nameTagStyle, nameTagPosition
        case bRoll, bumpers, branding, presentationModels, captionPosition, captionStyle
    }

    var step1Controls: Set<Control> {
        var controls: Set<Control> = [.sources, .outcome, .recipe, .length, .brief, .planningModels]
        if capabilities.styleReference { controls.insert(.styleReference) }
        if capabilities.fightResearch { controls.insert(.fightResearch) }
        if capabilities.layouts { controls.insert(.layouts) }
        if capabilities.critiqueLoop { controls.insert(.iteration) }
        return controls
    }

    var step2Controls: Set<Control> {
        var controls: Set<Control> = [.output, .pacing, .transitions, .presentationModels]
        if capabilities.audioMusic { controls.formUnion([.audio, .musicTrack]) }
        if capabilities.onScreenText { controls.formUnion([.text, .overlayStyle, .captionPosition, .captionStyle]) }
        if capabilities.offersCameraFocus { controls.formUnion([.nameTags, .nameTagContent, .nameTagStyle, .nameTagPosition]) }
        if capabilities.offersCameraFocus { controls.insert(.cameraFocus) }
        if capabilities.layouts { controls.insert(.framingCamera) }
        if capabilities.bRoll { controls.insert(.bRoll) }
        if capabilities.bumpers { controls.insert(.bumpers) }
        if capabilities.branding { controls.insert(.branding) }
        return controls
    }

    static func step2Collapsed(hasSelection: Bool, workflow: WizardWorkflow) -> Bool {
        !hasSelection && workflow != .automatic
    }

    var step1Models: [String] { capabilities.models.filter { $0 != "captions" && $0 != "broll" } }

    func step2Models(useBRoll: Bool, instructions: String) -> [String] {
        models(useBRoll: useBRoll, instructions: instructions).filter { $0 == "captions" || $0 == "broll" }
    }

    static func lengthHelp(recipe: ReelRecipe) -> FieldHelp {
        let help = WizardFieldHelp.length
        guard recipe.id == "podcast" else { return help }
        let exception = "A complete question and answer is kept even if it runs longer."
        return FieldHelp(help.tooltip + " " + exception,
                         caption: (help.caption.map { $0 + " " } ?? "") + exception)
    }

    static func outcome(recipe: ReelRecipe, critiqueLoop: Bool) -> ReelRecipe.Workflow {
        recipe.workflow == .highlights ? .highlights : (critiqueLoop ? .iterate : .oneReel)
    }

    static func applyingOutcome(_ outcome: ReelRecipe.Workflow, to options: WizardOptions) -> WizardOptions {
        var options = options
        options.critiqueLoop = outcome == .iterate
        return options
    }

    static func showsCriticBriefControls(outcome: ReelRecipe.Workflow) -> Bool {
        outcome == .iterate
    }

    /// Ordinary runs retain their live filters (and any explicit pasted
    /// restriction). Only an idea match pins an exact set of scene IDs.
    func applyingIdeaSources(to options: WizardOptions, proposedSceneIDs: Set<Int64>?) -> WizardOptions {
        guard capabilities.sources == .scenes, let proposedSceneIDs else { return options }
        var options = options
        options.sourcesRestricted = true
        options.sourceSceneSelection = true
        options.sourceSceneIDs = proposedSceneIDs
        options.sourceVideoPaths = []
        return options
    }

    /// Keep the library's order within each group, with usable recordings
    /// first so the default is ready for highlights whenever possible.
    static func podcastHighlightVideos(videos: [VideoRecord], scenes: [SceneRecord]) -> [VideoRecord] {
        let exchangeVideoIDs = Set(scenes.filter {
            !$0.excluded && !$0.ignored && $0.tags.contains("podcast-exchange")
        }.map(\.videoID))
        return videos.filter { exchangeVideoIDs.contains($0.id) }
            + videos.filter { !exchangeVideoIDs.contains($0.id) }
    }

    /// Capturing the config shares its value storage; comparisons inspect
    /// only dispatch inputs, without serializing it during body evaluation.
    struct ProviderAvailabilityKey: Equatable {
        let task: String
        let config: AIConfig

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.task == rhs.task
                && lhs.config.tasks == rhs.config.tasks
                && lhs.config.taskModels == rhs.config.taskModels
                && lhs.config.providerCooldownMinutes == rhs.config.providerCooldownMinutes
                && lhs.config.providers.count == rhs.config.providers.count
                && lhs.config.providers.allSatisfy { key, provider in
                    guard let other = rhs.config.providers[key] else { return false }
                    return provider.bin == other.bin && provider.model == other.model
                }
        }
    }

    /// A video's scenes are in the pool while the run uses every batch, or
    /// while one of its batches is among the chosen ones.
    static func videoContributes(runIDs: [Int64], limitToSelection: Bool, selectedRunIDs: Set<Int64>) -> Bool {
        !limitToSelection || runIDs.contains(where: selectedRunIDs.contains)
    }

    /// Clicking a thumbnail in the footage grid. Deselecting a video while
    /// every batch is in use narrows the run to the newest batch of each
    /// other video; selecting adds the video's newest batch back. Every
    /// video off leaves the batch limit on with nothing chosen, so the
    /// readiness row can say so instead of silently using everything.
    static func togglingVideo(runIDs: [Int64], newestRunID: Int64?, allRunsByVideo: [Int64: [Int64]],
                              limitToSelection: Bool, selectedRunIDs: Set<Int64>)
        -> (limitToSelection: Bool, selectedRunIDs: Set<Int64>) {
        let contributes = videoContributes(runIDs: runIDs, limitToSelection: limitToSelection,
                                           selectedRunIDs: selectedRunIDs)
        if !limitToSelection {
            // Narrow from "everything" to everyone but this one.
            let others = allRunsByVideo.values.flatMap { $0 }.filter { !runIDs.contains($0) }
            return (true, Set(others))
        }
        var selected = selectedRunIDs
        if contributes {
            selected.subtract(runIDs)
        } else if let newestRunID {
            selected.insert(newestRunID)
        }
        return (true, selected)
    }

    enum RecoveryAction: String, Sendable {
        case sources = "Open Sources"
        case analyze = "Analyze"
        case aiSettings = "AI settings"
    }

    enum Readiness: Equatable, Sendable {
        case ok
        case warning(message: String, action: RecoveryAction)

        var isBlocking: Bool {
            if case .warning = self { return true }
            return false
        }
    }

    /// `pool` is the effective engine-eligible selection. Transcript IDs must
    /// come from original transcript rows, never an analysis timestamp.
    func readiness(pool: [SceneRecord], videos: [VideoRecord], transcripts: Set<Int64>,
                   selectedVideoPath: String = "", limitToSelection: Bool = false,
                   selectedRunIDs: Set<Int64> = [], favoritesOnly: Bool = false,
                   providerIssue: String? = nil) -> [Readiness] {
        var items: [Readiness] = []
        if videos.isEmpty {
            items.append(.warning(message: "This project has no sources", action: .sources))
        } else if capabilities.sources == .podcastRecording {
            if let video = videos.first(where: { $0.path == selectedVideoPath }) {
                if !transcripts.contains(video.id) {
                    items.append(.warning(message: "Transcript required", action: .analyze))
                }
                if !pool.contains(where: { $0.videoID == video.id && !$0.excluded && !$0.ignored && $0.tags.contains("podcast-exchange") }) {
                    items.append(.warning(message: "No exchanges analyzed yet", action: .analyze))
                }
            } else {
                items.append(.warning(message: "Choose a recording", action: .sources))
            }
        } else if limitToSelection && selectedRunIDs.isEmpty {
            items.append(.warning(message: "Choose at least one Analyze batch", action: .sources))
        } else if pool.isEmpty {
            items.append(.warning(message: favoritesOnly ? "No favorites in this selection" : "No usable scenes in this selection",
                                  action: favoritesOnly ? .sources : .analyze))
        }
        if let providerIssue { items.append(.warning(message: providerIssue, action: .aiSettings)) }
        return items.isEmpty ? [.ok] : items
    }

    func runSummary(sceneCount: Int, source: String, targetSeconds: Int?,
                    highlightCount: Int, highlightSeconds: Double, captions: Bool,
                    critique: Bool, selectionReview: Bool,
                    critiqueTargetScore: Int = 85, critiqueMaxVersions: Int = 3) -> String {
        if capabilities.sources == .podcastRecording {
            let count = highlightCount > 0 ? "Up to \(highlightCount) highlights" : "Highlights with no count limit"
            return "\(count), up to \(Int(highlightSeconds))s each, from \(source), reviewed before render"
        }
        let length = targetSeconds.map { "\($0)s " } ?? ""
        var summary = "One \(length)reel from \(sceneCount) scenes" + (source.isEmpty ? "" : " \(source)")
        if capabilities.critiqueLoop && critique {
            summary += ", up to \(critiqueMaxVersions) takes until the critic scores \(critiqueTargetScore)+"
        } else if capabilities.onScreenText { summary += captions ? ", captions on" : ", captions off" }
        if capabilities.selectionReview && selectionReview { summary += ", cuts reviewed before render" }
        return summary
    }

    static func recipeForSceneHandoff(current: ReelRecipe, lastSceneRecipeID: String) -> ReelRecipe {
        guard current.capabilities.sources != .scenes else { return current }
        guard let previous = ReelRecipe.recipe(id: lastSceneRecipeID),
              previous.capabilities.sources == .scenes else { return .custom }
        return previous
    }

    func models(useBRoll: Bool, instructions: String) -> [String] {
        capabilities.models + (capabilities.bRoll && useBRoll
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ["broll"] : [])
    }

    var primaryTask: String { capabilities.sources == .podcastRecording ? "highlights" : "wizard" }

    var unsupportedOptions: [String] {
        var names: [String] = []
        if !capabilities.onScreenText { names.append("captions") }
        if !capabilities.audioMusic { names.append("music") }
        if !capabilities.branding { names.append("branding") }
        if !capabilities.layouts { names.append("layouts") }
        if !capabilities.bumpers { names.append("bumpers") }
        if !capabilities.critiqueLoop { names.append("quality variants") }
        return names
    }

    func editingSummary(audio: WizardAudioMode, captions: Bool, headlines: Bool,
                        critique: Bool, branding: String, useBRoll: Bool) -> String {
        var parts: [String] = []
        if capabilities.audioMusic {
            parts.append(audio == .mix ? "Mix" : audio == .music ? "Music only" : "Original audio")
        }
        if capabilities.onScreenText {
            if captions { parts.append("Captions") }
            if headlines { parts.append("Headlines") }
            if !captions && !headlines { parts.append("No text") }
        }
        if capabilities.branding { parts.append(branding) }
        if capabilities.bRoll && useBRoll { parts.append("B-roll") }
        return parts.isEmpty ? "Plain footage" : parts.joined(separator: " · ")
    }

    var copiedTextKeys: [String] {
        (capabilities.layouts ? ["framingCamera"] : [])
            + (capabilities.referenceTemplate ? ["templateLabel"] : [])
            + (capabilities.onScreenText ? ["pinnedOverlayTemplate", "pinnedOverlayText"] : [])
    }

    var copiedToggleKeys: [String] {
        (capabilities.fightResearch ? ["useFightResearch"] : [])
            + (capabilities.branding ? ["includeWatermark", "includeHeadline", "includeOutro"] : [])
    }
}
