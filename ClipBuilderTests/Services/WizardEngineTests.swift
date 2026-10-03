import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard engine")
struct WizardEngineTests {
    @Test("Builder draft neutralizes stale split zoom for fight recipes")
    func fightDraftIgnoresPodcastFraming() {
        var scene = Fixtures.scene(id: 1)
        scene.tags = ["podcast:split"]
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 1)])
        var persisted = WizardOptions()
        persisted.formatPreset = ReelRecipe.mmaFinish.id
        persisted.podcastFraming = .splitZoom
        let options = persisted.neutralized(for: .mmaFinish)
        let draft = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene],
            renderSettings: options.renderSettings, pacing: options.pacing, podcastFraming: options.podcastFraming)
        #expect(draft.videoTrack.count == 1)
        #expect(draft.cropBlocks.isEmpty)
        #expect(draft.videoTrack.allSatisfy { $0.track == 0 && $0.screenCrop == nil && !$0.centerStage })
        // This source exercises split zoom when the recipe actually allows it.
        let podcast = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], podcastFraming: .splitZoom)
        #expect(podcast.videoTrack.count == 2)
        #expect(!podcast.cropBlocks.isEmpty)
    }

    @Test("a favorite gets exactly one two-point boost and remains must-keep past the budget")
    func favoriteShortlist() {
        let ordinary = Fixtures.scene(id: 1, start: 0, end: 10)
        var favorite = ordinary
        favorite.id = 2
        favorite.favorite = true
        #expect(WizardEngine.shortlistRank(favorite) - WizardEngine.shortlistRank(ordinary) == 2)
        #expect(SceneStacks.rank(favorite) - SceneStacks.rank(ordinary) == 2)
        favorite.favoriteProvider = "claude"
        favorite.favoriteModel = "fixture"
        #expect(WizardEngine.shortlistRank(favorite) - WizardEngine.shortlistRank(ordinary) == 2)
        var pool = (3...52).map { id in Fixtures.scene(id: Int64(id), start: 0, end: 10) }
        favorite.score = -100
        var lowOrdinary = favorite
        lowOrdinary.id = 53
        lowOrdinary.favorite = false
        pool += [favorite, lowOrdinary]
        let kept = WizardEngine.shortlistScenes(pool, targetSeconds: 10, emit: { _ in })
        #expect(kept.contains { $0.id == favorite.id })
        #expect(!kept.contains { $0.id == lowOrdinary.id })
        #expect(kept.count == 41)
    }

    @Test("validated plan maps to a speed-aware timeline")
    func timelineDocument() {
        let plan = WizardPlan(
            targetDuration: 8, rationale: "test", musicName: "track.wav", musicVolume: 9,
            clips: [planClip(sceneID: 1, start: 2, end: 6, speed: 0.5),
                    planClip(sceneID: 2, start: 2, end: 6, speed: 1)],
            transitions: ["fade"], headline: "Big Finish", introTitle: nil, fileName: nil
        )
        let scenes: [Int64: SceneRecord] = [1: Fixtures.scene(id: 1), 2: Fixtures.scene(id: 2)]
        let document = WizardEngine.timelineDocument(from: plan, sceneMap: scenes)
        #expect(document.videoTrack.map(\.duration) == [8, 4])
        #expect(document.videoTrack[1].startTime == 8)
        #expect(document.videoTrack[1].transIn == "fade")
        #expect(document.soundTrack.first?.duration == 12)
        #expect(document.soundTrack.first?.volume == 5)
    }

    @Test("legacy flat timeline keeps order, transition, and music")
    func legacyTimeline() throws {
        let json = """
        [{"type":"music","name":"track.wav","volume":2},
         {"type":"clip","id":1,"start":2,"end":4},
         {"type":"transition","name":"wipeleft"},
         {"type":"clip","id":2,"start":4,"end":7}]
        """
        let document = try #require(WizardEngine.legacyTimelineDocument(
            fromFlat: json, scenes: [1: Fixtures.scene(id: 1), 2: Fixtures.scene(id: 2)]
        ))
        #expect(document.videoTrack.count == 2)
        #expect(document.videoTrack[1].transIn == "wipeleft")
        #expect(document.soundTrack.first?.name == "track.wav")
        #expect(document.soundTrack.first?.duration == 5)
    }

    @Test func preparedClipsKeepResolvedConcatTransitions() {
        let scenes = (1...3).map { Fixtures.scene(id: Int64($0)) }
        let plan = Fixtures.plan(clips: scenes.map { Fixtures.planClip(sceneID: $0.id) }, transitions: ["wipeleft"])
        let document = WizardEngine.timelineDocument(from: plan,
            sceneMap: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }))
        let urls = scenes.map { URL(fileURLWithPath: "/tmp/extracted-\($0.id).mp4") }
        for transitions in [["wipeleft", "fade"], ["cut", "fadeblack"], []] {
            let prepared = WizardEngine.preparedDocument(from: document, clipURLs: urls, transitions: transitions)
            let resolved = transitions.isEmpty ? ["fade", "fade"] : transitions
            #expect(Array(prepared.videoTrack.dropFirst().map(\.transIn)) == resolved.map { Optional($0) })
            #expect(Array(prepared.videoTrack.dropLast().map(\.transOut)) == resolved.map { Optional($0) })
            #expect(prepared.videoTrack.first?.transIn == nil && prepared.videoTrack.last?.transOut == nil)
            #expect(prepared.videoTrack.map(\.videoFile) == urls.map { Optional($0.path) })
        }
    }

    @Test("style accents and output names are sanitized")
    func sanitizers() {
        #expect(WizardTextStyle.sanitizedAccent(" #abc ") == "#abc")
        #expect(WizardTextStyle.sanitizedAccent("red") == nil)
        #expect(WizardPlan.slug("João's Big Finish!") == "joao-s-big-finish")
        #expect(WizardPlan.slug("---") == nil)
    }

    @Test("malformed plans are clamped and unknown transitions become cuts")
    func validation() async throws {
        let settings = AppSettings()
        let engine = WizardEngine(ai: AIService(config: settings.ai), render: RenderEngine())
        let raw: [String: Any] = [
            "target_duration": -10,
            "clips": [
                ["scene_id": 1, "start": -100, "end": 100, "speed": 99],
                ["scene_id": 999, "start": 0, "end": 2],
            ],
            "transitions": ["unknown"],
            "music": ["name": "missing.wav", "volume": 99],
        ]
        let plan = try #require(await engine.validatePlan(
            raw, scenes: [1: Fixtures.scene()], musicNames: [], options: WizardOptions()
        ))
        #expect(plan.clips.count == 1)
        #expect(plan.clips[0].start == 2)
        #expect(plan.clips[0].end == 6)
        #expect(plan.clips[0].speed == 2)
        #expect(plan.musicName == nil)
        #expect(plan.transitions.isEmpty)
    }

    @Test("podcast validation keeps the answer from a multi-clip planner response")
    func podcastValidationKeepsAnswer() async throws {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        var scene = Fixtures.scene(id: 670)
        scene.startTime = 1419.7
        scene.endTime = 1450.8
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.targetDurationSeconds = 15
        let raw: [String: Any] = ["clips": [
            ["scene_id": 670, "start": 1419.7, "end": 1423.5, "speed": 2, "replay": true],
            ["scene_id": 670, "start": 1423.5, "end": 1427.7],
            ["scene_id": 999, "start": 2, "end": 6],
            ["scene_id": 670, "start": 1427.7, "end": 1431.7],
            ["scene_id": 670, "start": 1431.7, "end": 1435.7],
        ], "transitions": ["fade", "fade", "fade", "fade"]]
        let turns = [SpeakerTurn(videoID: scene.videoID, start: 1419.7, end: 1423.5, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: scene.videoID, start: 1423.5, end: 1450.8, cluster: 1, confidence: 1)]
        let plan = try #require(await engine.validatePlan(raw,
            scenes: [670: scene, 999: Fixtures.scene(id: 999)], musicNames: [], options: options,
            podcastSentenceEnds: [670: [1423.5, 1427.7, 1431.7, 1435.7, 1441.7]],
            podcastSpeakerTurns: [scene.videoID: turns]))
        #expect(plan.clips.count == 1)
        #expect(plan.clips[0].sceneID == 670)
        #expect(plan.clips[0].start == 1419.7)
        #expect(plan.clips[0].end == 1431.7)
        #expect(plan.clips[0].speed == 1 && !plan.clips[0].replay)
        #expect(plan.clips[0].layout == nil && plan.clips[0].screenCrop == nil && plan.clips[0].areaClips.isEmpty)
        #expect(plan.transitions.isEmpty)
    }

    @Test("podcast validation uses later proposals and cuts between complete stretches")
    func podcastValidationKeepsClosingJump() async throws {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        var scene = Fixtures.scene()
        scene.startTime = 100
        scene.endTime = 131
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.targetDurationSeconds = 15
        let raw: [String: Any] = ["target_duration": 15, "clips": [
            ["scene_id": 1, "start": 100, "end": 104],
            ["scene_id": 2, "start": 2, "end": 6],
            ["scene_id": 1, "start": 125, "end": 130],
        ], "transitions": ["fade", "fade"]]
        let plan = try #require(await engine.validatePlan(raw,
            scenes: [1: scene, 2: Fixtures.scene(id: 2)], musicNames: [], options: options,
            podcastSentenceEnds: [1: [104, 110, 120, 125, 130]]))
        #expect(plan.clips.map(\.sceneID) == [1, 1])
        #expect(plan.clips.map(\.start) == [100, 125])
        #expect(plan.clips.map(\.end) == [110, 130])
        #expect(plan.transitions == ["cut"])
        #expect(plan.targetDuration == 15)
    }

    @Test("podcast validation keeps an over-target answer at its exact sentence boundary")
    func podcastValidationExceedsTargetForAnswer() async throws {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        let scene = Fixtures.scene(start: 100, end: 131)
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.targetDurationSeconds = 15
        let raw: [String: Any] = ["clips": [["scene_id": 1, "start": 105, "end": 108]]]
        let plan = try #require(await engine.validatePlan(raw, scenes: [1: scene], musicNames: [], options: options,
            podcastSentenceEnds: [1: [112, 120.123, 125]]))
        #expect(plan.clips[0].start == 100)
        #expect(plan.clips[0].end == 120.123)
        #expect(plan.targetDuration > 15)
    }

    @Test("podcast prompt shows dialogue and gives completeness priority over length")
    func podcastPromptShowsTranscript() async {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.targetDurationSeconds = 15
        let dialogue = "    [2.0–4.0] Host: Why?\n    [4.0–6.0] Guest: Here is why."
        let prompt = await engine.legacyPlanPrompt(profile: BrandProfile(name: "Test"), research: [:],
            scenes: [Fixtures.scene()], musicNames: ["music.wav"], signals: .init(), people: [], outcomes: [],
            podcastTranscripts: [1: dialogue], options: options)
        #expect(prompt.contains(dialogue))
        #expect(prompt.contains("at most three"))
        #expect(prompt.contains("answer's opening to its closing sentences"))
        #expect(prompt.contains("Completeness takes priority over Length"))
        #expect(!prompt.contains("1.5-5"))
        #expect(!prompt.contains("REQUIRED DURATION (HARD CONSTRAINT)"))
        options.formatPreset = "custom"
        let ordinary = await engine.legacyPlanPrompt(profile: BrandProfile(name: "Test"), research: [:],
            scenes: [Fixtures.scene()], musicNames: [], signals: .init(), people: [], outcomes: [],
            podcastTranscripts: [1: dialogue], options: options)
        #expect(!ordinary.contains(dialogue))
        #expect(ordinary.contains("each clip duration should be 1.5-5 seconds"))
        #expect(ordinary.contains("REQUIRED DURATION (HARD CONSTRAINT)"))
    }

    @Test("planning sees only the current project's scenes while Home sees every scene")
    func projectScope() async throws {
        let temp = try TempDatabase()
        let firstVideoID = try await temp.seedVideo()
        _ = try await temp.seedVideo()
        try await temp.database.ensureDefaultProject(profileName: "Fixture", legacyTimelineJSON: nil)
        let homeID = try #require(try await temp.database.homeProjectID(profileName: "Fixture"))
        let projectID = try await temp.database.createProject(
            profileName: "Fixture",
            name: "One Source",
            videoIDs: [firstVideoID]
        )
        let profile = Fixtures.brand(name: "Fixture")
        let settings = AppSettings()
        let engine = WizardEngine(ai: AIService(config: settings.ai), render: RenderEngine())

        var options = WizardOptions()
        options.projectID = projectID
        let scopedSceneIDs = try await engine.planningSceneIDs(
            options: options,
            profile: profile,
            database: temp.database
        )
        options.projectID = homeID
        let homeSceneIDs = try await engine.planningSceneIDs(
            options: options,
            profile: profile,
            database: temp.database
        )

        #expect(scopedSceneIDs.count == 1)
        #expect(homeSceneIDs.count == 2)
        #expect(Set(scopedSceneIDs).isSubset(of: Set(homeSceneIDs)))
    }

    private func planClip(sceneID: Int64, start: Double, end: Double, speed: Double) -> WizardPlanClip {
        WizardPlanClip(
            sceneID: sceneID, start: start, end: end, textOverlay: nil,
            overlayStyle: nil, overlayAnimation: nil, overlayKicker: nil,
            overlayAccent: nil, overlayPlacement: nil, overlayCase: nil,
            reason: nil, speed: speed
        )
    }
}

