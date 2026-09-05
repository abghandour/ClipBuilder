import Foundation

/// Deterministic, on-device transcript enrichment. Speaker labels use the
/// video's known identities and turn boundaries; energy is speech density.
nonisolated enum TranscriptFeatureAnalyzer {
    static func analyze(
        segments: [TranscriptSegment], videoID: Int64,
        speakerKeys: [String], mediaDuration: Double,
        speakerHints: [TranscriptSpeakerHint] = [],
        deadAirThreshold: Double, fillerRunThreshold: Double
    )
        -> (features: [TranscriptFeatureSegment], proposals: [EditProposal])
    {
        let ordered = segments.sorted { $0.start < $1.start }
        let fillers = Set(["um", "uh", "erm", "hmm", "like", "you know", "i mean", "so yeah"])
        var features: [TranscriptFeatureSegment] = []
        var proposals: [EditProposal] = []
        var cursor = 0.0
        var speakerIndex = 0
        var previousEnd = 0.0

        for segment in ordered {
            let gap = max(0, segment.start - cursor)
            if gap >= 0.3 {
                features.append(
                    .init(
                        id: 0, videoID: videoID, startTime: cursor,
                        endTime: segment.start, text: "", speakerKey: nil,
                        energy: 0, kind: .silence))
                if gap >= deadAirThreshold {
                    proposals.append(
                        .init(
                            id: 0, videoID: videoID, kind: .silence,
                            startTime: cursor, endTime: segment.start,
                            reason: "Silence longer than \(deadAirThreshold.formatted()) seconds",
                            decision: .pending))
                }
            }
            if segment.start - previousEnd > 0.75, !speakerKeys.isEmpty, !features.isEmpty {
                speakerIndex = (speakerIndex + 1) % speakerKeys.count
            }
            let normalized = segment.text.lowercased()
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            let words = normalized.split(whereSeparator: { $0.isWhitespace })
            let wordCount = max(1, words.count)
            let duration = max(0.15, segment.end - segment.start)
            let energy = min(1, max(0.05, Double(wordCount) / duration / 4.5))
            let fillerTokens = fillers.filter { normalized == $0 || normalized.hasPrefix("\($0) ") }
            let isFiller = !fillerTokens.isEmpty && (duration >= fillerRunThreshold || wordCount <= 4)
            let midpoint = (segment.start + segment.end) / 2
            let visibleSpeaker =
                speakerHints
                .filter { $0.startTime <= midpoint && midpoint <= $0.endTime }
                .min { ($0.endTime - $0.startTime) < ($1.endTime - $1.startTime) }?
                .personKey
            features.append(
                .init(
                    id: 0, videoID: videoID, startTime: segment.start,
                    endTime: segment.end, text: segment.text,
                    speakerKey: visibleSpeaker
                        ?? (speakerKeys.indices.contains(speakerIndex)
                            ? speakerKeys[speakerIndex] : nil),
                    energy: energy,
                    kind: isFiller ? .filler : .speech))
            if isFiller {
                proposals.append(
                    .init(
                        id: 0, videoID: videoID, kind: .filler,
                        startTime: segment.start, endTime: segment.end,
                        reason: "Filler run: “\(segment.text)”", decision: .pending))
            }
            cursor = max(cursor, segment.end)
            previousEnd = segment.end
        }

        if mediaDuration - cursor >= deadAirThreshold {
            features.append(
                .init(
                    id: 0, videoID: videoID, startTime: cursor,
                    endTime: mediaDuration, text: "", speakerKey: nil,
                    energy: 0, kind: .silence))
            proposals.append(
                .init(
                    id: 0, videoID: videoID, kind: .silence,
                    startTime: cursor, endTime: mediaDuration,
                    reason: "Trailing dead air", decision: .pending))
        }
        return (features, proposals)
    }

    static func speakerHints(scenes: [SceneRecord], personKeys: [String]) -> [TranscriptSpeakerHint] {
        scenes.compactMap { scene in
            guard let personKey = personKeys.first(where: { scene.tags.contains("person:\($0)") })
            else { return nil }
            return TranscriptSpeakerHint(
                startTime: scene.startTime, endTime: scene.endTime,
                personKey: personKey)
        }
    }
}
