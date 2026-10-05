import Foundation
import Synchronization
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

    /// Claude receives a JSON envelope, so decode its text before checking multiline rules.
    func appendClaudeRequest(_ stdin: Data?) throws {
        let data = try #require(stdin)
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try #require(envelope["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        let prompt = try #require(content.last(where: { $0["type"] as? String == "text" })?["text"] as? String)
        prompts.append(prompt)
    }
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

    @Test(arguments: [false, true], ["podcast", "podcast_highlights"])
    func renderingAcceptedTakeNeverReplansOrOverwritesItsContentScore(nameTagsOnly: Bool, recipe: String) async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Review", name: "Review", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        var options = WizardOptions()
        options.projectID = projectID
        options.critiqueLoop = true
        options.useMusic = false
        options.formatPreset = recipe
        options.nameTagsOnly = nameTagsOnly ? true : nil
        options.nameTags = nameTagsOnly
        options.enableTextOverlays = true
        options.podcastFraming = .original
        options.addCaptions = true
        options.includeIntroBumper = true
        var clip = Fixtures.planClip(sceneID: scene.id)
        clip.textOverlay = "Editorial overlay"
        clip.overlayKicker = "Context"
        clip.speakerIntroductions = [TextOverlayItem()]
        let introductions = clip.speakerIntroductions
        let plan = Fixtures.plan(clips: [clip])
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
            emit: { _ in }, renderPlan: { rendered, renderOptions in
                // Stored plans decode overlays with fresh uids; compare what renders.
                let kept = rendered.clips.first?.speakerIntroductions ?? []
                if nameTagsOnly {
                    #expect(renderOptions.usesNameTags && kept.isEmpty)
                } else {
                    #expect(kept.map { ($0.text, $0.startTime, $0.endTime, $0.position) }.elementsEqual(
                        introductions.map { ($0.text, $0.startTime, $0.endTime, $0.position) }, by: ==))
                }
                #expect(rendered.clips.first?.textOverlay == (nameTagsOnly ? nil : "Editorial overlay"))
                #expect(rendered.clips.first?.overlayKicker == (nameTagsOnly ? nil : "Context"))
                if nameTagsOnly { #expect(rendered.clips.first?.overlayStyle == nil) }
                #expect(renderOptions.addCaptions && renderOptions.includeIntroBumper)
                #expect(renderOptions.podcastFraming == .original)
                let output = try await database.insertGeneratedVideo(path: "/tmp/accepted.mp4", duration: 4,
                    timelineJSON: "{}", wizardProvider: nil, wizardModel: nil, projectID: projectID, selectionTakeID: accepted.id)
                let critique = try ReelCritic.parse(#"{"score":40,"regenerate":true,"notes":["Fix contrast"]}"#,
                    options: WizardOptions(), scope: .presentation)
                #expect(!critique.regenerate)
                try await database.updateGeneratedCritique(id: output,
                    critiqueJSON: String(decoding: try JSONEncoder().encode(critique), as: UTF8.self))
            })
        let takes = try await database.fetchWizardSelectionTakes(selectionID: first.selectionID)
        #expect(takes.last?.plan.clips.first?.textOverlay == "Editorial overlay")
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

