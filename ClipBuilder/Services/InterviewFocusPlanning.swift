import CoreGraphics
import Foundation

/// Static interview shots and slow moves, independent of decoding and persistence.
nonisolated enum InterviewFocusPlanning {
    static let moveSeconds = 0.8
    static let deadZoneCenter = 0.05
    static let deadZoneHeight = 0.08

    struct Shot: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case tight, twoShot }
        var kind: Kind
        var rect: FreeCropRect
    }

    /// Faces are normalized, top-left source coordinates. Work in source-height
    /// units so FaceGuard's margins and the canvas aspect use the same scale.
    static func rects(vipFace: CGRect, otherFaces: [CGRect], sourceAspect: Double,
                      canvasAspect: Double) -> (tight: FreeCropRect, twoShot: FreeCropRect, note: String?) {
        let sourceAspect = max(0.001, sourceAspect)
        let aspect = max(0.001, canvasAspect)
        let bounds = CGRect(x: 0, y: 0, width: sourceAspect, height: 1)
        func scaled(_ face: CGRect) -> CGRect {
            CGRect(x: face.minX * sourceAspect, y: face.minY,
                   width: face.width * sourceAspect, height: face.height).intersection(bounds)
        }
        func normalised(_ rect: CGRect) -> FreeCropRect {
            func round4(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }
            return FreeCropRect(xFrac: round4(rect.minX / sourceAspect), yFrac: round4(rect.minY),
                                wFrac: round4(rect.width / sourceAspect), hFrac: round4(rect.height))
        }
        let vip = scaled(vipFace)
        let others = otherFaces.map(scaled).filter { !$0.isNull && !$0.isEmpty }
        let maxHeight = min(1, sourceAspect / aspect)
        let height = min(maxHeight, CenterStageService.Tuning.conversation.minCropHeightFraction)
        let width = height * aspect
        let seed = CGRect(x: min(sourceAspect - width, max(0, vip.midX - width / 2)),
                          y: min(1 - height, max(0, vip.minY - height * FaceGuard.headroom)),
                          width: width, height: height)
        let tight = FaceGuard.contain(seed, faces: [vip], bounds: bounds)
        guard !others.isEmpty else { return (normalised(tight), normalised(tight), nil) }
        let faces = [vip] + others
        let union = faces.dropFirst().reduce(vip) { $0.union($1) }
        let padded = faces.map { $0.insetBy(dx: -$0.width * FaceGuard.margin, dy: -$0.height * FaceGuard.margin) }
            .reduce(CGRect.null) { $0.union($1) }.intersection(bounds)
        // Keep at least the tight shot's height; the shared VIP face guarantees
        // overlap even when the two-shot has to shift toward the interviewer.
        let neededHeight = max(tight.height, padded.height, padded.width / aspect,
                               (padded.maxY - union.minY) / (1 - FaceGuard.headroom))
        let twoHeight = min(maxHeight, neededHeight)
        let twoWidth = twoHeight * aspect
        let preferred = CGRect(x: min(sourceAspect - twoWidth, max(0, padded.midX - twoWidth / 2)),
                               y: min(1 - twoHeight, max(0, union.minY - twoHeight * FaceGuard.headroom)),
                               width: twoWidth, height: twoHeight)
        if neededHeight <= maxHeight + 1e-9 {
            let two = FaceGuard.contain(preferred, faces: faces, bounds: bounds)
            return (normalised(tight), normalised(two), nil)
        }
        // Both faces cannot fit. Go as far toward the interviewer as possible
        // while keeping the VIP's whole face and margin inside the frame.
        let towardRight = others.reduce(0) { $0 + $1.midX } / Double(others.count) >= vip.midX
        let paddedVIP = vip.insetBy(dx: -vip.width * FaceGuard.margin, dy: -vip.height * FaceGuard.margin)
            .intersection(bounds)
        let x = towardRight ? paddedVIP.minX : paddedVIP.maxX - twoWidth
        let anchored = FaceGuard.contain(CGRect(x: min(sourceAspect - twoWidth, max(0, x)),
                                               y: preferred.minY, width: twoWidth, height: twoHeight),
                                         faces: [vip], bounds: bounds)
        return (normalised(tight), normalised(anchored),
                "Two-shot cannot hold both faces; the interviewer is partly in frame")
    }

    /// Source-clock changes. Duration is known in advance, so qualifying turns
    /// start their ramp at the change, or when the current shot's hold expires.
    static func moves(segments: [CropRecipePlanner.Segment], vipTiles: [Int], range: ClosedRange<Double>,
                      hold: Double = VIPRotation.minimumHold, minimumTurn: Double = CropRecipePlanner.minimumTurn)
        -> [(time: Double, kind: Shot.Kind)] {
        let segments = segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
            .sorted { $0.start < $1.start }
        func kind(_ segment: CropRecipePlanner.Segment) -> Shot.Kind {
            vipTiles.contains(segment.talker) ? .tight : .twoShot
        }
        var result: [(time: Double, kind: Shot.Kind)] = [(range.lowerBound, segments.first.map(kind) ?? .tight)]
        for segment in segments.dropFirst() {
            guard let current = result.last, kind(segment) != current.kind,
                  segment.end - segment.start >= minimumTurn else { continue }
            let time = max(segment.start, current.time + max(VIPRotation.minimumHold, hold), range.lowerBound + 1)
            guard time < segment.end, time < range.upperBound - VIPRotation.tail else { continue }
            result.append((time, kind(segment)))
        }
        return result
    }

    static func inDeadZone(tight: FreeCropRect, twoShot: FreeCropRect) -> Bool {
        abs((tight.xFrac + tight.wFrac / 2) - (twoShot.xFrac + twoShot.wFrac / 2)) < deadZoneCenter
            && abs((tight.yFrac + tight.hFrac / 2) - (twoShot.yFrac + twoShot.hFrac / 2)) < deadZoneCenter
            && abs(tight.hFrac - twoShot.hFrac) < deadZoneHeight * tight.hFrac
    }

    /// Move times are on the source clock; keyframes count from the first move.
    static func path(moves: [(time: Double, kind: Shot.Kind)], tight: FreeCropRect, twoShot: FreeCropRect,
                     length: Double, moveSeconds: Double = moveSeconds) -> [CameraPathKeyframe] {
        let still = inDeadZone(tight: tight, twoShot: twoShot)
        let moves = moves.isEmpty ? [(time: 0.0, kind: Shot.Kind.tight)] : moves
        return path(shots: moves.map { ($0.time, Shot(kind: $0.kind, rect: still || $0.kind == .twoShot ? twoShot : tight)) },
                    length: length, moveSeconds: moveSeconds)
    }

    /// Also used when the existing VIP rotation changes which pair of rectangles
    /// is in focus. Identical rectangles produce only the opening and final hold.
    static func path(shots: [(time: Double, shot: Shot)], length: Double,
                     moveSeconds: Double = moveSeconds) -> [CameraPathKeyframe] {
        guard let first = shots.first, length > 0 else { return [] }
        func frame(_ rect: FreeCropRect, at time: Double) -> CameraPathKeyframe {
            CameraPathKeyframe(t: time, x: rect.xFrac, y: rect.yFrac, w: rect.wFrac, h: rect.hFrac)
        }
        var rect = first.shot.rect
        var result = [frame(rect, at: 0)]
        for shot in shots.dropFirst() {
            let time = shot.time - first.time
            guard shot.shot.rect != rect, time >= (result.last?.t ?? 0), time + moveSeconds <= length else { continue }
            if time > result[result.count - 1].t { result.append(frame(rect, at: time)) }
            rect = shot.shot.rect
            result.append(frame(rect, at: time + moveSeconds))
        }
        if result[result.count - 1].t < length { result.append(frame(rect, at: length)) }
        return result
    }
}