@Suite
struct LearnedWizardPromptTests {
    @Test func offPathIsByteIdenticalAndContributorOnlyAppendsItsLines() async throws {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        var profile = BrandProfile(name: "Test")
        profile.houseStyle = "Local house style"
        profile.tasteRubric = "Local taste"
        let options = WizardOptions()
        let signals = WizardEngine.TrainingSignals(lessons: [.init(id: 7, text: "Local lesson", pinned: false, evidence: "Two reviews")])
        let before = await engine.legacyPlanPrompt(profile: profile, research: [:], scenes: [], musicNames: [],
            signals: signals, people: [], outcomes: [], options: options)
        let off = await engine.planPrompt(profile: profile, research: [:], scenes: [], musicNames: [],
            signals: signals, people: [], outcomes: [], options: options, learnedContributors: [])
        #expect(Array(before.utf8) == Array(off.utf8))
        var contributor = BrandProfile(name: "Team")
        contributor.learnedSharing.deviceNickname = "Studio"
        let document = try LearnedDocumentBuilder.build(profile: contributor,
            lessons: [.init(id: 1, text: "Use a short hook", pinned: true, evidence: "Three reviews")], now: .distantPast).document
        let withContributor = await engine.planPrompt(profile: profile, research: [:], scenes: [], musicNames: [],
            signals: signals, people: [], outcomes: [], options: options, learnedContributors: [document])
        let local = try LearnedDocumentBuilder.build(profile: profile, lessons: signals.lessons, now: .distantPast).document
        let suffix = LearnedMerge.contributorBlock(LearnedMerge.merge(local: local, contributors: [document]))
        #expect(!suffix.isEmpty)
        #expect(withContributor == before + suffix)
        #expect(suffix.contains("[Team - Studio]"))
        let activeLocal = await engine.planPrompt(profile: profile, research: [:], scenes: [], musicNames: [],
            signals: signals, people: [], outcomes: [], options: options, learnedContributors: [], localLearning: local)
        let activeShared = await engine.planPrompt(profile: profile, research: [:], scenes: [], musicNames: [],
            signals: signals, people: [], outcomes: [], options: options, learnedContributors: [document], localLearning: local)
        #expect(activeLocal.contains("[Test -]"))
        #expect(activeShared == activeLocal + suffix)
    }
}

