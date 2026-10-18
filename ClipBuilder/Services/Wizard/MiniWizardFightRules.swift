import Foundation

/// Pure rules for Express Fight metrics: the chronological action list, how
/// picked actions merge into picks, and the names and plans picks get.
nonisolated enum MiniWizardFightRules {
    /// Half a second of run-up and follow-through around a scored action.
    static let padding = 0.5
    static let titleLimit = 60

    /// One scored action as the grid shows it.
    struct Action: Identifiable, Equatable, Sendable, Hashable {
        var id: Int64
        var time: Double
        var endTime: Double?
        var fighterKey: String
        var action: String
        var outcome: String?
        var detail: String?
        /// The stretch of the video the action covers, padded and clamped.
        var range: ClosedRange<Double>

        /// "Significant strike", "Takedown attempt · defended", "Submission attempt · armbar · completed".
        var label: String {
            var parts = [FightScoring.actionPoints.first { $0.action == action }?.label
                         ?? action.replacingOccurrences(of: "_", with: " ").capitalized]
            if let detail, !detail.isEmpty, detail != SubmissionHold.unknown.rawValue { parts.append(detail) }
            if let outcome, !outcome.isEmpty, action.hasSuffix("_attempt") { parts.append(outcome) }
            return parts.joined(separator: " · ")
        }

        /// The short family name for pick titles: strike, takedown, submission, ...
        var family: String {
            switch action {
            case "strike", "significant_strike", "ground_strike": "strike"
            case "knockdown": "knockdown"
            case "hurt": "hurt"
            case "takedown", "takedown_attempt": "takedown"
            case "submission_attempt": "submission"
            case "dominant_position": "position"
            case "reversal": "reversal"
            default: action.replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    /// Every scored action of the video in time order, counted the way the
    /// Fight Action inspector counts them: strike clusters deduplicated and
    /// attempt chains merged, so both surfaces agree.
    static func actions(events: [FightEventRecord], duration: Double) -> [Action] {
        let strikes = StrikeStatsSummary.deduplicatedStrikes(events)
        let others = StrikeStatsSummary.attemptSequences(events.filter { !StrikeStatsSummary.strikeFamily.contains($0.action) })
        return (strikes + others)
            .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
            .map { row in
                Action(id: row.id, time: row.time, endTime: row.endTime, fighterKey: row.fighterKey,
                       action: row.action, outcome: row.outcome, detail: row.detail,
                       range: span(start: row.time, end: row.endTime ?? row.time, duration: duration))
            }
    }

    /// The padded, clamped stretch for an action from `start` to `end`.
    static func span(start: Double, end: Double, duration: Double) -> ClosedRange<Double> {
        let limit = max(duration, padding * 2)
        let lower = min(max(0, start - padding), limit)
        let upper = max(lower, min(limit, max(start, end) + padding))
        return lower...upper
    }

    /// The stretch from the earliest picked action to the latest; nil for none.
    static func span(of picked: [Action]) -> ClosedRange<Double>? {
        guard let lower = picked.map(\.range.lowerBound).min(),
              let upper = picked.map(\.range.upperBound).max() else { return nil }
        return lower...max(lower, upper)
    }

    /// A run of picked actions that form one unbroken stretch of time.
    struct Unit: Equatable, Sendable {
        var range: ClosedRange<Double>
        var actions: [Action]
        var eventIDs: [Int64] { actions.map(\.id) }
    }

    /// Picked actions sorted by time and merged wherever one's span touches
    /// or overlaps the next, regardless of fighter or kind. Each unit becomes
    /// one pick.
    static func units(for picked: [Action]) -> [Unit] {
        var units: [Unit] = []
        for action in picked.sorted(by: { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }) {
            if var last = units.last, action.range.lowerBound <= last.range.upperBound + 0.001 {
                last.range = last.range.lowerBound...max(last.range.upperBound, action.range.upperBound)
                last.actions.append(action)
                units[units.count - 1] = last
            } else {
                units.append(Unit(range: action.range, actions: [action]))
            }
        }
        return units
    }

    /// The unit's name: fighters and what they did, e.g. "Felipe: 3 strikes,
    /// takedown" or "Felipe & João: 2 strikes, submission".
    static func title(for actions: [Action], names: [String: String], number: Int, limit: Int = titleLimit) -> String {
        guard !actions.isEmpty else { return "Pick \(number)" }
        var fighters: [String] = []
        for action in actions {
            let name = names[action.fighterKey] ?? (action.fighterKey.isEmpty ? "" : action.fighterKey)
            if !name.isEmpty, !fighters.contains(name) { fighters.append(name) }
        }
        var counts: [(family: String, count: Int)] = []
        for action in actions {
            if let index = counts.firstIndex(where: { $0.family == action.family }) {
                counts[index].count += 1
            } else {
                counts.append((action.family, 1))
            }
        }
        let what = counts.map { $0.count == 1 ? $0.family : "\($0.count) \($0.family)s" }.joined(separator: ", ")
        let text = fighters.isEmpty ? what.prefix(1).uppercased() + what.dropFirst() : fighters.joined(separator: " & ") + ": " + what
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The pick's title from the actions it was built from; a pick whose
    /// events are gone keeps a numbered name.
    static func title(for pick: FightPick, actions: [Action], names: [String: String], number: Int,
                      limit: Int = titleLimit) -> String {
        let byID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        return title(for: pick.eventIDs.compactMap { byID[$0] }, names: names, number: number, limit: limit)
    }

    /// Picks have no target duration: the whole stretch, including hand edits, is the clip.
    static func plan(for pick: FightPick, sceneID: Int64, name: String) -> WizardPlan {
        let clip = WizardPlanClip(sceneID: sceneID, start: pick.start, end: pick.end)
        return WizardPlan(targetDuration: pick.end - pick.start, rationale: name, musicName: nil,
                          musicVolume: 0, clips: [clip], transitions: [], headline: name)
    }
}
