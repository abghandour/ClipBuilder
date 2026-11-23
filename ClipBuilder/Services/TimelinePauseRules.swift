import Foundation

/// Builder pauses use one timeline clock, while each picture keeps its own source clock.
nonisolated enum TimelinePauseRules {
    struct Request: Sendable {
        var time: Double
        var duration: Double
        var drawing: Telestration? = nil
        var owner: UUID
    }

    struct Result: Sendable {
        var document: TimelineDocument
        var holds: [UUID]
        var count: Int { holds.count }
    }

    /// A slow edit already cut at contact. Freeze the continuation's first
    /// source frame without cutting a zero-length head off either side.
    static func slowBoundary(at time: Double, owner: UUID, in document: TimelineDocument) -> TimelineClip? {
        guard let selected = document.videoTrack.first(where: { $0.uid == owner }),
              let lineage = selected.slowLineage,
              let before = document.videoTrack.first(where: {
                  $0.track == selected.track && $0.slowLineage == lineage && $0.slowGroup != nil
                      && $0.hold != true && abs($0.startTime + $0.duration - time) < 1e-9
              }), let after = document.videoTrack.first(where: {
                  $0.track == selected.track && $0.slowLineage == lineage && $0.hold != true
                      && !$0.bumper && !$0.isCutaway && abs($0.startTime - time) < 1e-9
                      && $0.videoFile == before.videoFile && $0.sceneID == before.sceneID
                      && abs(($0.sourceStart ?? 0) - (before.sourceStart ?? 0) - before.sourceSpan) < 1e-9
              }) else { return nil }
        return after
    }

    static func insert(_ pauses: [Request], into document: TimelineDocument,
                       resolve: (TimelineClip) -> TimelineClip) -> Result? {
        var result = document
        // A later request still names the original clip, even after an earlier split.
        var owners = Dictionary(document.videoTrack.map { ($0.uid, $0.uid) }, uniquingKeysWith: { first, _ in first })
        guard owners.count == document.videoTrack.count else { return nil }
        var holds: [UUID] = []
        var shift = 0.0
        var previous: Double?
        let ordered = pauses.enumerated().filter { $0.element.time.isFinite }.sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }
        for (_, request) in ordered {
            let range = request.drawing == nil ? StrikeFreezeRules.holdRange : StrikeFreezeRules.drawingHoldRange
            guard request.duration.isFinite, range.contains(request.duration),
                  previous.map({ request.time - $0 >= StrikeFreezeRules.minimumPiece - 1e-9 }) ?? true else { continue }
            let time = request.time + shift
            let boundary = request.drawing == nil ? slowBoundary(at: time, owner: request.owner, in: result) : nil
            guard !result.videoTrack.contains(where: {
                $0.bumper && $0.startTime <= time && time < $0.startTime + $0.duration
            }), let owner = boundary ?? result.videoTrack.first(where: {
                owners[$0.uid] == request.owner && $0.hold != true
                    && $0.startTime <= time && time < $0.startTime + $0.duration
            }), boundary != nil || TelestrationHoldRules.insertionReason(in: resolve(owner), at: time) == nil else { continue }

            var clips: [TimelineClip] = []
            var lineage = owners
            var splits: [UUID: (head: UUID, tail: UUID)] = [:]
            var newHolds: [UUID] = []
            var ownerHold: UUID?
            var valid = true
            for clip in result.videoTrack {
                let playing = !clip.bumper && clip.startTime <= time && time < clip.startTime + clip.duration
                if playing {
                    let isOwner = clip.uid == owner.uid
                    guard var pieces = pieces(resolve(clip), at: time, request: request, owner: isOwner),
                          let frozen = pieces.first(where: { $0.hold == true && $0.uid != clip.uid }) else {
                        valid = false
                        break
                    }
                    if isOwner { ownerHold = frozen.uid }
                    newHolds.append(frozen.uid)
                    if pieces.count == 3 {
                        splits[clip.uid] = (pieces[0].uid, pieces[2].uid)
                    }
                    // Automatic freezes mark only their owner's pieces. Manual drawings
                    // and companion pieces retain the source clip's exact marker.
                    for index in pieces.indices {
                        if isOwner && request.drawing == nil { pieces[index].strikeImpactsFrozen = true }
                        lineage[pieces[index].uid] = owners[clip.uid]
                    }
                    clips += pieces
                } else {
                    var moved = clip
                    if moved.startTime >= time { moved.startTime += request.duration }
                    clips.append(moved)
                }
            }
            guard valid, let ownerHold else { continue }
            if boundary != nil {
                for index in clips.indices where clips[index].track == owner.track
                    && clips[index].slowLineage == owner.slowLineage {
                    clips[index].strikeImpactsFrozen = true
                }
            }
            let held = Set(newHolds)
            for index in clips.indices where held.contains(clips[index].uid) {
                clips[index].pauseGroup = ownerHold
            }
            result.videoTrack = clips
            if var lines = result.dubLines {
                for index in lines.indices {
                    if let split = splits[lines[index].clipUID] {
                        lines[index].clipUID = lines[index].start < time ? split.head : split.tail
                    }
                }
                result.dubLines = lines
            }
            moveLanes(in: &result, at: time, by: request.duration)
            owners = lineage
            holds.append(ownerHold)
            shift += request.duration
            previous = request.time
        }
        return holds.isEmpty ? nil : Result(document: result, holds: holds)
    }

    /// nil means an orphaned group, which callers must edit as a legacy hold.
    /// Also nil when other edits pulled the pause apart (a member moved, was
    /// split by a bumper or trimmed by a cut): the holds are then
    /// edited one by one, as before groups existed, which never moves
    /// material that the pause no longer lines up with.
    static func owner(group: UUID, in document: TimelineDocument) -> TimelineClip? {
        guard Set(document.videoTrack.map(\.uid)).count == document.videoTrack.count,
              let owner = document.videoTrack.first(where: { $0.uid == group && $0.pauseGroup == group && $0.hold == true })
        else { return nil }
        let members = document.videoTrack.filter { $0.hold == true && $0.pauseGroup == group }
        let time = owner.startTime
        guard members.allSatisfy({ member in
            guard abs(member.duration - owner.duration) < 1e-6, (member.telestration?.offset ?? 0) == 0 else { return false }
            // Two members on one track are overlapping pictures frozen at the
            // same instant, never the two halves of a freeze a bumper split.
            guard members.allSatisfy({ $0.track != member.track || abs($0.startTime - member.startTime) < 1e-6 })
            else { return false }
            if abs(member.startTime - time) <= StrikeFreezeRules.minimumPiece + 1e-6 { return true }
            // Further away only directly after an older freeze that was on screen at the pause.
            return document.videoTrack.contains {
                $0.hold == true && $0.pauseGroup != group && $0.track == member.track
                    && $0.startTime <= time && time < $0.startTime + $0.duration
                    && abs($0.startTime + $0.duration - member.startTime) < 1e-6
            }
        }) else { return nil }
        return owner
    }

    /// The length a pause needs: its longest drawing, or nil without one.
    static func drawingLength(group: UUID, in document: TimelineDocument, replacing uid: UUID,
                              with drawing: Telestration?) -> Double? {
        let others = document.videoTrack.filter { $0.hold == true && $0.pauseGroup == group && $0.uid != uid }
            .compactMap { $0.telestration?.duration }
        return (others + [drawing?.duration].compactMap { $0 }).max()
    }

    static func hasDrawing(group: UUID, in document: TimelineDocument) -> Bool {
        document.videoTrack.contains { $0.hold == true && $0.pauseGroup == group && $0.telestration != nil }
    }

    static func resized(group: UUID, in document: TimelineDocument, to duration: Double) -> TimelineDocument? {
        guard duration.isFinite, StrikeFreezeRules.drawingHoldRange.contains(duration),
              let owner = owner(group: group, in: document) else { return nil }
        return changing(group: group, owner: owner, in: document, to: duration, remove: false)
    }

    static func removed(group: UUID, in document: TimelineDocument) -> TimelineDocument? {
        guard let owner = owner(group: group, in: document) else { return nil }
        return changing(group: group, owner: owner, in: document, to: 0, remove: true)
    }

    private static func changing(group: UUID, owner: TimelineClip, in document: TimelineDocument,
                                 to duration: Double, remove: Bool) -> TimelineDocument {
        let delta = duration - owner.duration
        let members = document.videoTrack.filter { $0.hold == true && $0.pauseGroup == group }
        // Edge companions can sit before/after the owner's time. Their track
        // resumes after its own held frame, not after the owner's frame.
        // Everything the insertion moved started at or after the pause, or
        // after a freeze placed just before it (a clip that began within
        // `minimumPiece` before the pause).
        var starts: [Int: Double] = [:]
        for hold in members {
            starts[hold.track] = min(starts[hold.track] ?? owner.startTime, hold.startTime)
        }
        var result = document
        result.videoTrack = document.videoTrack.compactMap { clip in
            var clip = clip
            if clip.hold == true && clip.pauseGroup == group {
                if remove { return nil }
                clip.duration = duration
                if let path = clip.cameraPath { clip.cameraPath = HoldClipRules.cameraPath(path, duration: duration) }
            } else if clip.hold == true, clip.startTime <= owner.startTime,
                      owner.startTime < clip.startTime + clip.duration {
                // An older freeze on screen when the pause began: the pause's
                // own freeze follows it, and it was never moved.
            } else if clip.startTime >= (starts[clip.track] ?? owner.startTime) - 1e-9 {
                clip.startTime = max(0, clip.startTime + delta)
            }
            return clip
        }
        moveLanes(in: &result, at: owner.startTime, by: delta)
        return result
    }

    private static func pieces(_ clip: TimelineClip, at time: Double,
                               request: Request, owner: Bool) -> [TimelineClip]? {
        guard let start = clip.sourceStart, start.isFinite, start >= 0,
              clip.duration.isFinite, clip.duration > 0,
              clip.effectiveSpeed.isFinite, clip.effectiveSpeed > 0 else { return nil }
        let elapsed = time - clip.startTime
        let nearStart = elapsed < StrikeFreezeRules.minimumPiece - 1e-9
        let nearEnd = clip.duration - elapsed < StrikeFreezeRules.minimumPiece - 1e-9
        if (!owner && (clip.hold == true || nearStart || nearEnd)) || abs(elapsed) < 1e-9 {
            let before = clip.hold != true && nearStart
            // The end of the range is the first instant NOT played: hold the last frame shown.
            // The renderer selects the containing sample, including at high fps.
            let sourceTime = before || clip.hold == true ? start
                : max(start, start + clip.sourceSpan - 0.001)
            var frozen = clip
            frozen.uid = UUID()
            frozen.startTime = before ? clip.startTime : clip.startTime + clip.duration
            frozen.sourceStart = sourceTime
            frozen.sourceEnd = sourceTime
            frozen.duration = request.duration
            frozen.speed = nil
            frozen.hold = true
            frozen.slowGroup = nil
            frozen.telestration = nil
            frozen.transIn = nil
            frozen.transOut = nil
            frozen.fadeIn = 0
            frozen.fadeOut = 0
            if let path = clip.cameraPath {
                frozen.cameraPath = HoldClipRules.cameraPath(path, at: sourceTime - start, duration: request.duration)
            }
            var moving = clip
            if before { moving.startTime += request.duration }
            return before ? [frozen, moving] : [moving, frozen]
        }
        var source = clip
        // The Builder permits manual pauses in marked footage and pauses B-roll
        // along with its owner. Restore these fields after the shared splitter.
        source.strikeImpactsFrozen = nil
        source.role = .main
        // Another track's clip may be laid out a few frames past its scene's
        // end (the render stops on the last frame there). That must not make
        // the whole pause impossible: it is split over the span it plays.
        if !owner { source.sourceEnd = max(source.sourceEnd ?? 0, start + clip.duration * clip.effectiveSpeed) }
        let sourceTime = start + elapsed * clip.effectiveSpeed
        var drawing = request.drawing
        drawing?.time = sourceTime
        drawing?.offset = nil
        var result = StrikeFreezeRules.pieces(source, pauses: [
            .init(time: sourceTime, duration: request.duration, drawing: drawing)
        ])
        guard result.count == 3 else { return nil }
        for index in result.indices {
            result[index].role = clip.role
            result[index].strikeImpactsFrozen = clip.strikeImpactsFrozen
            if result[index].hold == true {
                result[index].slowGroup = nil
                if !owner { result[index].telestration = nil }
            }
        }
        return result
    }

    private static func moveLanes(in document: inout TimelineDocument, at time: Double, by delta: Double) {
        TimelineLaneMapping.pause(time: time, delta: delta).apply(to: &document)
    }
}
