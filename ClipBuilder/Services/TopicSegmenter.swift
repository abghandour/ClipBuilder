import Foundation

/// On-device topic boundary detection using pauses, questions, speaker turns,
/// and a maximum chapter span. Titles are derived from the transcript itself.
nonisolated enum TopicSegmenter {
    /// A speaker's uninterrupted run stays in one topic up to this long.
    static let speakerRunSpan = 75.0

    static func segment(_ features: [TranscriptFeatureSegment], videoID: Int64) -> [TopicRange] {
        let speech = coalesced(features.filter { $0.kind == .speech || $0.kind == .filler })
        guard !speech.isEmpty else { return [] }
        var groups: [[TranscriptFeatureSegment]] = []
        var current: [TranscriptFeatureSegment] = []

        for segment in speech {
            let previous = current.last
            let gap = previous.map { segment.startTime - $0.endTime } ?? 0
            let speakerTurn = previous?.speakerKey != segment.speakerKey
            let startsQuestion = segment.text.trimmingCharacters(in: .whitespaces).hasSuffix("?")
            let span = current.first.map { segment.endTime - $0.startTime } ?? 0
            if !current.isEmpty && (gap >= 3 || span >= 75 || (startsQuestion && speakerTurn && span >= 12)) {
                groups.append(current)
                current = []
            }
            current.append(segment)
        }
        if !current.isEmpty { groups.append(current) }

        var topics: [TopicRange] = []
        for (index, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let summary = group.map(\.text).joined(separator: " ")
            let cleaned = summary.replacingOccurrences(
                of: "[^[:alnum:]'’-]+",
                with: " ",
                options: .regularExpression
            )
            let titleWords =
                cleaned
                .split(separator: " ")
                .filter { $0.count > 2 }
                .prefix(7)
                .map { String($0) }
            let title: String
            if titleWords.isEmpty {
                title = "Topic \(index + 1)"
            } else {
                title = titleWords.joined(separator: " ").capitalized
            }
            topics.append(
                TopicRange(
                    id: 0, videoID: videoID, title: title,
                    startTime: first.startTime, endTime: last.endTime,
                    summary: String(summary.prefix(500)),
                    speakerKeys: Array(Set(group.compactMap(\.speakerKey))).sorted()))
        }
        return topics
    }

    /// Consecutive lines by one speaker, close together, joined into one
    /// unit: a topic boundary then never lands in the middle of an answer.
    /// Runs longer than `speakerRunSpan` are left as they come, so the
    /// span rule can still cut a monologue.
    static func coalesced(_ speech: [TranscriptFeatureSegment]) -> [TranscriptFeatureSegment] {
        var result: [TranscriptFeatureSegment] = []
        for segment in speech {
            if let last = result.last, let speaker = last.speakerKey, speaker == segment.speakerKey,
               segment.startTime - last.endTime < 3, segment.endTime - last.startTime <= speakerRunSpan {
                var joined = last
                joined.endTime = segment.endTime
                joined.text = last.text.isEmpty ? segment.text : last.text + " " + segment.text
                joined.energy = max(last.energy, segment.energy)
                joined.kind = last.kind == .filler && segment.kind == .filler ? .filler : .speech
                result[result.count - 1] = joined
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
