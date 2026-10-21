import Testing
@testable import Clip_Builder

struct VIPRotationTests {
    private func segment(_ start: Double, _ end: Double, _ talker: Int) -> CropRecipePlanner.Segment {
        .init(start: start, end: end, talker: talker, recent: [])
    }

    @Test func hostMonologueRotatesAndSkipsTail() {
        let shots = VIPRotation.shots(range: 0...20, segments: [segment(0, 20, 2)], vipTiles: [0, 1], recentFirst: nil)
        #expect(shots.map(\.time) == [0, 6, 12])
        #expect(shots.map(\.tile) == [0, 1, 0])
    }

    @Test func interjectionWaitsForHoldAndMustStillBeTalking() {
        let shots = VIPRotation.shots(range: 0...20,
            segments: [segment(0, 2, 2), segment(2, 8, 1), segment(8, 20, 2)], vipTiles: [0, 1], recentFirst: nil)
        #expect(shots.prefix(2).map(\.time) == [0, 4])
        let brief = VIPRotation.shots(range: 0...20,
            segments: [segment(0, 2, 2), segment(2, 3, 1), segment(3, 20, 2)], vipTiles: [0, 1], recentFirst: nil)
        #expect(brief.prefix(2).map(\.time) == [0, 6])
    }

    @Test func shortVIPSpeechDoesNotCutAwayWhenItEnds() {
        let shots = VIPRotation.shots(range: 0...20,
            segments: [segment(0, 5, 2), segment(5, 6, 1), segment(6, 20, 2)], vipTiles: [0, 1], recentFirst: nil)
        #expect(shots.map(\.time) == [0, 5, 11])
    }

    @Test func singleVIPAndRecentFirst() {
        #expect(VIPRotation.shots(range: 10...30, segments: [], vipTiles: [1], recentFirst: nil) == [.init(time: 10, tile: 1)])
        #expect(VIPRotation.shots(range: 10...30, segments: [], vipTiles: [0, 1], recentFirst: 1).first?.tile == 1)
        #expect(VIPRotation.shots(range: 10...30, segments: [segment(10, 30, 0)], vipTiles: [0, 1], recentFirst: 1).first?.tile == 0)
    }

    @Test func variedFixtureNeverFlashes() {
        // Deterministic pseudo-random lengths and speakers, reproducible on failure.
        var seed: UInt64 = 42
        var segments: [CropRecipePlanner.Segment] = []
        var time = 0.0
        while time < 120 {
            seed = seed &* 6364136223846793005 &+ 1
            let end = min(120, time + Double(seed % 50 + 1) / 10)
            segments.append(segment(time, end, Int((seed >> 8) % 3)))
            time = end
        }
        let shots = VIPRotation.shots(range: 0...120, segments: segments, vipTiles: [0, 1], recentFirst: nil)
        for (index, shot) in shots.enumerated() {
            let end = index + 1 < shots.count ? shots[index + 1].time : 120
            #expect(end - shot.time >= VIPRotation.minimumHold - 1e-6)
        }
    }
}
