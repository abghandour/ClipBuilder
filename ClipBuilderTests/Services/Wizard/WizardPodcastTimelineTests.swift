import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Wizard podcast camera timelines")
struct WizardPodcastTimelineTests {
    private func source() throws -> (VideoRecord, SceneRecord, [SpeakerTurn]) {
        var video = Fixtures.video()
        video.podcastLayout = "grid"
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode([
            PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "ann"),
            PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "bob"),
        ]), as: UTF8.self)
        var scene = Fixtures.scene(start: 0, end: 10)
        scene.tags = ["podcast", "podcast-exchange"]
        scene.centerStagePathJSON = String(decoding: try JSONEncoder().encode(SceneCameraPath(camera: "podcast", keyframes: [
            CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.3, h: 1),
            CameraPathKeyframe(t: 10, x: 0.5, y: 0, w: 0.3, h: 1),
        ])), as: UTF8.self)
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 4, cluster: 0, confidence: 1, personKey: "ann", tile: 0),
                     SpeakerTurn(videoID: 1, start: 4, end: 10, cluster: 1, confidence: 1, personKey: "bob", tile: 1)]
        return (video, scene, turns)
    }

    @Test func cutsHaveOneTrackPerAreaAndKeepExactTiming() throws {
        let (video, scene, turns) = try source()
        let ranges = [0.13...2.87, 3.12...6.34, 7.21...9.98]
        var plan = Fixtures.plan(clips: ranges.map { Fixtures.planClip(start: $0.lowerBound, end: $0.upperBound) },
                                 transitions: ["cut", "cut"])
        plan.framing = .talker
        for kind in [CropRecipe.Kind.grid, .talkerAndPrevious] {
            var options = WizardOptions()
            options.formatPreset = "podcast"
            options.highlightFraming = kind
            let cuts = WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: scene], options: options,
                videos: [video], turns: [1: turns], layouts: ScreenCropStore.builtIn)
            let document = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], podcastCuts: cuts)
            #expect(document.trackCount == 2 && document.videoTrack.count == 6)
            #expect(!document.trackSequential[1])
            var cursor = 0.0
            for range in ranges {
                let clips = document.videoTrack.filter { $0.sourceStart == range.lowerBound }
                try #require(clips.count == 2)
                #expect(Set(clips.map(\.track)) == [0, 1])
                #expect(clips.allSatisfy { $0.sourceEnd == range.upperBound && $0.startTime == cursor })
                #expect(clips.allSatisfy { abs($0.duration - (range.upperBound - range.lowerBound)) < 0.000001 })
                #expect(clips.allSatisfy { $0.precision == .speech && $0.transIn == nil && $0.transOut == nil })
                #expect(clips.filter { !$0.muted }.count == 1)
                #expect(document.cropBlocks.contains { abs($0.startTime - cursor) < 0.000001 && abs($0.duration - clips[0].duration) < 0.000001 })
                cursor += range.upperBound - range.lowerBound
            }
            let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [scene])
            #expect(resolved.count == 6)
        }
    }

    @Test func automaticAndExplicitChoices() throws {
        let (video, scene, turns) = try source()
        var plan = Fixtures.plan()
        plan.framing = .grid
        var options = WizardOptions()
        options.formatPreset = "podcast"
        func cuts() -> [Int: TimelineDocument] {
            WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: scene], options: options,
                videos: [video], turns: [1: turns], layouts: ScreenCropStore.builtIn)
        }
        #expect(cuts()[0]?.videoTrack.count == 2)
        options.highlightFraming = .talker
        #expect(cuts()[0]?.videoTrack.count == 1)
        options.highlightFraming = nil
        plan.framing = nil
        #expect(cuts()[0]?.videoTrack.count == 1)
        options.podcastFraming = .original
        #expect(cuts().isEmpty)
        let original = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], podcastFraming: .original, podcastCuts: cuts())
        #expect(original.videoTrack.count == 1 && original.videoTrack[0].centerStage == false)
        options.podcastFraming = .followSpeaker
        options.formatPreset = "mma-finish"
        #expect(cuts().isEmpty)
        options.formatPreset = "custom"
        #expect(cuts()[0]?.videoTrack.count == 1)
        var ordinary = scene
        ordinary.tags = ["fight"]
        #expect(WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: ordinary], options: options,
            videos: [video], turns: [1: turns], layouts: ScreenCropStore.builtIn).isEmpty)
    }

    @Test func missingAnalysisAndPlannerFailureFollowSpeaker() throws {
        let (video, scene, turns) = try source()
        let plan = Fixtures.plan()
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.highlightFraming = .grid
        var noTiles = video
        noTiles.podcastTilesJSON = nil
        for (source, speakerTurns, layouts, reason) in [
            (video, [SpeakerTurn](), ScreenCropStore.builtIn, "no speaker turns"),
            (noTiles, turns, ScreenCropStore.builtIn, "no feed tiles"),
            (video, turns, [ScreenCropLayout](), ""),
        ] {
            var messages: [String] = []
            let cuts = WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: scene], options: options,
                videos: [source], turns: [1: speakerTurns], layouts: layouts, log: { messages.append($0) })
            let document = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], podcastCuts: cuts)
            #expect(document.videoTrack.count == 1 && document.videoTrack[0].centerStage)
            #expect(document.videoTrack[0].sceneID == scene.id)
            #expect(document.cropBlocks.allSatisfy { $0.layout.isFullScreen })
            try #require(messages.count == 1)
            #expect(messages[0].contains(CropRecipe.Kind.grid.name))
            // Foundation's contains("") is false; the missing-layout case names no fixed reason.
            #expect((reason.isEmpty || messages[0].contains(reason)) && messages[0].contains("following speaker"))
        }
    }
}

extension WizardPodcastTimelineTests {
    @Test func captionPositionAndPersistentTagsSurviveComposedCutDocuments() throws {
        let (video, scene, turns) = try source()
        let people = [PersonRecord(id: 1, key: "ann", name: "Ann", descriptor: "Host"),
                      PersonRecord(id: 2, key: "bob", name: "Bob", descriptor: "Guest")]
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.highlightFraming = .talkerAndPrevious
        options.nameTags = true
        options.nameTagContent = "nameAndRole"
        options.addCaptions = true
        options.captionPosition = "bottom"
        let plan = Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 10)])
        let cuts = WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: scene], options: options,
            videos: [video], turns: [1: turns], layouts: ScreenCropStore.builtIn, people: people)
        let cut = try #require(cuts[0])
        #expect(cut.videoTrack.filter { $0.track == 0 }.allSatisfy { $0.captions == "bottom" })
        #expect(cut.videoTrack.filter { $0.track != 0 }.allSatisfy { $0.captions == "none" })
        #expect(cut.textOverlays.count == 4)
        #expect(cut.textOverlays.allSatisfy { $0.design == "nameTag" && $0.transIn == "cut" && $0.transOut == "cut" })
        let document = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], podcastCuts: cuts)
        #expect(document.textOverlays == cut.textOverlays)
        #expect(cut.textOverlays.contains { $0.text == "Bob\nGuest" && $0.startTime == 4 })
    }
}
