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

    /// The planner's tightest height for a normalised face (what 0 % gives).
    private func tightHeight(for face: CGRect) -> Double {
        InterviewFocusPlanning.tightHeight(
            vipFace: CGRect(x: face.minX * sourceAspect, y: face.minY, width: face.width * sourceAspect, height: face.height),
            canvasAspect: canvasAspect, maxHeight: min(1, sourceAspect / canvasAspect))
    }

    private func rectangle(_ crop: FreeCropRect) -> CGRect {
        CGRect(x: crop.xFrac, y: crop.yFrac, width: crop.wFrac, height: crop.hFrac)
    }

    @Test func nearbyFacesFitBelowFullHeightWithMarginAndHeadroom() {
        let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        #expect(abs(pair.tight.hFrac - tightHeight(for: vip)) < 0.0001, "0 % fills the frame with the face")
        #expect(pair.tight.hFrac < CenterStageService.Tuning.conversation.minCropHeightFraction)
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
        let close = tightHeight(for: vip)
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
    func distantFacesFollowPullBackAndKeepVIPWhole(vipX: Double) {
        let vip = CGRect(x: vipX, y: 0.2, width: 0.06, height: 0.12)
        let other = CGRect(x: 0.9 - vipX, y: 0.2, width: 0.06, height: 0.12)
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let room = vip.insetBy(dx: -vip.width * InterviewFocusPlanning.vipMarginX, dy: -vip.height * InterviewFocusPlanning.vipMarginY)
            .intersection(bounds)
        let padded = room.insetBy(dx: -room.width * FaceGuard.margin, dy: -room.height * FaceGuard.margin)
            .intersection(bounds)
        var previousHeight = 0.0
        for zoom in [0.0, 0.5, 1.0] {
            let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [other],
                sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: zoom)
            let two = rectangle(pair.twoShot), tight = rectangle(pair.tight)
            // The anchored shot follows Pull back but never gets smaller than the VIP's roomy face.
            #expect(two.height >= tight.height - 0.0001 && two.height >= previousHeight - 0.0001)
            if zoom == 1 { #expect(abs(two.height - 1) < 0.0001) }
            previousHeight = two.height
            #expect(pair.note?.hasPrefix("Two-shot cannot hold both faces") == true)
            #expect(two.insetBy(dx: -0.0001, dy: -0.0001).contains(padded))
            #expect(bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(two))
            // It leans toward the interviewer as far as the frame allows; a frame no
            // wider than the padded face cannot lean but never leans away.
            let canLean = two.width > padded.width + 0.001
            if vipX < 0.5 {
                #expect(abs(two.minX - padded.minX) < 0.0001)
                #expect(canLean ? two.midX > tight.midX : two.midX >= tight.midX - 0.0001)
            } else {
                #expect(abs(two.maxX - padded.maxX) < 0.0001)
                #expect(canLean ? two.midX < tight.midX : two.midX <= tight.midX + 0.0001)
            }
        }
    }

    @Test func fullyPulledBackAnchoredShotCanCoincideWithTightShot() {
        let pair = InterviewFocusPlanning.rects(
            vipFace: CGRect(x: 0, y: 0.2, width: 0.04, height: 0.1),
            otherFaces: [CGRect(x: 0.88, y: 0.2, width: 0.04, height: 0.1)],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: 1)
        #expect(pair.note != nil)
        #expect(pair.tight == pair.twoShot)
        #expect(InterviewFocusPlanning.inDeadZone(tight: pair.tight, twoShot: pair.twoShot))
        let path = InterviewFocusPlanning.path(moves: [(0, .tight), (4, .twoShot), (8, .tight)],
            tight: pair.tight, twoShot: pair.twoShot, length: 12)
        #expect(path.map(\.t) == [0, 12])
        #expect(path.allSatisfy { $0.x == pair.twoShot.xFrac && $0.h == 1 })
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

    @Test(arguments: [0.0, 0.5, 1.0])
    func zoomMovesIgnorePullBackAndOpenAroundTheVIPWhenPeopleCannotShareAFrame(zoom: Double) {
        let vip = CGRect(x: 0.55, y: 0.2, width: 0.06, height: 0.12)
        let other = CGRect(x: 0.2, y: 0.2, width: 0.06, height: 0.12)
        let panning = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [other],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: zoom)
        let zooming = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [other],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: zoom, zoomMoves: true)
        let close = CenterStageService.Tuning.conversation.minCropHeightFraction
        let tight = rectangle(zooming.tight), wide = rectangle(zooming.twoShot)
        #expect(abs(tight.height - close) < 0.0001, "Pull back is ignored: the tight shot stays at the conversation height")
        #expect(abs(wide.height - 1) < 0.0001, "the wide shot opens to the full height")
        #expect(abs(wide.midX - tight.midX) < 0.03, "and keeps the VIP's centre instead of leaning toward the interviewer")
        #expect(wide.insetBy(dx: -0.0001, dy: -0.0001).contains(vip))
        #expect(zooming.note?.contains("zooming out") == true)
        #expect(!InterviewFocusPlanning.inDeadZone(tight: zooming.tight, twoShot: zooming.twoShot))
        #expect(rectangle(panning.twoShot).midX <= rectangle(panning.tight).midX + 0.0001, "panning never leans away from the interviewer")
        if zoom > 0 { #expect(rectangle(panning.twoShot).midX < rectangle(panning.tight).midX, "and leans toward them once the frame has room") }
    }

    @Test func zoomMovesKeepEveryoneOnScreenWhenTheyFit() {
        let vip = CGRect(x: 0.55, y: 0.2, width: 0.06, height: 0.12)
        let other = CGRect(x: 0.43, y: 0.2, width: 0.06, height: 0.12)
        let zooming = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [other],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: 1, zoomMoves: true)
        let wide = rectangle(zooming.twoShot)
        #expect(zooming.note == nil)
        #expect(wide.insetBy(dx: -0.0001, dy: -0.0001).contains(vip) && wide.insetBy(dx: -0.0001, dy: -0.0001).contains(other),
                "both faces are in the zoomed-out shot")
        #expect(wide.height < 1, "and it opens only as far as needed")
        #expect(wide.height > rectangle(zooming.tight).height)
        let panning = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [other],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: 0)
        #expect(zooming.twoShot == panning.twoShot, "a two-shot that fits is the same shot either way")
    }

    @Test func zeroPullBackIsTheFaceWithItsGuardMarginsNeverSmallerThanTheFloor() {
        // A 9:16 column is 0.5625 source-height units wide; the face's width
        // plus margins decides the height when it is the tighter constraint.
        let face = CGRect(x: 0.5 * sourceAspect, y: 0.2, width: 0.06 * sourceAspect, height: 0.12)
        let height = InterviewFocusPlanning.tightHeight(vipFace: face, canvasAspect: canvasAspect, maxHeight: 1)
        let byHeight = 0.12 * (1 + 2 * FaceGuard.margin) / (1 - FaceGuard.headroom)
        let byWidth = face.width * (1 + 2 * FaceGuard.margin) / canvasAspect
        #expect(abs(height - max(byHeight, byWidth)) < 0.0001)
        #expect(height < CenterStageService.Tuning.conversation.minCropHeightFraction)
        // The shot at 0 % holds the face with headroom, and is far tighter than the conversation crop.
        let pair = InterviewFocusPlanning.rects(vipFace: CGRect(x: 0.5, y: 0.2, width: 0.06, height: 0.12), otherFaces: [],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: 0)
        #expect(abs(pair.tight.hFrac - height) < 0.0001)
        #expect(rectangle(pair.tight).contains(CGRect(x: 0.5, y: 0.2, width: 0.06, height: 0.12)))
        // A placeholder box (a layout face centre) is not a measured face: the
        // close shot keeps the conversation height instead of zooming into it.
        let speck = InterviewFocusPlanning.tightHeight(vipFace: CGRect(x: 0.9, y: 0.3, width: 0.02, height: 0.02),
                                                       canvasAspect: canvasAspect, maxHeight: 1)
        #expect(speck == CenterStageService.Tuning.conversation.minCropHeightFraction)
        // A small but measured face still stops at the floor.
        let small = InterviewFocusPlanning.tightHeight(vipFace: CGRect(x: 0.9, y: 0.3, width: 0.03, height: 0.06),
                                                       canvasAspect: canvasAspect, maxHeight: 1)
        #expect(small >= InterviewFocusPlanning.minimumHeight)
        // A face larger than the frame allows is capped at the full height.
        #expect(InterviewFocusPlanning.tightHeight(vipFace: CGRect(x: 0, y: 0, width: 1.5, height: 0.9),
                                                    canvasAspect: canvasAspect, maxHeight: 1) == 1)
    }

    @Test func twoShotHoldsBothHeadsEdgeToEdgeWhenTheRoomyFrameDoesNotFit() {
        // The real Tanner Boser interview faces: too far apart for the VIP's
        // extra room, close enough for both heads in one full-height column.
        let vip = CGRect(x: 0.5567, y: 0.1652, width: 0.0628, height: 0.1116)
        let host = CGRect(x: 0.3389, y: 0.2494, width: 0.0746, height: 0.1327)
        for zoom in [0.0, 1.0] {
            let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
                sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: zoom)
            let two = rectangle(pair.twoShot)
            #expect(pair.note == "Two-shot holds both people edge to edge")
            #expect(two.insetBy(dx: -0.0001, dy: -0.0001).contains(vip) && two.insetBy(dx: -0.0001, dy: -0.0001).contains(host),
                    "both heads are in the frame")
            #expect(two.height > 0.9, "a standing two-shot needs almost the full height")
            #expect(abs(two.midX - (vip.midX + host.midX) / 2) < 0.08, "centred between the two people")
        }
        // Zoom moves keep everyone on screen the same way.
        let zooming = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoomMoves: true)
        #expect(rectangle(zooming.twoShot).insetBy(dx: -0.0001, dy: -0.0001).contains(host))
    }
}

