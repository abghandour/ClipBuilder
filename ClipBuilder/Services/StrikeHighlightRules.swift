import CoreGraphics
import Foundation

/// Finds, in the body poses of one frame, the limb that throws a strike and
/// the spot it lands on, and strings the frames around a strike into a
/// highlight that follows the limb.
///
/// The scoring model says what the strike was (`StrikeDetail`); the pose
/// detector says where the joints are. Neither knows which skeleton is which
/// fighter, so the limb is chosen by geometry: of every limb that could have
/// thrown this technique, the one whose end is closest to the right part of
/// another body. The model's left/right words only break ties, because it
/// gets them wrong often. A limb must also be MOVING: across the frames
/// around a strike the hand or foot that lands has just travelled, while a
/// referee's arm beside a fighter or a guard held in place has not.
///
/// All points are 0…1 of the frame with the origin at the top left.
/// Pure, so it is tested without video or Vision.
nonisolated enum StrikeHighlightRules {
    enum Joint: String, CaseIterable, Sendable {
        case nose, neck, root
        case leftShoulder, leftElbow, leftWrist, rightShoulder, rightElbow, rightWrist
        case leftHip, leftKnee, leftAnkle, rightHip, rightKnee, rightAnkle
    }

    nonisolated struct Pose: Equatable, Sendable {
        var joints: [Joint: CGPoint]
        /// The share of the torso that is bare skin in the picture, when
        /// the picture was looked at. Fighters are mostly stripped to the
        /// waist; the referee, corner and crowd are not.
        var bare: CGFloat? = nil

        var minY: CGFloat { joints.values.map(\.y).min() ?? 0 }
        var maxY: CGFloat { joints.values.map(\.y).max() ?? 0 }
        var height: CGFloat { maxY - minY }
        var centerX: CGFloat {
            joints.isEmpty ? 0.5 : joints.values.reduce(0) { $0 + $1.x } / CGFloat(joints.count)
        }
    }

    /// The limb as a line through its joints, and the circle it lands in.
    nonisolated struct Highlight: Equatable, Sendable, Codable {
        var limb: [CGPoint]
        var target: CGPoint
        /// Circle radius as a share of the frame HEIGHT.
        var radius: CGFloat
        /// How well the picture fits the strike: lower is better.
        var cost: CGFloat
        var limbSide: StrikeDetail.Side
        var usesArm: Bool
        /// The attacker stands left of the defender.
        var attackerOnLeft: Bool
        /// Closed clockwise outline, top-left origin; absent in plain/legacy tracks.
        var contour: [CGPoint]? = nil
    }

    /// One moment of a highlight.
    nonisolated struct Keyframe: Equatable, Sendable, Codable {
        var time: Double
        var highlight: Highlight
    }

    /// A track reduced to what is drawn: two tracks that paint the same
    /// pixels are equal, whatever the search that found them recorded.
    static func drawable(_ track: Track) -> Track {
        var track = track.current
        track.contact = 0
        for index in track.keyframes.indices {
            track.keyframes[index].highlight.cost = 0
            track.keyframes[index].highlight.limbSide = .left
            track.keyframes[index].highlight.usesArm = false
            track.keyframes[index].highlight.attackerOnLeft = false
        }
        return track
    }

    /// A highlight over time, in the source video's seconds.
    nonisolated struct Track: Equatable, Sendable, Codable {
        var keyframes: [Keyframe]
        /// The moment of impact, in the source video's seconds.
        var contact: Double
        /// Frame width over height, for placing the 0…1 points.
        var aspect: CGFloat
        var start: Double { keyframes.first?.time ?? 0 }
        var end: Double { keyframes.last?.time ?? 0 }
        /// The contour rules its outlines were found with. Outlines of older
        /// rules are neither drawn nor counted as HD: HD is made again.
        var contourVersion: Int? = nil
        var isHD: Bool {
            contourVersion == StrikeHighlightRules.contourVersion && keyframes.contains { $0.highlight.contour != nil }
        }
        /// The track as it is drawn: outlines of older rules taken out.
        var current: Track {
            guard !isHD, keyframes.contains(where: { $0.highlight.contour != nil }) else { return self }
            var track = self
            for index in track.keyframes.indices { track.keyframes[index].highlight.contour = nil }
            return track
        }
    }

    /// Stored with every saved track. Bump when the rules change enough that
    /// saved tracks should be found again.
    static let version = 5
    static let contourPoints = 48
    /// Bump when the outline is found differently enough that saved HD
    /// highlights should be made again. 2: the area follows the limb's own
    /// width instead of a wide band that took in the other leg and the hips.
    static let contourVersion = 2
    /// How long playback holds on the moment of impact when that is switched on.
    static let impactHold = 0.8

    /// A body counts as a fighter when it is this tall relative to the tallest.
    static let comparableHeight: CGFloat = 0.6
    /// The limb's end must be within this many body heights of the target.
    static let maxCost: CGFloat = 0.45
    /// Added when the model named the other limb.
    static let limbPenalty: CGFloat = 0.08
    /// Added when the limb lands on another part of the body than the model
    /// named. A penalty, not a filter: scorers call a kick to the thigh "body".
    static let targetPenalty: CGFloat = 0.08
    /// Added when the model put the attacker on the other side of the picture.
    static let sidePenalty: CGFloat = 0.15
    /// The furthest the striking part of a limb may be from the spot it is
    /// said to land on, in body heights, whatever the hints say.
    static let maxReach: CGFloat = 0.3
    /// Two poses whose middles are closer than this (body heights) are one
    /// person seen twice, not an attacker and a defender.
    static let minSeparation: CGFloat = 0.25
    /// The hand or foot must have come this much nearer the landing spot
    /// since the frame before (body heights): a limb drawing back is not a strike.
    static let minClosing: CGFloat = 0.02
    /// A torso at least this bare can be a fighter's.
    static let bareTorso: CGFloat = 0.35
    /// A torso seen to be less bare than this is someone dressed.
    static let clothedTorso: CGFloat = 0.12

    /// The poses that can be fighters. A bout has two, and when two bodies
    /// in the frame are stripped to the waist those two are it: the barest
    /// pair, leaving out the referee, a cornerman, or someone half hidden
    /// behind a fighter whose torso reads as partly skin. In a sport fought
    /// clothed nobody passes and everyone stays.
    static func contenders(_ poses: [Pose]) -> [Pose] {
        let bare = poses.filter { ($0.bare ?? 0) >= bareTorso }.sorted { ($0.bare ?? 0) > ($1.bare ?? 0) }
        if bare.count >= 2 { return Array(bare.prefix(2)) }
        // One fighter's torso is hidden (arms across it, side on): at least
        // leave out anyone plainly dressed, if that still leaves two.
        guard bare.count == 1 else { return poses }
        let undressed = poses.filter { ($0.bare ?? 1) >= clothedTorso }
        return undressed.count >= 2 ? undressed : poses
    }
    /// Seconds shown before and after the contact frame.
    static let lead = 0.3
    static let tail = 0.3
    /// Contact must fall within this many seconds of the scorer's stamp.
    static let contactWindow = 0.3
    /// Seconds between the frames a track is built from.
    static let step = 1.0 / 12
    /// The striking hand or foot must have travelled at least this many body
    /// heights in one `step` on its way in (about 0.7 body heights a second).
    static let minApproach: CGFloat = 0.06
    /// How much a body height of travel per step lowers a limb's cost.
    static let approachWeight: CGFloat = 0.8
    /// Keyframes further apart than this are not joined.
    static let maxGap = 0.2
    static let fade = 0.08

    private static func chain(_ side: StrikeDetail.Side, arm: Bool) -> [Joint] {
        switch (side, arm) {
        case (.left, true): [.leftShoulder, .leftElbow, .leftWrist]
        case (.right, true): [.rightShoulder, .rightElbow, .rightWrist]
        case (.left, false): [.leftHip, .leftKnee, .leftAnkle]
        case (.right, false): [.rightHip, .rightKnee, .rightAnkle]
        }
    }

    /// Where a technique makes contact along its limb: the hand, the foot,
    /// the knee, the elbow.
    private static func strikingJoints(_ technique: StrikeDetail.Technique, _ side: StrikeDetail.Side) -> [Joint] {
        let limb = chain(side, arm: technique.usesArm)
        switch technique {
        case .punch, .kick: return limb
        case .knee, .elbow: return Array(limb.prefix(2))
        }
    }

    private static func mid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                       y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
    }

    /// The points on a defender a strike can land on, each with the part of
    /// the body it belongs to and the circle size that suits it (in defender
    /// body heights).
    private static func zones(_ pose: Pose) -> [(point: CGPoint, size: CGFloat, part: StrikeDetail.Target)] {
        func points(_ joints: [Joint]) -> [CGPoint] { joints.compactMap { pose.joints[$0] } }
        var result: [(CGPoint, CGFloat, StrikeDetail.Target)] = []
        if let head = pose.joints[.nose] ?? pose.joints[.neck] { result.append((head, 0.1, .head)) }
        if let torso = mid(points([.leftShoulder, .rightShoulder, .leftHip, .rightHip])) { result.append((torso, 0.14, .body)) }
        for (hip, knee, ankle) in [(Joint.leftHip, Joint.leftKnee, Joint.leftAnkle), (.rightHip, .rightKnee, .rightAnkle)] {
            if let thigh = mid(points([hip, knee])), pose.joints[hip] != nil, pose.joints[knee] != nil { result.append((thigh, 0.1, .legs)) }
            if let calf = mid(points([knee, ankle])), pose.joints[knee] != nil, pose.joints[ankle] != nil { result.append((calf, 0.1, .legs)) }
        }
        return result
    }

    /// One limb that could be the strike in one frame.
    nonisolated struct Candidate: Equatable, Sendable {
        var highlight: Highlight
        var tipJoint: Joint
        /// The two poses, for following the same people into other frames.
        var attacker: Pose
        var defender: Pose
        /// The middle of the part of the defender it reaches.
        var zone: CGPoint = .zero
    }

    /// The point of the segment a–b nearest `point`, with x stretched by
    /// `aspect` so distances are in frame heights.
    private static func nearest(on a: CGPoint, _ b: CGPoint, to point: CGPoint, aspect: CGFloat) -> CGPoint {
        let dx = (b.x - a.x) * aspect, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return b }
        let along = max(0, min(1, (((point.x - a.x) * aspect) * dx + (point.y - a.y) * dy) / length))
        return CGPoint(x: a.x + (b.x - a.x) * along, y: a.y + (b.y - a.y) * along)
    }

    /// Every limb within `maxCost` of a body it could be hitting, best first.
    /// `technique` nil (an event scored before techniques were logged) tries
    /// punches and kicks. `aspect` is frame width over height.
    static func candidates(poses: [Pose], technique: StrikeDetail.Technique?, limb: StrikeDetail.Side? = nil,
                           target: StrikeDetail.Target? = nil, frameSide: StrikeDetail.Side? = nil,
                           aspect: CGFloat, maxCost: CGFloat = maxCost, maxReach: CGFloat = maxReach) -> [Candidate] {
        guard aspect > 0, let tallest = poses.map(\.height).max(), tallest > 0 else { return [] }
        let fighters = contenders(poses.filter { $0.height >= tallest * comparableHeight })
        guard fighters.count >= 2 else { return [] }
        var found: [Candidate] = []
        for (attackerIndex, attacker) in fighters.enumerated() {
            for (defenderIndex, defender) in fighters.enumerated() where defenderIndex != attackerIndex {
                let scale = (attacker.height + defender.height) / 2
                let onLeft = attacker.centerX < defender.centerX
                // The detector sometimes reports one body twice.
                guard hypot((attacker.centerX - defender.centerX) * aspect,
                            (attacker.minY + attacker.maxY - defender.minY - defender.maxY) / 2) >= minSeparation * scale
                else { continue }
                for technique in technique.map({ [$0] }) ?? [.punch, .kick] {
                    for side in [StrikeDetail.Side.left, .right] {
                        let seen = strikingJoints(technique, side).filter { attacker.joints[$0] != nil }
                        let line = seen.compactMap { attacker.joints[$0] }
                        guard line.count >= 2, let tip = line.last, let tipJoint = seen.last else { continue }
                        // The closest zone of this defender for this limb.
                        var best: Highlight?
                        var bestZone = CGPoint.zero
                        for zone in zones(defender) {
                            // A blow lands with the forearm or shin as often
                            // as with the fist or foot: measure from the
                            // nearest point of the limb's last stretch.
                            let touch = nearest(on: line[line.count - 2], tip, to: zone.point, aspect: aspect)
                            let reach = hypot((touch.x - zone.point.x) * aspect, touch.y - zone.point.y)
                            var cost = reach / scale
                            guard cost <= maxReach else { continue }
                            if let target, target != zone.part { cost += targetPenalty }
                            if let limb, limb != side { cost += limbPenalty }
                            if let frameSide, (frameSide == .left) != (attacker.centerX < 0.5) { cost += sidePenalty }
                            guard cost <= maxCost, cost < best?.cost ?? .infinity else { continue }
                            // The circle sits where the limb meets that part
                            // of the body, not on the part's middle.
                            let radius = zone.size * defender.height
                            let pull = reach > 0 ? min(1, radius / reach) : 0
                            let landed = CGPoint(x: zone.point.x + (touch.x - zone.point.x) * pull,
                                                 y: zone.point.y + (touch.y - zone.point.y) * pull)
                            best = Highlight(limb: line, target: landed, radius: radius,
                                             cost: cost, limbSide: side, usesArm: technique.usesArm, attackerOnLeft: onLeft)
                            bestZone = zone.point
                        }
                        if let best {
                            found.append(Candidate(highlight: best, tipJoint: tipJoint, attacker: attacker, defender: defender,
                                                   zone: bestZone))
                        }
                    }
                }
            }
        }
        return found.sorted { $0.highlight.cost < $1.highlight.cost }
    }

    /// The best limb and landing spot in one frame taken alone, or nil when
    /// no limb reaches a body.
    static func highlight(poses: [Pose], technique: StrikeDetail.Technique?, limb: StrikeDetail.Side? = nil,
                          target: StrikeDetail.Target? = nil, frameSide: StrikeDetail.Side? = nil,
                          aspect: CGFloat, maxCost: CGFloat = maxCost) -> Highlight? {
        candidates(poses: poses, technique: technique, limb: limb, target: target, frameSide: frameSide,
                   aspect: aspect, maxCost: maxCost).first?.highlight
    }

    /// The same body in another frame: the pose whose middle is nearest,
    /// when it is near enough to be the same person a step later.
    private static func same(_ pose: Pose, in poses: [Pose], aspect: CGFloat) -> Pose? {
        func middle(_ pose: Pose) -> CGPoint { CGPoint(x: pose.centerX, y: (pose.minY + pose.maxY) / 2) }
        let from = middle(pose)
        let nearest = poses.min {
            hypot((middle($0).x - from.x) * aspect, middle($0).y - from.y)
                < hypot((middle($1).x - from.x) * aspect, middle($1).y - from.y)
        }
        guard let nearest, hypot((middle(nearest).x - from.x) * aspect, middle(nearest).y - from.y) <= pose.height * 0.35
        else { return nil }
        return nearest
    }

    /// How far the candidate's hand or foot travelled to get here from the
    /// frame before, in body heights. 0 when the frame before does not show it.
    static func approach(_ candidate: Candidate, previous: [Pose]?, aspect: CGFloat) -> CGFloat {
        guard let previous, let before = same(candidate.attacker, in: previous, aspect: aspect),
              let was = before.joints[candidate.tipJoint], let now = candidate.attacker.joints[candidate.tipJoint],
              candidate.attacker.height > 0 else { return 0 }
        return hypot((now.x - was.x) * aspect, now.y - was.y) / candidate.attacker.height
    }

    /// How much nearer the landing spot the hand or foot is than in the
    /// frame before, in body heights. Negative for a limb drawing back.
    static func closing(_ candidate: Candidate, previous: [Pose]?, aspect: CGFloat) -> CGFloat {
        guard let previous, let before = same(candidate.attacker, in: previous, aspect: aspect),
              let was = before.joints[candidate.tipJoint], let now = candidate.attacker.joints[candidate.tipJoint],
              candidate.attacker.height > 0 else { return 0 }
        func away(_ point: CGPoint) -> CGFloat { hypot((point.x - candidate.zone.x) * aspect, point.y - candidate.zone.y) }
        return (away(was) - away(now)) / candidate.attacker.height
    }

    /// The times to read poses at for a strike logged at `time`.
    static func sampleTimes(around time: Double, duration: Double = .infinity) -> [Double] {
        // The scorer's stamp is a still up to a quarter second from contact.
        var times: [Double] = []
        // On one grid for the whole file, so strikes close together read the
        // same frames and their poses are found once.
        var current = max(0, ((time - lead - 0.25) / step).rounded(.down) * step)
        let last = min(duration, time + tail + 0.25)
        while current <= last + 0.0001 {
            times.append(current)
            current += step
        }
        return times
    }

    /// A track from the poses of consecutive frames. Contact is chosen within
    /// `contactWindow` of the logged time; the frames around
    /// it follow the same limb of the same fighter, so the highlight never
    /// jumps to the other fighter mid-strike.
    static func track(frames: [(time: Double, poses: [Pose])], time: Double, detail: StrikeDetail?, aspect: CGFloat) -> Track? {
        let frames = frames.sorted { $0.time < $1.time }
        // Contact is the frame and limb with the best fit among limbs that
        // were moving in: reach, less a credit for how far the tip travelled.
        var best: (score: CGFloat, index: Int, candidate: Candidate)?
        for (index, frame) in frames.enumerated() {
            guard frame.time >= time - contactWindow, frame.time <= time + contactWindow else { continue }
            let previous = index > 0 && frame.time - frames[index - 1].time <= maxGap ? frames[index - 1].poses : nil
            for candidate in candidates(poses: frame.poses, technique: detail?.technique, limb: detail?.limb,
                                        target: detail?.target, frameSide: detail?.frameSide, aspect: aspect) {
                let travelled = approach(candidate, previous: previous, aspect: aspect)
                guard travelled >= minApproach,
                      closing(candidate, previous: previous, aspect: aspect) >= minClosing else { continue }
                let score = candidate.highlight.cost - min(travelled, 0.5) * approachWeight
                if score < best?.score ?? .infinity { best = (score, index, candidate) }
            }
        }
        guard let best else { return nil }
        let chosen = best.candidate.highlight
        let contact = frames[best.index].time
        let technique = detail?.technique ?? (chosen.usesArm ? .punch : .kick)
        // Away from contact the limb is chambered or withdrawn, so reach is
        // not required: only the same limb of the same two people, each
        // found again frame by frame. Where either is lost the highlight
        // ends rather than move to someone else.
        func follow(_ direction: Int) -> [Keyframe] {
            var result: [Keyframe] = []
            var attacker = best.candidate.attacker, defender = best.candidate.defender
            var last = contact
            var index = best.index + direction
            while frames.indices.contains(index) {
                let frame = frames[index]
                guard abs(frame.time - contact) <= (direction < 0 ? lead : tail) + 0.0001,
                      abs(frame.time - last) <= maxGap,
                      let nextAttacker = same(attacker, in: frame.poses, aspect: aspect),
                      let nextDefender = same(defender, in: frame.poses, aspect: aspect), nextAttacker != nextDefender,
                      let followed = candidates(poses: [nextAttacker, nextDefender], technique: technique,
                                                target: detail?.target, aspect: aspect, maxCost: 1.5, maxReach: 1.5)
                        .first(where: { $0.attacker == nextAttacker && $0.highlight.limbSide == chosen.limbSide })
                else { break }
                result.append(Keyframe(time: frame.time, highlight: followed.highlight))
                attacker = nextAttacker
                defender = nextDefender
                last = frame.time
                index += direction
            }
            return result
        }
        let keyframes = follow(-1).reversed() + [Keyframe(time: contact, highlight: chosen)] + follow(1)
        return Track(keyframes: keyframes, contact: contact, aspect: aspect)
    }

    /// The highlight at `time`, blended between the keyframes either side,
    /// with its opacity (fading in and out at the ends). nil outside the track.
    static func sample(_ track: Track, at time: Double) -> (highlight: Highlight, opacity: Double)? {
        let track = track.current
        guard let first = track.keyframes.first, let last = track.keyframes.last,
              time >= first.time - fade, time <= last.time + fade else { return nil }
        let opacity = min(1, max(0, min(time - (first.time - fade), (last.time + fade) - time) / fade))
        if time <= first.time { return (first.highlight, opacity) }
        if time >= last.time { return (last.highlight, opacity) }
        guard let next = track.keyframes.firstIndex(where: { $0.time >= time }), next > 0 else { return (first.highlight, opacity) }
        let a = track.keyframes[next - 1], b = track.keyframes[next]
        if time == b.time { return (b.highlight, opacity) }
        let share = CGFloat((time - a.time) / max(0.0001, b.time - a.time))
        func blend(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
            CGPoint(x: p.x + (q.x - p.x) * share, y: p.y + (q.y - p.y) * share)
        }
        var result = a.highlight
        // A joint the detector lost in one of the two frames cannot be
        // blended; hold the earlier shape until the next keyframe.
        if a.highlight.limb.count == b.highlight.limb.count {
            result.limb = zip(a.highlight.limb, b.highlight.limb).map(blend)
        }
        result.target = blend(a.highlight.target, b.highlight.target)
        result.radius = a.highlight.radius + (b.highlight.radius - a.highlight.radius) * share
        if let left = a.highlight.contour, let right = b.highlight.contour,
           left.count == contourPoints, right.count == contourPoints {
            result.contour = zip(left, right).map(blend)
        } else {
            result.contour = nil
        }
        return (result, opacity)
    }
}
