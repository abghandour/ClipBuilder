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

    /// Anchor each cluster to its first timestamp; a chain of nearby blows must not
    /// swallow a later blow more than 0.4 s from that anchor.
    static func deduplicatedStrikes(_ events: [FightEventRecord]) -> [FightEventRecord] {
        let groups = Dictionary(grouping: events.filter { strikeFamily.contains($0.action) }) {
            "\($0.videoID)|\($0.fighterKey)"
        }
        return groups.values.flatMap { rows -> [FightEventRecord] in
            var result: [FightEventRecord] = []
            var anchor = -Double.infinity
            for row in rows.sorted(by: { $0.time < $1.time }) {
                if row.time - anchor <= 0.4, let last = result.last {
                    if row.points > last.points { result[result.count - 1] = row }
                } else {
                    anchor = row.time
                    result.append(row)
                }
            }
            return result
        }.sorted { $0.time < $1.time }
    }

    /// Overlapping holds and a continuing chain through a short transition are
    /// one sequence, carrying the final hold and resolution. Legacy instants stay intact.
    static func attemptSequences(_ events: [FightEventRecord]) -> [FightEventRecord] {
        var result: [FightEventRecord] = []
        for row in events.sorted(by: { $0.time < $1.time }) {
            if row.action == "submission_attempt", (row.scoringVersion ?? 1) >= 2,
               let index = result.lastIndex(where: {
                   $0.videoID == row.videoID && $0.action == row.action && $0.fighterKey == row.fighterKey
                       && $0.targetKey == row.targetKey && ($0.scoringVersion ?? 1) >= 2
               }), let end = result[index].endTime, row.time <= end + 3,
               result[index].outcome != "completed" {
                if (row.endTime ?? row.time) >= end {
                    result[index].endTime = row.endTime
                    result[index].outcome = row.outcome
                    result[index].detail = row.detail
                }
            } else {
                result.append(row)
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
            if (row.scoringVersion ?? 1) < 2 || row.action == "takedown" {
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

    static func analyzedSeconds(scenes: [SceneRecord], start: Double, end: Double) -> Double {
        let ranges = scenes.filter { $0.tags.contains(where: SmartSampling.actionTags.contains) }
            .map { ($0.startTime, $0.endTime) }.sorted { $0.0 < $1.0 }
        // The scorer samples the short gaps too when merging adjacent scenes.
        var merged: [(Double, Double)] = []
        for range in ranges {
            if let last = merged.last, range.0 - last.1 <= 2 {
                merged[merged.count - 1].1 = max(last.1, range.1)
            } else { merged.append(range) }
        }
        return merged.reduce(0) { $0 + max(0, min(end, $1.1) - max(start, $1.0)) }
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
                              analyzedSeconds: analyzedSeconds(scenes: scenes, start: start, end: end),
                              round: StrikeStatsScope.round(type: video.type, start: start, end: end,
                                                            scenes: scenes, researchJSON: researchJSON),
                              isRecap: video.type == .recap)
        return payload
    }
}
