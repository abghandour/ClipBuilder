import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Podcast highlight entry points")
struct PodcastHighlightIntegrationTests {
    private func seed(_ temp: TempDatabase, profile: BrandProfile, filename: String = "fixture.mp4") async throws -> (project: Int64, video: VideoRecord) {
        let id = try await temp.database.registerVideo(hash: UUID().uuidString, filename: filename,
            path: temp.directory.url.appendingPathComponent(filename).path, duration: 30, width: 1920, height: 1080, wide: true)
        try await temp.database.setVideoType(id: id, type: "podcast")
        let ranges = [(start: 0.0, end: 8.0), (start: 10.0, end: 18.0), (start: 20.0, end: 28.0)]
        let run = try await temp.database.saveAnalysis(videoID: id, runName: "Exchanges", instructions: "",
            sampleInterval: 1, notesJSON: nil, tagRanges: ["podcast": ranges, "podcast-exchange": ranges, "person:guest": ranges],
            moments: [], analyzedTags: ["podcast"], provider: "fixture", model: "fixture", mode: "speech")
        let scenes = try await temp.database.fetchScenes(videoID: id).filter { $0.runID == run }
        for scene in scenes {
            try await temp.database.setSceneNarrative(scene.id, narrative: "Lesson \(Int(scene.startTime)) — A strong answer.", score: 8)
        }
        try await temp.database.replaceTranscripts(videoID: id, language: "en", isTranslation: false,
            segments: ranges.map { TranscriptSegment(start: $0.start, end: $0.end, text: "A full answer.", words: nil) },
            provider: "fixture", model: "fixture")
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Podcasts", videoIDs: [id])
        let video = try #require(try await temp.database.fetchVideos(projectID: project).first)
        return (project, video)
    }

