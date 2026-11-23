import Foundation
import Testing
@testable import Clip_Builder

struct RenderClockTests {
    @Test(.enabled(if: FixtureVideo.integrationsAvailable))
    func measuredBumperRunKeepsIncomingRecipeOrigin() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("clock-piece.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=2",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", input.path], timeout: 60)
        var clips = (0..<3).map { index -> TimelineClip in
            var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2, startTime: Double(index) * 2)
            clip.videoFile = input.path; clip.wide = false; clip.captions = "none"
            clip.transIn = index == 1 ? "whip_left" : "cut"; clip.transOut = "cut"
            return clip
        }
        clips[2].bumper = true
        var document = Fixtures.timelineDocument(clips: clips)
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 320, customHeight: 180)
        var transitions = TransitionSettings(); transitions.sfxEnabled = false
        try await RenderContext.$settings.withValue(document.renderSettings) {
            try await RenderContext.$transitions.withValue(transitions) {
                let segments = MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: document, scenes: [])).segments
                let runJoins = JoinOverlaps()
                let run = folder.appendingPathComponent("ordinary-run.mp4")
                try await RenderEngine().concatenate(clips: [input, input], transitions: ["whip_left"], output: run, overlaps: runJoins)
                let runClock = RenderClock(segmentStarts: [0, 2], segmentEnds: [2, 4], joins: runJoins)
                let bridge = try #require(runJoins.assembledBridges.first)
                #expect(bridge.head > 0)
                let measured = await FFmpeg.duration(of: run)
                let joins = JoinOverlaps()
                let output = folder.appendingPathComponent("with-bumper.mp4")
                _ = try await StayRenderFixture.renderer(folder).concatenateWithBumpers(paths: [input, input, input],
                    segments: segments, transitions: ["whip_left", "cut"], scratch: folder, output: output, overlaps: joins)
                let clock = RenderClock(segmentStarts: [0, 2, 4], segmentEnds: [2, 4, 6], joins: joins)
                for event in [1.0, 2 - bridge.tail / 2, 2.0, 2 + bridge.head / 2, 3.0] {
                    #expect(abs(clock.map(event) - runClock.map(event)) < 1.0 / 30)
                }
                #expect(abs(clock.map(4.5) - (measured + 0.5)) < 1.0 / 30)
                let origin = try #require(runJoins.assembledPieces[1]?.lowerBound)
                let carried = try #require(joins.assembledPieces[1]?.lowerBound)
                #expect(abs(carried - origin) < 1e-9)
            }
        }
    }

    @Test func bumperRunRetainsShiftedBridgeInterior() {
        let joins = JoinOverlaps()
        joins.reconcile(0, range: 0..<1)
        joins.reconcile(1, range: 1..<3)
        joins.reconcile(2, range: 2.7..<4.7)
        let local = JoinOverlaps.Bridge(gap: 0, tail: 0.5, head: 0, range: 1.5..<1.7)
        let bridge = local.shifted(gapOffset: 1, timeOffset: 1)
        joins.bridge(gap: bridge.gap, tail: bridge.tail, head: bridge.head, range: bridge.range)
        let clock = RenderClock(segmentStarts: [0, 1, 3], segmentEnds: [1, 3, 5], joins: joins)
        #expect(abs(clock.map(2.8) - 2.62) < 1e-9)
        #expect(abs(clock.map(4) - 3.7) < 1e-9)
        let boundary = JoinOverlaps()
        boundary.reconcile(0, range: 0..<4.7)
        boundary.reconcile(1, range: 4.4..<5.4)
        boundary.bridge(gap: 0, tail: 0.5, head: 0, range: 4.2..<4.4)
        let boundaryClock = RenderClock(segmentStarts: [0, 4.7], segmentEnds: [4.7, 5.7], joins: boundary)
        let carried = bridge.mapped(through: boundaryClock)
        #expect(abs(carried.range.lowerBound - 2.5) < 1e-9)
        #expect(abs(carried.range.upperBound - 2.7) < 1e-9)
    }

    @Test func boundedBumperRecipesSharePlannedPieceClock() {
        let joins = RenderEngine.frameAssemblyJoins(durations: [2, 2, 1],
            transitions: ["speed_ramp", "cut"], transitionDuration: 0.35)
        let clock = RenderClock(segmentStarts: [0, 2, 4], segmentEnds: [2, 4, 5], joins: joins)
        #expect(abs(clock.map(1.8) - 1.62) < 1e-9)
        #expect(abs(clock.map(4) - 3.7) < 1e-9)
        let boundaryJoins = RenderEngine.frameAssemblyJoins(durations: [2, 1, 2],
            transitions: ["speed_ramp", "fade"], transitionDuration: 0.35)
        let boundaryClock = RenderClock(segmentStarts: [0, 2, 3], segmentEnds: [2, 3, 5], joins: boundaryJoins)
        #expect(abs(boundaryClock.map(1.8) - 1.62) < 1e-9)
        #expect(abs(boundaryClock.map(3) - (2.7 - 11.0 / 30)) < 1e-9)
        let plainJoins = RenderEngine.frameAssemblyJoins(durations: [2, 1, 2],
            transitions: ["fade", "fade"], transitionDuration: 0.35)
        #expect(plainJoins.assembledPieces.isEmpty)
        #expect(plainJoins.assembledBridges.isEmpty)
        let old = RenderClock(segmentStarts: [0, 2, 3], overlaps: plainJoins.all)
        let unchanged = RenderClock(segmentStarts: [0, 2, 3], segmentEnds: [2, 3, 5], joins: plainJoins)
        #expect(old == unchanged)
    }

    @Test func compressedRecipeBridgeMapsItsInterior() {
        let joins = JoinOverlaps()
        joins.record(0, 0.3)
        joins.reconcile(0, range: 0..<2)
        joins.reconcile(1, range: 1.7..<3.7)
        joins.bridge(gap: 0, tail: 0.5, head: 0, range: 1.5..<1.7)
        let clock = RenderClock(segmentStarts: [0, 2], segmentEnds: [2, 4], joins: joins)
        #expect(abs(clock.map(1.8) - 1.62) < 1e-9)
        #expect(abs(clock.map(2) - 1.7) < 1e-9)
        #expect(abs(clock.map(2, end: true) - 1.7) < 1e-9)
        #expect(abs(clock.map(3) - 2.7) < 1e-9)
        let equal = JoinOverlaps()
        equal.reconcile(0, range: 0..<2)
        equal.reconcile(1, range: 2..<4)
        equal.bridge(gap: 0, tail: 0.5, head: 0, range: 1.5..<2)
        let unchanged = RenderClock(segmentStarts: [0, 2], segmentEnds: [2, 4], joins: equal)
        #expect(abs(unchanged.map(1.8) - 1.8) < 1e-9)
    }

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