extension LearnedWizardPromptTests {
    @Test func importedFramesCarryContributorLabels() async throws {
        let temp = try TempDirectory()
        let library = LearnedLibrary(root: temp.url)
        var contributor = BrandProfile(name: "Team")
        contributor.learnedSharing.deviceNickname = "Studio"
        contributor.tasteRubric = "Action"
        contributor.tasteExemplarFrames = ["injected.jpg"]
        let build = try LearnedDocumentBuilder.build(profile: contributor,
            readFrame: { _ in Data([0xff, 0xd8, 0xff, 0xd9]) })
        try library.install(build.document, frames: build.frames)
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        let frames = await engine.tasteExemplarFrames(profile: BrandProfile(name: "Local"),
            options: WizardOptions(), learnedLibrary: library)
        #expect(frames.count == 1)
        #expect(frames.first?.label.contains("[Team - Studio]") == true)
    }
}

extension WizardEngineTests {
    @Test(arguments: ["top 5", "at most 5 highlights", "5 highlights max", "at most 5 highlight", "at most 5 reels"])
    func podcastCountDoesNotBecomePartOfRecordingName(_ control: String) {
        let request = "podcast highlights for Modestino \(control)"
        #expect(WizardEngine.podcastHighlightMaxCount(in: request) == 5)
        #expect(WizardEngine.podcastRecordingFragment(in: request) == "Modestino")
    }

