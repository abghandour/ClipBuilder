import Foundation

/// Speech edits keep word boundaries; the default retains the UI's grid.
nonisolated enum TimelinePrecision: String, Codable, Sendable, CaseIterable {
    case ordinary, speech

    var minimumDuration: Double { self == .speech ? 0.05 : 0.5 }
    func rounded(_ time: Double) -> Double {
        let scale = self == .speech ? 1000.0 : 2.0
        return (time * scale).rounded() / scale
    }
}

/// Store validation failures are shared by UI-optional results and scripts.
nonisolated enum ClipEditFailure: String, Error, Sendable {
    case outOfBounds = "out_of_bounds"
    case tooShort = "too_short"
    case notFound = "not_found"
    case bumper

    var reason: String {
        switch self {
        case .outOfBounds: "Time or source bounds are invalid or unavailable."
        case .tooShort: "The edit leaves a piece below the precision minimum."
        case .notFound: "Clip is missing or outside this session."
        case .bumper: "This edit does not support bumpers."
        }
    }
}

nonisolated struct ClipSplitResult: Codable, Sendable, Equatable {
    var head: UUID
    var tail: UUID
    var at: Double
    var sourceStart: Double
    var sourceCut: Double
    var sourceEnd: Double
}

/// Shared math has no undo, notifications or packing, so a pause can place
/// its tail after an obstacle while a standalone cut opens no gap.
nonisolated enum TimelineSplit {
    /// Install the two pieces by value, leaving layout and notifications to
    /// the caller. Failure leaves the entire document untouched.
    static func split(in document: inout TimelineDocument, uid: UUID, at time: Double,
                      precision: TimelinePrecision = .ordinary) -> ClipSplitResult? {
        guard time.isFinite, let index = document.videoTrack.firstIndex(where: { $0.uid == uid }),
              let pieces = pieces(document.videoTrack[index], at: precision.rounded(time),
                                  minimum: precision.minimumDuration),
              let start = pieces.head.sourceStart, let cut = pieces.tail.sourceStart,
              let end = pieces.tail.sourceEnd else { return nil }
        var head = pieces.head
        var tail = pieces.tail
        if precision == .speech { head.precision = .speech; tail.precision = .speech }
        document.videoTrack[index] = head
        document.videoTrack.insert(tail, at: index + 1)
        return ClipSplitResult(head: pieces.head.uid, tail: pieces.tail.uid,
                               at: pieces.tail.startTime, sourceStart: start, sourceCut: cut, sourceEnd: end)
    }

    static func pieces(_ clip: TimelineClip, at: Double, minimum: Double = 0.05, ceiling: Double? = nil)
        -> (head: TimelineClip, tail: TimelineClip)? {
        guard !clip.bumper, at.isFinite, clip.startTime.isFinite, clip.duration.isFinite,
              let sourceStart = clip.sourceStart, sourceStart.isFinite,
              let sourceEnd = ceiling ?? clip.sourceEnd, sourceEnd.isFinite,
              clip.effectiveSpeed.isFinite, clip.effectiveSpeed > 0 else { return nil }
        let headDuration = at - clip.startTime
        let tailDuration = clip.duration - headDuration
        let playedEnd = sourceStart + clip.duration * clip.effectiveSpeed
        guard headDuration >= minimum - 1e-9, tailDuration >= minimum - 1e-9,
              sourceStart >= 0, playedEnd <= sourceEnd + 1e-9 else { return nil }
        let cut = sourceStart + headDuration * clip.effectiveSpeed
        var head = clip
        var tail = clip
        head.duration = headDuration
        head.sourceEnd = cut
        head.transOut = nil
        head.fadeOut = 0
        tail.uid = UUID()
        tail.startTime = at
        tail.sourceStart = cut
        tail.sourceEnd = playedEnd
        tail.duration = tailDuration
        tail.transIn = nil
        tail.fadeIn = 0
        return (head, tail)
    }
}
