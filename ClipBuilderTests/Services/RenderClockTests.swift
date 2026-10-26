import Foundation
import Testing
@testable import Clip_Builder

struct RenderClockTests {
    @Test func timesAfterAJoinMoveEarlierByTheOverlapSoFar() {
        let clock = RenderClock(segmentStarts: [0, 10, 20], overlaps: [0: 0.4, 1: 0.5])
        #expect(!clock.isIdentity)
        #expect(clock.map(5) == 5)
        #expect(abs(clock.map(12) - 11.6) < 1e-9)
        #expect(abs(clock.map(25) - 24.1) < 1e-9)
        // A start on the join belongs to the incoming segment; an end there to the outgoing one.
        #expect(abs(clock.map(10) - 9.6) < 1e-9)
        #expect(clock.map(10, end: true) == 10)
        #expect(abs(clock.map(30, end: true) - 29.1) < 1e-9)
    }

    @Test func hardCutsLeaveTheClockAlone() {
        let clock = RenderClock(segmentStarts: [0, 10], overlaps: [0: 0])
        #expect(clock.isIdentity && clock.map(12) == 12)
        #expect(RenderClock.identity.map(3) == 3)
    }

    @Test func dubbedSpeechFollowsItsFootage() {
        let clock = RenderClock(segmentStarts: [0, 10], overlaps: [0: 0.4])
        let uid = UUID()
        let lines = [DubLine(clipUID: uid, speakerKey: "a", voice: "v", text: "Later", sourceStart: 2, sourceEnd: 3,
                             start: 12, duration: 1),
                     DubLine(clipUID: uid, speakerKey: "a", voice: "v", text: "Under way", sourceStart: 0, sourceEnd: 1,
                             start: -0.5, duration: 1)]
        let mapped = clock.map(lines)
        #expect(abs(mapped[0].start - 11.6) < 1e-9 && mapped[0].duration == 1)
        #expect(mapped[1].start == -0.5)
    }

    @Test func crossfadeRunsUseTheEnginesClamping() {
        let overlaps = MultitrackRenderer.crossfadeOverlaps(durations: [10, 10, 0.5, 10],
                                                            transitions: ["fade", nil, "flash_white"],
                                                            transitionDuration: 0.5)
        #expect(overlaps[0] == 0.5)
        #expect((overlaps[1] ?? 0) == 0)
        // A 0.5 s segment affords at most 0.2 s; the flash wants 0.12 s.
        #expect(abs((overlaps[2] ?? 0) - 0.12) < 1e-9)
        // A run too short to crossfade at all joins with a hard cut.
        let tooShort = MultitrackRenderer.crossfadeOverlaps(durations: [0.1, 10], transitions: ["fade"],
                                                            transitionDuration: 0.5)
        #expect(tooShort[0] == 0)
    }
}
