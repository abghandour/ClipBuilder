import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard form plan")
struct WizardFormPlanTests {
    @Test func lengthHelpExplainsThePodcastClipExceptionOnly() {
        let podcast = WizardFormPlan.lengthHelp(recipe: .podcast)
        let exception = "A complete question and answer is kept even if it runs longer."
        #expect(podcast.caption?.hasSuffix(exception) == true)
        #expect(podcast.tooltip.hasSuffix(exception))
        for recipe in [ReelRecipe.custom, .podcastHighlights] {
            let help = WizardFormPlan.lengthHelp(recipe: recipe)
            #expect(help.caption == WizardFieldHelp.length.caption)
            #expect(help.tooltip == WizardFieldHelp.length.tooltip)
        }
    }

    @Test func criticBriefControlsOnlyAppearForIterateOutcome() {
        #expect(WizardFormPlan.showsCriticBriefControls(outcome: .iterate))
        #expect(!WizardFormPlan.showsCriticBriefControls(outcome: .oneReel))
        #expect(!WizardFormPlan.showsCriticBriefControls(outcome: .highlights))
    }

    @Test func ordinarySceneRunsKeepLiveFiltersWhenCopied() throws {
        let plan = WizardFormPlan(recipe: .custom)
        var options = WizardOptions()
        options.favoritesOnly = true
        options.selectedRunIDs = [7]
        options.sourcePeople = ["guest"]
        let submitted = plan.applyingIdeaSources(to: options, proposedSceneIDs: nil)
        let copied = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(submitted))
        #expect(!copied.sourcesRestricted)
        #expect(!copied.sourceSceneSelection)
        #expect(copied.sourceSceneIDs.isEmpty)
        #expect(copied.sourceVideoPaths.isEmpty)
        #expect(copied.favoritesOnly)
        #expect(copied.selectedRunIDs == [7])
        #expect(copied.sourcePeople == ["guest"])