extension WizardEngineTests {
    @Test("Mini uses one request for three validated alternatives", arguments: [false, true])
    func miniCandidatesSingleCallDropsInvalidAndOverlappingPlans(includeBadCandidates: Bool) async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 3)
        let projectID = try await temp.database.createProject(profileName: "Mini Test", name: "Mini", videoIDs: [videoID])
        let scenes = try await temp.database.fetchScenes(projectID: projectID).sorted { $0.startTime < $1.startTime }
        #expect(scenes.count == 3)
        var candidates: [[String: Any]] = scenes.enumerated().map { index, scene in
            ["target_duration": 8, "rationale": "Reason \(index + 1)", "headline": index == 0 ? "First moment" : "",
             "clips": [["scene_id": scene.id, "start": scene.startTime - 2, "end": scene.endTime + 2]]]
        }
        if includeBadCandidates {
            candidates.insert(["clips": [["scene_id": -999, "start": 0, "end": 8]]], at: 1)
            candidates.insert(candidates[0], at: 2)
        }
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": candidates]), as: UTF8.self)
        var config = AIConfig()
        config.tasks["wizard"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "message": ["content": [["type": "text", "text": reply]]]
        ])
        let requests = WizardPlannerRequests()
        let service = AIService(config: config) { _, _, stdin, _, _, _ in
            try await requests.appendClaudeRequest(stdin)
            return ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
        let engine = WizardEngine(ai: service, render: RenderEngine())
        var options = WizardOptions()
        options.projectID = projectID
        options.formatPreset = "custom"
        // Test candidate validation independently of the default near-adjacent scene stacking.
        options.stackLevel = SceneStackLevel.off.rawValue
        options.targetDurationSeconds = 10
        options.tastePreset = "none"
        options.useMusic = false
        options.critiqueLoop = false
        options.aiInstructions = "Keep complete moments."
        let result = try await engine.findCandidates(count: 3, options: options, profile: Fixtures.brand(name: "Mini Test"),
                                                    database: temp.database, emit: { _ in })
        #expect(result.takes.count == 3)
        #expect(result.takes.allSatisfy { $0.ordinal == 1 && $0.plan.provenance != nil })
        #expect(result.takes.map { $0.plan.clips[0].start } == scenes.map(\.startTime))
        #expect(result.takes.map { $0.plan.clips[0].end } == scenes.map(\.endTime))
        #expect(result.takes.map { $0.plan.rationale } == ["Reason 1", "Reason 2", "Reason 3"])
        let selections = try await temp.database.fetchWizardSelections(projectID: projectID, miniBatch: result.miniBatch)
        #expect(selections.map(\.name) == ["First moment", "Candidate 2", "Candidate 3"])
        #expect(selections.allSatisfy { $0.recipe == "custom" })
        let prompts = await requests.prompts
        #expect(prompts.count == 1)
        let prompt = try #require(prompts.first)
        #expect(prompt.contains("3 alternative plans"))
        #expect(prompt.contains("3 non-overlapping plans"))
        #expect(prompt.contains("no overlapping footage between candidates"))
        #expect(prompt.contains("candidates") && prompt.contains("one-line reason"))
        #expect(prompt.contains("Select approximately 10s"))
        #expect(prompt.contains("Keep complete moments."))
    }

    @Test func miniPodcastCandidatesBecomeSingleClipPlans() {
        var scene = Fixtures.scene(id: 5, start: 100, end: 160)
        scene.videoDuration = 200
        scene.tags = ["podcast-exchange"]
        let candidates = [
            HighlightCandidate(sourceStart: 105, sourceEnd: 115, title: "Opening", reason: "A complete answer",
                               score: 8, kind: .subcut, framing: .talker, speakerKeys: []),
            HighlightCandidate(sourceStart: 110, sourceEnd: 120, title: "Overlap", reason: "Drop this",
                               score: 8, kind: .subcut, speakerKeys: []),
            HighlightCandidate(sourceStart: 130, sourceEnd: 145, title: "Closing", reason: "A useful takeaway",
                               score: 9, kind: .subcut, speakerKeys: [])
        ]
        let plans = WizardEngine.miniHighlightPlans(candidates, videoID: scene.videoID, scenes: [scene])
        #expect(plans.count == 2)
        #expect(plans.allSatisfy { $0.clips.count == 1 && $0.clips[0].sceneID == scene.id })
        #expect(plans.map { $0.clips[0].start } == [105, 130])
        #expect(plans.map { $0.clips[0].end } == [115, 145])
        #expect(plans.map(\.targetDuration) == [10, 15])
        #expect(plans.first?.headline == "Opening" && plans.first?.rationale == "A complete answer")
        #expect(plans.first?.footage?.first?.videoID == scene.videoID)
    }
}

extension WizardEngineTests {
    @Test func miniRegenerationIncludesAvoidRuleAndRefusesOverlapBeforeSaving() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 2)
        let projectID = try await temp.database.createProject(profileName: "Mini Regenerate", name: "Mini", videoIDs: [videoID])
        let scenes = try await temp.database.fetchScenes(projectID: projectID).sorted { $0.startTime < $1.startTime }
        let scene = try #require(scenes.first)
        var options = WizardOptions()
        options.projectID = projectID
        options.formatPreset = "custom"
        // Test candidate validation independently of the default near-adjacent scene stacking.
        options.stackLevel = SceneStackLevel.off.rawValue
        options.targetDurationSeconds = 8
        options.tastePreset = "none"
        options.useMusic = false
        options.critiqueLoop = false
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 8)], targetDuration: 8)
        let first = try await temp.database.recordWizardTake(projectID: projectID, options: options.step1,
                                                            plan: plan, miniBatch: "regenerate-batch")
        let reply = """
        {"target_duration":8,"rationale":"Complete moment","clips":[{"scene_id":\(scene.id),"start":0,"end":8,"reason":"Keep the complete moment"}]}
        """
        var config = AIConfig()
        config.tasks["wizard"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "message": ["content": [["type": "text", "text": reply]]]
        ])
        let requests = WizardPlannerRequests()
        let service = AIService(config: config) { _, _, stdin, _, _, _ in
            try await requests.appendClaudeRequest(stdin)
            return ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
        let engine = WizardEngine(ai: service, render: RenderEngine())
        let ranges = [(videoID: videoID, start: 10.0, end: 18.0)]
        let avoidRule = WizardPlanRules.avoidRangesRule(ranges)
        let note = "Start with the answer\n\n" + avoidRule
        let second = try await engine.findMoments(options: options, note: note, previousTakes: [first],
            avoidingRanges: ranges, profile: Fixtures.brand(name: "Mini Regenerate"), database: temp.database, emit: { _ in }).take
        #expect(second.selectionID == first.selectionID && second.ordinal == 2)
        #expect(second.note == note)
        let prompts = await requests.prompts
        let prompt = try #require(prompts.first)
        #expect(prompt.contains(note))
        #expect(prompt.contains("## PREVIOUS TAKES"))
        #expect(prompt.contains("Take 1:"))
        #expect(prompt.contains(avoidRule))
        #expect(prompt.contains("## SOURCE VIDEO IDS FOR AVOID RANGES"))
        // Corrective requests must retain the same regeneration instructions too.
        #expect(prompts.allSatisfy { $0.contains(note) && $0.contains("## PREVIOUS TAKES") && $0.contains(avoidRule) })
        let overlap = [(videoID: videoID, start: 1.0, end: 3.0)]
        await #expect(throws: AIError.self) {
            _ = try await engine.findMoments(options: options, note: WizardPlanRules.avoidRangesRule(overlap),
                previousTakes: [first, second], avoidingRanges: overlap, profile: Fixtures.brand(name: "Mini Regenerate"),
                database: temp.database, emit: { _ in })
        }
        #expect(try await temp.database.fetchWizardSelectionTakes(selectionID: first.selectionID).count == 2)
        #expect(try await temp.database.wizardSelection(id: first.selectionID)?.miniBatch == "regenerate-batch")
    }
}

