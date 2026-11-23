/// Ordered degradation for the segment encode. Each retry retains earlier omissions.
nonisolated enum SegmentEncodeFallback {
    struct Attempt: Equatable, Sendable {
        var drawings: Bool
        var captions: Bool
    }

    static func attempts(drawings: Bool, captions: Bool) -> [Attempt] {
        var result = [Attempt(drawings: drawings, captions: captions)]
        if drawings { result.append(Attempt(drawings: false, captions: captions)) }
        if captions { result.append(Attempt(drawings: false, captions: false)) }
        return result
    }
}
