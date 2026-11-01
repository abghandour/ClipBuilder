import Foundation

/// Names audio clusters without letting one portrait claim several voices.
nonisolated enum SpeakerClusterNaming {
    struct Summary: Sendable, Equatable {
        var clusters: Int
        /// Clusters with a person on at least one turn.
        var namedClusters: Int = 0
        var namedKeys: Set<String>
        var rosterKeys: Set<String>
        var layout: PodcastLayout?

        /// Only signatures the current resolver never produces, so a re-map
        /// clears the flag instead of offering the same work again: every
        /// cluster named yet one person (the old single-camera fallback), a
        /// name outside the roster, or a single-camera map with one roster
        /// person and no name at all. With several people and no names the
        /// evidence was a tie (two faces visible the whole time) and a re-map
        /// returns the same unnamed map, so that is not flagged.
        var verdict: Verdict {
            var reasons: [String] = []
            if clusters >= 2, namedClusters == clusters, namedKeys.count == 1 {
                reasons.append("Several voice clusters share only one named speaker.")
            }
            if !namedKeys.isSubset(of: rosterKeys) {
                reasons.append("A named speaker is no longer in the video's roster.")
            }
            if clusters >= 1, namedClusters == 0, rosterKeys.count == 1, layout == .singleCamera {
                reasons.append("The voices have not been matched to the person in this video yet.")
            }
            return Verdict(reasons: reasons)
        }
    }

    struct Verdict: Sendable, Equatable {
        var reasons: [String]
        var isSuspicious: Bool { !reasons.isEmpty }
        var reason: String { reasons.joined(separator: " ") }
    }

    static func needsRemap(namedKeys: Set<String>, rosterBefore: Set<String>,
                           rosterAfter: Set<String>, verdict: Verdict) -> Bool {
        rosterBefore != rosterAfter || !namedKeys.isSubset(of: rosterAfter) || verdict.isSuspicious
    }

    /// The roster person each frame side shows, by portrait box.
    static func personBySide(roster: [VideoPersonRecord]) -> [PodcastSpeakerSide: String] {
        var personBySide: [PodcastSpeakerSide: String] = [:]
        for person in roster {
            guard let box = person.portraitBox else { continue }
            let side: PodcastSpeakerSide = box.x + box.w / 2 < 0.5 ? .left : .right
            if personBySide[side] == nil { personBySide[side] = person.key }
        }
        return personBySide
    }

    /// Turns the face tracker left unnamed (no tile matched a portrait) get
    /// the cluster rules over the people no named tile already took. Named
    /// turns keep their names.
    static func filling(_ turns: [SpeakerTurn], roster: [VideoPersonRecord], layout: PodcastLayout) -> [SpeakerTurn] {
        guard layout != .grid else { return turns }
        let taken = Set(turns.compactMap(\.personKey))
        let namedClusters = Set(turns.filter { $0.personKey != nil }.map(\.cluster))
        let unnamed = turns.filter { !namedClusters.contains($0.cluster) }
        let people = roster.filter { !taken.contains($0.key) }
        guard !unnamed.isEmpty, !people.isEmpty else { return turns }
        let names = assign(turns: unnamed, roster: people, layout: layout,
                           clusterSides: [:], personBySide: personBySide(roster: people))
        guard !names.isEmpty else { return turns }
        return turns.map { turn in
            guard turn.personKey == nil, let key = names[turn.cluster] else { return turn }
            var turn = turn
            turn.personKey = key
            return turn
        }
    }

    static func assign(turns: [SpeakerTurn], roster: [VideoPersonRecord], layout: PodcastLayout,
                       clusterSides: [Int: PodcastSpeakerSide],
                       personBySide: [PodcastSpeakerSide: String]) -> [Int: String] {
        guard layout != .grid else { return [:] }
        let grouped = Dictionary(grouping: turns, by: \.cluster)
        let durations = grouped.mapValues { $0.reduce(0) { $0 + max(0, $1.end - $1.start) } }
        var assigned: [Int: String] = [:]
        if layout == .singleCamera {
            // The only person in the video is the dominant voice; with two
            // voices of exactly equal length the one with more turns, then
            // the first cluster, so a one-person roster always gets a name.
            let dominant = roster.count == 1
                ? grouped.keys.sorted {
                    durations[$0] != durations[$1] ? durations[$0, default: 0] > durations[$1, default: 0]
                        : grouped[$0]!.count != grouped[$1]!.count ? grouped[$0]!.count > grouped[$1]!.count : $0 < $1
                }.first
                : uniqueBest(durations)
            guard let dominant else { return [:] }
            let coverage = Dictionary(roster.map { ($0.key, duration(merged($0.ranges))) },
                                      uniquingKeysWith: max)
            let longest = roster.count == 1 ? roster.first?.key : uniqueBest(coverage)
            guard let longest else { return [:] }
            assigned[dominant] = longest
            // Larger clusters get first choice; equally strong evidence never
            // gets a name merely because of dictionary or roster ordering.
            let remaining = durations.keys.filter { $0 != dominant }.sorted {
                durations[$0] == durations[$1] ? $0 < $1 : durations[$0, default: 0] > durations[$1, default: 0]
            }
            for cluster in remaining {
                let speech = merged((grouped[cluster] ?? []).compactMap {
                    $0.end > $0.start ? $0.start...$0.end : nil
                })
                var overlaps: [String: Double] = [:]
                for person in roster where !assigned.values.contains(person.key) {
                    overlaps[person.key] = speech.reduce(0) { total, turn in
                        total + merged(person.ranges).reduce(0) {
                            $0 + max(0, min(turn.upperBound, $1.upperBound) - max(turn.lowerBound, $1.lowerBound))
                        }
                    }
                }
                if let key = uniqueBest(overlaps) { assigned[cluster] = key }
            }
        } else {
            // Weight only the turns resolved to this side, not all the speech
            // from a cluster that happens to visit it briefly.
            var sideWeights: [Int: [PodcastSpeakerSide: Double]] = [:]
            for turn in turns {
                let side = turn.resolvedSide == .unknown ? (clusterSides[turn.cluster] ?? .unknown) : turn.resolvedSide
                guard side != .unknown else { continue }
                sideWeights[turn.cluster, default: [:]][side, default: 0] += max(0, turn.end - turn.start)
                    * max(turn.confidence, turn.pictureConfidence)
            }
            let preferredSides = sideWeights.compactMapValues { uniqueBest($0) }
            for side in [PodcastSpeakerSide.left, .right, .full] {
                guard let person = personBySide[side], !assigned.values.contains(person) else { continue }
                var weights: [Int: Double] = [:]
                for (cluster, preferred) in preferredSides where preferred == side {
                    weights[cluster] = sideWeights[cluster]?[side]
                }
                if let cluster = uniqueBest(weights) { assigned[cluster] = person }
            }
        }
        return assigned
    }

    private static func uniqueBest<Key>(_ weights: [Key: Double]) -> Key? {
        guard let best = weights.values.max(), best > 0 else { return nil }
        let winners = weights.filter { abs($0.value - best) < 0.000_001 }
        return winners.count == 1 ? winners.first?.key : nil
    }

    private static func duration(_ ranges: [ClosedRange<Double>]) -> Double {
        ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    private static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
