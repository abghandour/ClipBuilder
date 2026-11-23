import Foundation

/// The editor's real-time clock for one drawing: what the picture shows and
/// how far the animation is at each second of a preview or a voice recording.
/// The picture plays up to the drawing's moment, pauses or slows under the
/// figures for the drawing's length, then plays on.
nonisolated enum TelestrationPlayback {
    nonisolated struct Moment: Equatable, Sendable {
        /// Source seconds of the picture on screen.
        var source: Double
        /// The picture's speed: 0 while it is paused.
        var rate: Double
        /// Seconds into the drawing's animation; nil before it starts and after it ends.
        var drawing: Double?
        /// Seconds since the drawing ended, while figures may still stay.
        var linger: Double?
    }

    nonisolated struct Plan: Equatable, Sendable {
        /// Source seconds where playback starts.
        var start: Double
        /// The drawing's moment.
        var time: Double
        /// Seconds of the drawing's animation.
        var drawn: Double
        /// The picture's speed under the drawing; 0 is a pause.
        var rate: Double
        /// Seconds the picture plays on after the drawing.
        var tail: Double

        var lead: Double { max(0, time - start) }
        /// Source seconds where the picture is when the drawing ends.
        var resume: Double { time + drawn * rate }
        var total: Double { lead + drawn + tail }
        /// False when a still frame is all that is ever shown.
        var movesPicture: Bool { lead > 0 || rate > 0 || tail > 0 }
        /// The seconds at which the picture changes speed, in order.
        var boundaries: [Double] { [lead, lead + drawn].filter { $0 > 0 && $0 < total } }

        func moment(at elapsed: Double) -> Moment {
            let elapsed = elapsed.isFinite ? min(total, max(0, elapsed)) : 0
            if elapsed < lead { return Moment(source: start + elapsed, rate: 1) }
            let local = elapsed - lead
            if local < drawn { return Moment(source: time + local * rate, rate: rate, drawing: local) }
            return Moment(source: resume + (local - drawn), rate: tail > 0 ? 1 : 0, linger: local - drawn)
        }
    }

    /// Source seconds a drawing may use after its moment. `end` is the last
    /// source second of the clip (or of the file when no clip is known).
    static func room(after time: Double, end: Double) -> Double {
        max(0, end - StrikeFreezeRules.minimumPiece - time)
    }

    /// The drawing's own speed, lowered to nothing when the footage after
    /// its moment is too short to run under it.
    static func rate(of drawing: Telestration, end: Double) -> Double {
        guard let motion = drawing.motion, drawing.sourceSpan <= room(after: drawing.time, end: end) + 1e-9 else { return 0 }
        return motion
    }

    /// Play in the editor: the drawing alone, then the picture moving on for
    /// as long as a figure stays.
    static func preview(_ drawing: Telestration, end: Double) -> Plan {
        let rate = rate(of: drawing, end: end)
        let resume = drawing.time + drawing.duration * rate
        return Plan(start: drawing.time, time: drawing.time, drawn: drawing.duration, rate: rate,
                    tail: min(TelestrationRules.lingerDuration(of: drawing), max(0, end - resume)))
    }

    /// Record voice over: the whole clip in real time, with the drawing in it.
    static func clip(_ drawing: Telestration, range: ClosedRange<Double>) -> Plan {
        let time = min(range.upperBound, max(range.lowerBound, drawing.time))
        let rate = rate(of: drawing, end: range.upperBound)
        return Plan(start: range.lowerBound, time: time, drawn: drawing.duration, rate: rate,
                    tail: max(0, range.upperBound - (time + drawing.duration * rate)))
    }

    static func state(of drawing: Telestration, at moment: Moment) -> TelestrationRules.State {
        if let elapsed = moment.drawing { return TelestrationRules.state(of: drawing, at: elapsed) }
        if let elapsed = moment.linger { return TelestrationRules.lingerState(of: drawing, at: elapsed) }
        return TelestrationRules.State(figures: [], opacity: 0)
    }

    /// "Paused", "25%", "Normal speed": the picture under a drawing.
    static func label(_ motion: Double?) -> String {
        guard let motion else { return "Paused" }
        return motion >= 1 ? "Normal speed" : "\(Int((motion * 100).rounded()))%"
    }
}
