import Foundation

/// Impact presentation on one picture. All boundaries are source seconds;
/// durations and placement are screen seconds, including any existing holds.
nonisolated enum StrikeImpactRules {
    /// A saved strength this version does not know plays as medium; empty is off.
    static func strength(saved raw: String) -> String? {
        raw.isEmpty ? nil : (Strength(rawValue: raw) ?? .medium).rawValue
    }

    enum Strength: String, Codable, CaseIterable, Sendable {
        case subtle, medium, strong

        var lead: Double { self == .strong ? 0.6 : 0.5 }
        var factor: Double {
            switch self {
            case .subtle: 0.6
            case .medium: 0.4
            case .strong: 0.25
            }
        }
        var label: String {
            switch self {
            case .subtle: "Subtle"
            case .medium: "Medium"
            case .strong: "Strong"
            }
        }
    }

    static let flashDuration = 0.12
    static let minimumSpeed = 0.25

    struct Stretch: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var factor: Double

        var addedDuration: Double { (end - start) * (1 / factor - 1) }
        func addedTime(at time: Double) -> Double {
            max(0, min(end - start, time - start)) * (1 / factor - 1)
        }
    }

    struct Slowing: Sendable {
        var pieces: [TimelineClip]
        /// Source-clock intervals; the reel converts these to its planned clock.
        var stretches: [Stretch] = []
        var skipped = 0
    }

    static func slowed(_ pieces: [TimelineClip], contacts: [Double], strength: Strength) -> [TimelineClip] {
        slowing(pieces, contacts: contacts, strength: strength).pieces
    }

    static func slowing(_ pieces: [TimelineClip], contacts: [Double], strength: Strength) -> Slowing {
        var result = Slowing(pieces: [])
        var added = 0.0
        var previousContact = -Double.infinity
        for piece in pieces {
            guard piece.hold != true, !piece.bumper, !piece.isCutaway,
                  let start = piece.sourceStart, start.isFinite, piece.duration.isFinite,
                  piece.effectiveSpeed.isFinite, piece.effectiveSpeed > 0 else {
                var moved = piece
                moved.startTime += added
                result.pieces.append(moved)
                continue
            }
            let speed = piece.effectiveSpeed
            let end = start + piece.sourceSpan
            var cursor = start
            var intervals: [(start: Double, end: Double, speed: Double)] = []
            for contact in contacts.filter({ $0.isFinite && $0 > start && $0 <= end }).sorted() {
                let lower = max(start, contact - strength.lead)
                let newSpeed = speed * strength.factor
                let head = (lower - cursor) / speed
                let tail = (end - contact) / speed
                guard newSpeed >= minimumSpeed,
                      lower >= previousContact - 1e-9, lower >= cursor - 1e-9,
                      head <= 1e-9 || head >= StrikeFreezeRules.minimumPiece - 1e-9,
                      tail <= 1e-9 || tail >= StrikeFreezeRules.minimumPiece - 1e-9,
                      (contact - lower) / newSpeed >= StrikeFreezeRules.minimumPiece - 1e-9 else {
                    result.skipped += 1
                    continue
                }
                if lower > cursor + 1e-9 { intervals.append((cursor, lower, speed)) }
                intervals.append((lower, contact, newSpeed))
                result.stretches.append(Stretch(start: lower, end: contact, factor: strength.factor))
                cursor = contact
                previousContact = contact
            }
            guard !intervals.isEmpty else {
                var moved = piece
                moved.startTime += added
                result.pieces.append(moved)
                continue
            }
            if cursor < end - 1e-9 { intervals.append((cursor, end, speed)) }
            var screen = piece.startTime + added
            for interval in intervals {
                var part = slice(piece, from: interval.start, to: interval.end)
                part.speed = interval.speed
                part.duration = (interval.end - interval.start) / interval.speed
                part.startTime = screen
                result.pieces.append(part)
                screen += part.duration
            }
            added += screen - (piece.startTime + added + piece.duration)
        }
        return result
    }

    static func flashed(_ pieces: [TimelineClip], contacts: [Double]) -> [TimelineClip] {
        var result = pieces
        for contact in Set(contacts.filter(\.isFinite)).sorted() {
            // A hold and its following motion share a source start. Flash only
            // the first showing, so resuming after the hold never flashes twice.
            if let index = result.firstIndex(where: {
                !$0.bumper && !$0.isCutaway && abs(($0.sourceStart ?? -.infinity) - contact) < 1e-9
            }) {
                result[index].flashIn = flashDuration
                continue
            }
            guard let index = result.firstIndex(where: {
                guard let start = $0.sourceStart else { return false }
                return !$0.bumper && !$0.isCutaway && $0.hold != true
                    && contact > start && contact < start + $0.sourceSpan
            }), let start = result[index].sourceStart else { continue }
            let piece = result[index]
            let at = piece.startTime + (contact - start) / piece.effectiveSpeed
            guard var split = TimelineSplit.pieces(piece, at: at, minimum: StrikeFreezeRules.minimumPiece) else { continue }
            split.head.slowLineage = piece.slowLineage ?? piece.uid
            split.tail.slowLineage = split.head.slowLineage
            split.tail.stayCut = false
            split.tail.flashIn = flashDuration
            result.replaceSubrange(index...index, with: [split.head, split.tail])
        }
        return result
    }

    /// Same source-relative camera slicing as TimelineSplit, with the minimum
    /// checked on the new speed's screen clock by the caller.
    static func slice(_ clip: TimelineClip, from start: Double, to end: Double) -> TimelineClip {
        var piece = clip
        piece.slowLineage = clip.slowLineage ?? clip.uid
        let offset = start - (clip.sourceStart ?? start)
        piece.sourceStart = start
        piece.sourceEnd = end
        if offset > 1e-9 {
            piece.stayCut = false
            piece.uid = UUID()
            piece.transIn = nil
            piece.fadeIn = 0
            piece.flashIn = nil
        }
        if end < (clip.sourceStart ?? start) + clip.sourceSpan - 1e-9 {
            piece.transOut = nil
            piece.fadeOut = 0
        }
        if let path = clip.cameraPath, path.count >= 2 {
            let sliced = CenterStageService.slice(path, from: offset, duration: end - start)
            piece.cameraPath = sliced.count >= 2 ? sliced : nil
        }
        return piece
    }
}
