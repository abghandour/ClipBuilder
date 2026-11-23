import Foundation
import Testing
@testable import Clip_Builder

@Suite("Whole-frame strike slow motion")
struct SharedStrikeSlowingTests {
    private nonisolated static func clip(_ track: Int, speed: Double = 1, start: Double = 0, duration: Double = 4) -> TimelineClip {
        var clip = TimelineClip()
        clip.videoFile = "/tmp/slow-\(track).mp4"
        clip.sourceStart = Double(track * 10)
        clip.sourceEnd = Double(track * 10) + duration * speed
        clip.startTime = start
        clip.duration = duration
        clip.speed = speed
        clip.track = track
        return clip
    }

    @Test(arguments: [2, 3])
    func differentSpeeds(_ count: Int) throws {
        let tracks = (0..<count).map { [Self.clip($0, speed: [1.0, 2, 0.75][$0])] }
        let result = try #require(StrikeImpactRules.sharedSlowing(tracks, contacts: [2], strength: .medium))
        #expect(result.skipped == 0 && result.stretches.count == 1)
        for (index, pieces) in result.tracks.enumerated() {
            #expect(pieces.count == 3)
            #expect(abs(pieces[1].startTime - 1.5) < 1e-9)
            #expect(abs(pieces[1].duration - 1.25) < 1e-9)
            #expect(abs(pieces[1].effectiveSpeed - tracks[index][0].effectiveSpeed * 0.4) < 1e-9)
            #expect(abs(pieces[2].startTime - 2.75) < 1e-9)
            #expect(abs(pieces.reduce(0) { $0 + $1.sourceSpan } - tracks[index][0].sourceSpan) < 1e-9)
        }
    }

    @Test(arguments: [false, true])
    func clampsAtCompanionBoundary(hold: Bool) throws {
        var before = Self.clip(1, duration: 1.8)
        before.hold = hold ? true : nil
        let after = Self.clip(1, start: 1.8, duration: 2.2)
        let result = try #require(StrikeImpactRules.sharedSlowing([[Self.clip(0)], [before, after]], contacts: [2], strength: .medium))
        #expect(result.stretches.count == 1)
        #expect(abs(result.stretches[0].start - 1.8) < 1e-9)
        #expect(abs(result.stretches[0].addedDuration - 0.3) < 1e-9)
        #expect(result.tracks[1][0] == before)
    }

    @Test(arguments: ["speed", "head", "tail", "hold", "bumper", "cutaway", "gap"])
    func companionRejectsAtomically(_ failure: String) throws {
        var other = Self.clip(1)
        if failure == "speed" { other.speed = 0.5 }
        if failure == "head" { other.startTime = 1.4; other.duration = 2.6 }
        if failure == "tail" { other.duration = 2.1 }
        if failure == "hold" { other.hold = true }
        if failure == "bumper" { other.bumper = true }
        if failure == "cutaway" { other.role = .cutaway }
        if failure == "gap" { other.duration = 1.8 }
        let tracks = [[Self.clip(0)], [other]]
        let result = try #require(StrikeImpactRules.sharedSlowing(tracks, contacts: [2], strength: .medium))
        #expect(result.skipped == 1 && result.stretches.isEmpty)
        #expect(result.tracks == tracks)
    }

