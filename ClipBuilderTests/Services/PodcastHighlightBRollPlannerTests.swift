import Testing
@testable import Clip_Builder

struct PodcastHighlightBRollPlannerTests {
    private let candidate = HighlightCandidate(sourceStart: 100, sourceEnd: 140, title: "Exchange",
        reason: "", score: 8, kind: .whole, speakerKeys: ["host", "vip"])
    private var sources: PodcastHighlightBRollPlanner.Sources {
        .init(videoID: 1, range: 100...140, people: ["host", "vip"], preferredPeople: ["vip"])
    }
    private var tiles: [PodcastTile] {
        [.init(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "host"),
         .init(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "vip")]
    }

    @Test func mapsReactionBreakToSourceAndTimelineClocks() {
        let cuts = PodcastHighlightBRollPlanner.vipBRollPlan(candidate: candidate, sources: sources,
            turns: [.init(videoID: 1, start: 100, end: 140, cluster: 0, confidence: 1, personKey: "host", tile: 0)],
            tiles: tiles, scenes: [], breaks: [.init(start: 106, duration: 4, tile: 1, expressive: true)])
        #expect(cuts == [.init(source: .reaction(tile: 1), sourceStart: 106, start: 6, duration: 4,
                              reason: "VIP B-roll · expressive moment")])
        #expect(cuts.first?.vipWindow == nil)
    }

    @Test func singleFeedUsesNextVIPSceneWithOwnRecordingFirst() {
        var own = Fixtures.scene(id: 1, start: 40, end: 42.8)
        own.videoID = 1; own.tags = ["person:vip"]
        var external = Fixtures.scene(id: 2, start: 5, end: 10)
        external.videoID = 2; external.tags = ["person:vip"]
        var short = Fixtures.scene(id: 3, start: 0, end: 2)
        short.tags = ["person:vip"]
        var unrelated = Fixtures.scene(id: 4, start: 0, end: 10)
        unrelated.tags = ["person:host"]
        let cuts = PodcastHighlightBRollPlanner.vipBRollPlan(candidate: candidate, sources: sources,
            turns: [], tiles: [], scenes: [external, short, unrelated, own], breaks: [
                .init(start: 106, duration: 3, tile: nil, expressive: false),
                .init(start: 116, duration: 3, tile: nil, expressive: false)])
        #expect(cuts.map(\.source) == [.scene(1), .scene(2)])
        #expect(cuts.map(\.sourceStart) == [40, 5])
        #expect(cuts.map(\.start) == [6, 16])
        #expect(abs((cuts.first?.duration ?? 0) - 2.8) < 1e-6)
        #expect(cuts.allSatisfy { $0.duration >= 2.5 && $0.reason == "VIP B-roll · scheduled break" && $0.vipWindow == nil })
    }

    @Test func rejectsSpeakingVIPAndInvalidReactionFeed() {
        let speech = [SpeakerTurn(videoID: 1, start: 108, end: 120, cluster: 1, confidence: 1, tile: 1)]
        let cuts = PodcastHighlightBRollPlanner.vipBRollPlan(candidate: candidate, sources: sources,
            turns: speech, tiles: tiles, scenes: [], breaks: [
                .init(start: 106, duration: 4, tile: 1, expressive: true),
                .init(start: 125, duration: 3, tile: 0, expressive: false)])
        #expect(cuts.isEmpty)
    }

    @Test func highlightEntryPointSchedulesVIPFootageWithoutAnAIProvider() async throws {
        var video = Fixtures.video()
        video.duration = 140
        var scene = Fixtures.scene(id: 9, start: 40, end: 45)
        scene.tags = ["person:vip"]
        let roster = [VideoPersonRecord(videoID: 1, personID: 1, key: "vip", name: "Guest",
            descriptor: "", portraitAt: 0, portraitBox: nil, vip: true)]
        var options = WizardOptions()
        options.framing = Framing(subject: .vipFocus)
        options.useBRoll = true
        options.brollInstructions = "Show the guest."
        let cuts = try await PodcastHighlightBRollPlacement.plan(candidate: candidate, video: video,
            scenes: [scene], turns: [], roster: roster, segments: [], options: options)
        #expect(cuts.count == 1)
        #expect(cuts.first?.source == .scene(9))
        #expect(cuts.first?.duration == 3)
        #expect(cuts.first?.reason == "VIP B-roll · scheduled break")
    }
}