extension WizardEngineTests {
    @Test(arguments: ["translated", "failure", "cancelled"])
    func captionTranslationIsPreparedBeforeRendering(outcome: String) async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Captions", name: "Captions", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        try await database.replaceTranscripts(videoID: videoID, language: "pt", isTranslation: false,
            segments: [.init(start: 0, end: 4, text: "Olá", words: nil)], provider: "test", model: nil)
        var options = WizardOptions()
        options.projectID = projectID
        options.addCaptions = true
        options.captionLanguage = "en"
        options.useMusic = false
        options.enableTextOverlays = false
        options.formatPreset = "custom"
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 4),
                                        Fixtures.planClip(sceneID: scene.id, start: 0, end: 4)])
        let take = try await database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)
        let log = WizardCaptionTestLog()
        let translations = WizardCaptionTestLog()
        let rendered = WizardCaptionTestLog()
        let engine = WizardEngine(ai: AIService(config: AIConfig()), render: RenderEngine(),
            translateCaptions: { id, originals, target, database in
                translations.append("translate")
                #expect(id == videoID && target == "en" && originals.map(\.text) == ["Olá"])
                if outcome == "cancelled" { throw CancellationError() }
                if outcome == "failure" { throw AIError.unusableResponse("Translator unavailable") }
                try await database.replaceTranscripts(videoID: id, language: target, isTranslation: true,
                    segments: [.init(start: 0, end: 4, text: "Hello", words: nil)], provider: "test", model: nil)
                return 1
            })
        do {
            try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(), database: database,
                emit: { log.append($0) }, renderPlan: { _, _ in
                    rendered.append("render")
                    let fallbacks = WizardCaptionFallbackLog()
                    for _ in 0..<2 {
                        // Exercise the same fetch used by extractPlannedClip, without encoding.
                        let captions = try await engine.captionSegments(videoID: videoID, filename: scene.videoFilename,
                            start: 0, end: 4, language: "en", database: database, fallbacks: fallbacks,
                            emit: { log.append($0) })
                        #expect(captions.map(\.text) == (outcome == "translated" ? ["Hello"] : ["Olá"]))
                    }
                })
            #expect(outcome != "cancelled")
        } catch is CancellationError {
            #expect(outcome == "cancelled")
        }
        #expect(translations.lines().count == 1) // Two cuts of the same source translate once.
        if outcome == "translated" {
            #expect(log.lines().contains { $0.contains("translating 1 lines of fixture.mp4 to English") })
            #expect(log.lines().contains { $0.contains("translated 1 lines") })
            #expect(!log.lines().contains { $0.contains("using the original language") })
            // An existing target track is reused on later runs.
            try await engine.prepareCaptionTranslations(plan: plan, options: options, sceneMap: [scene.id: scene],
                                                        database: database, emit: { log.append($0) })
            #expect(translations.lines().count == 1)
        } else if outcome == "failure" {
            #expect(log.lines().contains {
                $0.contains("could not translate fixture.mp4 to English") && $0.contains("Translator unavailable")
                    && $0.contains("using the original language")
            })
            #expect(log.lines().filter { $0.contains("in this cut — using the original language") }.count == 1)
        } else {
            #expect(rendered.lines().isEmpty)
            #expect(!log.lines().contains { $0.contains("using the original language") })
        }
    }

    @Test func captionsSkipTranslationWhenDisabledOrAlreadyInOriginalLanguage() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let scene = try #require(try await temp.database.fetchScenes().first)
        try await temp.database.replaceTranscripts(videoID: videoID, language: "en", isTranslation: false,
            segments: [.init(start: 0, end: 4, text: "Hello", words: nil)], provider: "test", model: nil)
        let engine = WizardEngine(ai: AIService(config: AIConfig()), render: RenderEngine(),
            translateCaptions: { _, _, _, _ in
                Issue.record("Translation must not be requested")
                throw CancellationError()
            })
        for (enabled, language) in [(false, "pt"), (true, ""), (true, "en")] {
            var options = WizardOptions()
            options.addCaptions = enabled
            options.captionLanguage = language
            try await engine.prepareCaptionTranslations(plan: Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id)]),
                options: options, sceneMap: [scene.id: scene], database: temp.database, emit: { _ in })
        }
    }
}

private nonisolated final class WizardCaptionTestLog: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ line: String) { storage.withLock { $0.append(line) } }
    func lines() -> [String] { storage.withLock { $0 } }
}

