import Foundation

nonisolated enum CaptionWordStates {
    struct State: Equatable, Sendable {
        var page: CaptionPage
        var activeIndex: Int?
        var start: Double
        var end: Double
    }

    /// Only exact token clocks qualify. Silence is an unlit state, including
    /// gaps within a page; overlapping clocks are clipped at the next onset.
    static func states(for page: CaptionPage, words: [TranscriptWord]?) -> [State] {
        let tokens = page.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, page.start.isFinite, page.end.isFinite, page.end > page.start else { return [] }
        let clocks = words ?? page.words
        guard let clocks, clocks.count == tokens.count,
              zip(clocks, tokens).allSatisfy({ $0.word.trimmingCharacters(in: .whitespacesAndNewlines) == $1 }),
              clocks.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
              zip(clocks, clocks.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
            let step = (page.end - page.start) / Double(tokens.count)
            return tokens.indices.map {
                State(page: page, activeIndex: $0, start: page.start + Double($0) * step,
                      end: $0 == tokens.count - 1 ? page.end : page.start + Double($0 + 1) * step)
            }
        }
        var result: [State] = []
        var cursor = page.start
        for (index, word) in clocks.enumerated() {
            let start = min(page.end, max(cursor, word.start))
            if start > cursor { result.append(State(page: page, start: cursor, end: start)) }
            let next = index + 1 < clocks.count ? clocks[index + 1].start : page.end
            let end = min(page.end, min(word.end, next))
            if end > start { result.append(State(page: page, activeIndex: index, start: start, end: end)) }
            cursor = max(start, end)
        }
        if cursor < page.end { result.append(State(page: page, start: cursor, end: page.end)) }
        return result
    }
}