    @Test(arguments: ["20 s", "20 sec", "20 secs", "20 second", "20 seconds"])
    func podcastDurationIsNotAHighlightCount(_ duration: String) {
        #expect(WizardEngine.podcastHighlightMaxCount(in: "at most \(duration)") == nil)
        #expect(WizardEngine.podcastHighlightMaxCount(in: "top 5, at most \(duration)") == 5)
    }

    @Test func highlightCountOptionsRoundTripAndLegacyDefault() throws {
        var options = WizardOptions()
        options.highlightMaxCount = 5
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(WizardOptions.self, from: data).highlightMaxCount == 5)
        #expect(try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8)).highlightMaxCount == nil)
    }
}

extension WizardEngineTests {
    @Test func critiqueAttemptLimitUsesRunOptions() {
        var options = WizardOptions()
        for cap in 2...5 {
            options.critiqueMaxVersions = cap
            #expect(WizardEngine.versionLimit(options: options) == cap)
        }
        options.critiqueLoop = false
        #expect(WizardEngine.versionLimit(options: options) == 1)
        options.critiqueLoop = true
        options.critiqueMaxVersions = 0
        #expect(WizardEngine.versionLimit(options: options) == 2)
        options.critiqueMaxVersions = 100
        #expect(WizardEngine.versionLimit(options: options) == 5)
    }
}

