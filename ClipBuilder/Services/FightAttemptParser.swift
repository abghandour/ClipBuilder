import Foundation

nonisolated enum FightAttemptParser {
    static func parse(_ entry: [String: Any], videoID: Int64, start: Double, end: Double,
                      validKeys: Set<String>, keyByName: [String: String]) -> FightEventRecord? {
        guard let action = entry["action"] as? String, FightScoring.actionKeys.contains(action),
              let time = ((entry["at_time"] ?? entry["t"]) as? NSNumber)?.doubleValue, time.isFinite else { return nil }
        func key(_ value: Any?) -> String {
            let raw = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return validKeys.contains(raw) ? raw : keyByName[raw] ?? ""
        }
        var row = FightEventRecord(id: 0, videoID: videoID, time: min(max(start, time), end),
                                   fighterKey: key(entry["fighter"]), action: action, points: 0,
                                   scoringVersion: AnalysisPipeline.fightScorePass)
        if action == "takedown_attempt" || action == "submission_attempt" {
            guard let finish = (entry["end_time"] as? NSNumber)?.doubleValue,
                  finish.isFinite, finish > row.time else { return nil }
            let resolutionTime = min(end, finish)
            guard resolutionTime > row.time else { return nil }
            row.endTime = resolutionTime
            let target = key(entry["target_key"])
            row.targetKey = target.isEmpty || target == row.fighterKey ? nil : target
            let outcome = entry["outcome"] as? String ?? "unresolved"
            row.outcome = ["completed", "defended", "unresolved"].contains(outcome) ? outcome : "unresolved"
            if action == "submission_attempt" {
                row.detail = (SubmissionHold(rawValue: entry["detail"] as? String ?? "") ?? .unknown).rawValue
            }
        } else if action == "takedown" {
            // An old-style response has no attempt denominator, even during a v2 request.
            row.scoringVersion = 1
        }
        row.points = FightScoring.points(for: action, outcome: row.outcome)
        return row
    }
}
