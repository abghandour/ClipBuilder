import Foundation

/// Per-fighter totals from a video's scoring events, for the Sources grid
/// badge and the inspector's Fight Action rows.
nonisolated enum FightScoreDigest {
    struct Fighter: Equatable, Sendable, Identifiable {
        var key: String
        var strikes = 0
        var takedowns = 0
        var takedownAttempts = 0
        var submissions = 0
        var submissionAttempts = 0
        var id: String { key }
        var actions: Int { strikes + takedownAttempts + submissionAttempts }
    }

    /// One row per fighter, most active first; unattributed events land on "".
    static func fighters(events: [FightEventRecord]) -> [Fighter] {
        var rows: [String: Fighter] = [:]
        for strike in StrikeStatsSummary.deduplicatedStrikes(events) {
            rows[strike.fighterKey, default: Fighter(key: strike.fighterKey)].strikes += 1
        }
        for pair in StrikeStatsSummary.pairs(events: events) {
            var row = rows[pair.attacker, default: Fighter(key: pair.attacker)]
            switch pair.kind {
            case .takedown:
                row.takedownAttempts += pair.attempts
                row.takedowns += pair.completed + pair.legacy
            case .submission:
                row.submissionAttempts += pair.attempts
                row.submissions += pair.completed
            }
            rows[pair.attacker] = row
        }
        return rows.values.sorted { ($0.actions, $1.key) > ($1.actions, $0.key) }
    }

    static func totalActions(events: [FightEventRecord]) -> Int {
        fighters(events: events).reduce(0) { $0 + $1.actions }
    }

    /// "Felipe 15 strikes · 2/3 TD · 1 sub" style line per fighter.
    static func line(_ fighter: Fighter, name: String) -> String {
        var parts = ["\(fighter.strikes) strike" + (fighter.strikes == 1 ? "" : "s")]
        if fighter.takedownAttempts > 0 { parts.append("\(fighter.takedowns)/\(fighter.takedownAttempts) TD") }
        if fighter.submissionAttempts > 0 { parts.append("\(fighter.submissions)/\(fighter.submissionAttempts) sub") }
        return "\(name): " + parts.joined(separator: " · ")
    }
}

extension FightScoreDigest {
    enum Category: String, CaseIterable, Sendable, Hashable {
        case strikes, takedowns, submissions

        var label: String {
            switch self {
            case .strikes: "Strikes"
            case .takedowns: "Takedowns"
            case .submissions: "Submissions"
            }
        }
    }

    /// One scored action, ready to show as a frame: strike clusters are
    /// collapsed and attempt chains merged exactly as the totals count them,
    /// so the list and its count always agree.
    struct Entry: Equatable, Sendable, Identifiable {
        var id: Int64
        var time: Double
        var endTime: Double?
        var action: String
        var targetKey: String?
        var outcome: String?
        var detail: String?

        var label: String {
            if action == "takedown" { return "Takedown" }
            return FightScoring.actionPoints.first { $0.action == action }?.label ?? action.replacingOccurrences(of: "_", with: " ")
        }

        /// "Takedown attempt · defended", "Submission attempt · armbar · completed".
        var summary: String {
            var parts = [label]
            if let detail, !detail.isEmpty, detail != SubmissionHold.unknown.rawValue { parts.append(detail) }
            if let outcome, !outcome.isEmpty, action.hasSuffix("_attempt") { parts.append(outcome) }
            return parts.joined(separator: " · ")
        }

        /// A finished attempt shows its start and end frames; an instant shows one.
        var frameTimes: [Double] {
            if let endTime, endTime - time >= 1 { return [time, endTime] }
            return [time]
        }

        /// The window to play on repeat: a strike with a second of run-up and
        /// the follow-through, an attempt from just before the shot to just
        /// after it resolves.
        var loopRange: ClosedRange<Double> {
            let start = max(0, time - 1)
            if let endTime, endTime > time { return start...(endTime + 0.5) }
            return start...(time + 1.5)
        }
    }

    static func entries(events: [FightEventRecord], fighter: String, category: Category) -> [Entry] {
        let rows: [FightEventRecord]
        switch category {
        case .strikes:
            rows = StrikeStatsSummary.deduplicatedStrikes(events).filter { $0.fighterKey == fighter }
        case .takedowns:
            rows = StrikeStatsSummary.attemptSequences(events).filter {
                $0.fighterKey == fighter && ($0.action == "takedown_attempt" || $0.action == "takedown")
            }
        case .submissions:
            rows = StrikeStatsSummary.attemptSequences(events).filter {
                $0.fighterKey == fighter && $0.action == "submission_attempt"
            }
        }
        return rows.sorted { $0.time < $1.time }.map {
            Entry(id: $0.id, time: $0.time, endTime: $0.endTime, action: $0.action,
                  targetKey: $0.targetKey, outcome: $0.outcome, detail: $0.detail)
        }
    }

    static func count(_ fighter: Fighter, _ category: Category) -> Int {
        switch category {
        case .strikes: fighter.strikes
        case .takedowns: fighter.takedownAttempts
        case .submissions: fighter.submissionAttempts
        }
    }
}
