import Testing
@testable import Clip_Builder

struct VIPBRollScheduleTests {
    @Test func multipleVIPsAlternatePeaksAndFallback() {
        let peaks: [(time: Double, tile: Int)] = [(7, 0), (15, 0), (15, 1), (23, 1), (23, 0)]
        let expressive = VIPBRollSchedule.breaks(range: 0...40, eligible: [0...40],
            peaks: peaks, speakerChanges: [], rotate: true, vipTiles: [0, 1])
        #expect(expressive.map(\.tile) == [0, 1, 0])
        let fallback = VIPBRollSchedule.breaks(range: 0...40, eligible: [0...40],
            peaks: [], speakerChanges: [], rotate: true, vipTiles: [0, 1])
        #expect(fallback.map(\.tile) == [0, 1, 0])
    }

    @Test func leadGapDurationsAndShareHoldOnSourceClock() {
        let breaks = VIPBRollSchedule.breaks(range: 100...140, eligible: [100...140],
            peaks: [(105, 1), (107, 2), (113, 1), (121, 1), (129, 1), (137, 1)], speakerChanges: [])
        #expect(!breaks.isEmpty)
        #expect(breaks.allSatisfy { $0.start >= 103 && $0.start + $0.duration <= 140 })
        #expect(breaks.allSatisfy { (2.5...4).contains($0.duration) })
        #expect(zip(breaks, breaks.dropFirst()).allSatisfy { $1.start - ($0.start + $0.duration) >= 4 })
        #expect(breaks.reduce(0) { $0 + $1.duration } <= 14)
    }

    @Test func speakerChangeTrimsTheLastSecond() {
        let breaks = VIPBRollSchedule.breaks(range: 0...30, eligible: [0...30],
            peaks: [(7, 1)], speakerChanges: [8.5])
        #expect(breaks == [.init(start: 5, duration: 3.5, tile: 1, expressive: true)])
        let short = VIPBRollSchedule.breaks(range: 0...30, eligible: [3...6],
            peaks: [(4.5, 1)], speakerChanges: [5.4])
        #expect(short.isEmpty)
    }

    @Test func fallbackIsEvenAndIgnoresOutsidePeaks() {
        let plain = VIPBRollSchedule.breaks(range: 0...40, eligible: [0...40], peaks: [], speakerChanges: [])
        let outside = VIPBRollSchedule.breaks(range: 0...40, eligible: [0...40],
            peaks: [(1, 1), (80, 1)], speakerChanges: [])
        #expect(plain == outside)
        #expect(plain.count == 3)
        #expect(plain.allSatisfy { !$0.expressive && $0.tile == nil && $0.duration == 3 })
        #expect(abs((plain[1].start - plain[0].start) - (plain[2].start - plain[1].start)) < 1e-6)
    }

    @Test func strongestPeakWinsNearbyAndIneligiblePeaksCannotCreateBreaks() {
        let result = VIPBRollSchedule.breaks(range: 0...30, eligible: [3...12, 20...30],
            peaks: [(9, 2), (7, 1), (16, 1)], speakerChanges: [])
        #expect(result == [.init(start: 7, duration: 4, tile: 2, expressive: true)])
        #expect(VIPBRollSchedule.breaks(range: 0...30, eligible: [], peaks: [(7, 1)], speakerChanges: []).isEmpty)
    }

    @Test func silenceIsEligibleButOverlappingAndUnnamedVIPSpeechIsNot() {
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "host"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "vip")]
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 15, cluster: 0, confidence: 1, personKey: "host"),
                     SpeakerTurn(videoID: 1, start: 5, end: 9, cluster: 1, confidence: 1, personKey: "vip"),
                     SpeakerTurn(videoID: 1, start: 18, end: 20, cluster: 1, confidence: 1, tile: 1)]
        let eligible = VIPBRollSchedule.eligible(turns: turns, vipKeys: ["vip"], tiles: tiles, range: 0...30)
        #expect(eligible == [0...5, 9...18, 20...30])
        #expect(VIPBRollSchedule.eligible(turns: turns, vipKeys: [], tiles: tiles, range: 0...30).isEmpty)
        let breaks = VIPBRollSchedule.breaks(range: 0...30, eligible: eligible, peaks: [(7, 1), (23, 1)], speakerChanges: [])
        #expect(breaks.count == 1 && breaks.first?.start == 21)
    }

    @Test func joinSpacingUsesFourSecondsForVIPBreaks() {
        typealias Cut = PodcastHighlightBRollPlanner.Cut
        let first = Cut(source: .reaction(tile: 1), sourceStart: 5, start: 5, duration: 4, reason: "VIP")
        let close = Cut(source: .reaction(tile: 1), sourceStart: 3, start: 3, duration: 3, reason: "VIP")
        let next = Cut(source: .reaction(tile: 1), sourceStart: 4, start: 4, duration: 3, reason: "VIP")
        let cuts = WizardPodcastBRoll.spacedCuts([[first], [close, next]], offsets: [0, 9], minimumGap: 4)
        #expect(cuts == [[first], [next]])
    }
}
