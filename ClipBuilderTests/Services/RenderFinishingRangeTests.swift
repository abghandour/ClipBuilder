import Foundation
import Testing
@testable import Clip_Builder

struct RenderFinishingRangeTests {
    private func groups(_ identities: [String]) -> [RenderFinishingRanges.Group] {
        identities.map { RenderFinishingRanges.Group(duration: 2, identity: $0) }
    }

    @Test func rangesCutOnlyBetweenGroupsAndTheLastTakesTheRest() throws {
        let parts = try RenderFinishingRanges.plan(durations: [2, 2, 2, 2, 2, 1], target: 4)
        #expect(parts.map { [$0.first, $0.last] } == [[0, 1], [2, 3], [4, 5]])
        #expect(parts.map(\.start) == [0, 4, 8])
        #expect(parts.map(\.end) == [4, 8, 11])
        let long = try RenderFinishingRanges.plan(durations: [9, 1, 1], target: 4)
        #expect(long.map { [$0.first, $0.last] } == [[0, 0], [1, 2]])
        #expect(try RenderFinishingRanges.plan(durations: [3.5], target: 4).count == 1)
        #expect(throws: (any Error).self) { try RenderFinishingRanges.plan(durations: [], target: 4) }
        #expect(throws: (any Error).self) { try RenderFinishingRanges.plan(durations: [2, 0], target: 4) }
        #expect(throws: (any Error).self) { try RenderFinishingRanges.plan(durations: [2, .nan], target: 4) }
    }

    @Test func targetLengthGrowsWithLongOutputs() {
        #expect(RenderFinishingRanges.targetLength(totalDuration: 80) == 4)
        #expect(RenderFinishingRanges.targetLength(totalDuration: 600) == 25)
    }

    @Test func clockBoundariesLandOnWholeFramesAndTheLastTrimKeepsTheFinalFrame() throws {
        var parts = try RenderFinishingRanges.plan(durations: [2.0, 2.0, 2.0, 1.4], target: 4)
        RenderFinishingRanges.clock(&parts, startTime: 0.022982, limit: 7.423)
        #expect(parts.count == 2)
        #expect(abs(parts[0].clockStart - 1 / 30) < 1e-9)
        #expect(abs(parts[0].clockEnd - 4.033333333) < 1e-6)
        #expect(abs(parts[0].trimEnd - (4.033333333 - 1 / 60)) < 1e-6)
        #expect(parts[1].clockStart == parts[0].clockEnd)
        #expect(parts[1].clockEnd == 7.423)
        // ceil(7.423 * 30) / 30 - 1/60 = 223 / 30 - 1/60
        #expect(abs(parts[1].trimEnd - (223.0 / 30 - 1.0 / 60)) < 1e-9)
        for part in parts {
            let frames = part.clockStart * 30
            #expect(abs(frames - frames.rounded()) < 1e-6)
        }
        #expect(abs(RenderFinishingRanges.trimStart(parts[1]) - (parts[1].clockStart - 1 / 60)) < 1e-9)
        #expect(RenderFinishingRanges.trimStart(RenderFinishingRanges.Part(start: 0, end: 1, first: 0, last: 0)) == 0)
    }

    @Test func identityDependsOnCoveredAndNeighboringGroupsOnly() throws {
        var parts = try RenderFinishingRanges.plan(durations: [2, 2, 2, 2, 2, 2], target: 4)
        RenderFinishingRanges.clock(&parts, startTime: 0, limit: 12)
        let overlay = RenderFinishingKey.Overlay(pixels: "pixels", start: 0, end: 12, transIn: "fade", transOut: "none")
        func key(_ part: RenderFinishingRanges.Part, _ identities: [String],
                 overlays: [RenderFinishingKey.Overlay] = [overlay], encoder: [String] = ["-c:v", "x"]) throws -> String {
            try RenderFinishingRanges.key(part: part, groups: groups(identities), overlays: overlays,
                                          settings: RenderSettings(), encoder: encoder)
        }
        let base = ["a", "b", "c", "d", "e", "f"]
        let middle = parts[1]  // groups 2-3, neighbors 1 and 4
        let original = try key(middle, base)
        #expect(try key(middle, ["A", "b", "c", "d", "e", "f"]) == original)
        #expect(try key(middle, ["a", "b", "c", "d", "e", "F"]) == original)
        #expect(try key(middle, ["a", "B", "c", "d", "e", "f"]) != original)
        #expect(try key(middle, ["a", "b", "C", "d", "e", "f"]) != original)
        #expect(try key(middle, ["a", "b", "c", "d", "E", "f"]) != original)
        #expect(try key(parts[0], base) != original)
        var later = middle
        later.clockStart += 1 / 30
        #expect(try key(later, base) != original)
        var moved = overlay
        moved.start = 0.5
        #expect(try key(middle, base, overlays: [moved]) != original)
        #expect(try key(middle, base, encoder: ["-c:v", "y"]) != original)
        #expect(try key(parts[0], base) == key(parts[0], ["a", "b", "c", "D", "e", "f"]))
        #expect(try key(parts[2], base) != key(parts[2], ["a", "b", "c", "D", "e", "f"]))
    }

