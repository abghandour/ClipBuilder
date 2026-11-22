import Foundation

nonisolated extension FightCorrections {
    /// Partial retries need reconciliation of attempts spanning unselected windows.
    enum RetryScope: String, CaseIterable, Sendable {
        case wholeFight = "Whole fight"
    }

    static func inWindow(_ correction: FightCorrectionRecord, window: FightSampling.Range) -> Bool {
        [correction.time, correction.newTime ?? correction.time].contains { $0 >= window.start && $0 < window.end }
    }

    static func correctedWindows(_ windows: [FightSampling.Range], corrections: [FightCorrectionRecord]) -> [FightSampling.Range] {
        windows.filter { window in
            corrections.contains { $0.kind != .confirm && inWindow($0, window: window) }
        }
    }

    static func promptNotes(for window: FightSampling.Range, corrections: [FightCorrectionRecord],
                            roster: [VideoPersonRecord]) -> String? {
        let selected = corrections.filter { inWindow($0, window: window) }
        guard !selected.isEmpty else { return nil }
        return "REVIEWED BY A PERSON\n" + selected.map { note($0, roster: roster) }.joined(separator: "\n")
            + "\nTreat these as facts. Score the rest of the window with the same care; these show the kind of mistake made here before."
    }

    static func note(_ correction: FightCorrectionRecord, roster: [VideoPersonRecord]) -> String {
        func name(_ key: String) -> String {
            key.isEmpty ? "an unidentified fighter" : roster.first { $0.key == key }?.displayName ?? key
        }
        func description(_ event: FightEventRecord) -> String {
            // The technique alone hides a severity fix: "strike" to "knockdown"
            // would read as the same punch replaced by itself.
            let scored = event.action.replacingOccurrences(of: "_", with: " ")
            let action = StrikeDetail(event.detail).map { "\($0.label), scored as \(scored)" } ?? scored
            let end = event.endTime.map { " until \(String(format: "%.1f", $0))s" } ?? ""
            let outcome = event.outcome.map { ", outcome \($0)" } ?? ""
            let hold = StrikeDetail(event.detail) == nil ? event.detail.map { ", \($0)" } ?? "" : ""
            let target = event.targetKey.map { ", receiving fighter \(name($0))" } ?? ""
            return "\(name(event.fighterKey)) performed a \(action)\(end)\(outcome)\(hold)\(target)"
        }
        let original = correction.original ?? FightEventRecord(id: 0, videoID: correction.videoID,
            time: correction.time, fighterKey: correction.fighterKey, action: correction.action, points: 0, detail: correction.detail)
        let at = String(format: "%.1f", correction.time)
        let corrected = replacement(correction)
        let now = String(format: "%.1f", corrected.time)
        switch correction.kind {
        case .remove: return "At \(at)s, discard the previously logged action: \(description(original)). There is no scoring action matching that entry."
        case .add: return "At \(now)s, \(description(corrected)); this action was missed."
        case .confirm: return "At \(at)s, the reviewer confirmed: \(description(original))."
        case .edit: return "Replace the mistaken entry at \(at)s (\(description(original))) with this fact: at \(now)s, \(description(corrected))."
        }
    }

    struct Difference: Equatable, Sendable {
        var added = 0
        var removed = 0
        var reattributed = 0
        var revised = 0
        var changed: Int { added + removed + reattributed + revised }
        var summary: String {
            "Retry changed \(changed) actions across the whole fight: \(added) added, \(removed) removed, \(reattributed) re-attributed, \(revised) revised"
        }
    }

    /// Match exact content first, then nearest same-family actions one to one.
    /// Database ids, generations and model provenance are not action changes.
    static func difference(before: [FightEventRecord], after: [FightEventRecord]) -> Difference {
        func same(_ a: FightEventRecord, _ b: FightEventRecord) -> Bool {
            a.videoID == b.videoID && a.time == b.time && a.fighterKey == b.fighterKey
                && a.action == b.action && a.detail == b.detail && a.endTime == b.endTime
                && a.outcome == b.outcome && a.targetKey == b.targetKey && a.points == b.points
        }
        var remaining = after
        var unmatched: [FightEventRecord] = []
        for event in before {
            if let index = remaining.firstIndex(where: { same(event, $0) }) { remaining.remove(at: index) }
            else { unmatched.append(event) }
        }
        var result = Difference()
        for event in unmatched {
            let candidates = remaining.indices.filter {
                remaining[$0].videoID == event.videoID && family(remaining[$0].action) == family(event.action)
                    && abs(remaining[$0].time - event.time) <= tolerance + 1e-9
            }
            let match = candidates.min {
                let a = remaining[$0], b = remaining[$1]
                return (a.fighterKey == event.fighterKey ? 0 : 1, abs(a.time - event.time), $0)
                    < (b.fighterKey == event.fighterKey ? 0 : 1, abs(b.time - event.time), $1)
            }
            if let match {
                let next = remaining.remove(at: match)
                if next.fighterKey != event.fighterKey { result.reattributed += 1 }
                else { result.revised += 1 }
            } else { result.removed += 1 }
        }
        result.added = remaining.count
        return result
    }
}
