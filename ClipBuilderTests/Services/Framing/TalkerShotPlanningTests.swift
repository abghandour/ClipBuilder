import Foundation
import Testing
@testable import Clip_Builder

@Suite("Talker full screen shot clock")
struct TalkerShotPlanningTests {
    private typealias Segment = CropRecipePlanner.Segment

    private func events(_ segments: [Segment], end: Double, order: [Int] = [0, 1],
                        maxShot: Double = 8, minShot: Double = 2) -> [(Double, Int?)] {
        TalkerShotPlanning.events(segments: segments, range: 0...end, order: order, maxShot: maxShot, minShot: minShot)
            .map { ($0.time, $0.tile) }
    }

    private func same(_ actual: [(Double, Int?)], _ expected: [(Double, Int?)]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0.0 - $1.0) < 1e-6 && $0.1 == $1.1 }
    }

    @Test func oneLongTalkerCutsAwayAndComesBack() {
        let plan = events([Segment(start: 0, end: 20, talker: 0, recent: [1])], end: 20)
        #expect(same(plan, [(0, 0), (8, 1), (10, 0), (18, 1)]),
                "cut to the other person after 8 s, back after 2 s, and again 8 s after the return")
    }

    @Test func aQuickChangeWaitsForTheMinimumShot() {
        let plan = events([Segment(start: 0, end: 1, talker: 0, recent: [1]),
                           Segment(start: 1, end: 20, talker: 1, recent: [0])], end: 20)
        #expect(same(plan, [(0, 0), (2, 1), (10, 0), (12, 1)]), "the first shot lasts 2 s even though B starts at 1 s")
    }

    @Test func theClockRestartsAndStaysOnTheTalkerAfterACutaway() {
        let plan = events([Segment(start: 0, end: 9, talker: 0, recent: [1]),
                           Segment(start: 9, end: 30, talker: 1, recent: [0])], end: 30)
        #expect(same(plan, [(0, 0), (8, 1), (16, 0), (18, 1), (26, 0), (28, 1)]),
                "B is shown by the cutaway at 8 s and keeps the picture once B talks; B's own clock runs from 8 s")
    }

    @Test func theCutawayGoesToTheMostRecentOtherSpeakerElseRotates() {
        let three = events([Segment(start: 0, end: 5, talker: 2, recent: [0, 1]),
                            Segment(start: 5, end: 40, talker: 0, recent: [2, 1])], end: 40, order: [0, 1, 2])
        #expect(same(three, [(0, 2), (5, 0), (13, 2), (15, 0), (23, 2), (25, 0), (33, 2), (35, 0)]),
                "the cutaway shows the previous speaker, tile 2")
        // `segments` lists everyone in `recent` from the start, spoken or not.
        let fresh = events([Segment(start: 0, end: 40, talker: 0, recent: [1, 2])], end: 40, order: [0, 1, 2])
        #expect(same(fresh, [(0, 0), (8, 1), (10, 0), (18, 2), (20, 0), (28, 1), (30, 0), (38, 2)]),
                "nobody else has spoken: the others take turns")
    }

    @Test func equalMinAndMaxKeepTheClockRunning() {
        let plan = events([Segment(start: 0, end: 4, talker: 0, recent: [1]),
                           Segment(start: 4, end: 20, talker: 1, recent: [0])], end: 20, maxShot: 3, minShot: 3)
        #expect(same(plan, [(0, 0), (3, 1), (6, 0), (9, 1), (12, 0), (15, 1), (18, 0)]),
                "a forced cut on the moment the loop stands at still moves on")
    }

    @Test func aSingleFeedHasNobodyToCutTo() {
        #expect(same(events([Segment(start: 0, end: 30, talker: 0, recent: [])], end: 30, order: [0]), [(0, 0)]))
        #expect(events([], end: 10).isEmpty)
    }

    @Test func timingsClampAndKeepMinUnderMax() {
        #expect(TalkerShotPlanning.timings(max: nil, min: nil) == (8, 2))
        #expect(TalkerShotPlanning.timings(max: 50, min: 20) == (30, 10))
        #expect(TalkerShotPlanning.timings(max: 3, min: 5) == (3, 3))
        #expect(TalkerShotPlanning.timings(max: 1, min: 0.1) == (3, 1))
    }
}
