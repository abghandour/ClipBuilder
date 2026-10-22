import CoreGraphics
import Testing
@testable import Clip_Builder

struct InterviewFocusPlanningTests {
    private let vip = CGRect(x: 0.34, y: 0.2, width: 0.04, height: 0.1)
    private let host = CGRect(x: 0.52, y: 0.2, width: 0.04, height: 0.1)
    private let sourceAspect = 16.0 / 9
    private let canvasAspect = 9.0 / 16

    private func segment(_ start: Double, _ end: Double, _ talker: Int) -> CropRecipePlanner.Segment {
        .init(start: start, end: end, talker: talker, recent: [])
    }

    private func rectangle(_ crop: FreeCropRect) -> CGRect {
        CGRect(x: crop.xFrac, y: crop.yFrac, width: crop.wFrac, height: crop.hFrac)
    }

    @Test func nearbyFacesFitBelowFullHeightWithMarginAndHeadroom() {
        let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        #expect(pair.tight.hFrac == CenterStageService.Tuning.conversation.minCropHeightFraction)
        #expect(pair.twoShot.hFrac < 1 && pair.twoShot.hFrac > pair.tight.hFrac)
        #expect(pair.note == nil)
        for face in [vip, host] {
            let padded = face.insetBy(dx: -face.width * FaceGuard.margin, dy: -face.height * FaceGuard.margin)
            #expect(rectangle(pair.twoShot).insetBy(dx: -0.0001, dy: -0.0001).contains(padded))
        }
        #expect(vip.minY - pair.tight.yFrac >= pair.tight.hFrac * FaceGuard.headroom - 0.0001)
        #expect(rectangle(pair.tight).contains(vip))
    }

