import Testing
@testable import Clip_Builder

struct VIPBRollWindowsTests {
    private func turn(_ start: Double, _ end: Double, key: String, tile: Int = 0) -> SpeakerTurn {
        SpeakerTurn(videoID: 1, start: start, end: end, cluster: tile, confidence: 1, personKey: key, tile: tile)
    }

    @Test func overlapsClippingAndMinimumDuration() {
        let turns = [turn(0, 20, key: "host"), turn(4, 8, key: "guest"), turn(9, 11, key: "guest")]
        #expect(VIPBRollWindows.windows(turns: turns, vipKeys: ["guest"], range: 2...15) == [2...4, 11...15])
        #expect(VIPBRollWindows.windows(turns: turns, vipKeys: [], range: 0...20).isEmpty)
        #expect(VIPBRollWindows.windows(turns: [], vipKeys: ["guest"], range: 0...20).isEmpty)
    }

    @Test func portraitColumnsAreNotIndependentReactionFeeds() {
        let roster = [
            VideoPersonRecord(videoID: 1, personID: 1, key: "guest", name: "Guest", descriptor: "", portraitAt: 0,
                portraitBox: .init(x: 0.1, y: 0.2, w: 0.2, h: 0.4), vip: true),
            VideoPersonRecord(videoID: 1, personID: 2, key: "host", name: "Host", descriptor: "", portraitAt: 0,
                portraitBox: .init(x: 0.6, y: 0.2, w: 0.2, h: 0.4)),
        ]
        let video = Fixtures.video()
        #expect(CropRecipePlanner.tiles(video: video, roster: roster).count == 2)
        #expect(VIPRecipePlanning.recordedFeeds(video: video, roster: roster).isEmpty)
    }

    @Test func separateVIPFeedNeedsNoCutaways() {
        let roster = [VideoPersonRecord(videoID: 1, personID: 1, key: "guest", name: "Guest", descriptor: "",
            portraitAt: 0, portraitBox: nil, vip: true)]
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "host"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "guest")]
        #expect(VIPBRollWindows.needingFootage(turns: [turn(0, 10, key: "host")], roster: roster, tiles: tiles, range: 0...10).isEmpty)
        #expect(VIPBRollWindows.needingFootage(turns: [turn(0, 10, key: "host")], roster: roster,
            tiles: [PodcastTile(index: 0, x: 0, y: 0, w: 1, h: 1, personKey: "guest")], range: 0...10) == [0...10])
    }

    @Test func prefersVIPScenesAndKeepsBudgetWithConsecutiveCuts() {
        let candidate = HighlightCandidate(sourceStart: 0, sourceEnd: 20, title: "Test", reason: "", score: 8,
            kind: .whole, speakerKeys: ["host"])
        let sources = PodcastHighlightBRollPlanner.Sources(videoID: 1, range: 0...20, people: ["host", "guest"], preferredPeople: ["guest"])
        var own = Fixtures.scene(id: 2, start: 30, end: 40)
        own.videoID = 1
        own.tags = ["podcast", "person:guest"]
        own.score = 8
        var other = own
        other.id = 3
        other.videoID = 2
        other.score = 10
        var host = other
        host.id = 4
        host.tags = ["person:host"]
        let cuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources,
            turns: [turn(0, 20, key: "host")], segments: [], tiles: [], scenes: [host, other, own],
            threshold: 7, vipWindows: [0...20])
        #expect(cuts.map(\.source) == [.scene(2), .scene(2), .scene(2)])
        #expect(cuts.map(\.start) == [2, 5, 8])
        #expect(cuts.map(\.duration) == [3, 3, 2])
        #expect(WizardPodcastBRoll.spacedCuts([cuts], offsets: [0]) == [cuts])
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "host"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "guest")]
        let reactions = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources,
            turns: [turn(0, 20, key: "host")], segments: [], tiles: tiles, scenes: [own], threshold: 7, vipWindows: [0...20])
        #expect(reactions.allSatisfy { $0.source == .reaction(tile: 1) })
        #expect(reactions.reduce(0) { $0 + $1.duration } <= 8)
    }
}
