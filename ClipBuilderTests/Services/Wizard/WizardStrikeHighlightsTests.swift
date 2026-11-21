import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct WizardStrikeHighlightsTests {
    private struct AssemblyPrepared: Error {}

    @Test("Proxy source selection includes only fight footage used by the plan")
    func proxySources() {
        let videos = (1...3).map { index in
            var video = Fixtures.video(id: Int64(index))
            video.path = "/tmp/proxy-source-\(index).mp4"
            video.videoType = index == 2 ? VideoType.interview.rawValue : VideoType.fight.rawValue
            return video
        }
        let scenes = videos.map { video in
            var scene = Fixtures.scene(id: video.id)
            scene.videoID = video.id
            scene.videoPath = video.url.path
            return scene
        }
        // The scene map includes an unused fight. The used interview must
        // not be marked, even though its plan shares the highlight option.
        let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 1), Fixtures.planClip(sceneID: 2),
                                        Fixtures.planClip(sceneID: 1)])
        var options = WizardOptions()
        options.strikeHighlights = true
        let proxyOptions = WizardEngine.proxyOptions(options)
        var document = WizardEngine.timelineDocument(from: plan, sceneMap: sceneMap,
            renderSettings: proxyOptions.renderSettings, framing: Framing(subject: .original))
        let types = Dictionary(uniqueKeysWithValues: videos.compactMap { video in
            video.type.map { (video.url.path, $0) }
        })
        WizardStrikeHighlights.apply(to: &document, enabled: proxyOptions.strikeHighlights, sourceTypes: types)
        let paths = WizardStrikeHighlights.sourcePaths(in: [document])
        #expect(paths == Set([videos[0].url.path]))
        #expect(WizardStrikeHighlights.sources(for: paths, videos: videos).map(\.id) == [1])
        // Source selection remains defensive if a document has a stale flag.
        #expect(WizardStrikeHighlights.sources(for: Set(videos.map { $0.url.path }), videos: videos).map(\.id) == [1, 3])
        WizardStrikeHighlights.apply(to: &document, enabled: false, sourceTypes: types)
        #expect(WizardStrikeHighlights.sourcePaths(in: [document]).isEmpty)
    }

    @Test("Missing-highlight wording distinguishes errors, unscored, negative, unmarked and unknown sources")
    func missingMarksMessage() {
        let scored = WizardStrikeHighlights.SavedStatus(hasFightEvents: true, hasStrikes: true, hasSavedRows: false)
        #expect(WizardStrikeHighlights.missingMarksMessage(filename: "fight.mp4", status: scored, readError: "disk read failed")
            == "Strike highlights: could not read saved highlights for fight.mp4 — disk read failed")
        #expect(WizardStrikeHighlights.missingMarksMessage(filename: "fight.mp4",
            status: .init(hasFightEvents: false, hasStrikes: false, hasSavedRows: false))
            == "Strike highlights: none saved for fight.mp4; score the fight first")
        #expect(WizardStrikeHighlights.missingMarksMessage(filename: "fight.mp4",
            status: .init(hasFightEvents: true, hasStrikes: true, hasSavedRows: true))
            == "Strike highlights: no drawable strike highlights saved for fight.mp4")
        #expect(WizardStrikeHighlights.missingMarksMessage(filename: "fight.mp4", status: scored)
            == "Strike highlights: strikes are not marked yet for fight.mp4; use Sources → Mark strikes")
        #expect(WizardStrikeHighlights.missingMarksMessage(filename: "fight.mp4", status: nil)
            == "Strike highlights: could not check saved highlights for fight.mp4")
        #expect(WizardStrikeHighlights.missingMarksMessage(filename: "fight.mp4",
            status: .init(hasFightEvents: true, hasStrikes: false, hasSavedRows: false))
            == "Strike highlights: no drawable strike highlights saved for fight.mp4")
    }

    @Test("The status lookup includes negative matches, rejects old generations and recognizes takedown-only fights")
    func savedStatus() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        #expect(try await temp.database.strikeHighlightStatus(videoID: videoID)
            == .init(hasFightEvents: false, hasStrikes: false, hasSavedRows: false))
        try await temp.database.replaceFightEvents(videoID: videoID,
            events: [(time: 4, fighterKey: "a", action: "strike", points: 1)])
        #expect(try await temp.database.strikeHighlightStatus(videoID: videoID)
            == .init(hasFightEvents: true, hasStrikes: true, hasSavedRows: false))
        let generation = try await temp.database.fightEventGeneration(videoID: videoID)
        try await temp.database.saveStrikeHighlights(videoID: videoID,
            [.init(videoID: videoID, time: 4, fighterKey: "a", track: nil)], generation: generation)
        #expect(try await temp.database.strikeHighlightStatus(videoID: videoID)
            == .init(hasFightEvents: true, hasStrikes: true, hasSavedRows: true))
        // Advance without deleting rows to exercise the query's generation filter.
        try await temp.database.advanceFightEventGeneration(videoID: videoID)
        #expect(try await !temp.database.strikeHighlightStatus(videoID: videoID).hasSavedRows)
        try await temp.database.replaceFightEvents(videoID: videoID,
            events: [(time: 4, fighterKey: "a", action: "takedown", points: 4)])
        #expect(try await temp.database.strikeHighlightStatus(videoID: videoID)
            == .init(hasFightEvents: true, hasStrikes: false, hasSavedRows: false))
    }

    @Test("Real proxies and final extraction share contacts for marks, pauses, both, or a plain rough cut", arguments: [0, 1, 2, 3])
    func realProxyAndFinalRender(mode: Int) async throws {
        let highlights = mode == 0 || mode == 1
        let pauses = mode != 0
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        try await database.setVideoType(id: videoID, type: VideoType.fight.rawValue)
        try await database.replaceFightEvents(videoID: videoID,
            events: [(time: 2, fighterKey: "a", action: "strike", points: 1)])
        let projectID = try await database.createProject(profileName: "Real highlights", name: "Run", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 1, end: 4)])
        var options = WizardOptions()
        options.projectID = projectID
        options.strikeHighlights = highlights
        options.strikeImpactFreeze = pauses ? 0.8 : nil
        options.transitionChoice = "cut"
        options.useMusic = false
        options.useBRoll = false
        options.addCaptions = false
        options.enableTextOverlays = false
        options.includeHeadline = false
        options.includeWatermark = false
        options.includeOutro = false
        options.critiqueLoop = false
        options.framing = Framing(subject: .original)
        if mode == 3 {
            options.strikeHighlights = true
            options = WizardRoughCut.options(options)
            #expect(options.strikeHighlights == false && options.strikeImpactFreeze == 0.8)
        }
        let take = try await database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)
        let ai = AIService(config: AIConfig()) { _, _, _, _, _, _ in
            Issue.record("Highlight orchestration must not call a model")
            throw CancellationError()
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        let highlight = StrikeHighlightRules.Highlight(limb: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25)],
            target: CGPoint(x: 0.32, y: 0.25), radius: 0.06, cost: 0.1,
            limbSide: .left, usesArm: true, attackerOnLeft: true)
        let track = StrikeHighlightRules.Track(keyframes: [.init(time: 2, highlight: highlight)], contact: 2, aspect: 16.0 / 9)
        let expected = [scene.videoPath: [StrikeHighlightRules.drawable(track)]]
        let order = Mutex<[String]>([])
        let renders = Mutex(0)
        let output = temp.directory.url.appendingPathComponent("proxy.mp4")
        let profile = Fixtures.brand(name: "Real highlights")
        try await WizardStrikeHighlightSnapshot.$current.withValue(WizardStrikeHighlightSnapshot()) {
            try await WizardStrikeHighlights.$finder.withValue({ _, id, events, _ in
                order.withLock { $0.append("find") }
                #expect(id == videoID && events.count == 1)
                return [.init(videoID: id, time: 2, fighterKey: "a", track: track)]
            }) {
                try await MultitrackRenderer.$strikeHighlightRenderOverride.withValue({ document, tracks in
                    #expect(document.videoTrack.contains(where: { $0.strikeHighlights == true }) == highlights)
                    #expect(document.videoTrack.count == (pauses ? 3 : 1))
                    #expect(document.videoTrack.contains(where: { $0.hold == true }) == pauses)
                    #expect(abs(document.videoTrack.reduce(0) { $0 + $1.duration } - (pauses ? 3.8 : 3)) < 1e-9)
                    #expect(tracks == expected)
                    let ordinal = renders.withLock { $0 += 1; return $0 }
                    order.withLock { $0.append("render \(ordinal)") }
                    if ordinal == 3 { throw AssemblyPrepared() }
                    return .init(url: output, duration: pauses ? 3.8 : 3)
                }) {
                    for _ in 0..<2 {
                        _ = try await engine.renderProxy(plan: plan, sceneMap: [scene.id: scene], options: options,
                            profile: profile, database: database, emit: { _ in })
                    }
                    do {
                        try await engine.makeReel(take: take, options: options, profile: profile,
                            database: database, emit: { _ in })
                        Issue.record("The final extraction must reach the renderer seam")
                    } catch is AssemblyPrepared {}
                }
            }
        }
        #expect(order.withLock { $0 } == ["find", "render 1", "render 2", "render 3"])
        #expect(renders.withLock { $0 } == 3)
    }

    @Test("Automatic critique takes and the final render share one run snapshot")
    func automaticRunSnapshot() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Highlight run", name: "Run", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        let reply = """
        {"target_duration":8,"rationale":"Keep the complete moment","headline":"The moment",
         "clips":[{"scene_id":\(scene.id),"start":0,"end":8,"reason":"Complete moment"}]}
        """
        let response = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "message": ["content": [["type": "text", "text": reply]]]
        ])
        var config = AIConfig()
        config.tasks["wizard"] = "claude"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        let ai = AIService(config: config) { _, _, _, _, _, _ in
            ProcessResult(stdout: response, stderr: Data(), exitCode: 0)
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        var options = WizardOptions()
        options.projectID = projectID
        options.useMusic = false
        options.tastePreset = "none"
        options.framing = Framing(subject: .original)
        options.strikeHighlights = true
        options.critiqueLoop = true
        options.critiqueMaxVersions = 2
        let snapshots = Mutex<[WizardStrikeHighlightSnapshot]>([])
        let directory = temp.directory.url
        try await engine.runAutomatic(options: options, profile: Fixtures.brand(name: "Highlight run"),
            database: database, emit: { _ in }, renderTake: { _, _ in
                let snapshot = try #require(WizardStrikeHighlightSnapshot.current)
                snapshots.withLock { $0.append(snapshot) }
            }, renderProxy: { _, _, proxyOptions in
                #expect(proxyOptions.strikeHighlights == true)
                #expect(WizardStrikeHighlightContext.current != nil)
                let snapshot = try #require(WizardStrikeHighlightSnapshot.current)
                snapshots.withLock { $0.append(snapshot) }
                let url = directory.appendingPathComponent("proxy-\(UUID().uuidString).mp4")
                try Data("proxy fixture".utf8).write(to: url)
                return MultitrackRenderer.RenderResult(url: url, duration: 8)
            }, reviewContent: { _, _, take, _ in
                ReelCritique(score: 70, summary: "Content review", strengths: [], issues: [], notes: [],
                    regenerate: take.ordinal == 1, provider: "fixture", model: "critic")
            })
        let captured = snapshots.withLock { $0 }
        #expect(captured.count == 3)
        let first = try #require(captured.first)
        #expect(captured.allSatisfy { $0 === first })
        #expect(WizardStrikeHighlightSnapshot.current == nil)
    }

    @Test("Only fight footage gets highlights, independently of scene tags", arguments: VideoType.allCases)
    func sourceTypes(_ type: VideoType) throws {
        var scene = Fixtures.scene()
        scene.tags = ["fight"]
        var cut = WizardOrdinaryTimeline.cutDocument(clip: Fixtures.planClip(), sceneMap: [scene.id: scene],
            settings: RenderSettings(), framingPlan: nil)
        WizardStrikeHighlights.apply(to: &cut, enabled: true, sourceTypes: [scene.videoPath: type])
        let clip = try #require(cut.videoTrack.first)
        #expect((clip.strikeHighlights == true) == (type == .fight))
        for enabled: Bool? in [nil, false] {
            WizardStrikeHighlights.apply(to: &cut, enabled: enabled, sourceTypes: [scene.videoPath: .fight])
            #expect(cut.videoTrack.allSatisfy { $0.strikeHighlights == nil })
        }
    }

    @Test("Bumpers, generated cards, cutaways and unknown sources never get marks")
    func decorationsAndUnknownSources() {
        let path = "/tmp/fight.mp4"
        var main = Fixtures.timelineClip()
        main.videoFile = path
        var bumper = main
        bumper.bumper = true
        var cutaway = main
        cutaway.role = .cutaway
        var card = main
        card.videoFile = WizardEngine.wizardCardsRoot.appendingPathComponent("test/intro_card.mp4").path
        var unknown = main
        unknown.videoFile = "/tmp/unknown.mp4"
        var secondary = main
        secondary.track = 1
        var document = Fixtures.timelineDocument(clips: [main, bumper, cutaway, card, unknown, secondary])
        WizardStrikeHighlights.apply(to: &document, enabled: true,
            sourceTypes: [path: .fight, card.videoFile!: .fight])
        #expect(document.videoTrack.map { $0.strikeHighlights == true } == [true, false, false, false, false, true])
    }

    @Test("Cut flags survive assembly, retiming and extraction windows but not the final compositor")
    func renderCopies() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        try await temp.database.setVideoType(id: videoID, type: VideoType.fight.rawValue)
        let projectID = try await temp.database.createProject(profileName: "Highlights", name: "Highlights", videoIDs: [videoID])
        let scene = try #require(try await temp.database.fetchScenes(projectID: projectID).first)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 1, end: 4)])
        var options = WizardOptions()
        options.projectID = projectID
        options.useMusic = false
        options.useBRoll = false
        options.critiqueLoop = false
        options.framing = Framing(subject: .original)
        options.strikeHighlights = true
        let take = try await temp.database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)
        let ai = AIService(config: AIConfig()) { _, _, _, _, _, _ in
            Issue.record("Highlight assembly must not call a model")
            throw CancellationError()
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        let documents = Mutex<[TimelineDocument]>([])
        let cuts = Mutex<[Int: TimelineDocument]>([:])
        do {
            try await WizardEngine.$preparedDocumentProbe.withValue({ document in
                documents.withLock { $0.append(document) }
            }) {
                try await WizardEngine.$preparedCutsProbe.withValue({ prepared in
                    cuts.withLock { $0 = prepared }
                    throw AssemblyPrepared()
                }) {
                    try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(name: "Highlights"),
                                              database: temp.database, emit: { _ in })
                }
            }
            Issue.record("Stop before encoding")
        } catch is AssemblyPrepared {}
        let cut = try #require(cuts.withLock { $0[0] })
        let editable = try #require(documents.withLock { $0.first })
        let retimed = WizardOrdinaryTimeline.retimed(cut, speed: 0.5)
        let extraction = MultitrackRenderer.windowed(retimed, from: 0.5, to: 1.5)
        #expect(extraction.videoTrack.allSatisfy { $0.strikeHighlights == true })
        #expect(!extraction.videoTrack.isEmpty)
        let resolved = try #require(MultitrackRenderer.resolveClips(document: extraction, scenes: [scene]).first)
        #expect(resolved.strikeHighlights == true)
        #expect(editable.videoTrack.contains(where: { $0.strikeHighlights == true }))
        let rendered = URL(fileURLWithPath: "/tmp/extracted-fight.mp4")
        let compositor = WizardEngine.preparedDocument(from: editable, clipURLs: [rendered], transitions: [])
        let normalized = try #require(compositor.videoTrack.first)
        #expect(normalized.videoFile == rendered.path && normalized.sceneID == nil)
        #expect(!compositor.videoTrack.contains(where: { $0.strikeHighlights == true }))
        #expect(editable.videoTrack.contains(where: { $0.strikeHighlights == true }))
    }

    @Test("Marking selects missing strikes, respects saved negative matches and ignores other fight events")
    func missingMarks() {
        let first = FightEventRecord(id: 1, videoID: 1, time: 1, fighterKey: "a", action: "strike", points: 1)
        let second = FightEventRecord(id: 2, videoID: 1, time: 3, fighterKey: "a", action: "strike", points: 1)
        let takedown = FightEventRecord(id: 3, videoID: 1, time: 5, fighterKey: "a", action: "takedown", points: 4)
        let events = [first, second, takedown]
        #expect(WizardStrikeHighlights.missingStrikes(events: [], saved: []).isEmpty)
        #expect(WizardStrikeHighlights.missingStrikes(events: [takedown], saved: []).isEmpty)
        #expect(WizardStrikeHighlights.missingStrikes(events: events, saved: []).map(\.id) == [1, 2])
        let negative = StrikeHighlightRecord(videoID: 1, time: 1, fighterKey: "a", track: nil)
        #expect(WizardStrikeHighlights.missingStrikes(events: events, saved: [negative]).map(\.id) == [2])
        let allSaved = [negative, StrikeHighlightRecord(videoID: 1, time: 3, fighterKey: "a", track: nil)]
        #expect(WizardStrikeHighlights.missingStrikes(events: events, saved: allSaved).isEmpty)
        let otherVideo = StrikeHighlightRecord(videoID: 2, time: 1, fighterKey: "a", track: nil)
        #expect(WizardStrikeHighlights.missingStrikes(events: events, saved: [otherVideo]).count == 2)
    }
}
