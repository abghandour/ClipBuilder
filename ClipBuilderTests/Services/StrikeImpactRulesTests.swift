import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike impact rules")
struct StrikeImpactRulesTests {
    private func clip(speed: Double = 1) -> TimelineClip {
        var value = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 4 / speed, startTime: 3)
        value.videoFile = "/tmp/impact.mp4"
        value.sourceEnd = 14
        value.speed = speed
        return value
    }

    @Test(arguments: StrikeImpactRules.Strength.allCases, [1.0, 0.5])
    func strengths(strength: StrikeImpactRules.Strength, speed: Double) throws {
        let original = clip(speed: speed)
        let result = StrikeImpactRules.slowing([original], contacts: [12], strength: strength)
        if speed * strength.factor < 0.25 {
            #expect(result.skipped == 1 && result.pieces == [original])
            return
        }
        let slow = try #require(result.pieces.first { abs($0.effectiveSpeed - speed * strength.factor) < 1e-9 })
        #expect(abs(slow.duration - strength.lead / (speed * strength.factor)) < 1e-9)
        #expect(abs(try #require(slow.sourceStart) - (12 - strength.lead)) < 1e-9)
        #expect(abs(try #require(slow.sourceEnd) - 12) < 1e-9)
        let added = strength.lead / speed * (1 / strength.factor - 1)
        #expect(abs(result.pieces.reduce(0) { $0 + $1.duration } - original.duration - added) < 1e-9)
        #expect(abs(try #require(result.pieces.last).startTime - (3 + 2 / speed + added)) < 1e-9)
    }

    @Test func endContactAndHold() throws {
        let original = clip()
        let end = StrikeImpactRules.slowed([original], contacts: [14], strength: .medium)
        #expect(end.count == 2)
        #expect(abs(try #require(end.last).duration - 1.25) < 1e-9)
        let paused = StrikeFreezeRules.pieces(original, contacts: [12], hold: 0.8)
        let slowed = StrikeImpactRules.slowed(paused, contacts: [12, 13], strength: .medium)
        let held = try #require(slowed.first { $0.hold == true })
        #expect(abs(held.startTime - 5.75) < 1e-9)
        #expect(abs(held.duration - 0.8) < 1e-9)
        #expect(slowed.filter { $0.speed == 0.4 }.count == 2)
        #expect(abs(try #require(slowed.last).startTime - 8.3) < 1e-9)
    }

    @Test func overlapMinimumAndExclusions() {
        let original = clip()
        let overlap = StrikeImpactRules.slowing([original], contacts: [12, 12.3], strength: .medium)
        #expect(overlap.skipped == 1 && overlap.stretches.count == 1)
        for contact in [10.6, 13.9] {
            let result = StrikeImpactRules.slowing([original], contacts: [contact], strength: .medium)
            #expect(result.skipped == 1 && result.pieces == [original])
        }
        // A clamped lead may occupy the entire head, provided its new screen
        // duration meets the minimum; it need not meet it at the old speed.
        let short = StrikeImpactRules.slowing([original], contacts: [10.1], strength: .medium)
        #expect(short.skipped == 0)
        #expect(abs(short.pieces[0].duration - 0.25) < 1e-9)
        #expect(StrikeImpactRules.slowing([clip(speed: 0.625)], contacts: [12], strength: .medium).skipped == 0)
        #expect(StrikeImpactRules.slowing([clip(speed: 0.625 - 1e-10)], contacts: [12], strength: .medium).skipped == 1)
        for kind in 0..<3 {
            var excluded = original
            if kind == 0 { excluded.hold = true }
            if kind == 1 { excluded.bumper = true }
            if kind == 2 { excluded.role = .cutaway }
            #expect(StrikeImpactRules.slowed([excluded], contacts: [12], strength: .medium) == [excluded])
        }
    }

    @Test func cameraSlicesAndFlashes() throws {
        var original = clip()
        let path = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.5, h: 1),
                    CameraPathKeyframe(t: 4, x: 0.4, y: 0, w: 0.5, h: 1)]
        original.cameraPath = path
        let slow = StrikeImpactRules.slowed([original], contacts: [12], strength: .medium)
        #expect(slow[1].cameraPath == CenterStageService.slice(path, from: 1.5, duration: 0.5))
        #expect(slow[2].cameraPath == CenterStageService.slice(path, from: 2, duration: 2))
        let flashed = StrikeImpactRules.flashed([original], contacts: [12])
        #expect(flashed.count == 2 && flashed[0].flashIn == nil)
        #expect(flashed[1].flashIn == StrikeImpactRules.flashDuration)
        #expect(abs(flashed.reduce(0) { $0 + $1.duration } - original.duration) < 1e-9)
        let paused = StrikeFreezeRules.pieces(original, contacts: [12], hold: 0.8)
        let heldFlash = StrikeImpactRules.flashed(paused, contacts: [12])
        #expect(heldFlash[1].hold == true && heldFlash[1].flashIn == 0.12)
        #expect(heldFlash[2].flashIn == nil)
        #expect(StrikeImpactRules.flashed([original], contacts: [10.1, 13.9]) == [original])
    }

    @Test func optionalCodingAndEquality() throws {
        let original = clip()
        let encoder = JSONEncoder()
        let plain = try #require(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        #expect(plain["flash_in"] == nil)
        var flashed = original
        flashed.flashIn = 0.12
        #expect(flashed != original)
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: encoder.encode(flashed))
        #expect(decoded.flashIn == 0.12)
        #expect(try JSONDecoder().decode(TimelineClip.self, from: encoder.encode(original)).flashIn == nil)
    }
}
