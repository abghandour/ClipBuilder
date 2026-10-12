import Foundation

nonisolated enum StrikeStatsCopy {
    static let badge = "AI-scored"

    static func attempt(_ pair: StrikeStatsSummary.Pair, defense: Bool = false) -> String {
        let noun = pair.kind == .takedown ? "takedown" : "submission"
        if pair.legacy > 0 && pair.resolved + pair.unresolved == 0 {
            return pair.kind == .takedown
                ? "\(pair.legacy) takedowns · attempts not scored · Re-score"
                : "\(pair.legacy) submission attempts · outcomes not scored · Re-score"
        }
        if pair.attempts == 0 { return "No \(noun) attempts" }
        var text = "\(defense ? "\(noun.capitalized) defense" : pair.kind.label) \(defense ? pair.defended : pair.completed) of \(pair.resolved) resolved"
        if let success = pair.success {
            let percent = Int((success * 100).rounded())
            text += " · \(defense ? 100 - percent : percent) %"
        }
        text += " · \(pair.unresolved) unclear"
        if pair.kind == .submission {
            text += " · \(pair.attempts) attempts"
            if !pair.holds.isEmpty {
                text += " · " + pair.holds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            }
        }
        if pair.legacy > 0 { text += " · \(pair.legacy) \(pair.kind == .takedown ? "attempts not scored" : "outcomes not scored") · Re-score" }
        if pair.outcomeCheck { text += " · check outcome" }
        return text
    }

    static func lines(_ payload: StrikeStatPayload) -> [String] {
        guard payload.version == 1, let values = payload.values,
              payload.states?.contains(.unavailable) != true else {
            return ["Stats unavailable", "Re-score in Analyze"]
        }
        var lines = [badge + " · " + scope(payload.scope)]
        let pairs = (values.attempts ?? []).map(\.pair)
        for fighter in values.fighters ?? [] where payload.fighterKey == nil || payload.fighterKey == fighter.key {
            let key = fighter.key ?? ""
            lines.append(fighter.name ?? "Unattributed")
            if payload.kind == .roundCard {
                var strikes = "\(fighter.strikes ?? 0) strikes landed"
                if let seconds = payload.scope?.analyzedSeconds, seconds > 0 {
                    strikes += " · " + String(format: "%.1f", Double(fighter.strikes ?? 0) * 60 / seconds) + " per minute of analyzed footage"
                }
                lines.append(strikes)
                lines.append("\(fighter.significantStrikes ?? 0) significant strikes · \(fighter.knockdowns ?? 0) knockdowns")
            }
            for kind in AttemptKind.allCases where payload.attemptKind == nil || payload.attemptKind == kind {
                let offense = pairs.filter { $0.kind == kind && $0.attacker == key }
                if offense.isEmpty {
                    if payload.states?.contains(.legacy) == true {
                        lines.append(kind == .takedown ? "Takedown attempts not scored · Re-score" : "Submission outcomes not scored · Re-score")
                    } else {
                        lines.append(attempt(.init(kind: kind, attacker: key, defender: "")))
                    }
                }
                for pair in offense {
                    let target = values.fighters?.first { $0.key == pair.defender }?.name ?? "Unattributed"
                    lines.append(attempt(pair) + " vs " + target)
                }
                for pair in pairs where pair.kind == kind && pair.defender == key {
                    let attacker = values.fighters?.first { $0.key == pair.attacker }?.name ?? "Unattributed"
                    lines.append(attempt(pair, defense: true) + " vs " + attacker)
                }
            }
        }
        return lines
    }

    static func scope(_ scope: StrikeStatPayload.Scope?) -> String {
        if scope?.isRecap != true, let round = scope?.round { return "in round \(round) analyzed footage" }
        return "in analyzed footage"
    }

    static func text(_ payload: StrikeStatPayload) -> String { lines(payload).joined(separator: "\n") }
}
