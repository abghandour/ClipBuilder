import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Shared strike freezes")
struct SharedStrikeFreezeTests {
    private func track(_ slot: Int, start: Double = 10, duration: Double = 5,
                       at: Double = 0, speed: Double = 2) -> TimelineClip {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: start, duration: duration,
            startTime: at, track: slot, speed: speed)
        clip.videoFile = slot == 0 ? "/main.mp4" : "/companion.mp4"
        clip.precision = .speech
        clip.cameraPath = [.init(t: 0, x: 0, y: 0, w: 0.5, h: 1),
                           .init(t: duration * speed, x: 0.5, y: 0, w: 0.5, h: 1)]
        return clip
    }

    @Test("A main-source pause holds both clocks, preserves camera math and shifts later clips")
    func mainPause() throws {
        let main = track(0), companion = track(1, start: 30)
        let later = track(1, start: 60, duration: 1, at: 6)
        let result = try #require(StrikeFreezeRules.sharedPieces([[main], [companion, later]],
            pauses: [.init(time: 2, duration: 0.8)]))
        for (slot, start) in [(0, 10.0), (1, 30.0)] {
            #expect(result[slot].prefix(3).map(\.duration) == [2, 0.8, 3])
            #expect(result[slot].prefix(3).map(\.startTime) == [0, 2, 2.8])
            #expect(result[slot][1].sourceStart == start + 4)
            #expect(result[slot][1].sourceEnd == start + 4)
            #expect(result[slot][2].sourceStart == start + 4)
            #expect(result[slot][1].hold == true && result[slot][1].speed == nil)
            let path = try #require(slot == 0 ? main.cameraPath : companion.cameraPath)
            #expect(result[slot][1].cameraPath == HoldClipRules.cameraPath(path, at: 4, duration: 0.8))
            #expect(result[slot].allSatisfy { $0.strikeImpactsFrozen == true })
        }
        #expect(result[1][3].startTime == 6.8)
        #expect(result[1][3].sourceStart == later.sourceStart)
    }

    @Test("Companion drawing keeps its clock and attaches only to its own held frame")
    func companionDrawing() throws {
        let drawing = Telestration(time: 34, stay: 6)
        let result = try #require(StrikeFreezeRules.sharedPieces([[track(0)], [track(1, start: 30)]],
            pauses: [.init(time: 2, duration: drawing.duration, drawing: drawing, source: "/companion.mp4")]))
        #expect(result[0].allSatisfy { $0.telestration == nil })
        #expect(result[1][1].telestration == drawing)
        #expect(result[0][1].duration == drawing.duration && result[1][1].duration == drawing.duration)
        #expect(result[0][2].startTime == result[1][2].startTime)
    }

    @Test("A shorter companion stays absent after its end; a later clip still shifts")
    func shorterCompanionAndGap() throws {
        let main = track(0)
        let short = track(1, start: 30, duration: 1)
        let later = track(1, start: 60, duration: 1, at: 4)
        let result = try #require(StrikeFreezeRules.sharedPieces([[main], [short, later]],
            pauses: [.init(time: 0.5, duration: 0.8), .init(time: 2, duration: 0.8)]))
        #expect(result[0].count == 5 && result[1].count == 4)
        #expect(result[1].filter { $0.hold == true }.count == 1)
        #expect(abs(result[1][2].startTime + result[1][2].duration - 1.8) < 1e-9)
        #expect(abs(result[1][3].startTime - 5.6) < 1e-9)
        #expect(result[1].allSatisfy { $0.strikeImpactsFrozen == true })
    }

    @Test("An edge on any picture drops the pause everywhere, including internal source switches")
    func edgeDrops() throws {
        let main = track(0)
        let first = track(1, start: 30, duration: 2.1)
        let second = track(1, start: 60, duration: 2.9, at: 2.1)
        let pauses: [StrikeFreezeRules.Pause] = [.init(time: 1, duration: 0.8),
            .init(time: 2, duration: 0.8), .init(time: 2.2, duration: 0.8), .init(time: 3, duration: 0.8)]
        #expect(StrikeFreezeRules.sharedPauseIndices([[main], [first, second]], pauses: pauses) == [0, 3])
        let result = try #require(StrikeFreezeRules.sharedPieces([[main], [first, second]], pauses: pauses))
        for pieces in result {
            let holds = pieces.filter { $0.hold == true }.map(\.startTime)
            #expect(holds.count == 2 && abs(holds[0] - 1) < 1e-9 && abs(holds[1] - 3.8) < 1e-9)
            let last = try #require(pieces.last)
            #expect(abs(last.startTime + last.duration - 6.6) < 1e-9)
        }
        #expect(StrikeFreezeRules.sharedPieces([[main], [first]], pauses: [.init(time: 2, duration: 0.8)]) == nil)
    }

    @Test("Composed views of the same source draw in both matching areas, within one frame only")
    func sameSource() throws {
        let main = track(0)
        var same = track(1)
        same.videoFile = main.videoFile
        var shifted = same
        shifted.track = 2
        shifted.sourceStart = 10.1
        shifted.sourceEnd = 20.1
        let drawing = Telestration(time: 14)
        let result = try #require(StrikeFreezeRules.sharedPieces([[main], [same], [shifted]],
            pauses: [.init(time: 2, duration: drawing.duration, drawing: drawing)]))
        #expect(result[0][1].telestration == drawing && result[1][1].telestration == drawing)
        #expect(result[2][1].telestration == nil)
        shifted.sourceStart = 10 + 1.0 / 30
        shifted.sourceEnd = 20 + 1.0 / 30
        let close = try #require(StrikeFreezeRules.sharedPieces([[main], [shifted]],
            pauses: [.init(time: 2, duration: drawing.duration, drawing: drawing)]))
        #expect(close[1][1].telestration == drawing)
    }

    @Test("Nonzero clip starts and different speeds use each track's source clock")
    func independentClocks() throws {
        let main = track(0, at: 1, speed: 0.5)
        let companion = track(1, start: 30, duration: 4, at: 2, speed: 2)
        let result = try #require(StrikeFreezeRules.sharedPieces([[main], [companion]],
            pauses: [.init(time: 3, duration: 0.8), .init(time: 4, duration: 1)]))
        #expect(result[0].filter { $0.hold == true }.map(\.sourceStart) == [11, 11.5])
        #expect(result[1].filter { $0.hold == true }.map(\.sourceStart) == [32, 34])
        #expect(result[0].filter { $0.hold == true }.map(\.startTime) == [3, 4.8])
        #expect(result[1].filter { $0.hold == true }.map(\.startTime) == [3, 4.8])
    }

    @Test("One invalid source prevents a partial multi-track split")
    func atomicFailure() {
        var broken = track(1)
        broken.sourceStart = nil
        #expect(StrikeFreezeRules.sharedPieces([[track(0)], [broken]], pauses: [.init(time: 2, duration: 0.8)]) == nil)
    }
}
