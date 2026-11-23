import Foundation

/// Export's source-bed envelope, on the clock of the picture being played.
nonisolated enum DubSourceEnvelope {
    /// Replacement must happen before a bumper crossfade mixes its audio with
    /// footage. The existing segment mute flag also separates the cache key.
    static func replacesFootageBeforeAssembly(_ document: TimelineDocument) -> Bool {
        document.dub?.enabled == true && document.dub?.replaceOriginal == true
            && document.dubLines?.isEmpty == false && document.videoTrack.contains(where: \.bumper)
    }

    struct SourceRanges: Sendable, Equatable {
        var duck: [Envelope]
        /// The source is replaced everywhere except these spans.
        var replacementExclusions: [Range<Double>]
        var replace: Bool
        var level: Double
    }

    static func sourceRanges(lines: [DubLine], settings: DubSettings,
                             freezes: [Range<Double>], bumpers: [Range<Double>]) -> SourceRanges {
        SourceRanges(duck: ranges(lines: lines, freezes: freezes),
            replacementExclusions: DubFreezes.merged(bumpers), replace: settings.replaceOriginal,
            level: min(1, max(0, settings.originalLevel)))
    }

    struct Envelope: Sendable, Equatable {
        var start: Double
        var end: Double
        var attack: Double
        var release: Double
        var rise: Double
        var fall: Double

        func amount(at time: Double) -> Double {
            guard rise > 0, fall > 0 else { return time >= start && time <= end ? 1 : 0 }
            return max(0, min(1, min((time - attack) / rise, (release - time) / fall)))
        }

        var corners: [Double] {
            guard rise > 0, fall > 0 else { return [start, end] }
            let peak = min(1, (release - attack) / (rise + fall))
            return [attack, attack + rise * peak, release - fall * peak, release]
        }
    }

    struct Ramp: Sendable, Equatable {
        var start: Double
        var end: Double
        var from: Double
        var to: Double
    }

    static func ranges(lines: [DubLine], ramp: Double = 0.15,
                       freezes: [Range<Double>] = []) -> [Envelope] {
        lines.filter { $0.duration > 0 }.flatMap { line -> [Envelope] in
            let layout = DubPauseRules.layout(line, freezes: freezes)
            if layout.stopsForFreeze {
                return layout.segments.map { segment in
                    Envelope(start: segment.start, end: segment.start + segment.duration,
                        attack: segment.start - (segment.fadeIn > 0 ? 0 : ramp),
                        release: segment.start + segment.duration + (segment.fadeOut > 0 ? 0 : ramp),
                        rise: segment.fadeIn > 0 ? DubPauseRules.duckRamp : ramp,
                        fall: segment.fadeOut > 0 ? DubPauseRules.duckRamp : ramp)
                }
            }
            return [Envelope(start: line.start, end: line.start + line.duration,
                attack: line.start - ramp, release: line.start + line.duration + ramp, rise: ramp, fall: ramp)]
        }
    }

    static func bumpers(in document: TimelineDocument, clock: RenderClock = .identity) -> [Range<Double>] {
        DubFreezes.merged(document.videoTrack.filter(\.bumper).compactMap {
            let start = clock.map($0.startTime), end = clock.map($0.startTime + $0.duration, end: true)
            return end > start ? start..<end : nil
        })
    }

    /// Exact piecewise-linear maximum, including intersections of voices'
    /// attack/release ramps. Replacement has hard boundaries, never end ramps.
    static func ramps(envelopes: [Envelope], replace: Bool, level: Double,
                      bumpers: [Range<Double>], within span: Range<Double>, volume: Double) -> [Ramp] {
        guard !span.isEmpty else { return [] }
        var points = Set([span.lowerBound, span.upperBound])
        for envelope in envelopes {
            for point in envelope.corners where span.contains(point) { points.insert(point) }
        }
        for bumper in bumpers {
            for point in [bumper.lowerBound, bumper.upperBound] where span.contains(point) { points.insert(point) }
        }
        let boundaries = points.sorted()
        var result: [Ramp] = []
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where upper > lower {
            let middle = (lower + upper) / 2
            if replace && !bumpers.contains(where: { $0.contains(middle) }) {
                result.append(Ramp(start: lower, end: upper, from: 0, to: 0))
                continue
            }
            let active = envelopes.filter { $0.release > lower && $0.attack < upper }
            var cuts = [lower, upper]
            for i in active.indices {
                for j in active.indices where j > i {
                    let left = active[i].amount(at: lower) - active[j].amount(at: lower)
                    let right = active[i].amount(at: upper) - active[j].amount(at: upper)
                    if left * right < 0 { cuts.append(lower + (upper - lower) * left / (left - right)) }
                }
            }
            cuts.sort()
            func gain(_ time: Double) -> Double {
                volume * (1 - (1 - min(1, max(0, level))) * (active.map { $0.amount(at: time) }.max() ?? 0))
            }
            for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
                result.append(Ramp(start: a, end: b, from: gain(a), to: gain(b)))
            }
        }
        return result
    }
}