    @Test func groupIdentityCoversSegmentsTransitionsAndDuration() throws {
        let original = try RenderFinishingRanges.groupIdentity(segmentDigests: ["s1", "s2"], transitions: ["fade"],
                                                               transitionDuration: 0.3)
        #expect(try RenderFinishingRanges.groupIdentity(segmentDigests: ["s1", "s2"], transitions: ["fade"],
                                                        transitionDuration: 0.3) == original)
        #expect(try RenderFinishingRanges.groupIdentity(segmentDigests: ["s2", "s1"], transitions: ["fade"],
                                                        transitionDuration: 0.3) != original)
        #expect(try RenderFinishingRanges.groupIdentity(segmentDigests: ["s1", "s2"], transitions: ["wipeleft"],
                                                        transitionDuration: 0.3) != original)
        #expect(try RenderFinishingRanges.groupIdentity(segmentDigests: ["s1", "s2"], transitions: ["fade"],
                                                        transitionDuration: 0.5) != original)
    }

    @Test func ffmpegArgumentsSeekEveryInputAndKeepTheOriginalClock() throws {
        var parts = try RenderFinishingRanges.plan(durations: [2, 2, 2, 2], target: 4)
        RenderFinishingRanges.clock(&parts, startTime: 0, limit: 8)
        let part = parts[1]
        let video = URL(fileURLWithPath: "/tmp/assembled.mp4")
        let input = RenderFinishingRanges.inputArguments(video: video, part: part)
        #expect(input == ["-y", "-copyts", "-ss", "3.983333", "-i", "/tmp/assembled.mp4"])
        #expect(RenderFinishingRanges.seekArguments(part) == ["-ss", "3.983333"])
        let filter = RenderFinishingRanges.rangeFilter(previous: "[txt1]", part: part)
        #expect(filter == "[txt1]trim=start=3.983333333:end=7.983333333,setpts=PTS-4.000000000/TB[range]")
        let output = RenderFinishingRanges.outputArguments(part: part, encoder: ["-c:v", "x"],
                                                           output: URL(fileURLWithPath: "/tmp/r.mp4"))
        #expect(output == ["-map", "[range]", "-c:v", "x", "-pix_fmt", "yuv420p", "-an", "-fps_mode", "vfr",
                           "-t", "4.000000000", "/tmp/r.mp4"])
        let listing = RenderFinishingRanges.concatListing([URL(fileURLWithPath: "/tmp/a'b.mp4"),
                                                           URL(fileURLWithPath: "/tmp/c.mp4")])
        #expect(listing == "file '/tmp/a'\\''b.mp4'\nfile '/tmp/c.mp4'\n")
        let join = RenderFinishingRanges.joinArguments(listing: URL(fileURLWithPath: "/tmp/l.txt"), audio: video,
                                                       firstClockStart: parts[0].clockStart,
                                                       output: URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(join == ["-y", "-itsoffset", "0.000000000", "-f", "concat", "-safe", "0", "-i", "/tmp/l.txt",
                         "-i", "/tmp/assembled.mp4", "-map", "0:v:0", "-map", "1:a?", "-c", "copy",
                         "-movflags", "+faststart", "/tmp/out.mp4"])
    }
}
