import Foundation
import Testing
@testable import Clip_Builder

struct CropRecipePlannerTests {
    @Test func vipBRollBaseMatchesTalkerWithFourSecondHold() throws {
        let video = try CropRecipeTests.video()
        for members in [roster(["ann"]), []] {
            var talkerRecipe = CropRecipe(kind: .talker)
            talkerRecipe.minimumHold = 4
            let talker = try CropRecipePlanner.plan(talkerRecipe, video: video, range: 0...10,
                turns: CropRecipeTests.turns, roster: members, layouts: [], canvasAspect: 9.0 / 16)
            let broll = try CropRecipePlanner.plan(CropRecipe(kind: .vipBRoll), video: video, range: 0...10,
                turns: CropRecipeTests.turns, roster: members, layouts: [], canvasAspect: 9.0 / 16)
            #expect(broll == talker)
        }
        #expect(WizardCameraFocus.summary("vip_broll") == CropRecipe.Kind.vipBRoll.summary)
        #expect(CropRecipe.builtIn.contains { $0.kind == .vipBRoll })
    }

    @Test func twoVIPTrackingSpansRespectMinimumHold() throws {
        var video = try CropRecipeTests.video(tiles: [
            PodcastTile(index: 0, x: 0, y: 0, w: 0.3, h: 1, personKey: "a"),
            PodcastTile(index: 1, x: 0.3, y: 0, w: 0.3, h: 1, personKey: "b"),
            PodcastTile(index: 2, x: 0.6, y: 0, w: 0.4, h: 1, personKey: "host"),
        ])
        video.duration = 20
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 20, cluster: 2, confidence: 1, personKey: "host", tile: 2)]
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .vip), video: video, range: 0...20,
            turns: turns, roster: roster(["a", "b"]), layouts: [], canvasAspect: 9.0 / 16)
        let spans = try #require(plan.slots.first?.trackingSpans)
        #expect(spans.map(\.start) == [0, 6, 12])
        #expect(spans.allSatisfy { $0.end - $0.start >= VIPRotation.minimumHold - 1e-6 })
    }

    private func roster(_ keys: [String]) -> [VideoPersonRecord] {
        keys.enumerated().map { index, key in
            VideoPersonRecord(videoID: 1, personID: Int64(index + 1), key: key, name: key,
                descriptor: "", portraitAt: 0, portraitBox: nil, vip: true)
        }
    }

    @Test func vipKeepsGuestDuringHostSpeech() throws {
        let video = try CropRecipeTests.video(tiles: [
            PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "host"),
            PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "guest"),
        ])
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 4, cluster: 0, confidence: 1, personKey: "host", tile: 0),
                     SpeakerTurn(videoID: 1, start: 4, end: 10, cluster: 1, confidence: 1, personKey: "guest", tile: 1)]
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .vip), video: video, range: 0...10,
            turns: turns, roster: roster(["guest"]), layouts: [], canvasAspect: 9.0 / 16)
        #expect(plan.layout.isFullScreen)
        #expect(plan.slots.first?.region?.xFrac == 0.5)
        #expect(plan.slots.first?.talking == [4...10])
        #expect(plan.notes.isEmpty)
        #expect(CropRecipeSubject(token: "vip") == .vip)
    }

    @MainActor @Test func twoVIPsRememberTheMostRecentAndNoVIPFollowsTalker() throws {
        let video = try CropRecipeTests.video(tiles: [
            PodcastTile(index: 0, x: 0, y: 0, w: 0.3, h: 1, personKey: "a"),
            PodcastTile(index: 1, x: 0.3, y: 0, w: 0.3, h: 1, personKey: "b"),
            PodcastTile(index: 2, x: 0.6, y: 0, w: 0.4, h: 1, personKey: "host"),
        ])
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 3, cluster: 0, confidence: 1, personKey: "a", tile: 0),
                     SpeakerTurn(videoID: 1, start: 3, end: 6, cluster: 1, confidence: 1, personKey: "b", tile: 1),
                     SpeakerTurn(videoID: 1, start: 6, end: 10, cluster: 2, confidence: 1, personKey: "host", tile: 2)]
        let tiles = CropRecipePlanner.tiles(video: video, roster: [])
        let segments = CropRecipePlanner.segments(turns: turns, tiles: tiles, range: 0...10, hold: 1.5)
        let events = VIPRecipePlanning.events(segments: segments, tiles: tiles, roster: roster(["a", "b"]), turns: turns, start: 0)
        #expect(events.compactMap(\.tile) == [0, 1])
        let tracking = try CropRecipePlanner.plan(CropRecipe(kind: .vip), video: video, range: 0...10,
            turns: turns, roster: roster(["a", "b"]), layouts: [], canvasAspect: 9.0 / 16)
        #expect(tracking.slots.first?.trackingSpans?.map(\.start) == [0, 4])
        #expect(tracking.slots.first?.trackingSpans?.map(\.end) == [4, 10])
        let sourceScene = Fixtures.scene(id: 42, start: 0, end: 10)
        var options = WizardOptions()
        options.framing = Framing(subject: .vipFocus)
        options.useBRoll = false
        let document = PodcastRecipeTimeline.build(subject: .vipFocus, video: video, range: 0...10,
            sourceScene: sourceScene, turns: turns, roster: roster(["a", "b"]), layouts: [],
            settings: RenderSettings(), options: options, tagText: [:])
        #expect(document.videoTrack.allSatisfy { $0.sceneID == sourceScene.id })
        #expect(document.videoTrack.map(\.sourceStart) == [0, 4])
        #expect(document.videoTrack.map(\.sourceEnd) == [4, 10])
        #expect(document.videoTrack.map(\.duration) == [4, 6])
        #expect(document.videoTrack.allSatisfy { $0.areaRegion != nil && !$0.muted })

        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .vip), video: video, range: 0...10,
            turns: turns, roster: [], layouts: [], canvasAspect: 9.0 / 16)
        #expect(plan.notes == ["No VIP on this recording; following the talker."])
        #expect(plan.slots.first?.path?.last?.x ?? 0 >= 0.6)
    }
}
