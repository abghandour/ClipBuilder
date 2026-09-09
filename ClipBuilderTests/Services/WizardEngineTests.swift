import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard engine")
struct WizardEngineTests {
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

@Suite(.serialized)
struct LearnedWizardPromptTests {
    @Test func offPathIsByteIdenticalAndContributorOnlyAppendsItsLines() async throws {
        let data = try DataFolderOverride()
        defer { _ = data }
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
        let data = try DataFolderOverride()
        defer { _ = data }
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