        // Footage analyzed after copying can still qualify for these filters.
        var later = Fixtures.scene(id: 99)
        later.runID = 7
        later.favorite = true
        later.tags = ["person:guest"]
        #expect(!copied.sourcesRestricted || copied.includesCopiedSource(later))
        #expect(copied.selectedRunIDs.contains(later.runID ?? -1) && later.favorite)
    }

    @Test func onlyIdeaMatchesReplaceExplicitSourceRestrictions() {
        let plan = WizardFormPlan(recipe: .custom)
        var pasted = WizardOptions()
        pasted.sourcesRestricted = true
        pasted.sourceVideoPaths = ["/tmp/copied.mp4"]
        let ordinary = plan.applyingIdeaSources(to: pasted, proposedSceneIDs: nil)
        #expect(ordinary.sourcesRestricted)
        #expect(!ordinary.sourceSceneSelection)
        #expect(ordinary.sourceVideoPaths == pasted.sourceVideoPaths)

        let idea = plan.applyingIdeaSources(to: pasted, proposedSceneIDs: [2, 3])
        #expect(idea.sourcesRestricted && idea.sourceSceneSelection)
        #expect(idea.sourceSceneIDs == [2, 3])
        #expect(idea.sourceVideoPaths.isEmpty)
        #expect(!idea.includesCopiedSource(Fixtures.scene(id: 99)))
        let emptyIdea = plan.applyingIdeaSources(to: pasted, proposedSceneIDs: [])
        #expect(emptyIdea.sourcesRestricted && emptyIdea.sourceSceneSelection)
        #expect(emptyIdea.sourceSceneIDs.isEmpty)
        #expect(!emptyIdea.includesCopiedSource(Fixtures.scene()))
    }

    @Test func highlightRecordingsPreferUsableExchangesAndKeepEveryVideo() {
        let videos = (1...4).map { Fixtures.video(id: Int64($0)) }
        var third = Fixtures.scene(id: 3)
        third.videoID = 3
        third.tags = ["podcast-exchange"]
        var second = third
        second.id = 2
        second.videoID = 2
        let preferred = WizardFormPlan.podcastHighlightVideos(videos: videos, scenes: [third, second])
        #expect(preferred.map(\.id) == [2, 3, 1, 4])
        #expect(preferred.first?.id == 2, "The first recording is the form's default")
        #expect(WizardFormPlan.podcastHighlightVideos(videos: videos, scenes: []).map(\.id) == [1, 2, 3, 4])
        second.excluded = true
        third.ignored = true
        #expect(WizardFormPlan.podcastHighlightVideos(videos: videos, scenes: [second, third]).map(\.id) == [1, 2, 3, 4])
        #expect(WizardFormPlan.podcastHighlightVideos(videos: [], scenes: [second]).isEmpty)
    }

    @Test func providerAvailabilityIdentityTracksDispatchInputs() {
        typealias Key = WizardFormPlan.ProviderAvailabilityKey
        var config = AIConfig()
        config.tasks["wizard"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/tmp/claude", model: "model-a")
        let original = Key(task: "wizard", config: config)
        #expect(original == Key(task: "wizard", config: config))
        #expect(original != Key(task: "highlights", config: config))
        var changed = config
        changed.tasks["wizard"] = "openai"
        #expect(original != Key(task: "wizard", config: changed))
        changed = config
        changed.taskModels["wizard"] = "model-b"
        #expect(original != Key(task: "wizard", config: changed))
        changed = config
        changed.providers["claude"]?.bin = "/tmp/other-cli"
        #expect(original != Key(task: "wizard", config: changed))
        changed = config
        changed.providers["claude"]?.model = "model-b"
        #expect(original != Key(task: "wizard", config: changed))
        changed = config
        changed.providers.removeValue(forKey: "claude")
        #expect(original != Key(task: "wizard", config: changed))
        changed = config
        changed.providerCooldownMinutes += 1
        #expect(original != Key(task: "wizard", config: changed))
        changed = config
        changed.mutedDispatchPlans = ["generate"]
        #expect(original == Key(task: "wizard", config: changed))
    }

    @Test func sceneReadinessUsesEffectiveSelection() {
        let plan = WizardFormPlan(recipe: .custom)
        let video = Fixtures.video()
        #expect(plan.readiness(pool: [Fixtures.scene()], videos: [video], transcripts: []) == [.ok])
        #expect(plan.readiness(pool: [], videos: [], transcripts: []) == [
            .warning(message: "This project has no sources", action: .sources)])
        #expect(plan.readiness(pool: [], videos: [video], transcripts: [],
            limitToSelection: true) == [.warning(message: "Choose at least one Analyze batch", action: .sources)])
        #expect(plan.readiness(pool: [], videos: [video], transcripts: [],
            favoritesOnly: true) == [.warning(message: "No favorites in this selection", action: .sources)])
        #expect(plan.readiness(pool: [], videos: [video], transcripts: []).contains { $0.isBlocking })
        #expect(plan.readiness(pool: [Fixtures.scene()], videos: [video], transcripts: [],
            providerIssue: "No AI provider is available").contains { $0.isBlocking })
    }

    @Test func highlightsRequireTheSelectedRecordingsOriginalTranscriptAndExchanges() {
        let plan = WizardFormPlan(recipe: .podcastHighlights)
        let video = Fixtures.video()
        var exchange = Fixtures.scene()
        exchange.tags = ["podcast-exchange"]
        #expect(plan.readiness(pool: [exchange], videos: [video], transcripts: [video.id],
            selectedVideoPath: video.path) == [.ok])
        #expect(plan.readiness(pool: [exchange], videos: [video], transcripts: [99],
            selectedVideoPath: video.path) == [.warning(message: "Transcript required", action: .analyze)])
        #expect(plan.readiness(pool: [], videos: [video], transcripts: [video.id],
            selectedVideoPath: video.path) == [.warning(message: "No exchanges analyzed yet", action: .analyze)])
        exchange.excluded = true
        #expect(plan.readiness(pool: [exchange], videos: [video], transcripts: [video.id],
            selectedVideoPath: video.path).contains { $0.isBlocking })
        exchange.excluded = false
        exchange.ignored = true
        #expect(plan.readiness(pool: [exchange], videos: [video], transcripts: [video.id],
            selectedVideoPath: video.path).contains { $0.isBlocking })
        #expect(plan.readiness(pool: [exchange], videos: [video], transcripts: [video.id],
            selectedVideoPath: "/missing.mp4") == [.warning(message: "Choose a recording", action: .sources)])
    }

    @Test(arguments: ReelRecipe.all)
    func primaryActionAndTaskFollowRecipe(_ recipe: ReelRecipe) {
        let plan = WizardFormPlan(recipe: recipe)
        let highlights = recipe.workflow == .highlights
        #expect(plan.primaryTask == (highlights ? "highlights" : "wizard"))
    }

    @Test func runSummariesDescribeTheNextOperation() {
        let scenes = WizardFormPlan(recipe: .custom)
        #expect(scenes.runSummary(sceneCount: 24, source: "of Jack Della Maddalena", targetSeconds: 20,
            highlightCount: 5, highlightSeconds: 30, captions: true, critique: true,
            selectionReview: false) == "One 20s reel from 24 scenes of Jack Della Maddalena, up to 3 takes until the critic scores 85+")
        #expect(scenes.runSummary(sceneCount: 2, source: "in this project", targetSeconds: nil,
            highlightCount: 0, highlightSeconds: 30, captions: false, critique: false,
            selectionReview: true).hasSuffix("cuts reviewed before render"))
        let highlights = WizardFormPlan(recipe: .podcastHighlights)
        #expect(highlights.runSummary(sceneCount: 10, source: "Podcast 02.mp4", targetSeconds: 20,
            highlightCount: 5, highlightSeconds: 30, captions: true, critique: true,
            selectionReview: false) == "Up to 5 highlights, up to 30s each, from Podcast 02.mp4, reviewed before render")
        #expect(highlights.runSummary(sceneCount: 10, source: "Podcast.mp4", targetSeconds: nil,
            highlightCount: 0, highlightSeconds: 30, captions: false, critique: false,
            selectionReview: false).hasPrefix("Highlights with no count limit"))
    }

    @Test func editingSummaryOmitsUnsupportedPreferences() {
        let highlights = WizardFormPlan(recipe: .podcastHighlights)
        #expect(highlights.editingSummary(audio: .mix, captions: true, headlines: true,
            critique: true, branding: "Brand default", useBRoll: true) == "B-roll")
        #expect(highlights.unsupportedOptions.contains("captions"))
        #expect(highlights.unsupportedOptions.contains("music"))
        #expect(highlights.unsupportedOptions.contains("branding"))
        let custom = WizardFormPlan(recipe: .custom)
        #expect(custom.unsupportedOptions.isEmpty)
        #expect(custom.editingSummary(audio: .mix, captions: true, headlines: false,
            critique: true, branding: "Brand default", useBRoll: false) == "Mix · Captions · Brand default")
    }

    @Test func runEditsBeatCopiedSettingsWhichBeatProfileDefaults() {
        let profilePacing = EditPacing(cadence: .twoSeconds, curve: .steady)
        var copied = WizardOptions()
        copied.pacing = EditPacing(cadence: .threeSeconds, curve: .accelerate)
        copied.renderSettings = RenderSettings(preset: .square1080)
        let runPacing = EditPacing(cadence: .mixedTwoToFour, curve: .decelerate)
        let runRender = RenderSettings(preset: .landscape4K)
        #expect(WizardDefaults.resolvedPacing(run: nil, copied: nil, profile: profilePacing) == profilePacing)
        #expect(WizardDefaults.resolvedPacing(run: nil, copied: copied, profile: profilePacing) == copied.pacing)
        #expect(WizardDefaults.resolvedPacing(run: runPacing, copied: copied, profile: profilePacing) == runPacing)
        #expect(WizardDefaults.resolvedRenderSettings(run: nil, copied: nil, profile: runRender) == runRender)
        #expect(WizardDefaults.resolvedRenderSettings(run: nil, copied: copied, profile: runRender) == copied.renderSettings)
        #expect(WizardDefaults.resolvedRenderSettings(run: runRender, copied: copied, profile: RenderSettings()) == runRender)
    }

    @Test("footage grid: clicking a video off narrows the run to the others' newest batches, clicking on adds its newest batch")
    func footageGridToggle() {
        let byVideo: [Int64: [Int64]] = [1: [11], 2: [22], 3: [33]]
        // Everything contributes; clicking video 2 off keeps 1 and 3.
        let first = WizardFormPlan.togglingVideo(runIDs: [21, 22], newestRunID: 22, allRunsByVideo: byVideo,
                                                 limitToSelection: false, selectedRunIDs: [])
        #expect(first.limitToSelection)
        #expect(first.selectedRunIDs == [11, 33])
        #expect(!WizardFormPlan.videoContributes(runIDs: [21, 22], limitToSelection: true, selectedRunIDs: first.selectedRunIDs))
        #expect(WizardFormPlan.videoContributes(runIDs: [11], limitToSelection: true, selectedRunIDs: first.selectedRunIDs))
        // Clicking it on again adds only its newest batch.
        let second = WizardFormPlan.togglingVideo(runIDs: [21, 22], newestRunID: 22, allRunsByVideo: byVideo,
                                                  limitToSelection: true, selectedRunIDs: first.selectedRunIDs)
        #expect(second.selectedRunIDs == [11, 22, 33])
        // Clicking the last one off leaves the limit on with nothing chosen.
        let third = WizardFormPlan.togglingVideo(runIDs: [11], newestRunID: 11, allRunsByVideo: byVideo,
                                                 limitToSelection: true, selectedRunIDs: [11])
        #expect(third.limitToSelection && third.selectedRunIDs.isEmpty)
        #expect(HoverScrubThumbnail.next(after: 1, duration: 60) == 11)
        #expect(HoverScrubThumbnail.next(after: 51, duration: 60) == 1)
        #expect(WizardSourceGrid.collapsedTitle(["A.mp4", "B.mov"]) == "A.mp4, B.mov")
    }
}

