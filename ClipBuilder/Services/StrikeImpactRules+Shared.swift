import Foundation

nonisolated extension StrikeImpactRules {
    struct SharedSlowing: Sendable {
        var tracks: [[TimelineClip]]
        /// Pre-slow screen clock, including already inserted holds.
        var stretches: [Stretch]
        var skipped: Int
    }

    static func mapped(_ time: Double, through stretches: [Stretch]) -> Double {
        time + stretches.reduce(0) { $0 + $1.addedTime(at: time) }
    }

    static func inverse(_ stretches: [Stretch]) -> [Stretch] {
        stretches.map {
            Stretch(start: mapped($0.start, through: stretches),
                    end: mapped($0.end, through: stretches), factor: 1 / $0.factor)
        }
    }

    static func sharedSlowing(_ tracks: [[TimelineClip]], contacts: [Double], strength: Strength) -> SharedSlowing? {
        guard let main = tracks.first, !main.isEmpty else { return nil }
        // Keep the established 7a splitter and its arithmetic for one source
        // split into moving pieces/holds. Repeated source ranges in a Builder
        // track need the screen-clock path so a later showing is not slowed too.
        let moving = main.filter { $0.hold != true && !$0.bumper && !$0.isCutaway }
        let unambiguous = zip(main, main.dropFirst()).allSatisfy {
            $0.startTime + $0.duration <= $1.startTime + 1e-9
        } && zip(moving, moving.dropFirst()).allSatisfy {
            ($0.sourceStart ?? 0) + $0.sourceSpan <= ($1.sourceStart ?? 0) + 1e-9
        }
        if tracks.count == 1, unambiguous {
            let sources = contacts.compactMap { time -> Double? in
                guard let clip = main.first(where: {
                    $0.hold != true && time > $0.startTime && time <= $0.startTime + $0.duration
                }), let start = clip.sourceStart else { return nil }
                return start + (time - clip.startTime) * clip.effectiveSpeed
            }
            let result = slowing(main, contacts: sources, strength: strength)
            let stretches = result.stretches.compactMap { stretch -> Stretch? in
                guard let clip = main.first(where: {
                    guard let start = $0.sourceStart else { return false }
                    return $0.hold != true && stretch.start >= start - 1e-9
                        && stretch.end <= start + $0.sourceSpan + 1e-9
                }), let start = clip.sourceStart else { return nil }
                return Stretch(start: clip.startTime + (stretch.start - start) / clip.effectiveSpeed,
                               end: clip.startTime + (stretch.end - start) / clip.effectiveSpeed,
                               factor: stretch.factor)
            }
            return SharedSlowing(tracks: [result.pieces], stretches: stretches, skipped: result.skipped)
        }
        var stretches: [Stretch] = []
        var skipped = 0
        for contact in contacts.filter(\.isFinite).sorted() {
            // The picture immediately BEFORE contact supplies the lead. A hold
            // starting at contact is allowed; a hold in the lead is never slowed.
            let covering = tracks.map { track in
                track.filter { $0.startTime < contact && contact <= $0.startTime + $0.duration + 1e-9 }
            }
            guard covering.allSatisfy({ $0.count == 1 }), let owner = covering.first?.first else {
                skipped += 1
                continue
            }
            // Every boundary matters, including an overlapping picture that
            // finishes before contact. No stretch crosses a start, end or hold.
            let boundaries = tracks.flatMap { $0 }.flatMap { [$0.startTime, $0.startTime + $0.duration] }
                .filter { $0 < contact - 1e-9 }
            let lower = max(contact - strength.lead / owner.effectiveSpeed, boundaries.max() ?? contact)
            let clips = tracks.flatMap { $0 }.filter {
                $0.startTime < contact - 1e-9 && $0.startTime + $0.duration > lower + 1e-9
            }
            guard lower.isFinite, contact > lower,
                  lower >= (stretches.last?.end ?? -.infinity) - 1e-9,
                  clips.allSatisfy({ clip in
                      guard clip.hold != true, !clip.bumper, !clip.isCutaway,
                            let start = clip.sourceStart, start.isFinite,
                            clip.effectiveSpeed.isFinite, clip.effectiveSpeed * strength.factor >= minimumSpeed else { return false }
                      // Earlier kept windows also split this piece.
                      let cursor = max(clip.startTime, stretches.last?.end ?? clip.startTime)
                      let head = lower - cursor, tail = clip.startTime + clip.duration - contact
                      return (head <= 1e-9 || head >= StrikeFreezeRules.minimumPiece - 1e-9)
                          && (tail <= 1e-9 || tail >= StrikeFreezeRules.minimumPiece - 1e-9)
                          && (contact - lower) / strength.factor >= StrikeFreezeRules.minimumPiece - 1e-9
                  }) else {
                skipped += 1
                continue
            }
            stretches.append(.init(start: lower, end: contact, factor: strength.factor))
        }
        return SharedSlowing(tracks: applying(stretches, to: tracks), stretches: stretches, skipped: skipped)
    }

    static func applying(_ stretches: [Stretch], to tracks: [[TimelineClip]]) -> [[TimelineClip]] {
        tracks.map { track in
            track.flatMap { clip -> [TimelineClip] in
                let windows = stretches.filter { $0.start < clip.startTime + clip.duration - 1e-9 && $0.end > clip.startTime + 1e-9 }
                guard !windows.isEmpty, let start = clip.sourceStart else {
                    var moved = clip
                    moved.startTime = mapped(clip.startTime, through: stretches)
                    return [moved]
                }
                let end = clip.startTime + clip.duration
                let edges = Set([clip.startTime] + windows.flatMap {
                    [max(clip.startTime, $0.start), min(end, $0.end)]
                } + [end]).sorted()
                return zip(edges, edges.dropFirst()).compactMap { lower, upper in
                    guard upper - lower > 1e-9 else { return nil }
                    var part = slice(clip, from: start + (lower - clip.startTime) * clip.effectiveSpeed,
                                     to: start + (upper - clip.startTime) * clip.effectiveSpeed)
                    let factor = windows.first { lower >= $0.start - 1e-9 && upper <= $0.end + 1e-9 }?.factor ?? 1
                    part.startTime = mapped(lower, through: stretches)
                    part.speed = clip.effectiveSpeed * factor
                    part.duration = (upper - lower) / factor
                    return part
                }
            }
        }
    }
}