    @Test func overlapAndCameraSlices() throws {
        var first = Self.clip(0)
        let path = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.8, h: 1),
                    CameraPathKeyframe(t: 4, x: 0.4, y: 0, w: 0.4, h: 1)]
        first.cameraPath = path
        let result = try #require(StrikeImpactRules.sharedSlowing([[first], [Self.clip(1)]], contacts: [2, 2.3], strength: .medium))
        #expect(result.skipped == 1 && result.stretches.count == 1)
        #expect(result.tracks[0][1].cameraPath == CenterStageService.slice(path, from: 1.5, duration: 0.5))
    }

    @Test(arguments: StrikeImpactRules.Strength.allCases, [0.5, 1.0, 2.0])
    func oneTrackPinsSevenA(strength: StrikeImpactRules.Strength, speed: Double) throws {
        let original = Self.clip(0, speed: speed)
        for contacts in [[2 * speed], [4 * speed], [2 * speed, 2.3 * speed], [0.1 * speed]] {
            let old = StrikeImpactRules.slowing([original], contacts: contacts, strength: strength)
            var shared = try #require(StrikeImpactRules.sharedSlowing([[original]], contacts: contacts.map { $0 / speed }, strength: strength))
            #expect(shared.tracks[0].count == old.pieces.count)
            guard shared.tracks[0].count == old.pieces.count else { continue }
            // New split uids are intentionally fresh in both calls; all other
            // stored values (including graph/key inputs) must be identical.
            for index in old.pieces.indices { shared.tracks[0][index].uid = old.pieces[index].uid }
            #expect(shared.tracks[0] == old.pieces)
            #expect(shared.skipped == old.skipped)
            for (actual, expected) in zip(shared.stretches, old.stretches) {
                #expect(abs(actual.start - expected.start / speed) < 1e-9)
                #expect(abs(actual.end - expected.end / speed) < 1e-9)
            }
        }
    }


    @Test func oneTrackAfterHoldPinsSevenA() throws {
        let original = Self.clip(0)
        let paused = StrikeFreezeRules.pieces(original, contacts: [2], hold: 0.8)
        let old = StrikeImpactRules.slowing(paused, contacts: [2, 3], strength: .medium)
        var shared = try #require(StrikeImpactRules.sharedSlowing([paused], contacts: [2, 3.8], strength: .medium))
        #expect(shared.tracks[0].count == old.pieces.count)
        guard shared.tracks[0].count == old.pieces.count else { return }
        for index in old.pieces.indices { shared.tracks[0][index].uid = old.pieces[index].uid }
        #expect(shared.tracks[0] == old.pieces)
        #expect(shared.skipped == old.skipped)
        #expect(abs(shared.stretches[1].start - 3.3) < 1e-9)
    }

    @Test func repeatedSourceOnOneTrackUsesTheScreenClock() throws {
        let first = Self.clip(0)
        var repeated = first
        repeated.uid = UUID(); repeated.startTime = 4
        let result = try #require(StrikeImpactRules.sharedSlowing([[first, repeated]], contacts: [2], strength: .medium))
        #expect(result.stretches.count == 1)
        let last = try #require(result.tracks[0].last)
        #expect(last.uid == repeated.uid)
        #expect(abs(last.effectiveSpeed - 1) < 1e-9)
        #expect(abs(last.startTime - 4.75) < 1e-9)
    }

    @Test func mappingIsContinuousMonotonicAndInvertible() {
        let stretches: [StrikeImpactRules.Stretch] = [.init(start: 1.5, end: 2, factor: 0.4), .init(start: 3.4, end: 4, factor: 0.25)]
        let inverse = StrikeImpactRules.inverse(stretches)
        var previous = -Double.infinity
        for i in 0...1000 {
            let time = Double(i) / 100
            let mapped = StrikeImpactRules.mapped(time, through: stretches)
            #expect(mapped > previous)
            #expect(abs(StrikeImpactRules.mapped(mapped, through: inverse) - time) < 1e-9)
            previous = mapped
        }
        for edge in stretches.flatMap({ [$0.start, $0.end] }) {
            let left = StrikeImpactRules.mapped(edge - 1e-10, through: stretches)
            let right = StrikeImpactRules.mapped(edge + 1e-10, through: stretches)
            #expect(right - left < 1e-9)
        }
    }
    @Test(arguments: [false, true])
    func overlapEndingBeforeContactClampsEverySlice(hold: Bool) throws {
        let main = Self.clip(0)
        var overlap = Self.clip(1, start: 1.4, duration: 0.4)
        overlap.hold = hold ? true : nil
        let companion = Self.clip(1)
        let result = try #require(StrikeImpactRules.sharedSlowing([[main], [companion, overlap]], contacts: [2], strength: .medium))
        #expect(result.stretches.count == 1)
        #expect(abs(try #require(result.stretches.first).start - 1.8) < 1e-9)
        #expect(result.tracks[1].last == overlap)
        let pieces = result.tracks.flatMap { $0 }
        #expect(Set(pieces.map(\.uid)).count == pieces.count)
        for piece in result.tracks[1].dropLast() {
            #expect((piece.sourceStart ?? -1) >= (companion.sourceStart ?? 0))
            #expect((piece.sourceEnd ?? .infinity) <= (companion.sourceEnd ?? 0))
        }
        var doc = Fixtures.timelineDocument(clips: pieces)
        let owner = try #require(doc.videoTrack.first { $0.track == 0 && $0.startTime > 2 })
        #expect(TimelinePauseRules.insert([.init(time: owner.startTime + 0.5, duration: 0.8, owner: owner.uid)],
            into: doc, resolve: { $0 }) != nil)
        // Malformed saved documents must be rejected without trapping.
        doc.videoTrack.append(doc.videoTrack[0])
        #expect(TimelinePauseRules.insert([.init(time: 0.5, duration: 0.8, owner: main.uid)],
            into: doc, resolve: { $0 }) == nil)
    }

    @Test func slicingNeverLeavesIntersectingClipBounds() {
        let clip = Self.clip(1, start: 1.7, duration: 0.2)
        let pieces = StrikeImpactRules.applying([.init(start: 1.5, end: 2, factor: 0.4)], to: [[clip]])[0]
        #expect(pieces.count == 1)
        #expect(pieces.first?.sourceStart == clip.sourceStart)
        #expect(abs((pieces.first?.sourceEnd ?? -1) - (clip.sourceEnd ?? 0)) < 1e-9)
    }

}