extension WizardFormPlanTests {
    @Test func iterateOutcomeMapsToLoopWithoutChangingRecipe() {
        for recipe in ReelRecipe.all where recipe.workflow == .oneReel {
            #expect(WizardFormPlan.outcome(recipe: recipe, critiqueLoop: true) == .iterate)
            #expect(WizardFormPlan.outcome(recipe: recipe, critiqueLoop: false) == .oneReel)
        }
        for outcome in ReelRecipe.Workflow.allCases {
            let options = WizardFormPlan.applyingOutcome(outcome, to: WizardOptions())
            #expect(options.critiqueLoop == (outcome == .iterate))
            #expect(options.formatPreset == "custom")
        }
        #expect(WizardFormPlan.outcome(recipe: .podcastHighlights, critiqueLoop: true) == .highlights)
        #expect(ReelRecipe.menuSections(workflow: .iterate, preferredSources: .scenes)
            == ReelRecipe.menuSections(workflow: .oneReel, preferredSources: .scenes))
    }

    @Test func iterateSummaryNamesTargetAndAttempts() {
        let summary = WizardFormPlan(recipe: .custom).runSummary(sceneCount: 24, source: "", targetSeconds: 20,
            highlightCount: 0, highlightSeconds: 30, captions: false, critique: true, selectionReview: false,
            critiqueTargetScore: 80, critiqueMaxVersions: 4)
        #expect(summary == "One 20s reel from 24 scenes, up to 4 takes until the critic scores 80+")
    }

    @Test @MainActor func iterationOptionsRoundTripAndPaste() throws {
        let legacy = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(legacy.critiqueTargetScore == 85 && legacy.critiqueMaxVersions == 3)
        var options = legacy
        options.critiqueTargetScore = 80; options.critiqueMaxVersions = 4; options.critiqueLoop = true
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.critiqueTargetScore == 80 && decoded.critiqueMaxVersions == 4)
        let name = "CriticIteration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        AISettingsPreferences.write(JSONSetting.dictionary(options), kind: .wizard,
            scopes: [.options], defaults: defaults)
        #expect(defaults.integer(forKey: "wizard.critiqueTargetScore") == 80)
        #expect(defaults.integer(forKey: "wizard.critiqueMaxVersions") == 4)
        #expect(defaults.string(forKey: "wizard.outcome") == "iterate")
        let copy = AISettingsPreferences.wizard(defaults: defaults, profile: Fixtures.brand())
        #expect(copy["critiqueTargetScore"] == .number(80) && copy["critiqueMaxVersions"] == .number(4))
        options.critiqueLoop = false
        AISettingsPreferences.write(JSONSetting.dictionary(options), kind: .wizard,
            scopes: [.options], defaults: defaults)
        #expect(defaults.string(forKey: "wizard.outcome") == "oneReel")
    }
}