    @Test func sidebarPreparationDoesNotCreateOrRenderBeforeReview() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "PodcastReviewTests")
        let input = try await seed(temp, profile: profile)
        let stub = try StubAI(response: "{}")
        let engine = WizardEngine(ai: stub.service, render: RenderEngine())
        var options = WizardOptions()
        options.projectID = input.project
        options.formatPreset = "podcast_highlights"
        options.highlightMaxSeconds = 25
        options.renderSettings.preset = .portrait4K
        options.renderSettings.quality = .archival
        options.sourcesRestricted = true
        options.sourceVideoPaths = [input.video.path]
        let review = try await engine.findPodcastHighlights(options: options, settings: PodcastSettings(), database: temp.database, emit: { _ in })
        #expect(review.options.renderSettings == options.renderSettings)
        #expect(review.highlightThreshold == PodcastSettings().highlightThreshold)
        #expect(review.candidates.count == 3)
        #expect(review.candidates.allSatisfy { $0.kind == .whole && $0.duration <= 25 })
        #expect(!review.options.reviewProposedCuts && !review.options.addCaptions && !review.options.useMusic)
        #expect(!review.options.useFightResearch && !review.options.critiqueLoop)
        #expect(review.options.tastePreset == "none" && review.options.screenCropLayouts.isEmpty)
        #expect(!review.options.includeWatermark && !review.options.enableTextOverlays)
        #expect(try await temp.database.fetchGeneratedVideos(projectID: input.project).isEmpty)
        #expect(try await temp.database.fetchTimelines(projectID: input.project).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stub.calls.path))
    }

    @Test func builderCreatesSeparateTimelinesWithoutRenderingOrReplacingOpenDocument() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "PodcastBuilderTests")
        let input = try await seed(temp, profile: profile)
        let stub = try StubAI(response: "{}")
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile, ai: stub.service, database: temp.database)
        store.activeProjectID = input.project
        var clip = Fixtures.timelineClip(sourceStart: 0, duration: 28)
        clip.videoFile = input.video.path
        let original = Fixtures.timelineDocument(clips: [clip])
        let json = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        let timelineID = try await temp.database.createTimeline(projectID: input.project, name: "Original", documentJSON: json)
        store.openTimelineRecord(try #require(try await temp.database.fetchTimeline(id: timelineID)))
        // Opening hydrates the document (derived track count, defaults), so
        // the untouched state to compare against is what is open now.
        let opened = store.builder.document
        #expect(opened.videoTrack.count == 1)
        let names = try await store.createPodcastHighlightTimelines(maxSeconds: 25)
        #expect(names.count == 3)
        #expect(names.allSatisfy { $0.hasPrefix(input.video.filename + " — Lesson") })
        #expect(try await temp.database.fetchTimelines(projectID: input.project).count == 4)
        #expect(store.openTimelineID == timelineID)
        #expect(store.builder.document == opened)
        #expect(try await temp.database.fetchGeneratedVideos(projectID: input.project).isEmpty)
    }
    @Test func emptyBuilderFallsBackToOnlyAnalyzedPodcast() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "PodcastFallbackTests")
        let input = try await seed(temp, profile: profile)
        let other = try await temp.seedVideo(sceneCount: 0)
        try await temp.database.setVideoType(id: other, type: "podcast")
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Mixed",
                                                            videoIDs: [input.video.id, other])
        let stub = try StubAI(response: "{}")
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile, ai: stub.service, database: temp.database)
        store.activeProjectID = project
        #expect(store.builder.document.videoTrack.isEmpty)
        let names = try await store.createPodcastHighlightTimelines(maxSeconds: 25)
        #expect(names.count == 3 && names.allSatisfy { $0.hasPrefix(input.video.filename + " — ") })
        #expect(store.builder.document.videoTrack.isEmpty)
    }

    @Test func multiplePinnedPodcastsListFilenamesAndAcceptRequestFragment() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "PodcastChoiceTests")
        let first = try await seed(temp, profile: profile, filename: "Interview Modestino.mp4")
        let second = try await seed(temp, profile: profile, filename: "Interview Alex.mp4")
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Interviews",
                                                            videoIDs: [first.video.id, second.video.id])
        let stub = try StubAI(response: "{}")
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile, ai: stub.service, database: temp.database)
        store.activeProjectID = project
        store.builder.addVideo(first.video)
        store.builder.addVideo(second.video)
        let opened = store.builder.document
        do {
            _ = try await store.createPodcastHighlightTimelines(maxSeconds: 25)
            Issue.record("Expected a recording choice")
        } catch {
            #expect(error.userMessage.contains(first.video.filename))
            #expect(error.userMessage.contains(second.video.filename))
        }
        #expect(try await temp.database.fetchTimelines(projectID: project).isEmpty)
        let names = try await store.createPodcastHighlightTimelines(maxSeconds: 25,
            requestText: "podcast highlights for Modestino, 25 seconds max")
        #expect(names.count == 3 && names.allSatisfy { $0.hasPrefix(first.video.filename + " — ") })
        #expect(store.builder.document == opened)
    }

    @Test func renderRefusalKeepsPendingReviewWithMessage() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "PodcastRenderGuardTests")
        let input = try await seed(temp, profile: profile)
        let stub = try StubAI(response: "{}")
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile, ai: stub.service, database: temp.database)
        var options = WizardOptions()
        options.projectID = input.project
        var review = try await WizardEngine(ai: stub.service, render: RenderEngine()).findPodcastHighlights(
            options: options, settings: PodcastSettings(), database: temp.database, emit: { _ in })
        let selected = Set(review.candidates.map(\.id))
        store.pendingPodcastHighlights = review
        store.isWizardRunning = true
        #expect(!store.renderPodcastHighlights(review, selected: selected))
        #expect(store.wizardFailureMessage?.contains("active") == true)
        #expect(store.pendingPodcastHighlights?.id == review.id)
        store.isWizardRunning = false
        review.profileGeneration = store.profileGeneration + 1
        store.pendingPodcastHighlights = review
        #expect(!store.renderPodcastHighlights(review, selected: selected))
        #expect(store.wizardFailureMessage?.contains("profile changed") == true)
        #expect(store.pendingPodcastHighlights?.id == review.id)
        #expect(try await temp.database.fetchGeneratedVideos(projectID: input.project).isEmpty)
    }


    @Test func reviewCarriesExplicitCameraAndBRollRequest() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "PodcastControlsTests")
        let input = try await seed(temp, profile: profile, filename: "Modestino.mp4")
        let stub = try StubAI(response: "{}")
        var options = WizardOptions()
        options.projectID = input.project
        options.brollInstructions = "Never cover the host."
        let review = try await WizardEngine(ai: stub.service, render: RenderEngine()).findPodcastHighlights(
            options: options, settings: PodcastSettings(), database: temp.database, emit: { _ in },
            requestText: "podcast highlights for Modestino camera: grid no b-roll")
        #expect(review.options.highlightFraming == .grid && !review.options.useBRoll)
        #expect(review.options.brollInstructions == options.brollInstructions)
        #expect(review.candidates.count == 3 && review.candidates.allSatisfy { $0.framing == .grid })
    }

    @Test func singleReelBRollControlsReachEditableTimeline() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "SingleReelBRollTests")
        let input = try await seed(temp, profile: profile)
        let other = try await temp.seedVideo(sceneCount: 1)
        let footage = try #require(try await temp.database.fetchScenes(videoID: other).first)
        try await temp.database.addSceneTag(sceneID: footage.id, tag: "person:guest")
        try await temp.database.setSceneNarrative(footage.id, narrative: "Strong lesson", score: 8)
        // A better-scoring recording of someone else never becomes this reel's B-roll.
        let stranger = try await temp.seedVideo(sceneCount: 1)
        let unrelated = try #require(try await temp.database.fetchScenes(videoID: stranger).first)
        try await temp.database.setSceneNarrative(unrelated.id, narrative: "Strong lesson", score: 10)
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "B-roll",
            videoIDs: [input.video.id, other, stranger])
        let source = try #require(try await temp.database.fetchScenes(videoID: input.video.id).first)
        let document = WizardEngine.timelineDocument(from: Fixtures.plan(clips: [Fixtures.planClip(sceneID: source.id,
            start: source.startTime, end: source.endTime)]), sceneMap: [source.id: source])
        for preset in ["podcast", "interview"] {
            var options = WizardOptions()
            options.projectID = project
            options.formatPreset = preset
            options.brollInstructions = "no reactions"
            let stub = try StubAI(response: "invalid")
            options.useBRoll = false
            let off = try await WizardPodcastBRoll.adding(to: document, options: options, database: temp.database,
                ai: stub.service, log: { _ in })
            #expect(off == document && !FileManager.default.fileExists(atPath: stub.calls.path))
            options.useBRoll = true
            let on = try await WizardPodcastBRoll.adding(to: document, options: options, database: temp.database,
                ai: stub.service, log: { _ in })
            let cutaways = on.videoTrack.filter(\.isCutaway)
            #expect(!cutaways.isEmpty && cutaways.allSatisfy { $0.sceneID == footage.id && $0.muted && $0.coverAllAreas })
            #expect(on.videoTrack.filter { !$0.isCutaway } == document.videoTrack)
        }
    }


    @Test func singleReelUsesOnePlacementCallAcrossSourceSpans() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "SingleReelPlacementTests")
        let input = try await seed(temp, profile: profile, filename: "Podcast.mp4")
        let other = try await temp.seedVideo(sceneCount: 1)
        let footage = try #require(try await temp.database.fetchScenes(videoID: other).first)
        try await temp.database.addSceneTag(sceneID: footage.id, tag: "person:guest")
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Placement",
            videoIDs: [input.video.id, other])
        let source = Array(try await temp.database.fetchScenes(videoID: input.video.id).sorted { $0.startTime < $1.startTime }.prefix(2))
        try await temp.database.replaceTranscripts(videoID: input.video.id, language: "en", isTranslation: false,
            segments: source.flatMap { scene in
                [TranscriptSegment(start: scene.startTime, end: scene.startTime + 3, text: "Hook.", words: nil),
                 TranscriptSegment(start: scene.startTime + 3, end: scene.endTime, text: "A fight.", words: nil)]
            }, provider: "fixture", model: "fixture")
        let plan = Fixtures.plan(clips: source.map {
            Fixtures.planClip(sceneID: $0.id, start: $0.startTime, end: $0.endTime)
        }, transitions: ["wipeleft"])
        let document = WizardEngine.timelineDocument(from: plan,
            sceneMap: Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) }))
        var options = WizardOptions()
        options.projectID = project
        options.formatPreset = "interview"
        options.brollInstructions = "Only illustrate the first answer with fight footage."
        let stub = try StubAI(response: """
        {"placements":[{"first_sentence":1,"last_sentence":1,"source":"scene:\(footage.id)","reason":"First answer only"}]}
        """)
        let logs = Mutex<[String]>([])
        let on = try await WizardPodcastBRoll.adding(to: document, options: options, database: temp.database,
            ai: stub.service, log: { line in logs.withLock { $0.append(line) } })
        let cuts = on.videoTrack.filter(\.isCutaway)
        #expect(cuts.count == 1 && cuts.first?.startTime == 3 && cuts.first?.duration == 3)
        let calls = try String(contentsOf: stub.calls, encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 1)
        let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
        #expect(prompt.contains("[3]"))
        #expect(logs.withLock { $0.filter { $0.contains("loaded source context") }.count } == 1)
        let prepared = WizardEngine.preparedDocument(from: on,
            clipURLs: source.map { URL(fileURLWithPath: "/tmp/extracted-\($0.id).mp4") }, transitions: plan.transitions)
        let main = prepared.videoTrack.filter { !$0.isCutaway }
        #expect(main[0].transOut == plan.transitions[0] && main[1].transIn == plan.transitions[0])
        #expect(prepared.videoTrack.filter(\.isCutaway) == cuts)
    }

    @Test(arguments: ["podcast", "interview"])
    func plainSingleReelKeepsOriginalTimeline(_ preset: String) async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand()
        let input = try await seed(temp, profile: profile)
        let other = try await temp.seedVideo(sceneCount: 1)
        let footage = try #require(try await temp.database.fetchScenes(videoID: other).first)
        try await temp.database.addSceneTag(sceneID: footage.id, tag: "person:guest")
        try await temp.database.setSceneNarrative(footage.id, narrative: "Strong lesson", score: 8)
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Plain reel",
            videoIDs: [input.video.id, other])
        let source = try await temp.database.fetchScenes(videoID: input.video.id)
            .sorted { $0.startTime < $1.startTime }
        let plan = Fixtures.plan(clips: source.map {
            Fixtures.planClip(sceneID: $0.id, start: $0.startTime, end: $0.endTime)
        }, transitions: ["wipeleft"])
        let document = WizardEngine.timelineDocument(from: plan,
            sceneMap: Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) }))
        var options = WizardOptions()
        options.projectID = project
        options.formatPreset = preset
        #expect(options.useBRoll)
        let stub = try StubAI(response: "invalid")
        for instructions in ["", " \n "] {
            options.brollInstructions = instructions
            let on = try await WizardPodcastBRoll.adding(to: document, options: options,
                database: temp.database, ai: stub.service, log: { _ in })
            #expect(on == document)
            #expect(on.videoTrack.allSatisfy { !$0.isCutaway })
            #expect(on.videoTrack.map(\.transIn) == document.videoTrack.map(\.transIn))
            #expect(!FileManager.default.fileExists(atPath: stub.calls.path))
        }
    }

    @Test func critiqueVersionsReusePlacementsAndInvalidateChangedRequests() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand()
        let input = try await seed(temp, profile: profile)
        let other = try await temp.seedVideo(sceneCount: 1)
        let footage = try #require(try await temp.database.fetchScenes(videoID: other).first)
        try await temp.database.addSceneTag(sceneID: footage.id, tag: "person:guest")
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Cached B-roll",
            videoIDs: [input.video.id, other])
        let source = try #require(try await temp.database.fetchScenes(videoID: input.video.id).first)
        try await temp.database.replaceTranscripts(videoID: input.video.id, language: "en", isTranslation: false,
            segments: [.init(start: source.startTime, end: source.startTime + 3, text: "Hook.", words: nil),
                       .init(start: source.startTime + 3, end: source.endTime, text: "Answer.", words: nil)],
            provider: "fixture", model: "fixture")
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: source.id, start: source.startTime, end: source.endTime)])
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.projectID = project
        options.critiqueLoop = true
        options.brollInstructions = "Use external footage."
        let maxVersions = options.critiqueLoop ? 3 : 1
        let stub = try StubAI(response: """
        {"placements":[{"first_sentence":1,"last_sentence":1,"source":"scene:\(footage.id)","reason":"Answer"}]}
        """)
        var cache = WizardPodcastBRoll.Cache()
        var last = TimelineDocument()
        // Exercise the assembly's B-roll stage for each critique version. Each
        // version has fresh clip identities and may change non-source settings.
        for version in 1...maxVersions {
            var document = WizardEngine.timelineDocument(from: plan, sceneMap: [source.id: source])
            document.videoTrack[0].captions = version == 1 ? "none" : "bottom"
            var card = TimelineClip()
            card.videoFile = "/tmp/version-\(version)/outro.mp4"
            card.startTime = document.videoTrack[0].duration
            card.duration = 2.5
            document.videoTrack.append(card)
            last = try await WizardPodcastBRoll.adding(to: document, options: options,
                database: temp.database, ai: stub.service, cache: &cache, log: { _ in })
            let cuts = last.videoTrack.filter(\.isCutaway)
            #expect(cuts.count == 1 && cuts[0].startTime == 3 && cuts[0].duration == 3)
            #expect(last.videoTrack.filter { !$0.isCutaway } == document.videoTrack)
        }
        #expect(try String(contentsOf: stub.calls, encoding: .utf8).split(separator: "\n").count == 1)
        var changed = last
        changed.videoTrack.removeAll(where: \.isCutaway)
        changed.videoTrack[0].sourceEnd = source.endTime - 1
        changed.videoTrack[0].duration -= 1
        _ = try await WizardPodcastBRoll.adding(to: changed, options: options,
            database: temp.database, ai: stub.service, cache: &cache, log: { _ in })
        #expect(try String(contentsOf: stub.calls, encoding: .utf8).split(separator: "\n").count == 2)
        options.brollInstructions = "No reactions; use external footage."
        _ = try await WizardPodcastBRoll.adding(to: changed, options: options,
            database: temp.database, ai: stub.service, cache: &cache, log: { _ in })
        #expect(try String(contentsOf: stub.calls, encoding: .utf8).split(separator: "\n").count == 3)
        var nextRun = WizardPodcastBRoll.Cache()
        _ = try await WizardPodcastBRoll.adding(to: changed, options: options,
            database: temp.database, ai: stub.service, cache: &nextRun, log: { _ in })
        #expect(try String(contentsOf: stub.calls, encoding: .utf8).split(separator: "\n").count == 4)
    }

    @Test func renderKeyCoversEveryInputAndFindsTheReelStillOnDisk() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "RenderKeyTests")
        let input = try await seed(temp, profile: profile)
        var options = WizardOptions()
        options.projectID = input.project
        options.formatPreset = "podcast_highlights"
        let review = try await WizardEngine(ai: StubAI(response: "{}").service, render: RenderEngine()).findPodcastHighlights(
            options: options, settings: PodcastSettings(), database: temp.database, emit: { _ in })
        let candidate = try #require(review.candidates.first)
        let key = { (request: PodcastHighlightReviewRequest, source: String, layouts: [ScreenCropLayout]) in
            try PodcastHighlightRenderKey.make(candidate: candidate, request: request, layouts: layouts, profile: profile, sourceFingerprint: source)
        }
        let base = try key(review, "size:1", [])
        #expect(try key(review, "size:1", []) == base)
        #expect(try key(review, "size:2", []) != base)
        var changed = review
        changed.options.brollInstructions = "Show the guest's fights."
        #expect(try key(changed, "size:1", []) != base)
        changed = review
        changed.scenes[0].tags.append("person:guest-2")
        #expect(try key(changed, "size:1", []) != base)
        changed = review
        changed.highlightThreshold += 0.5
        #expect(try key(changed, "size:1", []) != base)
        let layouts = ScreenCropStore.all()
        let withLayouts = try key(review, "size:1", layouts)
        #expect(layouts.isEmpty || withLayouts != base)
        var other = candidate
        other.sourceEnd += 1
        #expect(try PodcastHighlightRenderKey.make(candidate: other, request: review, layouts: [], profile: profile, sourceFingerprint: "size:1") != base)

        let reel = temp.directory.url.appendingPathComponent("reel.mp4")
        try Data("reel".utf8).write(to: reel)
        let settings = WizardRunSettings(options: options, renderFingerprint: base)
        let id = try await temp.database.insertGeneratedVideo(path: reel.path, duration: 5, timelineJSON: "{}",
            wizardProvider: nil, wizardModel: nil, projectID: input.project, settings: settings)
        #expect(try await temp.database.generatedVideo(projectID: input.project, renderFingerprint: base)?.id == id)
        #expect(try await temp.database.generatedVideo(projectID: input.project, renderFingerprint: "other") == nil)
        try FileManager.default.removeItem(at: reel)
        #expect(try await temp.database.generatedVideo(projectID: input.project, renderFingerprint: base) == nil)
    }

    @Test func sourceContextLoadsOncePerDistinctRecording() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand()
        let first = try await seed(temp, profile: profile, filename: "First.mp4")
        let second = try await seed(temp, profile: profile, filename: "Second.mp4")
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Two sources",
            videoIDs: [first.video.id, second.video.id])
        let scenes = try await temp.database.fetchScenes(projectID: project, includeExcluded: false)
        let plan = Fixtures.plan(clips: scenes.map {
            Fixtures.planClip(sceneID: $0.id, start: $0.startTime, end: $0.endTime)
        })
        let document = WizardEngine.timelineDocument(from: plan,
            sceneMap: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }))
        var options = WizardOptions()
        options.projectID = project
        options.formatPreset = "interview"
        options.brollInstructions = "Only reactions."
        let stub = try StubAI(response: #"{"placements":[]}"#)
        let logs = Mutex<[String]>([])
        _ = try await WizardPodcastBRoll.adding(to: document, options: options,
            database: temp.database, ai: stub.service, log: { line in logs.withLock { $0.append(line) } })
        let loads = logs.withLock { $0.filter { $0.contains("loaded source context") } }
        #expect(scenes.count == 6 && loads.count == 2)
        #expect(loads.contains("B-roll: loaded source context for video \(first.video.id)."))
        #expect(loads.contains("B-roll: loaded source context for video \(second.video.id)."))
    }
}