extension WizardEngineTests {
    @Test func plannerOnlyRequestsEditorialDecisions() async throws {
        let engine = WizardEngine(ai: AIService(config: AIConfig()), render: RenderEngine())
        var options = WizardOptions()
        options.enableTextOverlays = true
        options.pinnedOverlayText = "Keep this headline"
        options.pinnedOverlayTemplate = "Forbidden template sentinel"
        options.allowedTransitions = ["knife_slash"]
        options.overlayStyle = "banner"
        options.overlayAnimation = "pop"
        let prompt = await engine.planPrompt(profile: Fixtures.brand(), research: [:],
            scenes: [Fixtures.scene()], musicNames: ["Forbidden music sentinel"], signals: .init(),
            people: [], outcomes: [], options: options, learnedContributors: [])
        for removed in ["Available Music", "Available Transitions", "Music Beat Analysis",
                        "Forbidden music sentinel", "Forbidden template sentinel", "knife_slash",
                        "\"style\":", "\"animation\":", "\"accent\":", "\"placement\":",
                        "\"text_case\":", "\"transitions\":", "\"music\":"] {
            #expect(!prompt.contains(removed), "Planner must not request \(removed)")
        }
        #expect(prompt.contains("Keep this headline"))
        #expect(prompt.contains("\"kicker\":"))
        #expect(prompt.contains("\"speed\":"))
        #expect(prompt.contains("\"areas\":"))
        let raw: [String: Any] = [
            "target_duration": 4, "headline": "The answer",
            "music": ["name": "track", "volume": 5], "transitions": ["fade"],
            "clips": [["scene_id": 1, "start": 2, "end": 6, "reason": "Keep the answer",
                       "text_overlay": ["text": "The answer", "kicker": "Guest", "style": "banner",
                                        "animation": "pop", "accent": "#abc", "placement": "bottom",
                                        "text_case": "upper"]]]
        ]
        let plan = try #require(await engine.validatePlan(raw, scenes: [1: Fixtures.scene()],
                                                         musicNames: ["track"], options: options))
        #expect(plan.musicName == nil)
        #expect(plan.clips[0].textOverlay == "The answer" && plan.clips[0].overlayKicker == "Guest")
        #expect(plan.clips[0].overlayStyle == nil && plan.clips[0].overlayAnimation == nil)
        #expect(plan.clips[0].overlayAccent == nil && plan.clips[0].overlayPlacement == nil)
        #expect(plan.clips[0].overlayCase == nil)
    }

    @Test func automaticRecordsOneTakeBeforeRendering() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let projectID = try await temp.database.createProject(profileName: "Selection Test", name: "Project", videoIDs: [videoID])
        let scene = try #require(try await temp.database.fetchScenes(projectID: projectID).first)
        let reply = """
        {"target_duration":8,"rationale":"Keep the complete moment","headline":"The moment",
         "clips":[{"scene_id":\(scene.id),"start":0,"end":8,"reason":"Complete moment"}]}
        """
        var config = AIConfig()
        config.tasks["wizard"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "message": ["content": [["type": "text", "text": reply]]]
        ])
        let requests = WizardPlannerRequests()
        let service = AIService(config: config) { _, arguments, stdin, _, _, _ in
            await requests.append(arguments.joined(separator: " ") + String(decoding: stdin ?? Data(), as: UTF8.self))
            return ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
        let engine = WizardEngine(ai: service, render: RenderEngine())
        var options = WizardOptions()
        options.projectID = projectID
        options.useMusic = false
        options.critiqueLoop = false
        options.tastePreset = "none"
        let profile = Fixtures.brand(name: "Selection Test")
        let database = temp.database
        try await engine.runAutomatic(options: options, profile: profile, database: database, emit: { _ in }, renderTake: { take, renderOptions in
            let persisted = try await database.fetchWizardSelectionTakes(selectionID: take.selectionID)
            #expect(persisted.count == 1 && persisted.first?.id == take.id)
            #expect(take.ordinal == 1 && renderOptions.projectID == projectID)
            #expect(take.plan.clips.map(\.sceneID) == [scene.id])
            // Stand in only for encoding. Persist using the production output link API.
            try await database.insertGeneratedVideo(path: "/tmp/automatic.mp4", duration: 8,
                timelineJSON: "{}", wizardProvider: nil, wizardModel: nil,
                projectID: projectID, selectionTakeID: take.id)
        })
        let selections = try await temp.database.fetchWizardSelections(projectID: projectID)
        let selection = try #require(selections.first)
        #expect(selections.count == 1)
        let takes = try await temp.database.fetchWizardSelectionTakes(selectionID: selection.id)
        #expect(takes.count == 1 && selection.bestTakeID == takes.first?.id)
        #expect(try await temp.database.fetchGeneratedVideos(projectID: projectID).first?.selectionTakeID == takes.first?.id)
        let next = try await engine.findMoments(options: options, note: "Start with the answer", previousTakes: takes,
            profile: profile, database: temp.database, emit: { _ in })
        #expect(next.take.selectionID == selection.id && next.take.ordinal == 2)
        #expect(next.take.note == "Start with the answer")
        let prompts = await requests.prompts
        #expect(prompts.contains { $0.contains("USER RULE FOR THIS TAKE") && $0.contains("Start with the answer") })
        #expect(try await temp.database.fetchWizardSelections(projectID: projectID).count == 1)
    }

    @Test func makeReelRejectsMissingScenesWithoutCallingThePlanner() async throws {
        let temp = try TempDatabase()
        let project = try await temp.database.createProject(profileName: "Test", name: "Project")
        var options = WizardOptions()
        options.projectID = project
        options.critiqueLoop = true
        let take = try await temp.database.recordWizardTake(projectID: project, options: options.step1, plan: Fixtures.plan())
        let service = AIService(config: AIConfig()) { _, _, _, _, _, _ in
            Issue.record("Rendering a saved take must never call the planner to repair missing footage")
            throw CancellationError()
        }
        let engine = WizardEngine(ai: service, render: RenderEngine())
        await #expect(throws: AIError.self) {
            try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(),
                                      database: temp.database, emit: { _ in })
        }
        #expect(try await temp.database.fetchWizardSelectionTakes(selectionID: take.selectionID).count == 1)
    }
}