extension WizardEngineTests {
    @Test(arguments: [false, true])
    func wizardUsesTheSharedTranslateAIRoute(batch: Bool) async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let scene = try #require(try await temp.database.fetchScenes().first)
        try await temp.database.replaceTranscripts(videoID: videoID, language: "pt", isTranslation: false,
            segments: [.init(start: 0, end: 4, text: "Olá", words: nil)], provider: "test", model: nil)
        var config = AIConfig()
        config.tasks["translate"] = "claude"
        config.taskModels["translate"] = "translation-fixture"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        config.onDeviceOverrides["translation-batch"] = batch
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "message": ["content": [["type": "text", "text": "1. Hello"]]]
        ])
        let requests = WizardCaptionTestLog()
        let ai = AIService(config: config) { _, arguments, _, _, _, _ in
            requests.append("translate")
            #expect(arguments.contains("translation-fixture"))
            return ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine(), captionOnDevice: { _, _ in [:] })
        var options = WizardOptions()
        options.addCaptions = true
        options.captionLanguage = "en"
        try await engine.prepareCaptionTranslations(plan: Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id)]),
            options: options, sceneMap: [scene.id: scene], database: temp.database, emit: { _ in })
        let rows = try await temp.database.transcriptSegments(videoID: videoID, start: 0, end: 4, language: "en")
        #expect(rows.map(\.text) == ["Hello"])
        #expect(requests.lines().count == 1)
    }

    @Test func fortySecondCutOnlyTranslatesOverlappingRowsOfLongTranscriptWithProgress() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let scene = try #require(try await temp.database.fetchScenes().first)
        let transcript = (0..<276).map {
            TranscriptSegment(start: Double($0), end: Double($0 + 1), text: "Portuguese line \($0)", words: nil)
        }
        try await temp.database.replaceTranscripts(videoID: videoID, language: "pt", isTranslation: false,
            segments: transcript, provider: "fixture", model: nil)
        let stub = CaptionTranslationStub()
        let engine = WizardEngine(ai: stub.service(), render: RenderEngine(), captionOnDevice: { _, _ in [:] })
        var options = WizardOptions()
        options.addCaptions = true
        options.captionLanguage = "en"
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 100, end: 140)])
        try await engine.prepareCaptionTranslations(plan: plan, options: options, sceneMap: [scene.id: scene],
            database: temp.database, emit: { stub.log($0) })
        #expect(stub.calls().map { $0.texts.count } == [25, 17])
        #expect(stub.calls().flatMap(\.texts) == (99..<141).map { "Portuguese line \($0)" })
        #expect(stub.logs() == ["Captions: translating 42 lines of fixture.mp4 to English…",
                                "Captions: translated 25 of 42 lines", "Captions: translated 42 of 42 lines",
                                "Captions: fixture.mp4 translated 42 lines"])
        let stored = try await temp.database.fetchTranscripts(videoID: videoID)
        #expect(stored.filter { !$0.isTranslation }.count == 276)
        #expect(stored.filter(\.isTranslation).count == 42)
        // Reusing exactly these cuts does no work and emits nothing.
        let logCount = stub.logs().count
        try await engine.prepareCaptionTranslations(plan: plan, options: options, sceneMap: [scene.id: scene],
            database: temp.database, emit: { stub.log($0) })
        #expect(stub.calls().count == 2 && stub.logs().count == logCount)
    }

    @Test func captionRangesIncludeAreaClipsAndFillPartialTracksPerRow() async throws {
        let temp = try TempDatabase()
        let firstID = try await temp.seedVideo()
        let secondID = try await temp.seedVideo()
        let scenes = try await temp.database.fetchScenes()
        let first = try #require(scenes.first { $0.videoID == firstID })
        let second = try #require(scenes.first { $0.videoID == secondID })
        for id in [firstID, secondID] {
            try await temp.database.replaceTranscripts(videoID: id, language: "pt", isTranslation: false,
                segments: [.init(start: 0, end: 2, text: "First \(id)", words: nil),
                           .init(start: 2, end: 4, text: "Second \(id)", words: nil),
                           .init(start: 20, end: 22, text: "Area \(id)", words: nil),
                           .init(start: 90, end: 92, text: "Unused \(id)", words: nil)], provider: "fixture", model: nil)
        }
        try await temp.database.replaceTranscripts(videoID: firstID, language: "en", isTranslation: true,
            segments: [.init(start: 0, end: 2, text: "Already translated", words: nil)], provider: "fixture", model: nil)
        var cut = Fixtures.planClip(sceneID: first.id, start: 0, end: 4)
        cut.areaClips = [.init(area: "Same source", sceneID: first.id, start: 20, end: 22),
                         .init(area: "Other source", sceneID: second.id, start: 20, end: 22)]
        let stub = CaptionTranslationStub()
        let engine = WizardEngine(ai: stub.service(), render: RenderEngine(), captionOnDevice: { _, _ in [:] })
        var options = WizardOptions()
        options.addCaptions = true
        options.captionLanguage = "en"
        try await engine.prepareCaptionTranslations(plan: Fixtures.plan(clips: [cut, cut]), options: options,
            sceneMap: [first.id: first, second.id: second], database: temp.database, emit: { stub.log($0) })
        #expect(stub.calls().map(\.texts) == [["Second \(firstID)", "Area \(firstID)"], ["Area \(secondID)"]])
        let stored = try await temp.database.fetchTranscripts(videoID: firstID).filter(\.isTranslation)
        #expect(stored.map(\.text) == ["Already translated", "English Second \(firstID)", "English Area \(firstID)"])
    }
}