extension InterviewFocusPlanningTests {
    @Test(arguments: InterviewPunchIn.allCases)
    func punchInSelectsTheRequestedSpeaker(punchIn: InterviewPunchIn) {
        let moves = InterviewFocusPlanning.moves(segments: [segment(10, 15, 0), segment(15, 22, 1), segment(22, 30, 0)],
            vipTiles: [0], range: 10...30, punchIn: punchIn)
        let expected: [InterviewFocusPlanning.Shot.Kind]
        switch punchIn {
        case .vip: expected = [.tight, .twoShot, .tight]
        case .interviewer: expected = [.twoShot, .interviewerTight, .twoShot]
        case .talker: expected = [.tight, .interviewerTight, .tight]
        }
        #expect(moves.map(\.kind) == expected)
        #expect(moves.map(\.time) == [10, 15, 22])
        let short = InterviewFocusPlanning.moves(segments: [segment(0, 5, 0), segment(5, 5.9, 1), segment(5.9, 20, 0)],
            vipTiles: [0], range: 0...20, punchIn: punchIn)
        #expect(short.count == 1)
        let held = InterviewFocusPlanning.moves(segments: [segment(0, 2, 0), segment(2, 7, 1), segment(7, 20, 0)],
            vipTiles: [0], range: 0...20, punchIn: punchIn)
        #expect(held.map(\.time) == [0, 4, 8])
        let tail = InterviewFocusPlanning.moves(segments: [segment(0, 19, 0), segment(19, 20, 1)],
            vipTiles: [0], range: 0...20, punchIn: punchIn)
        #expect(tail.count == 1)
    }

