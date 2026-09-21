import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Podcast highlight timelines and batch bookkeeping")
struct PodcastHighlightTimelineTests {
    @Test func exactPlainFootageWindow() {
        let candidate = HighlightCandidate(sourceStart: 2.13, sourceEnd: 6.87, title: "Test", reason: "Test", score: 8, kind: .subcut, speakerKeys: [])
        let document = PodcastHighlightTimeline.build(candidate: candidate, video: Fixtures.video(), scenes: [Fixtures.scene()],
            turns: [], roster: [], segments: [], layouts: [], settings: RenderSettings(), log: { _ in })
        #expect(document.videoTrack.count == 1)
        #expect(document.videoTrack.first?.sourceStart == 2.13)
        #expect(document.videoTrack.first?.sourceEnd == 6.87)
        #expect(document.videoTrack.first?.captions == "none")
        #expect(document.soundTrack.isEmpty && document.textOverlays.isEmpty && document.imageOverlays.isEmpty && document.overlayBlocks.isEmpty)
        #expect(document.renderSettings.preset == .portrait1080)
    }

    @Test func recipesKeepOnlyFirstTrackAudibleAndCutawaysMuted() throws {
        var video = Fixtures.video()
        video.podcastLayout = "grid"
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "ann"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "bob")]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 4, cluster: 0, confidence: 1, personKey: "ann", tile: 0),
                     SpeakerTurn(videoID: 1, start: 4, end: 10, cluster: 1, confidence: 1, personKey: "bob", tile: 1)]
        let segments = [TranscriptSegment(start: 0, end: 10, text: "A full exchange.", words: nil)]
        for framing in [CropRecipe.Kind.talker, .talkerAndPrevious] {
            let candidate = HighlightCandidate(sourceStart: 0, sourceEnd: 10, title: "Test", reason: "Test", score: 8,
                                               kind: .whole, framing: framing, speakerKeys: ["ann", "bob"])
            let document = PodcastHighlightTimeline.build(candidate: candidate, video: video, scenes: [], turns: turns,
                roster: [], segments: segments, layouts: ScreenCropStore.builtIn, settings: RenderSettings(), log: { _ in })
            let main = document.videoTrack.filter { !$0.isCutaway }
            #expect(main.count == (framing == .talker ? 1 : 2))
            #expect(main.filter { !$0.muted }.count == 1)
            #expect(main.allSatisfy { $0.cameraPath != nil && $0.captions == "none" && $0.duration == 10 })
            let cuts = document.videoTrack.filter(\.isCutaway)
            #expect(!cuts.isEmpty)
            #expect(cuts.allSatisfy { $0.muted && $0.coverAllAreas && $0.cutawaySourceWindow != nil && $0.startTime >= 2 && $0.duration <= 3 })
            #expect(document.textOverlays.isEmpty && document.overlayBlocks.isEmpty && document.soundTrack.isEmpty)
            let restored = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(document))
            #expect(restored.videoTrack.filter(\.isCutaway).allSatisfy { $0.cutawaySourceWindow != nil && $0.areaWindow == nil })
            let resolved = MultitrackRenderer.resolveClips(document: restored, scenes: [])
            #expect(resolved.filter { $0.role == .cutaway }.allSatisfy { $0.staticAreaFilter?.contains("crop=") == true && $0.fillCanvas })
        }
    }

    @Test func oneTimelinePerReelWithinSharedBatch() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand(name: "PodcastHighlightTimelineTests")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Highlights")
        let document = Fixtures.timelineDocument()
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        for index in 1...3 {
            try await temp.database.insertGeneratedVideo(path: "/tmp/highlight-\(index).mp4", duration: 4,
                timelineJSON: json, wizardProvider: nil, wizardModel: nil, projectID: project, batchID: "shared-batch")
        }
        let videos = try await temp.database.fetchGeneratedVideos(projectID: project)
        #expect(Set(videos.compactMap(\.batchID)) == ["shared-batch"])
        let names = Dictionary(uniqueKeysWithValues: videos.map { ($0.path, "Podcast recording.mp4 — Choice \($0.id)") })
        await store.recordWizardTimelines(videos, projectID: project, formatName: "podcast_highlights", timelineNames: names)
        await store.recordWizardTimelines(videos, projectID: project, formatName: "podcast_highlights", timelineNames: names)
        let timelines = try await temp.database.fetchTimelines(projectID: project)
        #expect(timelines.count == 3)
        #expect(Set(timelines.map(\.name)) == Set(names.values))
        #expect(Set(videos.map { AppStore.wizardTimelineKey($0, formatName: "podcast") }) == ["shared-batch"])
        #expect(Set(videos.map { AppStore.wizardTimelineKey($0, formatName: "mma-finish") }) == ["shared-batch"])
    }
    @Test func composedPortraitAndSquareSourcesDoNotForceWide() throws {
        for size in [(1080, 1920), (1080, 1080), (1920, 1080)] {
            var video = Fixtures.video()
            video.width = size.0; video.height = size.1
            video.podcastLayout = "grid"
            video.podcastTilesJSON = String(decoding: try JSONEncoder().encode([
                PodcastTile(index: 0, x: 0, y: 0, w: 1, h: 1, personKey: "ann")
            ]), as: UTF8.self)
            let turns = [SpeakerTurn(videoID: 1, start: 0, end: 10, cluster: 0, confidence: 1, personKey: "ann", tile: 0)]
            let candidate = HighlightCandidate(sourceStart: 0, sourceEnd: 10, title: "Test", reason: "Test", score: 8,
                                               kind: .whole, speakerKeys: ["ann"])
            var settings = RenderSettings()
            settings.preset = .portrait4K
            settings.quality = .archival
            let document = PodcastHighlightTimeline.build(candidate: candidate, video: video, scenes: [], turns: turns,
                roster: [], segments: [], layouts: ScreenCropStore.builtIn, settings: settings, log: { _ in })
            #expect(document.renderSettings == settings)
            let main = try #require(document.videoTrack.first { !$0.isCutaway })
            #expect(main.cameraPath != nil)
            #expect(main.wide == (size.0 > size.1))
        }
    }


    @Test func brollOffSkipsEvenSuppliedPlacements() {
        var scene = Fixtures.scene(id: 2, start: 0, end: 10)
        scene.videoID = 2
        scene.tags = ["person:guest"]
        let candidate = HighlightCandidate(sourceStart: 0, sourceEnd: 10, title: "Test", reason: "Test", score: 8,
                                           kind: .whole, speakerKeys: ["guest"])
        var options = WizardOptions()
        options.useBRoll = false
        let document = PodcastHighlightTimeline.build(candidate: candidate, video: Fixtures.video(), scenes: [scene],
            turns: [], roster: [], segments: [], layouts: [], settings: RenderSettings(), options: options,
            plannedCuts: [.init(source: .scene(2), sourceStart: 0, start: 2, duration: 3, reason: "Must not appear")], log: { _ in })
        #expect(!document.videoTrack.contains { $0.isCutaway })
        #expect(document.videoTrack.count == 1 && document.videoTrack[0].duration == 10)
    }

}