extension WizardEngineTests {
    private func cameraFocusFixture() async throws -> (TempDatabase, WizardOptions, WizardSelectionTake) {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let database = temp.database
        let projectID = try await database.createProject(profileName: "Camera focus", name: "Podcast", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        try await database.addSceneTag(sceneID: scene.id, tag: "podcast")
        try await database.addSceneTag(sceneID: scene.id, tag: "q&a")
        try await database.setPodcastLayout(videoID: videoID, layout: .splitHorizontal, seamX: 0.5, confidence: 1)
        try await database.replaceSpeakerTurns(videoID: videoID, turns: [
            SpeakerTurn(videoID: videoID, start: 0, end: 2, cluster: 0, confidence: 1),
            SpeakerTurn(videoID: videoID, start: 2, end: 8, cluster: 1, confidence: 1)
        ])
        var options = WizardOptions()
        options.projectID = projectID
        options.formatPreset = "podcast"
        options.useMusic = false
        options.critiqueLoop = false
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 8)])
        let take = try await database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)
        return (temp, options, take)
    }

    private func cameraFocusService(calls: WizardCaptionTestLog, reply: String,
                                    failure: Bool = false, cancel: Bool = false) -> AIService {
        var config = AIConfig()
        config.tasks["framing"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        return AIService(config: config) { _, _, stdin, timeout, _, _ in
            calls.append(String(decoding: stdin ?? Data(), as: UTF8.self))
            if cancel { throw CancellationError() }
            if failure { throw AIError.unusableResponse("Fixture model unavailable") }
            #expect(timeout == 90)
            let response = try JSONSerialization.data(withJSONObject: [
                "type": "assistant", "message": ["content": [["type": "text", "text": reply]]]
            ])
            return ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
    }

    @Test func cameraFocusIsSavedAndSecondRenderDoesNotCallAgain() async throws {
        let (temp, options, take) = try await cameraFocusFixture()
        let calls = WizardCaptionTestLog()
        let logs = WizardCaptionTestLog()
        let engine = WizardEngine(ai: cameraFocusService(calls: calls,
            reply: #"{"choices":[{"id":\#(take.id),"framing":"grid","reason":"Show both reactions."}]}"#),
            render: RenderEngine())
        for _ in 0..<2 {
            // Deliberately reuse the original nil-framing snapshot, like a reopened review.
            try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(), database: temp.database,
                emit: { logs.append($0) }, renderPlan: { plan, _ in
                    #expect(plan.framing == .grid)
                    #expect(plan.framingProvenance?.task == "framing")
                    #expect(plan.framingProvenance?.model == "fixture")
                })
        }
        #expect(calls.lines().count == 1)
        let saved = try #require(try await temp.database.wizardSelectionTake(id: take.id))
        #expect(saved.plan.framing == .grid)
        #expect(saved.plan.framingProvenance?.provider == "claude")
        #expect(logs.lines().contains { $0.contains("Camera focus: Everyone in a grid — Show both reactions.") })
    }

    @Test(arguments: [false, true])
    func explicitCameraFocusAndOriginalSkipAI(original: Bool) async throws {
        let (temp, base, take) = try await cameraFocusFixture()
        var options = base
        if original { options.podcastFraming = .original }
        else { options.highlightFraming = .talkerAndRest }
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: cameraFocusService(calls: calls, reply: "{}"), render: RenderEngine())
        try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(), database: temp.database,
            emit: { _ in }, renderPlan: { plan, _ in #expect(plan.framing == nil) })
        #expect(calls.lines().isEmpty)
        #expect(try await temp.database.wizardSelectionTake(id: take.id)?.plan.framing == nil)
    }

    @Test(arguments: [false, true])
    func unansweredCameraFocusFallsBackAndLogs(failure: Bool) async throws {
        let (temp, options, take) = try await cameraFocusFixture()
        let calls = WizardCaptionTestLog()
        let logs = WizardCaptionTestLog()
        let engine = WizardEngine(ai: cameraFocusService(calls: calls, reply: "{}", failure: failure), render: RenderEngine())
        try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(), database: temp.database,
            emit: { logs.append($0) }, renderPlan: { plan, _ in
                #expect(plan.framing == .talkerAndPrevious)
                #expect(plan.framingProvenance?.provider == "local")
                #expect(plan.framingProvenance?.fellBack == true)
            })
        let saved = try #require(try await temp.database.wizardSelectionTake(id: take.id))
        #expect(saved.plan.framing == .talkerAndPrevious)
        #expect(logs.lines().contains { $0.contains("Camera focus: Talker and previous — chosen by rule (the model did not answer)") })
        #expect(!calls.lines().isEmpty)
    }

    @Test func cameraFocusBatchesTakesBeforeCombining() async throws {
        let (temp, options, first) = try await cameraFocusFixture()
        let second = try await temp.database.recordWizardTake(projectID: try #require(options.projectID),
            options: options.step1, plan: first.plan)
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: cameraFocusService(calls: calls, reply: """
            {"choices":[{"id":\(first.id),"framing":"grid","reason":"Both people."},
                        {"id":\(second.id),"framing":"talker","reason":"Focus on the answer."}]}
            """), render: RenderEngine())
        let chosen = try await engine.chooseCameraFocus(takes: [first, second], options: options,
            profile: Fixtures.brand(), database: temp.database, emit: { _ in })
        #expect(calls.lines().count == 1)
        #expect(chosen.map(\.plan.framing) == [.grid, .talker])
        let combined = WizardPlanRules.combinedPlan(chosen)
        #expect(combined.framing == .grid)
        #expect(combined.framingProvenance == chosen[0].plan.framingProvenance)
        #expect(try await temp.database.wizardSelectionTake(id: second.id)?.plan.framing == .talker)
    }

    @Test func cancellingCameraFocusDoesNotPersistFallback() async throws {
        let (temp, options, take) = try await cameraFocusFixture()
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: cameraFocusService(calls: calls, reply: "{}", cancel: true), render: RenderEngine())
        await #expect(throws: CancellationError.self) {
            try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(), database: temp.database,
                emit: { _ in }, renderPlan: { _, _ in Issue.record("Cancelled camera choice must not render") })
        }
        #expect(try await temp.database.wizardSelectionTake(id: take.id)?.plan.framing == nil)
    }
}

