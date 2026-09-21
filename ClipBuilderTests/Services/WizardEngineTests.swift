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
