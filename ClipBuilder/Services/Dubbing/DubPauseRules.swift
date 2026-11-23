import Foundation

/// Transient audible layout in the caller's clock (timeline or render).
nonisolated enum DubPauseRules {
    static let fade = 0.01
    static let duckRamp = 0.04

    struct Segment: Codable, Sendable, Equatable {
        var audioStart: Double
        var start: Double
        var duration: Double
        var fadeIn: Double
        var fadeOut: Double
    }

    struct Layout: Sendable, Equatable {
        var segments: [Segment]
        var end: Double
        var stopsForFreeze: Bool
    }

    static func layout(_ line: DubLine, freezes: [Range<Double>]) -> Layout {
        layout(start: line.start, duration: line.duration, freezes: freezes)
    }

    /// Intervals are normalized by DubFreezes. A freeze at the last audible
    /// instant is excluded; one at the first instant delays the whole line.
    static func layout(start: Double, duration: Double, freezes: [Range<Double>]) -> Layout {
        guard start.isFinite, duration.isFinite, duration > 0 else {
            return Layout(segments: [], end: start, stopsForFreeze: false)
        }
        var cursor = start, audio = 0.0
        var segments: [Segment] = []
        var resumed = false, stopped = false
        for freeze in freezes {
            guard freeze.upperBound > cursor else { continue }
            let remaining = duration - audio
            guard freeze.lowerBound < cursor + remaining else { break }
            let length = max(0, freeze.lowerBound - cursor)
            if length > 0 {
                segments.append(Segment(audioStart: audio, start: cursor, duration: length,
                    fadeIn: resumed ? min(fade, length / 2) : 0, fadeOut: min(fade, length / 2)))
                audio += length
            }
            cursor = freeze.upperBound
            resumed = true
            stopped = true
        }
        let remaining = duration - audio
        segments.append(Segment(audioStart: audio, start: cursor, duration: remaining,
            fadeIn: resumed ? min(fade, remaining / 2) : 0, fadeOut: 0))
        return Layout(segments: segments, end: cursor + remaining, stopsForFreeze: stopped)
    }

    struct CacheLine: Encodable, Sendable {
        var id: UUID
        var segments: [Segment]
    }

    /// Nil contributes no JSON key, retaining the pre-freeze cache identity.
    static func cacheSegments(lines: [DubLine], freezes: [Range<Double>]) -> [CacheLine]? {
        let changed = lines.compactMap { line -> CacheLine? in
            let layout = Self.layout(line, freezes: freezes)
            return layout.stopsForFreeze ? CacheLine(id: line.id, segments: layout.segments) : nil
        }
        return changed.isEmpty ? nil : changed
    }
}