    @Test func whoeverTalksStartsWideUntilSpeechIsKnown() {
        let moves = InterviewFocusPlanning.moves(segments: [segment(5, 12, 1), segment(12, 20, 0)],
            vipTiles: [0], range: 0...20, punchIn: .talker)
        #expect(moves.map(\.time) == [0, 5, 12])
        #expect(moves.map(\.kind) == [.twoShot, .interviewerTight, .tight])
        #expect(InterviewFocusPlanning.moves(segments: [], vipTiles: [0], range: 0...20, punchIn: .talker).first?.kind == .twoShot)
    }

    @Test(arguments: [0.0, 0.5, 1.0])
    func interviewerTightUsesTheOtherFaceAndPullBack(zoom: Double) throws {
        let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect, zoom: zoom)
        let close = try #require(pair.interviewerTight)
        #expect(abs(rectangle(close).midX - host.midX) < 0.001)
        #expect(rectangle(close).insetBy(dx: -0.0001, dy: -0.0001).contains(host))
        #expect(abs(close.hFrac - (tightHeight(for: host) + (1 - tightHeight(for: host)) * zoom)) < 0.001)
        let alone = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        #expect(alone.interviewerTight == nil)
        let fallback = InterviewFocusPlanning.path(moves: [(0, .interviewerTight)],
            tight: alone.tight, twoShot: alone.twoShot, length: 10)
        #expect(fallback.allSatisfy { $0.x == alone.twoShot.xFrac })
    }

    @Test func cutsHoldUntilTheBoundaryAndNeverRamp() throws {
        let pair = InterviewFocusPlanning.rects(vipFace: vip, otherFaces: [host],
            sourceAspect: sourceAspect, canvasAspect: canvasAspect)
        let close = try #require(pair.interviewerTight)
        let path = InterviewFocusPlanning.path(moves: [(10, .twoShot), (15, .interviewerTight), (22, .tight)],
            tight: pair.tight, twoShot: pair.twoShot, interviewerTight: close, length: 20, moveSeconds: 0)
        #expect(path.map(\.t) == [0, 5 - CameraKeyframes.cutGap, 5, 12 - CameraKeyframes.cutGap, 12, 20])
        #expect(CameraKeyframes.isCut(path, at: 2) && CameraKeyframes.isCut(path, at: 4))
        for time in [0.0, 4.0, 4.995] {
            #expect(CenterStageService.interpolated(path, at: time)?.x == pair.twoShot.xFrac)
        }
        #expect(CenterStageService.interpolated(path, at: 5)?.x == close.xFrac)
        #expect(CenterStageService.interpolated(path, at: 11.995)?.x == close.xFrac)
        #expect(CenterStageService.interpolated(path, at: 12)?.x == pair.tight.xFrac)
        let slice = CenterStageService.slice(path, from: 5, duration: 10)
        #expect(slice.first?.x == close.xFrac)
        #expect(CenterStageService.interpolated(slice, at: 6.995)?.x == close.xFrac)
        #expect(CenterStageService.interpolated(slice, at: 7)?.x == pair.tight.xFrac)
        let trimmedInGap = CenterStageService.slice(path, from: 4.995, duration: 1)
        #expect(CenterStageService.interpolated(trimmedInGap, at: 0.002)?.x == pair.twoShot.xFrac)
        #expect(CenterStageService.interpolated(trimmedInGap, at: 0.006)?.x == close.xFrac)
        let trimmedToCut = CenterStageService.slice(path, from: 4.995, duration: 5 - 4.995)
        #expect(CenterStageService.interpolated(trimmedToCut, at: 0.002)?.x == pair.twoShot.xFrac)
        #expect(trimmedToCut.last?.x == close.xFrac)
        let area = ScreenCropArea(name: "Full Screen", points: [
            .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
        let filter = AreaFramer.pathFilter(keyframes: path, source: CGSize(width: 1920, height: 1080), area: area)
        #expect(filter.contains("gte(t,5.000000000)") && filter.contains("gte(T\\\\,5.000000000)"))
        #expect(!filter.contains("clip(("), "hard cuts use steps, never interpolation ramps")
    }

    @Test func deadZoneIsCheckedForEachShotPair() {
        let tight = FreeCropRect(xFrac: 0.3, yFrac: 0.1, wFrac: 0.2, hFrac: 0.6)
        let two = FreeCropRect(xFrac: 0.29, yFrac: 0.1, wFrac: 0.21, hFrac: 0.62)
        let host = FreeCropRect(xFrac: 0.65, yFrac: 0.1, wFrac: 0.2, hFrac: 0.6)
        let path = InterviewFocusPlanning.path(moves: [(0, .tight), (5, .interviewerTight), (10, .twoShot)],
            tight: tight, twoShot: two, interviewerTight: host, length: 15)
        #expect(path.map(\.t) == [0, 5, 5.8, 10, 10.8, 15])
        #expect(path[0].x == two.xFrac && path[2].x == host.xFrac && path[4].x == two.xFrac)
        let nearHost = FreeCropRect(xFrac: 0.31, yFrac: 0.1, wFrac: 0.2, hFrac: 0.6)
        let direct = InterviewFocusPlanning.path(shots: [(0, .init(kind: .tight, rect: tight)),
            (5, .init(kind: .interviewerTight, rect: nearHost))], length: 10)
        #expect(direct.map(\.t) == [0, 10])
    }
}