extension WizardFormPlanTests {
    @Test func everyControlBelongsToExactlyOneStep() {
        let custom = WizardFormPlan(recipe: .custom)
        #expect(custom.step1Controls == [.sources, .outcome, .recipe, .length, .brief,
            .styleReference, .fightResearch, .layouts, .iteration, .planningModels])
        #expect(custom.step2Controls == [.output, .pacing, .audio, .musicTrack, .text,
            .overlayStyle, .transitions, .cameraFocus, .framingCamera, .bRoll, .bumpers, .branding, .presentationModels])
        #expect(custom.step1Controls.union(custom.step2Controls) == Set(WizardFormPlan.Control.allCases))
        for recipe in ReelRecipe.all {
            let form = WizardFormPlan(recipe: recipe)
            #expect(form.step1Controls.isDisjoint(with: form.step2Controls))
            #expect(!form.step1Controls.contains(.cameraFocus))
            #expect(!form.step1Controls.contains(.bRoll))
            #expect(!form.step2Controls.contains(.layouts))
            #expect(!form.step2Controls.contains(.iteration))
        }
        let highlights = WizardFormPlan(recipe: .podcastHighlights)
        #expect(!highlights.step1Controls.contains(.iteration))
        #expect(!highlights.step2Controls.contains(.audio))
        #expect(!highlights.step2Controls.contains(.branding))
        #expect(highlights.step2Controls.contains(.cameraFocus))
    }

    @Test func modelRowsAreSplitByStepWithoutDuplicates() {
        let form = WizardFormPlan(recipe: .custom)
        #expect(form.step1Models == ["wizard", "critique"])
        #expect(form.step2Models(useBRoll: true, instructions: "Use fight footage") == ["captions", "broll"])
        #expect(form.step2Models(useBRoll: false, instructions: "") == ["captions"])
        #expect(Set(form.step1Models).isDisjoint(with: form.step2Models(useBRoll: true, instructions: "Cutaways")))
    }

    @Test func lookCardStaysCollapsedUntilSelectionOrAutomaticWorkflow() {
        for workflow in WizardWorkflow.allCases {
            #expect(!WizardFormPlan.step2Collapsed(hasSelection: true, workflow: workflow))
            #expect(WizardFormPlan.step2Collapsed(hasSelection: false, workflow: workflow) == (workflow != .automatic))
        }
    }

    @Test func legacyWorkflowMappingRunsOnceAndPreservesAnExplicitChoice() throws {
        for legacy in [false, true] {
            let suite = "WizardWorkflow-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(legacy, forKey: "wizard.reviewProposedCuts")
            WizardDefaults.migrateLegacy(defaults: defaults)
            #expect(defaults.object(forKey: "wizard.reviewProposedCuts") == nil)
            #expect(defaults.string(forKey: WizardDefaults.workflowKey)
                == (legacy ? WizardWorkflow.reviewMoments.rawValue : WizardWorkflow.automatic.rawValue))
            defaults.set(WizardWorkflow.reviewMomentsAndLook.rawValue, forKey: WizardDefaults.workflowKey)
            defaults.set(!legacy, forKey: "wizard.reviewProposedCuts")
            WizardDefaults.migrateLegacy(defaults: defaults)
            #expect(defaults.object(forKey: "wizard.reviewProposedCuts") == nil)
            #expect(defaults.string(forKey: WizardDefaults.workflowKey) == WizardWorkflow.reviewMomentsAndLook.rawValue)
        }
        let suite = "WizardWorkflowFresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WizardDefaults.migrateLegacy(defaults: defaults)
        #expect(defaults.string(forKey: WizardDefaults.workflowKey) == WizardWorkflow.automatic.rawValue)
    }

    @Test func legacyReviewSnapshotsEncodeOnlyWorkflowAndMigrateClipboard() throws {
        let legacy = try JSONDecoder().decode(WizardOptions.self, from: Data(#"{"reviewProposedCuts":true}"#.utf8))
        let encoded = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("reviewProposedCuts"))
        #expect(try JSONDecoder().decode(WizardOptions.self, from: encoded).resolvedWorkflow == .reviewMoments)
        let modern = try JSONDecoder().decode(WizardOptions.self,
            from: Data(#"{"reviewProposedCuts":true,"workflow":"automatic"}"#.utf8))
        #expect(modern.resolvedWorkflow == .automatic)
        let envelope = AISettingsEnvelope(kind: .wizard, sourceName: "Legacy", scopes: [.options],
            settings: ["reviewProposedCuts": .bool(true)])
        #expect(envelope.settings["workflow"] == .string("reviewMoments"))
        #expect(envelope.settings["reviewProposedCuts"] == nil)
        // Synthesized step snapshots ignore the retired key.
        let step = try JSONDecoder().decode(WizardStep1Options.self,
            from: Data(#"{"reviewProposedCuts":true,"workflow":"reviewMoments"}"#.utf8))
        #expect(step.workflow == .reviewMoments)
    }

    @Test @MainActor func workflowAndLookOptionsSurviveCopyAndSharedFormSubsets() throws {
        let suite = "WizardTwoStepCopy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = try JSONDecoder().decode(WizardOptions.self, from: Data("{\"reviewProposedCuts\":true}".utf8))
        #expect(legacy.workflow == .reviewMoments && legacy.resolvedWorkflow == .reviewMoments)
        var options = WizardOptions()
        options.workflow = .reviewMomentsAndLook
        options.overlayStyle = "minimal"
        options.overlayAnimation = "fade"
        options.overlayPlacement = "bottom"
        options.musicTrack = "Fights/theme.mp3"
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.resolvedWorkflow == .reviewMomentsAndLook)
        AISettingsPreferences.write(JSONSetting.dictionary(options), kind: .wizard,
            scopes: [.options], defaults: defaults)
        let shared = AppStore.wizardOptionsFromForm(transcriptsAvailable: true, defaults: defaults)
        #expect(shared.step1.workflow == .reviewMomentsAndLook)
        #expect(shared.step2.overlayStyle == "minimal")
        #expect(shared.step2.overlayAnimation == "fade")
        #expect(shared.step2.overlayPlacement == "bottom")
        #expect(shared.step2.musicTrack == "Fights/theme.mp3")
    }
}
