import Foundation

nonisolated enum AttemptKind: String, Codable, CaseIterable, Sendable {
    case takedown, submission
    var action: String { self == .takedown ? "takedown_attempt" : "submission_attempt" }
    var label: String { self == .takedown ? "Takedowns" : "Submissions" }
}

nonisolated enum SubmissionHold: String, Codable, CaseIterable, Sendable {
    case rearNakedChoke = "rear-naked choke", guillotine, armTriangle = "arm triangle", triangle
    case darceAnaconda = "D'Arce/anaconda", armbar, kimura, americana
    case heelHook = "heel hook", kneebar, ankleLock = "ankle lock"
    case otherChoke = "other choke", otherLock = "other lock", unknown

    var group: String {
        switch self {
        case .rearNakedChoke, .guillotine, .armTriangle, .triangle, .darceAnaconda, .otherChoke: "chokes"
        default: rawValue
        }
    }
}

nonisolated enum StrikeStatsSummary {
    struct Pair: Equatable, Sendable {
        var kind: AttemptKind
        var attacker: String
        var defender: String
        var completed = 0
        var defended = 0
        var unresolved = 0
        var legacy = 0
        var holds: [String: Int] = [:]
        var outcomeCheck = false
        var resolved: Int { completed + defended }
        var attempts: Int { resolved + unresolved + legacy }
        var success: Double? { resolved >= 2 ? Double(completed) / Double(resolved) : nil }
        var defense: Double? { success.map { 1 - $0 } }
    }

    static let strikeFamily: Set<String> = ["strike", "significant_strike", "hurt", "knockdown", "ground_strike"]

    /// Legacy clusters span at most 0.4 s from their first timestamp. Dense
    /// scoring (v3 onward) keeps distinct contacts, merging only repeats or
    /// severity upgrades of the same named blow under 0.2 s from that anchor.
    static func deduplicatedStrikes(_ events: [FightEventRecord]) -> [FightEventRecord] {
        strikeUnits(events).map(\.shown)
    }

    /// One counted action and the stored rows it stands for, as indices into
    /// the list it was built from. `shown` carries the id of the row at `stored`.
    struct Unit: Sendable {
        var shown: FightEventRecord
        var stored: Int
        var members: [Int]
    }

    static func strikeUnits(_ events: [FightEventRecord]) -> [Unit] {
        let groups = Dictionary(grouping: events.indices.filter { strikeFamily.contains(events[$0].action) }) {
            "\(events[$0].videoID)|\(events[$0].fighterKey)"
        }
        return groups.values.flatMap { rows -> [Unit] in
            var result: [Unit] = []
            var anchor = -Double.infinity
            for index in rows.sorted(by: { events[$0].time < events[$1].time }) {
                let row = events[index]
                if row.time - anchor <= 0.4, let last = result.last, sameBlow(row, last.shown, anchor: anchor) {
                    result[result.count - 1].members.append(index)
                    if row.points > last.shown.points {
                        result[result.count - 1].shown = row
                        result[result.count - 1].stored = index
                    }
                } else {
                    anchor = row.time
                    result.append(Unit(shown: row, stored: index, members: [index]))
                }
            }
            return result
        }.sorted { $0.shown.time < $1.shown.time }
    }

    private static func sameBlow(_ first: FightEventRecord, _ second: FightEventRecord, anchor: Double) -> Bool {
        if (first.scoringVersion ?? 1) >= 3 || (second.scoringVersion ?? 1) >= 3 {
            guard first.time < anchor + 0.2,
                  let a = StrikeDetail(first.detail), let b = StrikeDetail(second.detail),
                  a.technique == b.technique, let limb = a.limb, limb == b.limb else { return false }
            let repeated = first.action == second.action && first.points == second.points
                && first.detail == second.detail && first.targetKey == second.targetKey
            let upgraded = second.action == "strike" && first.action == "significant_strike"
            // Equal stamps have no chronological order; keep the upgrade
            // even when it appeared first in the input.
            let sameStamp = first.time == second.time
                && second.action == "significant_strike" && first.action == "strike"
            return repeated || upgraded || sameStamp
        }
        guard let a = StrikeDetail(first.detail), let b = StrikeDetail(second.detail) else { return true }
        if a.technique != b.technique { return false }
        if let left = a.limb, let right = b.limb, left != right { return false }
        return true
    }

    /// Overlapping holds and a continuing chain through a short transition are
    /// one sequence, carrying the final hold and resolution. Legacy instants stay intact.
    static func attemptSequences(_ events: [FightEventRecord]) -> [FightEventRecord] {
        attemptUnits(events).map(\.shown)
    }

    /// Every event as a unit; a submission chain is one unit of several rows.
    static func attemptUnits(_ events: [FightEventRecord]) -> [Unit] {
        var result: [Unit] = []
        for position in events.indices.sorted(by: { events[$0].time < events[$1].time }) {
            let row = events[position]
            if row.action == "submission_attempt", (row.scoringVersion ?? 1) >= 2,
               let index = result.lastIndex(where: {
                   $0.shown.videoID == row.videoID && $0.shown.action == row.action && $0.shown.fighterKey == row.fighterKey
                       && $0.shown.targetKey == row.targetKey && ($0.shown.scoringVersion ?? 1) >= 2
               }), let end = result[index].shown.endTime, row.time <= end + 3,
               result[index].shown.outcome != "completed" {
                result[index].members.append(position)
                if (row.endTime ?? row.time) >= end {
                    result[index].shown.endTime = row.endTime
                    result[index].shown.outcome = row.outcome
                    result[index].shown.detail = row.detail
                }
            } else {
                result.append(Unit(shown: row, stored: position, members: [position]))
            }
        }
        return result
    }

    static func pairs(events: [FightEventRecord], outcomes: [FightOutcome] = [],
                      validationEvents: [FightEventRecord]? = nil) -> [Pair] {
        let sequences = attemptSequences(events)
        let finishes = (validationEvents.map(attemptSequences) ?? sequences).filter { $0.action == "submission_attempt" && $0.outcome == "completed" }
        var pairs: [Pair] = []
        for row in sequences {
            guard let kind = AttemptKind.allCases.first(where: { row.action == $0.action || ($0 == .takedown && row.action == "takedown") }) else { continue }
            let target = row.targetKey ?? ""
            let index: Int
            if let existing = pairs.firstIndex(where: { $0.kind == kind && $0.attacker == row.fighterKey && $0.defender == target }) {
                index = existing
            } else {
                index = pairs.count
                pairs.append(Pair(kind: kind, attacker: row.fighterKey, defender: target))
            }
            // An old row says nothing about how the attempt ended. Once it
            // carries a result (the reviewer gave it one), it counts by it.
            if row.action == "takedown" || ((row.scoringVersion ?? 1) < 2 && row.outcome == nil) {
                pairs[index].legacy += 1
                continue
            }
            if kind == .submission {
                let hold = SubmissionHold(rawValue: row.detail ?? "") ?? .unknown
                pairs[index].holds[hold.group, default: 0] += 1
            }
            let fightOutcome = outcomes.filter { $0.videoID == row.videoID }.max {
                ($0.runID, $0.id) < ($1.runID, $1.id)
            }
            let matchesOutcome = fightOutcome.map {
                $0.method.lowercased() == "submission"
                    && ($0.winnerKey == nil || $0.winnerKey == row.fighterKey)
                    && ($0.loserKey == nil || $0.loserKey == row.targetKey)
            } ?? false
            let invalidFinish = kind == .submission && row.outcome == "completed" &&
                (finishes.count(where: { $0.videoID == row.videoID }) != 1 || !matchesOutcome)
            if invalidFinish {
                pairs[index].outcomeCheck = true
                pairs[index].unresolved += 1
            } else {
                switch row.outcome {
                case "completed": pairs[index].completed += 1
                case "defended": pairs[index].defended += 1
                default: pairs[index].unresolved += 1
                }
            }
        }
        return pairs
    }

    /// Only reconcile a shot still unresolved at the end of the immediately
    /// preceding scoring window. Attempts within a window remain independent.
    static func takedownContinuations(_ windows: [(range: FightSampling.Range, events: [FightEventRecord])]) -> [FightEventRecord] {
        var result: [FightEventRecord] = []
        var previous: FightSampling.Range?
        var previousIndices: [Int] = []
        for window in windows.sorted(by: { $0.range.start < $1.range.start }) {
            var indices: [Int] = []
            var used: Set<Int> = []
            for row in window.events.sorted(by: { $0.time < $1.time }) {
                if let previous, abs(previous.end - window.range.start) < 0.001,
                   row.action == "takedown_attempt", !row.fighterKey.isEmpty, row.targetKey != nil,
                   // Sheet stamps are rounded to hundredths of a second.
                   abs(row.time - window.range.start) <= 0.01,
                   let index = previousIndices.last(where: {
                       let prior = result[$0]
                       return !used.contains($0) && prior.action == row.action && prior.videoID == row.videoID
                           && prior.fighterKey == row.fighterKey && prior.targetKey == row.targetKey
                           && prior.outcome == "unresolved"
                           && prior.endTime.map { abs($0 - previous.end) <= FightSampling.denseInterval + 0.001 } == true
                   }) {
                    result[index].endTime = row.endTime
                    result[index].outcome = row.outcome
                    result[index].detail = row.detail
                    used.insert(index)
                    result[index].points = row.points
                    indices.append(index)
                } else {
                    indices.append(result.count)
                    result.append(row)
                }
            }
            previous = window.range
            previousIndices = indices
        }
        return result
    }

    /// Unknown legacy coverage is zero; current sampling policy is not evidence
    /// that any of those seconds were actually scored.
    static func analyzedSeconds(passes: [AnalysisPassRecord], videoID: Int64, start: Double, end: Double) -> Double {
        guard let pass = passes.filter({ $0.videoID == videoID && $0.pass == .fightScore })
            .max(by: { (Double($0.startedAt) ?? 0) < (Double($1.startedAt) ?? 0) }),
              let ranges = FightSampling.successfulRanges(pass) else { return 0 }
        return ranges
            .reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
    }

    static func snapshot(_ original: StrikeStatPayload, video: VideoRecord, events: [FightEventRecord],
                         scenes: [SceneRecord], outcomes: [FightOutcome], roster: [VideoPersonRecord],
                         passes: [AnalysisPassRecord], researchJSON: String? = nil) -> StrikeStatPayload {
        let start = original.scope?.start ?? 0
        let end = original.scope?.end ?? video.duration
        let scoped = events.filter { $0.time >= start && $0.time < end }.map { event in
            var row = event
            if let finish = row.endTime, finish > end {
                row.endTime = end
                row.outcome = "unresolved"
            }
            return row
        }
        let strikes = deduplicatedStrikes(scoped)
        let pairs = pairs(events: scoped, outcomes: outcomes, validationEvents: events)
        let observedKeys = Set(roster.map(\.key) + scoped.map(\.fighterKey) + scoped.compactMap(\.targetKey)).sorted()
        let keys = observedKeys.isEmpty ? [""] : observedKeys
        var payload = original
        payload.values = .init(fighters: keys.map { key in
            let rows = strikes.filter { $0.fighterKey == key }
            return .init(key: key, name: roster.first { $0.key == key }?.displayName ?? (key.isEmpty ? "Unattributed" : key),
                         strikes: rows.count, significantStrikes: rows.count { $0.action != "strike" && $0.action != "ground_strike" },
                         knockdowns: rows.count { $0.action == "knockdown" })
        }, attempts: pairs.map(StrikeStatPayload.Attempt.init))
        let completed = passes.last { $0.videoID == video.id && $0.pass == .fightScore && $0.status == .completed }
        let legacy = completed.map { $0.version < 2 } ?? events.contains { ($0.scoringVersion ?? 1) < 2 }
        payload.states = events.isEmpty && completed == nil ? [.unavailable] : [legacy ? .legacy : .scored]
        if pairs.contains(where: { $0.outcomeCheck }) { payload.states?.append(.outcomeCheck) }
        payload.scope = .init(start: start, end: end,
                              analyzedSeconds: analyzedSeconds(passes: passes, videoID: video.id, start: start, end: end),
                              round: StrikeStatsScope.round(type: video.type, start: start, end: end,
                                                            scenes: scenes, researchJSON: researchJSON),
                              isRecap: video.type == .recap)
        return payload
    }
}
