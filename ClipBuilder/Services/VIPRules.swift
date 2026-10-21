import Foundation

/// Conservative fallback only for people whose model response omitted a VIP decision.
nonisolated enum VIPRules {
    static func fallback(videoType: VideoType?,
                         people: [(key: String, descriptor: String, category: PersonCategory?)],
                         talkShare: [String: Double]) -> Set<String> {
        switch videoType {
        case .fight, .recap:
            return Set(people.filter {
                $0.category == .fighter || $0.descriptor.localizedCaseInsensitiveContains("fighter")
                    || $0.descriptor.localizedCaseInsensitiveContains("champion")
            }.map(\.key))
        case .podcast, .interview:
            let speakers = talkShare.filter { $0.value.isFinite && $0.value > 0 }
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard speakers.count >= 2, let host = speakers.first?.key else { return [] }
            return Set(people.map(\.key)).intersection(speakers.map(\.key)).subtracting([host])
        case .training:
            return Set(people.filter { $0.category == .fighter }.map(\.key))
        default:
            return []
        }
    }

    static func judgement(modelValue: Bool?, key: String, fallback: Set<String>) -> (vip: Bool, source: String) {
        if let modelValue { return (modelValue, "ai") }
        return (fallback.contains(key), "rules")
    }

    static func talkShare(turns: [SpeakerTurn], range: ClosedRange<Double>? = nil) -> [String: Double] {
        var durations: [String: Double] = [:]
        var total = 0.0
        for turn in turns where turn.start.isFinite && turn.end.isFinite {
            let start = max(turn.start, range?.lowerBound ?? turn.start)
            let end = min(turn.end, range?.upperBound ?? turn.end)
            if end > start {
                total += end - start
                if let key = turn.personKey { durations[key, default: 0] += end - start }
            }
        }
        return total > 0 ? durations.mapValues { $0 / total } : [:]
    }

    static func speakingEvidence(turns: [SpeakerTurn], transcripts: [TranscriptRow]) -> String {
        let turns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        guard !turns.isEmpty else { return "" }
        let groups = Dictionary(grouping: turns) { $0.personKey ?? "unidentified speaker \($0.cluster + 1)" }
        let total = turns.reduce(0) { $0 + max(0, $1.end - $1.start) }
        guard total > 0 else { return "" }
        return "SPEAKING (unidentified speaker labels are voice clusters; use timestamps and frames to match people):\n"
            + groups.keys.sorted().map { key in
                let ownTurns = groups[key] ?? []
                let duration = ownTurns.reduce(0) { $0 + max(0, $1.end - $1.start) }
                let questions = transcripts.filter { row in
                    guard !row.isTranslation, row.text.contains("?") else { return false }
                    if let speaker = row.speakerKey { return speaker == key }
                    let mid = (row.startTime + row.endTime) / 2
                    return ownTurns.contains { $0.start <= mid && $0.end > mid }
                }.count
                let times = ownTurns.prefix(6).map { String(format: "%.1f–%.1fs", $0.start, $0.end) }.joined(separator: ", ")
                return "  - \(key): \(Int(duration / total * 100))% talk share; \(questions) question lines; speaking at \(times)"
            }.joined(separator: "\n")
    }

}