    @Test func pullBackOpensBothShotsTowardFullHeight() {
        let tight = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        let half = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: 0.5)
        let wide = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: 1)
        let close = CenterStageService.Tuning.conversation.minCropHeightFraction
        #expect(abs(half.tight.hFrac - (close + (1 - close) / 2)) < 0.001)
        #expect(wide.tight.hFrac == 1 && wide.twoShot.hFrac == 1)
        #expect(half.twoShot.hFrac >= half.tight.hFrac && half.twoShot.hFrac >= tight.twoShot.hFrac)
        // The tight shot stays centred on the VIP; the two-shot still slides toward the host.
        #expect(rectangle(wide.tight).contains(vip))
        #expect(abs((wide.tight.xFrac + wide.tight.wFrac / 2) - vip.midX) < 0.001)
        #expect(wide.twoShot.xFrac > wide.tight.xFrac)
        for face in [vip, host] {
            #expect(rectangle(wide.twoShot).insetBy(dx: -0.0001, dy: -0.0001).contains(face))
        }
        // Out-of-range values clamp instead of producing an impossible crop.
        let over = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: 3)
        #expect(over.tight == wide.tight)
    }

    @Test(arguments: [0.05, 0.85])
    func distantFacesSaturateAndKeepVIPWhole(vipX: Double) {
        let vip = CGRect(x: vipX, y: 0.2, width: 0.08, height: 0.12)
        let other = CGRect(x: 0.9 - vipX, y: 0.2, width: 0.08, height: 0.12)
        let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [other],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        #expect(pair.twoShot.hFrac == 1)
        #expect(pair.note == "Two-shot cannot hold both faces; the interviewer is partly in frame")
        let room = vip.insetBy(dx: -vip.width * InterviewFocusPlanning.vipMarginX, dy: -vip.height * InterviewFocusPlanning.vipMarginY)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let padded = room.insetBy(dx: -room.width * FaceGuard.margin, dy: -room.height * FaceGuard.margin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(rectangle(pair.twoShot).insetBy(dx: -0.0001, dy: -0.0001).contains(padded))
        #expect(rectangle(pair.twoShot).minX >= 0 && rectangle(pair.twoShot).maxX <= 1.0001)
        if vipX < 0.5 {
            #expect(abs(pair.twoShot.xFrac - padded.minX) < 0.0001)
        } else {
            #expect(abs(rectangle(pair.twoShot).maxX - padded.maxX) < 0.0001)
        }
    }

    @Test func twoShotKeepsHalfAFaceOfRoomAroundTheVIP() {
        // A 9:16 column of a 16:9 source at full height is 0.316 wide; the
        // interviewer at 0.365 and the VIP at 0.59 fit, but only just, so
        // without the VIP's extra room the VIP's head would sit on the edge.
        let vip = CGRect(x: 0.56, y: 0.15, width: 0.05, height: 0.09)
        let host = CGRect(x: 0.355, y: 0.2, width: 0.02, height: 0.02)
        let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: 16.0 / 9, canvasAspect: 9.0 / 16, zoom: 1)
        let two = rectangle(pair.twoShot)
        #expect(two.maxX >= vip.maxX + vip.width * InterviewFocusPlanning.vipMarginX - 0.0001)
        #expect(two.minX <= vip.minX - vip.width * InterviewFocusPlanning.vipMarginX + 0.0001)
        #expect(two.minY <= vip.minY - vip.height * InterviewFocusPlanning.vipMarginY + 0.0001)
    }

    @Test func deadZoneUsesTwoShotForEntireClip() {
        let tight = FreeCropRect(xFrac: 0.3, yFrac: 0.1, wFrac: 0.2, hFrac: 0.6)
        let two = FreeCropRect(xFrac: 0.29, yFrac: 0.1, wFrac: 0.21, hFrac: 0.62)
        let path = InterviewFocusPlanning.path(moves: [(10, .tight), (14, .twoShot), (20, .tight)],
            tight: tight, twoShot: two, length: 20)
        #expect(path.map(\.t) == [0, 20])
        #expect(path.allSatisfy { $0.x == two.xFrac && $0.y == two.yFrac && $0.w == two.wFrac && $0.h == two.hFrac })
    }

    @Test func bothKindsOfShortInterjectionNeverMove() {
        for opening in [0, 1] {
            let moves = InterviewFocusPlanning.moves(segments: [segment(10, 15, opening),
                segment(15, 15.9, 1 - opening), segment(15.9, 30, opening)], vipTiles: [0], range: 10...30)
            #expect(moves.count == 1)
            #expect(moves.first?.time == 10)
            #expect(moves.first?.kind == (opening == 0 ? .tight : .twoShot))
        }
    }

    @Test func holdWaitsFourSecondsAndExpiredTurnsDoNotMove() {
        let moves = InterviewFocusPlanning.moves(segments: [segment(10, 12, 0), segment(12, 17, 1), segment(17, 30, 0)],
            vipTiles: [0], range: 10...30)
        #expect(moves.map(\.time) == [10, 14, 18])
        #expect(moves.map(\.kind) == [.tight, .twoShot, .tight])
        let expired = InterviewFocusPlanning.moves(segments: [segment(10, 12, 0), segment(12, 13.5, 1), segment(13.5, 30, 0)],
            vipTiles: [0], range: 10...30)
        #expect(expired.count == 1)
    }

    @Test func openingFollowsFirstTalkerAndHasNoImmediateMove() {
        let moves = InterviewFocusPlanning.moves(segments: [segment(10, 10.2, 1), segment(10.2, 30, 0)],
            vipTiles: [0], range: 10...30)
        #expect(moves.first?.kind == .twoShot)
        #expect(moves.map(\.time) == [10, 14])
        #expect(InterviewFocusPlanning.moves(segments: [], vipTiles: [0], range: 10...30).first?.kind == .tight)
    }

    @Test func silenceAndChangesBetweenInterviewersKeepTheSameShot() {
        let moves = InterviewFocusPlanning.moves(segments: [segment(0, 5, 1), segment(8, 12, 2), segment(15, 20, 1)],
            vipTiles: [0], range: 0...20)
        #expect(moves.count == 1 && moves.first?.kind == .twoShot)
        let vipMoves = InterviewFocusPlanning.moves(segments: [segment(0, 5, 0), segment(5, 20, 2)],
            vipTiles: [0, 2], range: 0...20)
        #expect(vipMoves.count == 1 && vipMoves.first?.kind == .tight)
    }

    @Test func oneSecondTurnQualifiesAndTailSuppressesLateMoves() {
        let exact = InterviewFocusPlanning.moves(segments: [segment(0, 5, 0), segment(5, 6, 1), segment(6, 20, 0)],
            vipTiles: [0], range: 0...20)
        #expect(exact.map(\.time) == [0, 5, 9])
        for change in [7.5, 8.0, 9.0] {
            let tail = InterviewFocusPlanning.moves(segments: [segment(0, change, 0), segment(change, 10, 1)],
                vipTiles: [0], range: 0...10)
            #expect(tail.count == 1)
        }
        let before = InterviewFocusPlanning.moves(segments: [segment(0, 7.4, 0), segment(7.4, 10, 1)],
            vipTiles: [0], range: 0...10)
        #expect(before.map(\.time) == [0, 7.4])
    }

    @Test func pathsHoldStillBetweenPointEightSecondRampsWithoutCutDuplicates() {
        let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        let path = InterviewFocusPlanning.path(moves: [(10, .tight), (14, .twoShot), (19, .tight)],
            tight: pair.tight, twoShot: pair.twoShot, length: 20)
        #expect(path.map(\.t) == [0, 4, 4.8, 9, 9.8, 20])
        for (from, to) in zip(path, path.dropFirst()) {
            if from.x != to.x || from.y != to.y || from.w != to.w || from.h != to.h {
                #expect(abs(to.t - from.t - InterviewFocusPlanning.moveSeconds) < 1e-9)
            }
            #expect(to.t - from.t > CameraKeyframes.cutGap)
        }
        #expect(path[0].x == path[1].x && path[0].h == path[1].h)
        #expect(path[2].x == path[3].x && path[2].h == path[3].h)
    }

    @Test(arguments: [9.0 / 16, 1.0, 16.0 / 9])
    func roundedRectanglesMatchCanvasAndStayInsideSource(aspect: Double) {
        let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: aspect)
        let path = InterviewFocusPlanning.path(moves: [(0, .tight), (4, .twoShot)],
            tight: pair.tight, twoShot: pair.twoShot, length: 12)
        #expect(CenterStageService.pathMatchesCanvas(path, sourceSize: CGSize(width: 1920, height: 1080), canvasAspect: aspect))
        for frame in path {
            #expect(frame.x >= 0 && frame.y >= 0 && frame.x + frame.w <= 1.0001 && frame.y + frame.h <= 1.0001)
            for value in [frame.x, frame.y, frame.w, frame.h] {
                #expect(abs(value * 10000 - (value * 10000).rounded()) < 1e-8)
            }
        }
    }
}
