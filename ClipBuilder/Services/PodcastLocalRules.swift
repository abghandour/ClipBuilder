import Foundation

nonisolated enum PodcastLocalRules {
    static func locked(_ exchange: PodcastExchange, segments: [TranscriptSegment], turns: [SpeakerTurn]) -> Bool {
        guard exchange.end - exchange.start < 90 else { return false }
        let rows = segments.filter { $0.start >= exchange.start && $0.end <= exchange.end }
        guard let question = rows.first, question.text.trimmingCharacters(in: .whitespaces).hasSuffix("?") else { return false }
        let answers = turns.filter { $0.start >= question.end && $0.start < exchange.end }
        guard answers.count == 1, let answer = answers.first, answer.end <= exchange.end else { return false }
        guard let next = segments.first(where: { $0.start >= exchange.end }) else { return false }
        return next.start - exchange.end > 1.5
    }
    static func score(segments: [TranscriptSegment], start: Double, end: Double) -> Double {
        let rows = segments.filter { $0.end > start && $0.start < end }
        let features = TranscriptFeatureAnalyzer.analyze(segments: rows, videoID: 0, speakerKeys: [],
            mediaDuration: end, deadAirThreshold: 1.5, fillerRunThreshold: 0.5).features
        let duration = max(0.1, end - start)
        let speech = features.filter { $0.kind == .speech }.reduce(0) { $0 + max(0, min(end, $1.endTime) - max(start, $1.startTime)) }
        let filler = features.filter { $0.kind == .filler }.reduce(0) { $0 + max(0, min(end, $1.endTime) - max(start, $1.startTime)) }
        return min(0.5, max(0.05, 0.1 + 0.3 * speech / duration - 0.2 * filler / duration + (rows.contains { $0.text.contains("?") } ? 0.1 : 0)))
    }
    static func preserve(_ model: [PodcastExchange], locked: [PodcastExchange]) -> [PodcastExchange] {
        var result = model
        for fixed in locked {
            let overlaps = result.filter { $0.start < fixed.end && $0.end > fixed.start }
            var replacement = overlaps.first ?? fixed
            replacement.start = fixed.start
            replacement.end = fixed.end
            replacement.speakerKeys = fixed.speakerKeys
            result = result.flatMap { exchange -> [PodcastExchange] in
                guard exchange.start < fixed.end && exchange.end > fixed.start else { return [exchange] }
                var parts: [PodcastExchange] = []
                if exchange.start < fixed.start { var left = exchange; left.end = fixed.start; parts.append(left) }
                if exchange.end > fixed.end { var right = exchange; right.start = fixed.end; parts.append(right) }
                return parts
            }
            result.append(replacement)
        }
        return result.sorted { $0.start < $1.start }
    }
}