extension WizardEngineTests {
    @Test func cameraFocusRejectsMultiCellResponseForASingleFeed() async throws {
        let (temp, options, take) = try await cameraFocusFixture()
        let scene = try #require(try await temp.database.fetchScenes(projectID: options.projectID).first)
        try await temp.database.setPodcastLayout(videoID: scene.videoID, layout: .singleCamera, seamX: nil, confidence: 1)
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: cameraFocusService(calls: calls,
            reply: #"{"choices":[{"id":\#(take.id),"framing":"grid","reason":"Invalid for this recording."}]}"#),
            render: RenderEngine())
        let chosen = try await engine.chooseCameraFocus(takes: [take], options: options,
            profile: Fixtures.brand(), database: temp.database, emit: { _ in })
        #expect(chosen[0].plan.framing == .talker)
        #expect(chosen[0].plan.framingProvenance?.provider == "local")
    }

    @Test func cameraFocusSkipsOrdinaryScenes() async throws {
        let (temp, options, take) = try await cameraFocusFixture()
        try await temp.database.removeSceneTags(sceneID: take.plan.clips[0].sceneID, withPrefix: "podcast")
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: cameraFocusService(calls: calls, reply: "{}"), render: RenderEngine())
        let chosen = try await engine.chooseCameraFocus(takes: [take], options: options,
            profile: Fixtures.brand(), database: temp.database, emit: { _ in })
        #expect(chosen[0].plan.framing == nil)
        #expect(calls.lines().isEmpty)
    }
}

