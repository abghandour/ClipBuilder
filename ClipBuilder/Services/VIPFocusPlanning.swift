import Foundation

/// The rhythm of VIP focus: whoever talks is on screen, the VIP is home.
/// A question shows the asker briefly and returns to the VIP; a long answer
/// cuts away to the asker for a moment; several people take turns in the
/// returns and cutaways, the VIPs first. Pure: source-clock tiles in, no
/// rectangles, no persistence (docs/VIP-Focus-Plan.md).
nonisolated enum VIPFocusPlanning {
    /// A non-VIP talker is shown this long before the picture returns to the VIP.
    static let askerShow = 2.0
    /// VIP speech this long earns a cutaway; a non-VIP still talking comes back after it.
    static let vipStretch = 8.0
    /// Length of a cutaway from a talking VIP.
    static let cutaway = 2.0
    /// A return to the VIP must leave them this long on screen before the next change.
    static let minimumReturn = 2.0
    /// Shot changes are at least this far apart.
    static let hold = 2.0
    /// The UI's ranges for the asker/cutaway length and the VIP stretch.
    static let showRange = 1.0...5.0
    static let stretchRange = 4.0...20.0
    /// A change already this close to a sentence end counts as on it.
    static let sentenceSlack = 0.05

    /// Where sentences end in a transcript, on the source clock: the ends of
    /// original lines that close with sentence punctuation, or every line end
    /// when the transcript has no punctuation at all.
    static func sentenceEnds(rows: [TranscriptRow]) -> [Double] {
        sentenceEnds(lines: rows.filter { !$0.isTranslation }.map { ($0.text, $0.endTime) })
    }

    static func sentenceEnds(segments: [TranscriptSegment]) -> [Double] {
        sentenceEnds(lines: segments.map { ($0.text, $0.end) })
    }

    static func sentenceEnds(lines: [(text: String, end: Double)]) -> [Double] {
        let closing: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
        let punctuated = lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)»"))
            return text.last.map(closing.contains) ?? false
        }
        return Array(Set((punctuated.isEmpty ? lines : punctuated).map(\.end))).sorted()
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound
    }

    /// Which tile is on screen from when, on the source clock, over `range`.
    /// `segments` are the planner's hold-folded talker stretches (the first
    /// may start after the range when nobody talks yet); `tiles` is everyone
    /// who can be shown and `vipTiles` the VIPs among them. `show` is how long
    /// an asker or a cutaway is on screen, `stretch` how long a talker holds
    /// the picture before the other side is shown. With `sentenceEnds`, a
    /// change inside a sentence waits for its end (a new talker is always a
    /// cut point: the previous person stopped). Consecutive repeats are
    /// dropped and nothing changes inside the clip's tail.
    static func events(segments: [CropRecipePlanner.Segment], tiles: [Int], vipTiles: [Int],
                       range: ClosedRange<Double>, hold: Double = hold, show: Double = askerShow,
                       stretch: Double = vipStretch, sentenceEnds: [Double] = []) -> [(time: Double, tile: Int)] {
        guard range.upperBound > range.lowerBound else { return [] }
        let segments = segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
            .sorted { $0.start < $1.start }
        let everyone = Array(Set(tiles + vipTiles + segments.map(\.talker))).sorted()
        let vips = Array(Set(vipTiles)).sorted().filter(everyone.contains)
        guard !vips.isEmpty else {
            // No VIP: plain talker following, opening on the first talker.
            var plain: [(time: Double, tile: Int)] = []
            for segment in segments where plain.last?.tile != segment.talker {
                plain.append((plain.isEmpty ? range.lowerBound : segment.start, segment.talker))
            }
            return plain
        }
        let show = clamp(show, to: showRange), stretch = clamp(stretch, to: stretchRange)
        // Changes keep the hold apart, but a short asker setting must still
        // be that short: the hold never exceeds the show length.
        let hold = min(max(hold, Self.hold), show)
        let lastChange = range.upperBound - VIPRotation.tail
        let segmentStarts = segments.map(\.start)
        let sentenceEnds = sentenceEnds.filter { $0 > range.lowerBound && $0 < range.upperBound }.sorted()
        /// The first moment at or after `time` that is not inside a sentence:
        /// a sentence end, or the next talker change, whichever comes first.
        func sentenceSafe(_ time: Double) -> Double {
            guard !sentenceEnds.isEmpty, !segmentStarts.contains(where: { abs($0 - time) < 1e-6 }) else { return time }
            let sentence = sentenceEnds.first { $0 >= time - sentenceSlack }
            let change = segmentStarts.first { $0 > time + 1e-6 }
            return max(time, min(sentence ?? .infinity, change ?? .infinity))
        }
        func isVIP(_ tile: Int) -> Bool { vips.contains(tile) }

        // The VIP with the most speech is home when nobody answers next.
        var speech: [Int: Double] = [:]
        for segment in segments where isVIP(segment.talker) {
            speech[segment.talker, default: 0] += min(segment.end, range.upperBound) - max(segment.start, range.lowerBound)
        }
        let home = vips.max { (speech[$0] ?? 0, -$0) < (speech[$1] ?? 0, -$1) } ?? vips[0]
        // The rotation starts on home: the pointer sits one before it.
        var vipPointer = (vips.firstIndex(of: home) ?? 0) - 1
        /// The VIP who answers at or after `time`, else the VIPs in turn.
        func nextVIP(after time: Double) -> Int {
            if let answer = segments.first(where: { $0.end > time && isVIP($0.talker) }) { return answer.talker }
            if vips.count == 1 { return vips[0] }
            vipPointer = (vipPointer + 1) % vips.count
            return vips[vipPointer]
        }
        var lastAsker: Int?
        var rotation = -1
        /// Who a talking VIP cuts away to: the last asker, else the others in turn.
        func cutawayTarget(from vip: Int) -> Int? {
            if let lastAsker, lastAsker != vip { return lastAsker }
            let others = everyone.filter { $0 != vip }
            guard !others.isEmpty else { return nil }
            rotation = (rotation + 1) % others.count
            return others[rotation]
        }

        var result: [(time: Double, tile: Int)] = []
        /// Appends a change no earlier than the hold allows; nil when it
        /// cannot happen before `deadline` or inside the tail.
        @discardableResult
        func push(_ time: Double, _ tile: Int, before deadline: Double) -> Double? {
            guard let last = result.last else { result.append((range.lowerBound, tile)); return range.lowerBound }
            if last.tile == tile { return last.time }
            let at = sentenceSafe(max(time, last.time + hold))
            guard at < deadline, at < lastChange else { return nil }
            result.append((at, tile))
            return at
        }

        // Segment starts are never moved by the sentence rule; everything
        // else (returns, cutaways and their ends) is measured in `show`/`stretch`.
        // The opening holds on the VIP until someone talks.
        if let first = segments.first, first.start > range.lowerBound + 1e-6 {
            push(range.lowerBound, nextVIP(after: range.lowerBound), before: range.upperBound)
        } else if segments.isEmpty {
            return [(range.lowerBound, home)]
        }
        for segment in segments {
            let start = max(segment.start, range.lowerBound), end = min(segment.end, range.upperBound)
            if isVIP(segment.talker) {
                guard push(start, segment.talker, before: end) != nil else { continue }
                var next = start + stretch
                while next + show + minimumReturn <= end + 1e-9, let target = cutawayTarget(from: segment.talker) {
                    guard let away = push(next, target, before: end - show - minimumReturn + 1e-9) else { break }
                    // A cutaway that cannot come back (the tail) does not start.
                    guard let back = push(away + show, segment.talker, before: end) else { result.removeLast(); break }
                    next = back + stretch
                }
            } else {
                lastAsker = segment.talker
                guard var shown = push(start, segment.talker, before: end) else { continue }
                while true {
                    let returnAt = shown + show
                    guard end - returnAt >= minimumReturn - 1e-9,
                          let back = push(returnAt, nextVIP(after: end), before: end - minimumReturn + 1e-9) else { break }
                    guard let again = push(back + stretch, segment.talker, before: end - minimumReturn + 1e-9) else { break }
                    shown = again
                }
            }
        }
        return result
    }
}
