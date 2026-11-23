import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder drawing hold rules")
struct TelestrationHoldRulesTests {
    @Test("A drawn hold samples the stored zoom in rectangle space")
    func storedZoomHold() throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        clip.cameraPath = [.init(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
                           .init(t: 2, x: 0.3, y: 0.2, w: 0.4, h: 0.4)]
        let pieces = try #require(TelestrationHoldRules.insertion(in: clip, at: 1,
            drawing: Telestration(time: 1, stay: 1)))
        let hold = try #require(pieces.first { $0.hold == true })
        let path = try #require(hold.cameraPath)
        for key in path { #expect(abs(key.w - 0.6) < 1e-9) }
        let boundary = HoldClipRules.cameraPath(clip.cameraPath ?? [], at: 1.999, duration: 1)
        let width = try #require(boundary.first).w
        #expect(abs(width - (0.8 - 0.4 * 1.999 / 2)) < 1e-9)
    }

    private func drawing() -> Telestration {
        Telestration(time: 99, figures: [.init(kind: .arrow,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)])], stay: 2.7)
    }

    @Test("Insertion preserves source clocks, camera paths, and clip settings", arguments: [0.5, 1.0, 2.0])
    func pieces(speed: Double) throws {
        var clip = Fixtures.timelineClip(sourceStart: 10, duration: 4, startTime: 5, speed: speed)
        clip.cameraPath = [.init(t: 0, x: 0, y: 0, w: 0.4, h: 1),
                           .init(t: 4 * speed, x: 0.6, y: 0, w: 0.4, h: 1)]
        clip.transIn = "fade"
        clip.transOut = "fadeblack"
        clip.fadeIn = 0.2
        clip.fadeOut = 0.3
        clip.strikeHighlights = true
        let note = drawing()
        let pieces = try #require(TelestrationHoldRules.insertion(in: clip, at: 6, drawing: note))
        #expect(pieces.count == 3)
        let head = pieces[0], hold = pieces[1], tail = pieces[2]
        let contact = 10 + speed
        #expect(abs(try #require(head.sourceStart) - 10) < 1e-9)
        #expect(abs(try #require(head.sourceEnd) - contact) < 1e-9)
        #expect(abs(try #require(hold.sourceStart) - contact) < 1e-9)
        #expect(abs(try #require(hold.sourceEnd) - contact) < 1e-9)
        #expect(abs(try #require(tail.sourceStart) - contact) < 1e-9)
        #expect(abs(try #require(tail.sourceEnd) - (10 + 4 * speed)) < 1e-9)
        #expect(abs(head.duration - 1) < 1e-9 && abs(tail.duration - 3) < 1e-9)
        #expect(abs(hold.duration - note.duration) < 1e-9)
        #expect(abs(hold.startTime - 6) < 1e-9)
        #expect(abs(tail.startTime - (6 + note.duration)) < 1e-9)
        #expect(abs(pieces.reduce(0) { $0 + $1.duration } - (clip.duration + note.duration)) < 1e-9)
        #expect(hold.hold == true && head.hold != true && tail.hold != true)
        #expect(hold.speed == nil && abs(hold.sourceSpan) < 1e-9)
        #expect(abs(head.effectiveSpeed - speed) < 1e-9 && abs(tail.effectiveSpeed - speed) < 1e-9)
        let saved = try #require(hold.telestration)
        #expect(abs(saved.time - contact) < 1e-9 && saved.figures == note.figures)
        #expect(head.telestration == nil && tail.telestration == nil)
        #expect(Set(pieces.map(\.uid)).count == 3 && pieces.allSatisfy { $0.uid != clip.uid })
        #expect(pieces.allSatisfy { $0.originKey == clip.originKey && $0.strikeHighlights == true })
        #expect(head.transIn == clip.transIn && tail.transOut == clip.transOut)
        #expect(head.transOut == nil && hold.transIn == nil && hold.transOut == nil && tail.transIn == nil)
        #expect(abs(hold.fadeIn) < 1e-9 && abs(hold.fadeOut) < 1e-9)
        let frozenPath = try #require(hold.cameraPath)
        #expect(frozenPath.count == 2)
        #expect(abs(frozenPath[0].x - 0.15) < 1e-9 && abs(frozenPath[1].x - 0.15) < 1e-9)
        #expect(abs(frozenPath[1].t - note.duration) < 1e-9)
        #expect(abs(try #require(head.cameraPath?.last).t - speed) < 1e-9)
        #expect(abs(try #require(tail.cameraPath?.first).x - 0.15) < 1e-9)
        #expect(abs(try #require(tail.cameraPath?.last).t - 3 * speed) < 1e-9)
    }

    @Test("Builder preserves the original freeze flag; the reel splitter still marks every piece")
    func marks() throws {
        for mark in [nil, false, true] as [Bool?] {
            var clip = Fixtures.timelineClip(sourceStart: 0, duration: 4)
            clip.strikeImpactsFrozen = mark
            let pieces = try #require(TelestrationHoldRules.insertion(in: clip, at: 2, drawing: drawing()))
            #expect(pieces.allSatisfy { $0.strikeImpactsFrozen == mark })
            if mark != true {
                #expect(StrikeFreezeRules.contacts(pieces[0], contacts: [1]).count == 1)
            }
        }
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 4)
        let reel = StrikeFreezeRules.pieces(clip, pauses: [.init(time: 2, duration: drawing().duration, drawing: drawing())])
        #expect(reel.count == 3 && reel.allSatisfy { $0.strikeImpactsFrozen == true })
    }

    @Test("Unsupported clips, invalid times and durations are refused without changing the clip")
    func refusals() {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 2, startTime: 3)
        for time in [Double.nan, .infinity, 2.9, 3, 3.249, 4.751, 5, 6] {
            #expect(TelestrationHoldRules.insertion(in: clip, at: time, drawing: drawing()) == nil)
        }
        for time in [3.25, 4.75] {
            #expect(TelestrationHoldRules.insertion(in: clip, at: time, drawing: drawing())?.count == 3)
        }
        var bumper = clip; bumper.bumper = true
        var cutaway = clip; cutaway.role = .cutaway
        var hold = clip; hold.hold = true
        var missing = clip; missing.sourceStart = nil
        var shortSource = clip; shortSource.sourceEnd = 0.5
        for invalid in [bumper, cutaway, hold, missing, shortSource] {
            #expect(TelestrationHoldRules.insertion(in: invalid, at: 4, drawing: drawing()) == nil)
        }
        for duration in [Double.nan, .infinity, -1, 0.049, 40.001] {
            var invalid = drawing()
            invalid.stay = duration - Double(invalid.figures.count) * invalid.drawSpeed - invalid.fade
            #expect(TelestrationHoldRules.insertion(in: clip, at: 4, drawing: invalid) == nil)
        }
    }

    @Test("Applying follows drawing timing and removal clamps only into the plain-hold range")
    func applying() throws {
        let clip = Fixtures.timelineClip(sourceStart: 2, duration: 4)
        var hold = try #require(TelestrationHoldRules.insertion(in: clip, at: 1, drawing: drawing()))[1]
        hold.cameraPath = [.init(t: 0, x: 0.2, y: 0, w: 0.4, h: 1),
                           .init(t: hold.duration, x: 0.2, y: 0, w: 0.4, h: 1)]
        var long = drawing(); long.stay = 9
        let edited = TelestrationHoldRules.applying(long, to: hold)
        #expect(edited.uid == hold.uid && edited.hold == true)
        #expect(abs(try #require(edited.sourceStart) - (try #require(hold.sourceStart))) < 1e-9)
        #expect(abs(try #require(edited.sourceEnd) - (try #require(hold.sourceEnd))) < 1e-9)
        #expect(abs(edited.duration - long.duration) < 1e-9)
        #expect(abs(try #require(edited.telestration).time - 3) < 1e-9)
        #expect(abs(try #require(edited.cameraPath?.last).t - long.duration) < 1e-9)
        for (length, expected) in [(edited.duration, 5.0), (0.01, 0.05), (0.8, 0.8)] {
            var source = edited; source.duration = length
            let cleared = TelestrationHoldRules.applying(nil, to: source)
            #expect(cleared.telestration == nil && cleared.uid == hold.uid)
            #expect(abs(cleared.duration - expected) < 1e-9)
            #expect(abs(try #require(cleared.cameraPath?.last).t - expected) < 1e-9)
        }
    }

    @Test("Locked Builder editor never steps or clamps the held moment")
    func lockedEditor() {
        let editor = TelestratorEditor(initialTime: 9.99, duration: 10, aspect: 1,
                                       existing: drawing(), lockTime: true)
        #expect(abs(editor.drawing.time - 9.99) < 1e-9)
        editor.step(-1)
        editor.setTime(1)
        #expect(abs(editor.drawing.time - 9.99) < 1e-9)
        let ordinary = TelestratorEditor(initialTime: 2, duration: 10, aspect: 1, existing: nil)
        ordinary.setTime(3)
        #expect(abs(ordinary.drawing.time - 3) < 1e-9)
    }
}