extension WizardEngineTests {
    private func tagTextFixture() async throws -> (TempDatabase, WizardOptions, WizardSelectionTake, [Int64: SceneRecord]) {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let database = temp.database
        let projectID = try await database.createProject(profileName: "Tags", name: "Tags", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes().first)
        for key in ["ann", "bob", "outside"] {
            try await database.upsertPerson(key: key, descriptor: "tall, grey hoodie")
            let person = try #require(try await database.fetchPeople().first { $0.key == key })
            try await database.renamePerson(id: person.id, name: key.capitalized)
            if key != "outside" { try await database.addSceneTag(sceneID: scene.id, tag: "person:" + key) }
        }
        let roster = try await database.fetchPeople()
        try await database.replaceVideoPeople(videoID: videoID, entries: roster.map {
            (personID: $0.id, portraitAt: 0, portraitJSON: nil, rangesJSON: nil)
        })
        var options = WizardOptions()
        options.nameTags = true
        options.formatPreset = "custom"
        options.useMusic = false
        options.critiqueLoop = false
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id)])
        options.projectID = projectID
        let take = try await database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)
        let scenes = try await database.fetchScenes()
        return (temp, options, take, Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }))
    }

    private func tagTextService(calls: WizardCaptionTestLog, reply: String = #"{"ann":"Host","bob":"Guest"}"#,
                                failure: Bool = false, cancel: Bool = false) -> AIService {
        var config = AIConfig()
        config.tasks["tag_text"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        return AIService(config: config) { _, _, stdin, timeout, _, _ in
            calls.append(String(decoding: stdin ?? Data(), as: UTF8.self))
            if cancel { throw CancellationError() }
            if failure { throw AIError.unusableResponse("Fixture unavailable") }
            #expect(timeout == 90)
            let response = try JSONSerialization.data(withJSONObject: [
                "type": "assistant", "message": ["content": [["type": "text", "text": reply]]]
            ])
            return ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
    }

    @Test func tagTextBatchesMissingPeopleAndReusesCacheAcrossReels() async throws {
        let (temp, options, take, scenes) = try await tagTextFixture()
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: tagTextService(calls: calls), render: RenderEngine())
        for run in 0..<2 {
            let fields = try await engine.prepareTagText(plan: take.plan, options: options, profile: Fixtures.brand(),
                sceneMap: scenes, database: temp.database, emit: { _ in })
            #expect(Set(fields.map(\.personKey)) == (run == 0 ? ["ann", "bob"] : []))
            #expect(fields.allSatisfy { $0.provenance?.task == "tag_text" && $0.provenance?.model == "fixture" })
        }
        #expect(calls.lines().count == 1)
        #expect(calls.lines()[0].contains("ann") && calls.lines()[0].contains("bob"))
        #expect(!calls.lines()[0].contains("outside"), "A roster entry alone must not trigger tag text")
        let tagText = try await temp.database.tagText(field: "Role")
        #expect(tagText["ann"] == "Host")
        #expect(try await temp.database.fetchPeople().allSatisfy { $0.descriptor == "tall, grey hoodie" })
    }

    @Test func savedTagFieldWinsAndTheVisualDescriptionIsNeverTagText() async throws {
        let (temp, options, take, scenes) = try await tagTextFixture()
        for key in ["ann", "bob"] { try await temp.database.upsertPerson(key: key, descriptor: "tall, grey hoodie") }
        try await temp.database.savePersonTagField(personKey: "ann", field: "Role", value: "Saved role", provenance: nil)
        #expect(try await temp.database.tagText(field: "Role")["bob"] == nil)
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: tagTextService(calls: calls), render: RenderEngine())
        let fields = try await engine.prepareTagText(plan: take.plan, options: options, profile: Fixtures.brand(),
            sceneMap: scenes, database: temp.database, emit: { _ in })
        #expect(fields.filter { $0.provenance != nil }.map(\.personKey) == ["bob"])
        #expect(!calls.lines()[0].contains("\"key\":\"ann\""))
        let tagText = try await temp.database.tagText(field: "Role")
        #expect(tagText["ann"] == "Saved role")
        #expect(tagText["bob"] == "Guest")
    }

    @Test func failedTagTextRendersNameOnlyAndDoesNotCache() async throws {
        let (temp, options, take, scenes) = try await tagTextFixture()
        let engine = WizardEngine(ai: tagTextService(calls: WizardCaptionTestLog(), failure: true), render: RenderEngine())
        let fields = try await engine.prepareTagText(plan: take.plan, options: options, profile: Fixtures.brand(),
            sceneMap: scenes, database: temp.database, emit: { _ in })
        #expect(fields.isEmpty)
        var scene = try #require(scenes.values.first)
        scene.tags = ["person:ann"]
        let tagText = try await temp.database.tagText(field: "Role")
        let people = try await temp.database.fetchPeople()
        let tags = WizardNameTags.ordinary(scene: scene, duration: 4, people: people, tagText: tagText, options: options,
            captionStyle: CaptionStyle(), profile: Fixtures.brand())
        #expect(tags.first?.text == "Ann")
    }

    @Test func cancellationPropagatesWithoutCachingTagText() async throws {
        let (temp, options, take, scenes) = try await tagTextFixture()
        let engine = WizardEngine(ai: tagTextService(calls: WizardCaptionTestLog(), cancel: true), render: RenderEngine())
        await #expect(throws: CancellationError.self) {
            _ = try await engine.prepareTagText(plan: take.plan, options: options, profile: Fixtures.brand(),
                sceneMap: scenes, database: temp.database, emit: { _ in })
        }
        #expect(try await temp.database.personTagFields().isEmpty)
    }

    @Test func tagTextCacheIsPerFieldAndPeopleCanEditAndClearIt() async throws {
        let (temp, options, take, scenes) = try await tagTextFixture()
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: tagTextService(calls: calls), render: RenderEngine())
        var profile = Fixtures.brand()
        for field in ["Role", "Team"] {
            var style = TagStyle()
            style.description.field = field
            profile.tagStyle = style
            _ = try await engine.prepareTagText(plan: take.plan, options: options, profile: profile,
                sceneMap: scenes, database: temp.database, emit: { _ in })
        }
        #expect(calls.lines().count == 2)
        try await temp.database.savePersonTagField(personKey: "ann", field: "Team", value: "Corrected", provenance: nil)
        #expect(try await temp.database.tagText(field: "Team")["ann"] == "Corrected")
        try await temp.database.clearPersonTagField(personKey: "ann", field: "Team")
        #expect(try await temp.database.personTagFields(personKey: "ann").map(\.field) == ["Role"])
    }

    @Test func makeReelPreparesTagTextBeforeTheRenderHook() async throws {
        let (temp, options, take, _) = try await tagTextFixture()
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: tagTextService(calls: calls), render: RenderEngine())
        try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(), database: temp.database,
            emit: { _ in }, renderPlan: { _, _ in
                let cached = try? await temp.database.personTagFields()
                #expect(cached?.count == 2)
            })
        #expect(calls.lines().count == 1)
    }
}

