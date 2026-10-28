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
        plan.framing = .speakerFocus
        for layout in ["Split", "50-50 Horizontal"] {
            var options = WizardOptions()
            options.formatPreset = "podcast"
            options.framing = Framing(subject: .layout, layout: layout)
            let cuts = WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: scene], options: options,
                videos: [video], turns: [1: turns], layouts: ScreenCropStore.builtIn)
            let document = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], podcastCuts: cuts)
            #expect(document.trackCount == 2 && document.videoTrack.count >= 6)
            #expect(!document.trackSequential[1])
            var cursor = 0.0
            for range in ranges {
                let end = cursor + range.upperBound - range.lowerBound
                for track in 0...1 {
                    let clips = document.videoTrack.filter { $0.track == track && $0.startTime >= cursor - 0.000001 && $0.startTime < end - 0.000001 }
                        .sorted { $0.startTime < $1.startTime }
                    #expect(clips.first?.sourceStart == range.lowerBound)
                    #expect(clips.last?.sourceEnd == range.upperBound)
                    #expect(abs(clips.reduce(0) { $0 + $1.duration } - (end - cursor)) < 0.000001)
                    #expect(clips.allSatisfy { $0.precision == .speech && $0.transIn == nil && $0.transOut == nil })
                    #expect(clips.allSatisfy { $0.muted == (track > 0) })
                    #expect(clips.allSatisfy { $0.framingPlan?.area(forTrack: track) != nil })
                }
                cursor += range.upperBound - range.lowerBound
            }
            let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [scene])
            #expect(resolved.count == document.videoTrack.count)
        }
    }

    @Test func automaticAndExplicitChoices() throws {
        let (video, scene, turns) = try source()
        var plan = Fixtures.plan()
        plan.framing = .layout
        var options = WizardOptions()
        options.formatPreset = "podcast"
        func cuts() -> [Int: TimelineDocument] {
            WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: scene], options: options,
                videos: [video], turns: [1: turns], layouts: ScreenCropStore.builtIn)
        }
        #expect(Set(cuts()[0]?.videoTrack.map(\.track) ?? []) == [0, 1])
        options.framing = Framing(subject: .speakerFocus)
        #expect(cuts()[0]?.videoTrack.count == 1)
        options.framing = Framing()
        plan.framing = nil
        #expect(cuts()[0]?.videoTrack.count == 1)
        options.framing = Framing(subject: .original)
        #expect(cuts().isEmpty)
        let original = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], framing: Framing(subject: .original), podcastCuts: cuts())
        #expect(original.videoTrack.count == 1 && original.videoTrack[0].centerStage == false)
        options.framing = Framing(subject: .speakerFocus)
        options.formatPreset = "mma-finish"
        #expect(cuts().isEmpty)
        options.formatPreset = "custom"
        #expect(cuts()[0]?.videoTrack.count == 1)
        var ordinary = scene
        ordinary.tags = ["fight"]
        #expect(WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: ordinary], options: options,
            videos: [video], turns: [1: turns], layouts: ScreenCropStore.builtIn).isEmpty)
    }

    @Test func layoutsHonorTheirAreasWithoutPeopleAndUseBuiltInFallbacks() throws {
        let (video, scene, turns) = try source()
        let plan = Fixtures.plan()
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.framing = Framing(subject: .layout)
        var noTiles = video
        noTiles.podcastTilesJSON = nil
        for source in [noTiles, video] {
            var messages: [String] = []
            let cuts = WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: scene], options: options,
                videos: [source], turns: [1: turns], layouts: [], log: { messages.append($0) })
            let document = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], podcastCuts: cuts)
            #expect(Set(document.videoTrack.map(\.track)) == [0, 1])
            #expect(document.videoTrack.allSatisfy { $0.framingPlan?.area(forTrack: $0.track) != nil })
            #expect(messages.contains { $0.contains("No VIP") })
        }
    }

}

extension WizardPodcastTimelineTests {
    @Test func captionPositionAndPersistentTagsSurviveComposedCutDocuments() throws {
        let (video, scene, turns) = try source()
        // The visual descriptor never reaches a tag; the second line is the tag text.
        let people = [PersonRecord(id: 1, key: "ann", name: "Ann", descriptor: "tall, grey hoodie"),
                      PersonRecord(id: 2, key: "bob", name: "Bob", descriptor: "short, red cap")]
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.framing = Framing(subject: .layout, layout: "Split")
        options.nameTags = true
        options.addCaptions = true
        options.captionPosition = "bottom"
        let plan = Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 10)])
        let cuts = WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [1: scene], options: options,
            videos: [video], turns: [1: turns], layouts: ScreenCropStore.builtIn, people: people, tagText: ["ann": "Host", "bob": "Guest"])
        let cut = try #require(cuts[0])
        #expect(cut.videoTrack.contains { $0.track != 0 })
        #expect(cut.videoTrack.filter { $0.track == 0 }.allSatisfy { $0.captions == "bottom" })
        #expect(cut.videoTrack.filter { $0.track != 0 }.allSatisfy { $0.captions == "none" })
        // Both people remain tagged as the current and previous talker exchange areas.
        #expect(cut.textOverlays.count == 4)
        #expect(cut.textOverlays.allSatisfy { $0.design == "nameTag" && $0.transIn == "cut" && $0.transOut == "cut" })
        let document = WizardEngine.timelineDocument(from: plan, sceneMap: [1: scene], podcastCuts: cuts)
        #expect(document.textOverlays == cut.textOverlays)
        #expect(cut.textOverlays.contains { $0.text == "Bob\nGuest" && $0.startTime == 0 })
        #expect(cut.textOverlays.contains { $0.text == "Ann\nHost" && $0.startTime == 0 })
    }
}
