import Foundation
import Testing
@testable import Clip_Builder

@Suite("Camera keyframe editing")
struct CameraKeyframesTests {
    private func k(_ t: Double, _ x: Double, y: Double = 0, w: Double = 0.3, h: Double = 1) -> CameraPathKeyframe {
        CameraPathKeyframe(t: t, x: x, y: y, w: w, h: h)
    }

    @Test("a hard cut is a hold duplicate one gap before the keyframe; hold duplicates stay hidden")
    func cutsAndVisibility() {
        let glide = [k(0, 0.1), k(4, 0.6)]
        #expect(!CameraKeyframes.isCut(glide, at: 1) && CameraKeyframes.visible(glide) == [0, 1])
        let cut = CameraKeyframes.setCut(glide, at: 1, cut: true)
        #expect(cut.count == 3 && abs(cut[1].t - 3.99) < 1e-9 && cut[1].x == 0.1)
        #expect(CameraKeyframes.isCut(cut, at: 2) && CameraKeyframes.visible(cut) == [0, 2])
        #expect(CameraKeyframes.setCut(cut, at: 2, cut: true) == cut)
        #expect(CameraKeyframes.setCut(cut, at: 2, cut: false) == glide)
        // The glide is really a glide halfway; the cut holds until the last instant.
        #expect(abs((CameraKeyframes.rect(glide, at: 2)?.x ?? 0) - 0.35) < 1e-9)
        #expect(abs((CameraKeyframes.rect(cut, at: 2)?.x ?? 0) - 0.1) < 1e-9)
        // Too close to its predecessor for a hold: unchanged.
        #expect(CameraKeyframes.setCut([k(0, 0.1), k(0.005, 0.6)], at: 1, cut: true).count == 2)
    }

    @Test("setting the crop moves a keyframe within the merge window, otherwise inserts, and keeps hold duplicates in step")
    func setRectInsertsOrMoves() {
        let path = [k(0, 0.1), k(4, 0.6)]
        let moved = CameraKeyframes.setRect(path, at: 3.9, rect: k(0, 0.5))
        #expect(moved.count == 2 && moved[1].t == 4 && moved[1].x == 0.5)
        let inserted = CameraKeyframes.setRect(path, at: 2, rect: k(0, 0.4))
        #expect(inserted.map(\.t) == [0, 2, 4] && inserted[1].x == 0.4)
        // Clamped inside the frame at the minimum size.
        let clamped = CameraKeyframes.setRect(path, at: 2, rect: k(0, 0.95, y: -0.2, w: 0.3, h: 2))
        #expect(clamped[1].x == 0.7 && clamped[1].y == 0 && clamped[1].h == 1)
        // A cut's hold duplicate repeats the keyframe it holds.
        let cut = CameraKeyframes.setCut([k(0, 0.1), k(2, 0.3), k(4, 0.6)], at: 2, cut: true)
        let changed = CameraKeyframes.setRect(cut, at: 2, rect: k(0, 0.25))
        #expect(changed[1].x == 0.25 && changed[2].x == 0.25 && changed[3].x == 0.6)
        // Nothing lands on a hold duplicate's instant.
        #expect(CameraKeyframes.setRect(cut, at: 3.99, rect: k(0, 0.9)) == CameraKeyframes.setRect(cut, at: 3.99, rect: k(0, 0.9)))
        #expect(CameraKeyframes.nearestVisible(cut, to: 3.99) == 3)
    }

    @Test("removing a keyframe takes its hold along, re-holds the next cut, and clears the path below two")
    func removal() {
        let cut = CameraKeyframes.setCut([k(0, 0.1), k(2, 0.3), k(4, 0.6)], at: 2, cut: true)
        #expect(cut.map(\.t) == [0, 2, 3.99, 4])
        let removed = try! #require(CameraKeyframes.remove(cut, at: 1))
        // The hold before the cut now repeats the first keyframe.
        #expect(removed.map(\.t) == [0, 3.99, 4] && removed[1].x == 0.1)
        let removedCut = try! #require(CameraKeyframes.remove(cut, at: 3))
        #expect(removedCut.map(\.t) == [0, 2])
        #expect(CameraKeyframes.remove([k(0, 0.1), k(4, 0.6)], at: 0) == nil)
    }

    @Test("rescaling to a new canvas keeps heights and centers; seeds are centered at the ratio")
    func rescaleAndSeed() {
        let path = [k(0, 0.2, y: 0, w: 0.3, h: 1), k(4, 0.7, y: 0, w: 0.3, h: 1)]
        let square = CameraKeyframes.rescaled(path, to: 0.5625)
        #expect(abs(square[0].w - 0.5625) < 1e-9 && square[0].h == 1)
        #expect(abs((square[0].x + square[0].w / 2) - 0.35) < 1e-9)
        #expect(abs(square[1].x - (1 - 0.5625)) < 1e-9)
        let wide = CameraKeyframes.rescaled(path, to: 1.5)
        #expect(wide[0].w == 1 && abs(wide[0].h - 1 / 1.5) < 1e-9)
        let seed = CameraKeyframes.seed(span: 8, ratio: 0.3164)
        #expect(seed.count == 2 && seed[1].t == 8 && abs(seed[0].x - (1 - 0.3164) / 2) < 1e-9 && seed[0].h == 1)
        let clip = Fixtures.timelineClip(sourceStart: 2, duration: 4, startTime: 10, speed: 2)
        #expect(CameraKeyframes.timelineTime(of: k(4, 0), clip: clip) == 12)
        #expect(CameraKeyframes.sourceOffset(atTimeline: 11, clip: clip) == 2)
        #expect(CameraKeyframes.sourceOffset(atTimeline: 30, clip: clip) == 8)
    }
}