extension WizardEngineTests {
    @Test func miniBatchPreparationDoesNotRetryMissingAnswersDuringEachReel() async throws {
        let (temp, options, take, scenes) = try await tagTextFixture()
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: tagTextService(calls: calls, reply: "{}"), render: RenderEngine())
        _ = try await engine.prepareTagText(plan: take.plan, options: options, profile: Fixtures.brand(),
            sceneMap: scenes, database: temp.database, emit: { _ in })
        for _ in 0..<2 {
            try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(), database: temp.database,
                tagTextPrepared: true, emit: { _ in }, renderPlan: { _, _ in })
        }
        #expect(calls.lines().count == 1)
        #expect(try await temp.database.personTagFields().isEmpty)
    }

    @Test func tagTextSkipsDisabledTagsAndPeopleOutsideThePlan() async throws {
        let (temp, base, take, scenes) = try await tagTextFixture()
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: tagTextService(calls: calls), render: RenderEngine())
        var options = base
        options.nameTags = false
        _ = try await engine.prepareTagText(plan: take.plan, options: options, profile: Fixtures.brand(),
            sceneMap: scenes, database: temp.database, emit: { _ in })
        options.nameTags = true
        _ = try await engine.prepareTagText(plan: Fixtures.plan(clips: []), options: options, profile: Fixtures.brand(),
            sceneMap: scenes, database: temp.database, emit: { _ in })
        #expect(calls.lines().isEmpty)
    }
}

extension WizardEngineTests {
    @Test func highlightsBatchKeptPeopleReuseCacheAndAttributeOnlyNewFields() async throws {
        let (temp, options, _, sceneMap) = try await tagTextFixture()
        let video = try #require(try await temp.database.fetchVideos().first)
        var scene = try #require(sceneMap.values.first)
        scene.tags = ["person:ann"]
        let people = try await temp.database.fetchPeople()
        let roster = people.map { person in
            VideoPersonRecord(videoID: video.id, personID: person.id, key: person.key, name: person.name,
                descriptor: person.descriptor, portraitAt: 0, portraitBox: nil)
        }
        let candidates = [
            HighlightCandidate(sourceStart: 0, sourceEnd: 2, title: "First", reason: "Test", score: 8,
                kind: .subcut, speakerKeys: ["ann"]),
            HighlightCandidate(sourceStart: 2, sourceEnd: 4, title: "Second", reason: "Test", score: 8,
                kind: .subcut, speakerKeys: ["bob"]),
            HighlightCandidate(sourceStart: 20, sourceEnd: 24, title: "Not kept", reason: "Test", score: 8,
                kind: .subcut, speakerKeys: ["outside"])
        ]
        let turns = [
            SpeakerTurn(videoID: video.id, start: 2, end: 4, cluster: 0, confidence: 1, personKey: "bob"),
            SpeakerTurn(videoID: video.id, start: 20, end: 24, cluster: 1, confidence: 1, personKey: "outside")
        ]
        let request = PodcastHighlightReviewRequest(video: video, candidates: candidates, scenes: [scene],
            segments: [], turns: turns, roster: roster, people: people, profile: Fixtures.brand(), options: options)
        let calls = WizardCaptionTestLog()
        let engine = WizardEngine(ai: tagTextService(calls: calls), render: RenderEngine())
        let kept = Array(candidates.prefix(2))
        let written = try await engine.prepareTagText(request: request, candidates: kept, database: temp.database, emit: { _ in })
        #expect(Set(written.map(\.personKey)) == ["ann", "bob"])
        #expect(written.allSatisfy { $0.provenance?.task == "tag_text" })
        #expect(try await temp.database.tagText(field: "Role") == ["ann": "Host", "bob": "Guest"])
        let cached = try await engine.prepareTagText(request: request, candidates: kept, database: temp.database, emit: { _ in })
        #expect(cached.isEmpty, "Cached fields must not be credited as AI work in this run")
        #expect(calls.lines().count == 1)
        #expect(calls.lines()[0].contains("ann") && calls.lines()[0].contains("bob"))
        #expect(!calls.lines()[0].contains("outside") && !calls.lines()[0].contains("grey hoodie"))
    }

    @Test func highlightsTagTextFailureUsesNamesAndCancellationPropagates() async throws {
        let (temp, options, _, sceneMap) = try await tagTextFixture()
        let video = try #require(try await temp.database.fetchVideos().first)
        let candidate = HighlightCandidate(sourceStart: 0, sourceEnd: 4, title: "Test", reason: "Test", score: 8,
            kind: .subcut, speakerKeys: ["ann", "bob"])
        let request = PodcastHighlightReviewRequest(video: video, candidates: [candidate], scenes: Array(sceneMap.values),
            segments: [], turns: [], roster: [], people: try await temp.database.fetchPeople(),
            profile: Fixtures.brand(), options: options)
        let failed = WizardEngine(ai: tagTextService(calls: WizardCaptionTestLog(), failure: true), render: RenderEngine())
        #expect(try await failed.prepareTagText(request: request, candidates: [candidate], database: temp.database, emit: { _ in }).isEmpty)
        #expect(try await temp.database.tagText(field: "Role").isEmpty)
        let cancelled = WizardEngine(ai: tagTextService(calls: WizardCaptionTestLog(), cancel: true), render: RenderEngine())
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.prepareTagText(request: request, candidates: [candidate], database: temp.database, emit: { _ in })
        }
        #expect(try await temp.database.tagText(field: "Role").isEmpty)
    }
}
