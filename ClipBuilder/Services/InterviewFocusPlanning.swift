import CoreGraphics
import Foundation

nonisolated enum InterviewPunchIn: String, Codable, CaseIterable, Sendable {
    case vip, interviewer, talker

    var label: String {
        switch self {
        case .vip: "VIP"
        case .interviewer: "Interviewer"
        case .talker: "Whoever talks"
        }
    }
}

/// Static interview shots and slow moves, independent of decoding and persistence.
nonisolated enum InterviewFocusPlanning {
    static let moveSeconds = FramingHolds.glide
    static let deadZoneCenter = 0.05
    static let deadZoneHeight = 0.08
    /// Room the two-shot keeps around the VIP's face, as fractions of the
    /// face: half a face either side and a quarter above and below, so the
    /// VIP is never the one clipped at an edge when both people are in frame.
    static let vipMarginX = 0.5
    static let vipMarginY = 0.25

    struct Shot: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case tight, twoShot, interviewerTight }
        var kind: Kind
        var rect: FreeCropRect
    }

    /// Faces are normalized, top-left source coordinates. Work in source-height
    /// units so FaceGuard's margins and the canvas aspect use the same scale.
    /// `zoom` is the user's pull-back: 0 keeps the conversation crop height on
    /// the tight shot, 1 opens both shots to the full source height (a 9:16
    /// column of a 16:9 source shows both people head to knees).
    /// `zoomMoves` ("Zoom in/out for focus") ignores `zoom`: the tight shot is
    /// the conversation height on the VIP, and the wide shot holds everyone
    /// when they fit, else opens to the full height centred on the VIP, so
    /// the camera zooms in and out instead of panning toward the interviewer.
    static func rects(vipFace: CGRect, otherFaces: [CGRect], sourceAspect: Double,
                      canvasAspect: Double, zoom: Double = 0, zoomMoves: Bool = false)
        -> (tight: FreeCropRect, twoShot: FreeCropRect, interviewerTight: FreeCropRect?, note: String?) {
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
        let zoom = zoomMoves ? 0 : min(1, max(0, zoom.isFinite ? zoom : 0))
        // 0 % fills the frame with the VIP's face (the guard margins are the
        // only room), 100 % is the full source height; zoom moves keep the
        // conversation height for their close shot.
        func closeShot(_ face: CGRect) -> CGRect {
            let closeHeight = zoomMoves
                ? min(maxHeight, CenterStageService.Tuning.conversation.minCropHeightFraction)
                : tightHeight(vipFace: face, canvasAspect: aspect, maxHeight: maxHeight)
            let height = closeHeight + (maxHeight - closeHeight) * zoom
            let width = height * aspect
            let seed = CGRect(x: min(sourceAspect - width, max(0, face.midX - width / 2)),
                              y: min(1 - height, max(0, face.minY - height * FaceGuard.headroom)),
                              width: width, height: height)
            return FaceGuard.contain(seed, faces: [face], bounds: bounds)
        }
        let tight = closeShot(vip)
        let height = tight.height
        let interviewerTight = others.first.map { normalised(closeShot($0)) }
        guard !others.isEmpty else { return (normalised(tight), normalised(tight), nil, nil) }

        // The VIP comes first even while the interviewer talks: the two-shot
        // is planned around a VIP face with generous room, so a cut that
        // cannot hold everyone clips the interviewer, never the VIP.
        let roomy = vip.insetBy(dx: -vip.width * vipMarginX, dy: -vip.height * vipMarginY).intersection(bounds)
        let faces = [roomy] + others
        let union = faces.dropFirst().reduce(roomy) { $0.union($1) }
        let padded = faces.map { $0.insetBy(dx: -$0.width * FaceGuard.margin, dy: -$0.height * FaceGuard.margin) }
            .reduce(CGRect.null) { $0.union($1) }.intersection(bounds)
        // Keep at least the tight shot's height; the shared VIP face guarantees
        // overlap even when the two-shot has to shift toward the interviewer.
        let neededHeight = max(tight.height, padded.height, padded.width / aspect,
                               (padded.maxY - union.minY) / (1 - FaceGuard.headroom))
        let bothFit = neededHeight <= maxHeight + 1e-9
        let twoHeight = bothFit ? min(maxHeight, neededHeight) : height
        let twoWidth = twoHeight * aspect
        let preferred = CGRect(x: min(sourceAspect - twoWidth, max(0, padded.midX - twoWidth / 2)),
                               y: min(1 - twoHeight, max(0, union.minY - twoHeight * FaceGuard.headroom)),
                               width: twoWidth, height: twoHeight)
        if bothFit {
            // Everyone fits: the wide shot holds them all (for zoom moves too).
            let two = FaceGuard.contain(preferred, faces: faces, bounds: bounds)
            return (normalised(tight), normalised(two), interviewerTight, nil)
        }
        // Second tier: both heads fit once the VIP gives up the extra room,
        // so the frame holds everyone edge to edge (shoulders may be cut),
        // the usual two-shot of a standing interview, before the camera has
        // to fall back to the VIP alone.
        let plainFaces = [vip] + others
        let plainUnion = others.reduce(vip) { $0.union($1) }
        let plainPadded = plainFaces.map { $0.insetBy(dx: -$0.width * FaceGuard.margin, dy: -$0.height * FaceGuard.margin) }
            .reduce(CGRect.null) { $0.union($1) }.intersection(bounds)
        let plainNeeded = max(tight.height, plainPadded.height, plainPadded.width / aspect,
                              (plainPadded.maxY - plainUnion.minY) / (1 - FaceGuard.headroom))
        if plainNeeded <= maxHeight + 1e-9 {
            let edgeHeight = min(maxHeight, plainNeeded), edgeWidth = edgeHeight * aspect
            let seed = CGRect(x: min(sourceAspect - edgeWidth, max(0, plainPadded.midX - edgeWidth / 2)),
                              y: min(1 - edgeHeight, max(0, plainUnion.minY - edgeHeight * FaceGuard.headroom)),
                              width: edgeWidth, height: edgeHeight)
            let two = FaceGuard.contain(seed, faces: plainFaces, bounds: bounds)
            return (normalised(tight), normalised(two), interviewerTight, "Two-shot holds both people edge to edge")
        }
        if zoomMoves {
            // They cannot all fit: open to the full height around the tight
            // shot's centre so the move is a zoom, not a pan toward the interviewer.
            let wideWidth = maxHeight * aspect
            let wideSeed = CGRect(x: min(sourceAspect - wideWidth, max(0, tight.midX - wideWidth / 2)),
                                  y: min(1 - maxHeight, max(0, vip.minY - maxHeight * FaceGuard.headroom)),
                                  width: wideWidth, height: maxHeight)
            let wide = FaceGuard.contain(wideSeed, faces: [vip], bounds: bounds)
            return (normalised(tight), normalised(wide), interviewerTight, "Both people do not fit one frame; zooming out around the VIP")
        }
        // Both faces cannot fit. Follow pull-back and go as far toward the
        // interviewer as possible while keeping the VIP's roomy face inside.
        let towardRight = others.reduce(0) { $0 + $1.midX } / Double(others.count) >= roomy.midX
        let paddedVIP = roomy.insetBy(dx: -roomy.width * FaceGuard.margin, dy: -roomy.height * FaceGuard.margin)
            .intersection(bounds)
        // Never smaller than the VIP's roomy face: a face-tight Pull back
        // still shows the whole head with room while the interviewer asks.
        let anchoredHeight = min(maxHeight, max(twoHeight, paddedVIP.height / (1 - FaceGuard.headroom), paddedVIP.width / aspect))
        let anchoredWidth = anchoredHeight * aspect
        let x = towardRight ? paddedVIP.minX : paddedVIP.maxX - anchoredWidth
        let anchored = FaceGuard.contain(CGRect(x: min(sourceAspect - anchoredWidth, max(0, x)),
                                               y: min(1 - anchoredHeight, max(0, union.minY - anchoredHeight * FaceGuard.headroom)),
                                               width: anchoredWidth, height: anchoredHeight),
                                         faces: [roomy], bounds: bounds)
        let showsInterviewer = others.contains { anchored.intersects($0) }
        return (normalised(tight), normalised(anchored), interviewerTight,
                showsInterviewer ? "Two-shot cannot hold both faces; the interviewer is partly in frame"
                                 : "Two-shot cannot hold both faces; the camera stays on the VIP")
    }

    /// The smallest crop height that still holds a face with FaceGuard's
    /// margins and headroom, in source-height units (`face` is already
    /// scaled by the source aspect). Never below `minimumHeight` so a tiny
    /// detection cannot zoom into a few pixels.
    static let minimumHeight = 0.12
    /// Face boxes below this are placeholders (a layout face centre, 2 % of
    /// the frame), not a measured face: the close shot keeps the
    /// conversation height rather than zooming into an unknown.
    static let measuredFaceHeight = 0.05
    static func tightHeight(vipFace face: CGRect, canvasAspect: Double, maxHeight: Double) -> Double {
        guard face.width > 0, face.height >= measuredFaceHeight else {
            return min(maxHeight, CenterStageService.Tuning.conversation.minCropHeightFraction)
        }
        let byHeight = face.height * (1 + 2 * FaceGuard.margin) / (1 - FaceGuard.headroom)
        let byWidth = face.width * (1 + 2 * FaceGuard.margin) / max(0.001, canvasAspect)
        return min(maxHeight, max(minimumHeight, byHeight, byWidth))
    }

    /// Source-clock changes. Duration is known in advance, so qualifying turns
    /// start their ramp at the change, or when the current shot's hold expires.
    static func moves(segments: [CropRecipePlanner.Segment], vipTiles: [Int], range: ClosedRange<Double>,
                      hold: Double = VIPRotation.minimumHold, minimumTurn: Double = CropRecipePlanner.minimumTurn,
                      punchIn: InterviewPunchIn = .vip)
        -> [(time: Double, kind: Shot.Kind)] {
        let segments = segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
            .sorted { $0.start < $1.start }
        func kind(_ segment: CropRecipePlanner.Segment) -> Shot.Kind {
            let isVIP = vipTiles.contains(segment.talker)
            switch punchIn {
            case .vip: return isVIP ? .tight : .twoShot
            case .interviewer: return isVIP ? .twoShot : .interviewerTight
            case .talker: return isVIP ? .tight : .interviewerTight
            }
        }
        // Preserve the VIP default; other choices start wide if speech has not begun.
        let opening = punchIn == .vip ? segments.first : segments.first { $0.start <= range.lowerBound }
        var result: [(time: Double, kind: Shot.Kind)] = [
            (range.lowerBound, opening.map(kind) ?? (punchIn == .vip ? .tight : .twoShot))
        ]
        for segment in segments {
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
            && abs(tight.hFrac - twoShot.hFrac) < deadZoneHeight * min(tight.hFrac, twoShot.hFrac)
    }

    /// Move times are on the source clock; keyframes count from the first move.
    static func path(moves: [(time: Double, kind: Shot.Kind)], tight: FreeCropRect, twoShot: FreeCropRect,
                     interviewerTight: FreeCropRect? = nil, length: Double,
                     moveSeconds: Double = moveSeconds) -> [CameraPathKeyframe] {
        let moves = moves.isEmpty ? [(time: 0.0, kind: Shot.Kind.tight)] : moves
        return path(shots: moves.map {
            ($0.time, Shot(kind: $0.kind, rect: rect(for: $0.kind, tight: tight,
                twoShot: twoShot, interviewerTight: interviewerTight)))
        }, length: length, moveSeconds: moveSeconds)
    }

    static func rect(for kind: Shot.Kind, tight: FreeCropRect, twoShot: FreeCropRect,
                     interviewerTight: FreeCropRect?) -> FreeCropRect {
        switch kind {
        case .tight: inDeadZone(tight: tight, twoShot: twoShot) ? twoShot : tight
        case .twoShot: twoShot
        case .interviewerTight: interviewerTight.map { inDeadZone(tight: $0, twoShot: twoShot) ? twoShot : $0 } ?? twoShot
        }
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
            guard !inDeadZone(tight: rect, twoShot: shot.shot.rect), time >= (result.last?.t ?? 0), time + moveSeconds <= length else { continue }
            // Match recipe hard cuts: the hold key ends just before the cut.
            let holdTime = moveSeconds == 0 ? time - CameraKeyframes.cutGap : time
            if holdTime > result[result.count - 1].t { result.append(frame(rect, at: holdTime)) }
            rect = shot.shot.rect
            result.append(frame(rect, at: time + moveSeconds))
        }
        if result[result.count - 1].t < length { result.append(frame(rect, at: length)) }
        return result
    }
}