private actor WizardPlannerRequests {
    private(set) var prompts: [String] = []
    func append(_ prompt: String) { prompts.append(prompt) }
}

extension WizardEngineTests {
    @Test("Proxy retries record scores and render only the best take, newest wins ties",
          arguments: [false, true], [70, 92, 80])
    func critiqueRetriesOnTakes(step1Only: Bool, secondScore: Int) async throws {
        try await exerciseTakeIteration(step1Only: step1Only, scores: [80, secondScore], regenerate: [true, false])
    }

    @Test("A satisfied content critic leaves one scored take", arguments: [false, true])
    func satisfiedCriticStopsTakeIteration(step1Only: Bool) async throws {
        try await exerciseTakeIteration(step1Only: step1Only, scores: [93], regenerate: [false])
    }

    @Test("The attempt cap keeps take history and announces the best", arguments: [false, true])
    func critiqueTakeLimit(step1Only: Bool) async throws {
        try await exerciseTakeIteration(step1Only: step1Only, scores: [80, 70], regenerate: [true, true])
    }

    private func exerciseTakeIteration(step1Only: Bool, scores: [Int], regenerate: [Bool]) async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Take Loop", name: "Iteration", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        let reply = """
        {"target_duration":8,"rationale":"Keep the complete moment","headline":"The moment",
         "clips":[{"scene_id":\(scene.id),"start":0,"end":8,"reason":"Complete moment"}]}
        """
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "message": ["content": [["type": "text", "text": reply]]]
        ])
        let requests = WizardPlannerRequests()
        var config = AIConfig()
        config.tasks["wizard"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        let ai = AIService(config: config) { _, arguments, stdin, _, _, _ in
            await requests.append(arguments.joined(separator: " ") + String(decoding: stdin ?? Data(), as: UTF8.self))
            return ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        var options = WizardOptions()
        options.projectID = projectID
        options.useMusic = false
        options.tastePreset = "none"
        options.critiqueLoop = true
        options.critiqueMaxVersions = 2
        let profile = Fixtures.brand(name: "Take Loop")
        let logs = WizardIterationLog()
        let directory = temp.path.deletingLastPathComponent()
        let renderProxy: WizardEngine.ProxyRenderer = { _, _, proxyOptions in
            #expect(proxyOptions.renderSettings.quality == .compact)
            #expect(proxyOptions.renderSettings.width == 360 && proxyOptions.renderSettings.height == 640)
            #expect(!proxyOptions.addCaptions && !proxyOptions.enableTextOverlays && !proxyOptions.useMusic)
            #expect(try await database.fetchGeneratedVideos(projectID: projectID).isEmpty)
            let url = directory.appendingPathComponent("preview-\(UUID().uuidString).mp4")
            try Data("proxy fixture".utf8).write(to: url)
            return MultitrackRenderer.RenderResult(url: url, duration: 8)
        }
        let reviewContent: WizardEngine.ContentReviewer = { url, duration, take, previous in
            let index = take.ordinal - 1
            let saved = try #require(try await database.wizardSelectionTake(id: take.id))
            #expect(saved.proxyPath == url.path && FileManager.default.fileExists(atPath: url.path))
            #expect(url.deletingLastPathComponent() == WizardEngine.takeProxyDirectory(database: database))
            #expect(duration == 8 && previous.count == index)
            if index > 0 {
                #expect(saved.note?.contains("CONTENT CRITIC REVIEWED THE PROXY TAKE 1") == true)
                #expect(saved.note?.contains("Improve take 1") == true)
            }
            return ReelCritique(score: scores[index], summary: "Content review of take \(take.ordinal)",
                strengths: ["Keep the moment"], issues: ["Issue in take \(take.ordinal)"],
                notes: ["Improve take \(take.ordinal)"], regenerate: regenerate[index], provider: "fixture", model: "critic")
        }
        let renderTake: @Sendable (WizardSelectionTake, WizardOptions) async throws -> Void = { take, _ in
            #expect(try await database.fetchGeneratedVideos(projectID: projectID).isEmpty, "Only one final render")
            #expect(try await database.fetchWizardSelectionTakes(selectionID: take.selectionID).count == scores.count)
            #expect(take.criticScore == scores.max())
            let output = try await database.insertGeneratedVideo(path: "/tmp/take-\(take.id).mp4", duration: 8,
                timelineJSON: "{}", wizardProvider: nil, wizardModel: nil,
                projectID: projectID, selectionTakeID: take.id, batchID: "final-render")
            let presentation = ReelCritique(score: 33, summary: "Presentation only", strengths: [], issues: [],
                notes: ["Improve the look"], regenerate: false, provider: "fixture", model: "critic")
            try await database.updateGeneratedCritique(id: output,
                critiqueJSON: String(decoding: try JSONEncoder().encode(presentation), as: UTF8.self))
        }
        if step1Only {
            let first = try await engine.findMoments(options: options, profile: profile, database: database, emit: { _ in })
            let best = try await engine.iterateTakes(first: first.take, options: options, profile: profile,
                database: database, emit: { logs.append($0) }, renderProxy: renderProxy, reviewContent: reviewContent)
            #expect(try await database.fetchGeneratedVideos(projectID: projectID).isEmpty, "Review stops before step 2")
            try await engine.makeReel(take: best, options: options, profile: profile, database: database,
                emit: { _ in }, renderTake: renderTake)
        } else {
            try await engine.runAutomatic(options: options, profile: profile, database: database,
                emit: { logs.append($0) }, renderTake: renderTake, renderProxy: renderProxy, reviewContent: reviewContent)
        }
        let selections = try await database.fetchWizardSelections(projectID: projectID)
        let selection = try #require(selections.first)
        #expect(selections.count == 1)
        let takes = try await database.fetchWizardSelectionTakes(selectionID: selection.id)
        #expect(takes.map(\.ordinal) == Array(1...scores.count))
        #expect(takes.map(\.criticScore) == scores.map { Optional($0) })
        #expect(takes.allSatisfy { $0.proxyPath != nil && $0.criticNotes?.contains("Content review") == true })
        let bestIndex = try #require(scores.indices.max {
            scores[$0] == scores[$1] ? $0 < $1 : scores[$0] < scores[$1]
        })
        #expect(selection.bestTakeID == takes[bestIndex].id)
        let outputs = try await database.fetchGeneratedVideos(projectID: projectID)
        #expect(outputs.count == 1)
        let output = try #require(outputs.first)
        #expect(output.selectionTakeID == selection.bestTakeID && output.critique?.score == 33)
        #expect(WizardBatchRanking.best(in: outputs, batchID: "final-render")?.id == output.id)
        #expect(WizardBatchRanking.discards(in: outputs, keeping: output).isEmpty)
        if scores.count == 2 { #expect(await requests.prompts.contains { $0.contains("Improve take 1") }) }
        if regenerate.last == true {
            #expect(logs.lines.contains { $0.contains("cap is reached. Best: Take \(bestIndex + 1), \(scores[bestIndex])/100.") })
        } else { #expect(logs.lines.contains("The content critic is satisfied — no further takes.")) }
        try await engine.discardOtherTakeProxies(selectionID: selection.id, keeping: takes[bestIndex].id, database: database)
        let retained = try await database.fetchWizardSelectionTakes(selectionID: selection.id)
        #expect(retained.count == scores.count && retained.map(\.criticScore) == takes.map(\.criticScore))
        for (index, take) in retained.enumerated() {
            #expect((take.proxyPath != nil) == (index == bestIndex))
            let oldPath = try #require(takes[index].proxyPath)
            #expect(FileManager.default.fileExists(atPath: oldPath) == (index == bestIndex))
        }
        #expect(try await database.fetchGeneratedVideos(projectID: projectID).count == 1)
    }

    @Test func renderingAcceptedTakeNeverReplansOrOverwritesItsContentScore() async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Review", name: "Review", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        var options = WizardOptions()
        options.projectID = projectID
        options.critiqueLoop = true
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id)])
        let first = try await database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)
        let accepted = try await database.addWizardSelectionTake(selectionID: first.selectionID, plan: plan,
            note: "User chose this take", criticScore: 95, criticNotes: "Content score")
        try await database.setBestWizardSelectionTake(selectionID: first.selectionID, takeID: accepted.id)
        let ai = AIService(config: AIConfig()) { _, _, _, _, _, _ in
            Issue.record("Making the accepted reel must not call the planner")
            throw CancellationError()
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        try await engine.makeReel(take: accepted, options: options, profile: Fixtures.brand(), database: database,
            emit: { _ in }) { take, _ in
                #expect(take.id == accepted.id)
                let output = try await database.insertGeneratedVideo(path: "/tmp/accepted.mp4", duration: 4,
                    timelineJSON: "{}", wizardProvider: nil, wizardModel: nil, projectID: projectID, selectionTakeID: take.id)
                let critique = try ReelCritic.parse(#"{"score":40,"regenerate":true,"notes":["Fix contrast"]}"#,
                    options: WizardOptions(), scope: .presentation)
                #expect(!critique.regenerate)
                try await database.updateGeneratedCritique(id: output,
                    critiqueJSON: String(decoding: try JSONEncoder().encode(critique), as: UTF8.self))
            }
        let takes = try await database.fetchWizardSelectionTakes(selectionID: first.selectionID)
        #expect(takes.map(\.ordinal) == [1, 2] && takes[1].criticScore == 95)
        #expect(try await database.wizardSelection(id: first.selectionID)?.bestTakeID == accepted.id)
        #expect(try await database.fetchGeneratedVideos(projectID: projectID).count == 1)
    }
}

nonisolated private final class WizardIterationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}

extension WizardEngineTests {
    @Test("A failed proxy or judge preserves the take; cancellation propagates", arguments: [false, true], [false, true])
    func proxyFailureAndCancellation(cancel: Bool, failBeforeReview: Bool) async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let project = try await database.createProject(profileName: "Proxy failure", name: "Test", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: project).first)
        var options = WizardOptions()
        options.projectID = project
        options.critiqueLoop = true
        let first = try await database.recordWizardTake(projectID: project, options: options.step1,
            plan: Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id)]))
        let ai = AIService(config: AIConfig()) { _, _, _, _, _, _ in
            Issue.record("A failed first proxy or judge must not call the planner")
            throw CancellationError()
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        let directory = temp.path.deletingLastPathComponent()
        let proxy: WizardEngine.ProxyRenderer = { _, _, _ in
            if failBeforeReview {
                if cancel { throw CancellationError() }
                throw CocoaError(.fileWriteUnknown)
            }
            let url = directory.appendingPathComponent("preview.mp4")
            try Data("proxy".utf8).write(to: url)
            return .init(url: url, duration: 4)
        }
        let reviewer: WizardEngine.ContentReviewer = { _, _, _, _ in
            if cancel { throw CancellationError() }
            throw AIError.unusableResponse("Judge unavailable")
        }
        if cancel {
            await #expect(throws: CancellationError.self) {
                _ = try await engine.iterateTakes(first: first, options: options, profile: Fixtures.brand(),
                    database: database, emit: { _ in }, renderProxy: proxy, reviewContent: reviewer)
            }
        } else {
            let best = try await engine.iterateTakes(first: first, options: options, profile: Fixtures.brand(),
                database: database, emit: { _ in }, renderProxy: proxy, reviewContent: reviewer)
            #expect(best.id == first.id)
        }
        let saved = try #require(try await database.wizardSelectionTake(id: first.id))
        #expect(saved.criticScore == nil)
        #expect((saved.proxyPath == nil) == failBeforeReview)
        #expect(try await database.wizardSelection(id: first.selectionID)?.bestTakeID == first.id)
        #expect(try await database.fetchWizardSelectionTakes(selectionID: first.selectionID).count == 1)
        #expect(try await database.fetchGeneratedVideos(projectID: project).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("preview.mp4").path))
    }
}
