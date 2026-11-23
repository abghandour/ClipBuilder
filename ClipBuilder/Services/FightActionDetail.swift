import Foundation

/// The popup uses exactly the strike and attempt units counted by the inspector.
nonisolated enum FightActionDetail {
    struct Row: Identifiable, Equatable, Sendable {
        /// The action as counted: a submission chain carries its last hold and result.
        var event: FightEventRecord
        /// The saved row behind it, which a correction is made against. It
        /// differs from `event` only for a chain of several rows.
        var stored: FightEventRecord
        var fighter: String
        var sentence: String
        var impact: String
        var id: Int64 { event.id }
        var points: Double { event.points }
        var entry: FightScoreDigest.Entry {
            .init(id: id, time: event.time, endTime: event.endTime, action: event.action,
                  targetKey: event.targetKey, outcome: event.outcome, detail: event.detail, generation: event.generation)
        }
        var loopRange: ClosedRange<Double> { entry.loopRange }
    }

    struct Fighter: Identifiable, Sendable {
        var counts: FightScoreDigest.Fighter
        var name: String
        var points: Double
        var share: Double
        var id: String { counts.key }
    }

    struct Breakdown: Identifiable, Sendable {
        var title: String
        var values: [String: Int]
        var id: String { title }
    }

    struct Model: Sendable {
        var fighters: [Fighter] = []
        var rows: [Row] = []
        var breakdowns: [String: [Breakdown]] = [:]
        var markers: [Row] { rows }
    }

    static func scoped(_ events: [FightEventRecord], round: Int?, ranges: [FightRoundRange]) -> [FightEventRecord] {
        guard let round else { return events }
        let spans = ranges.filter { $0.round == round }
        return events.filter { event in spans.contains { event.time >= $0.start && event.time < $0.end } }
    }

    static func build(events: [FightEventRecord], people: [PersonRecord], rounds: [FightRoundRange] = [],
                      round: Int? = nil, outcomes: [FightOutcome] = []) -> Model {
        // An action is the same rows whatever round is shown: units are made
        // over the whole video (as a correction and a re-score make them) and
        // then listed by where the action sits. Made per round, a blow logged
        // on both sides of a round's edge would be two rows that a correction
        // of either removes together.
        let all = events
        func inScope(_ event: FightEventRecord) -> Bool { !scoped([event], round: round, ranges: rounds).isEmpty }
        let events = scoped(events, round: round, ranges: rounds)
        let strikeUnits = StrikeStatsSummary.strikeUnits(all).filter { inScope($0.shown) }
        let attemptUnits = StrikeStatsSummary.attemptUnits(all).filter {
            ["takedown", "takedown_attempt", "submission_attempt"].contains($0.shown.action) && inScope($0.shown)
        }
        let strikes = strikeUnits.map(\.shown)
        // Totals follow the rows: a stored row counts in the round its action
        // is listed in, not the round its own stamp falls in.
        var listedIn: [Int: FightEventRecord] = [:]
        // attemptUnits wraps every row, strikes included, one to one; the
        // strike units go last so a merged blow keeps its shared row.
        for unit in StrikeStatsSummary.attemptUnits(all) + StrikeStatsSummary.strikeUnits(all) {
            for member in unit.members { listedIn[member] = unit.shown }
        }
        let counted = all.indices.filter { inScope(listedIn[$0] ?? all[$0]) }.map { all[$0] }
        func name(_ key: String) -> String {
            key.isEmpty ? "Unattributed" : people.first { $0.key == key }?.displayName ?? key
        }
        let rows = (strikeUnits + attemptUnits).sorted { ($0.shown.time, $0.shown.id) < ($1.shown.time, $1.shown.id) }.map { unit in
            let event = unit.shown
            let impact = FightScoring.actionPoints.first { $0.action == event.action }?.label ?? event.action
            let action = StrikeDetail(event.detail)?.label ?? impact.lowercased()
            let suffix = event.action.hasSuffix("_attempt")
                ? [event.detail, event.outcome].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") : ""
            return Row(event: event, stored: all[unit.stored], fighter: name(event.fighterKey),
                       sentence: name(event.fighterKey) + " " + action + (suffix.isEmpty ? "" : " · " + suffix), impact: impact)
        }
        let total = rows.reduce(0) { $0 + $1.points }
        let fighters = FightScoreDigest.fighters(events: counted, outcomes: outcomes, validationEvents: all).map { fighter in
            let points = rows.filter { $0.event.fighterKey == fighter.key }.reduce(0) { $0 + $1.points }
            return Fighter(counts: fighter, name: name(fighter.key), points: points, share: total > 0 ? points / total : 0)
        }.sorted { lhs, rhs in
            if lhs.id.isEmpty != rhs.id.isEmpty { return !lhs.id.isEmpty }
            return (lhs.points, rhs.id) > (rhs.points, lhs.id)
        }
        func table(_ values: [(String, String)]) -> [Breakdown] {
            Dictionary(grouping: values, by: { $0.0 }).map { label, rows in
                Breakdown(title: label, values: Dictionary(grouping: rows, by: { $0.1 }).mapValues(\.count))
            }.sorted { $0.title < $1.title }
        }
        var breakdowns: [String: [Breakdown]] = [
            "Technique": table(strikes.map { (StrikeDetail($0.detail)?.technique.rawValue.capitalized ?? "Unknown", $0.fighterKey) }),
            "Landed on": table(strikes.map { (StrikeDetail($0.detail)?.target?.rawValue.capitalized ?? "Unknown", $0.fighterKey) }),
            "Limb": table(strikes.map { (StrikeDetail($0.detail)?.limb?.rawValue.capitalized ?? "Unknown", $0.fighterKey) }),
        ]
        breakdowns["Impact"] = table(strikes.map { event in
            (FightScoring.actionPoints.first { $0.action == event.action }?.label ?? event.action, event.fighterKey)
        })
        breakdowns["Attempts"] = ["Takedowns", "Submissions"].flatMap { title in
            [Breakdown(title: title + " done", values: Dictionary(uniqueKeysWithValues: fighters.map {
                ($0.id, title == "Takedowns" ? $0.counts.takedowns : $0.counts.submissions)
            })), Breakdown(title: title + " attempted", values: Dictionary(uniqueKeysWithValues: fighters.map {
                ($0.id, title == "Takedowns" ? $0.counts.takedownAttempts : $0.counts.submissionAttempts)
            }))]
        }
        breakdowns["Rounds"] = table(rows.compactMap { row in
            rounds.first { row.event.time >= $0.start && row.event.time < $0.end }
                .map { ("Round \($0.round)", row.event.fighterKey) }
        })
        return Model(fighters: fighters, rows: rows, breakdowns: breakdowns)
    }

    /// The row to stay on once the list is rebuilt. The same saved row when
    /// it is still there. After the whole list was scored again the ids mean
    /// nothing (they are handed out afresh), so the same action is looked for:
    /// that fighter, that kind of action, at about that time.
    static func row(for wanted: FightEventRecord, in rows: [Row]) -> Row? {
        if let same = rows.first(where: { $0.id == wanted.id && $0.event.generation == wanted.generation }) { return same }
        guard !rows.contains(where: { $0.event.generation == wanted.generation }) else { return nil }
        let events = rows.map(\.event)
        return FightCorrections.nearest(in: events, videoID: wanted.videoID, time: wanted.time, fighter: wanted.fighterKey,
                                        action: wanted.action, detail: wanted.detail).map { rows[$0] }
    }

    static func rounds(scenes: [SceneRecord], researchJSON: String?, duration: Double) -> [FightRoundRange] {
        if let data = researchJSON?.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let story = object["story"] as? [String: Any] ?? object
            let ranges = StrikeStatsScope.parseRanges(story["rounds"] ?? story["round_boundaries"], start: 0, end: duration)
            if !ranges.isEmpty { return ranges.sorted { $0.start < $1.start } }
        }
        return StrikeStatsScope.merged(scenes.compactMap { scene in
            let numbers = Set(scene.tags.compactMap { $0.hasPrefix("round:") ? Int($0.dropFirst(6)) : nil })
            guard numbers.count == 1, let round = numbers.first, round > 0 else { return nil }
            return FightRoundRange(round: round, start: scene.startTime, end: scene.endTime)
        }).sorted { $0.start < $1.start }
    }
}
