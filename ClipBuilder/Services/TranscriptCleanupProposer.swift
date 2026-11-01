import Foundation

/// Word-level cleanup suggestions over a transcript's timed words: filler
/// words, stutters (a word said twice), false starts (a short fragment the
/// speaker abandons and restarts) and retakes (a line said again shortly
/// after; the last take is kept). Pure and deterministic; every proposal is
/// reviewed in Transcript Tools before it cuts anything.
///
/// Cut boundaries: a cut may reach from the end of the kept word before it
/// to the start of the kept word after it, never inside any word. That
/// stretch is trimmed so `minGap` of the silence stays on each side (a
/// breath before and after the join); where the silence next to the
/// removed words is already shorter than `minGap`, the cut stops at the
/// removed word's edge and all of that silence stays. A cut that ends up
/// shorter than `minCut` is dropped.
nonisolated enum TranscriptCleanupProposer {
    struct Options: Sendable {
        /// Normalized tokens or bigrams that are always filler.
        var fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "hmm", "you know", "i mean"]
        /// Filler only between two pauses of at least `conditionalPause`
        /// ("like" is a real word mid-sentence).
        var conditionalFillers: Set<String> = ["like"]
        var conditionalPause: Double = 0.2
        /// A false start is at most this many words ending in this long a pause.
        var falseStartMaxWords: Int = 3
        var falseStartPause: Double = 0.4
        /// Silence kept on each side of a cut.
        var minGap: Double = 0.25
        /// Cuts shorter than this are not worth proposing.
        var minCut: Double = 0.05
        /// Two takes of a line must lie within this many seconds.
        var retakeWindow: Double = 20
        /// Token Jaccard similarity two lines need to count as takes.
        var retakeSimilarity: Double = 0.8
        var maxRetakeWords: Int = 40
        /// Shorter lines ("Yeah.", "Thank you.") repeat for real.
        var minRetakeWords: Int = 3

        init() {}
    }

    enum Kind: String, Sendable, Hashable, CaseIterable {
        case filler, repeatWord, falseStart, retake

        var editKind: EditProposal.Kind {
            switch self {
            case .filler: .filler
            case .repeatWord: .repeatWord
            case .falseStart: .falseStart
            case .retake: .retake
            }
        }

        var label: String { editKind.label }
    }

    struct CleanupProposal: Sendable, Hashable {
        var kind: Kind
        var rowID: Int64
        /// Indices into the row's `words`.
        var wordRange: Range<Int>
        var startTime: Double
        var endTime: Double
        /// The detail, without the kind ("“um”").
        var reason: String
    }

    /// Lowercased with surrounding punctuation and symbols removed; inner
    /// apostrophes stay ("don't").
    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
    }

    /// Jaccard similarity of the two token sets (normalized; empty tokens
    /// ignored). Two empty lists are not similar.
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        let left = Set(a.map(normalize)).subtracting([""])
        let right = Set(b.map(normalize)).subtracting([""])
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(union.count)
    }

    private struct Position: Hashable {
        var row: Int
        var word: Int
    }

    private struct Sentence {
        var row: Int
        var range: Range<Int>
        var tokens: [String]
        var start: Double
        var end: Double
        var speaker: String?
    }

    static func propose(rows: [TranscriptRow], options: Options = .init()) -> [CleanupProposal] {
        let ordered = rows.filter { !$0.isTranslation }.sorted { $0.startTime < $1.startTime }
        let words: [[TranscriptWord]] = ordered.map { $0.words ?? [] }
        let norms: [[String]] = words.map { $0.map { normalize($0.word) } }

        // Every word in time order, for the silence on either side of a word.
        var stream: [Position] = []
        for row in words.indices { for word in words[row].indices { stream.append(Position(row: row, word: word)) } }
        stream.sort {
            let a = words[$0.row][$0.word].start, b = words[$1.row][$1.word].start
            return a != b ? a < b : ($0.row, $0.word) < ($1.row, $1.word)
        }
        var streamIndex: [Position: Int] = [:]
        for (index, position) in stream.enumerated() { streamIndex[position] = index }
        func word(_ position: Position) -> TranscriptWord { words[position.row][position.word] }
        func previousEnd(_ position: Position) -> Double? {
            guard let index = streamIndex[position], index > 0 else { return nil }
            return word(stream[index - 1]).end
        }
        func nextStart(_ position: Position) -> Double? {
            guard let index = streamIndex[position], index + 1 < stream.count else { return nil }
            return word(stream[index + 1]).start
        }

        var marks: [[Kind?]] = words.map { Array(repeating: nil, count: $0.count) }
        var retakeFollows: [Position: Double] = [:]
        func isFree(_ row: Int, _ range: Range<Int>) -> Bool { range.allSatisfy { marks[row][$0] == nil } }
        func mark(_ row: Int, _ range: Range<Int>, _ kind: Kind) { for index in range { marks[row][index] = kind } }
        // Word indices in a row whose token is not empty (punctuation-only words are skipped).
        let spoken: [[Int]] = norms.map { row in row.indices.filter { !row[$0].isEmpty } }

        // Retakes first: a whole earlier line outranks the words inside it.
        var sentences: [Sentence] = []
        for row in words.indices where !words[row].isEmpty {
            var start = 0
            for index in words[row].indices {
                let raw = words[row][index].word.trimmingCharacters(in: .whitespacesAndNewlines)
                let terminal = raw.last.map { ".?!…".contains($0) } ?? false
                if terminal || index == words[row].count - 1 {
                    let range = start..<(index + 1)
                    let tokens = range.map { norms[row][$0] }.filter { !$0.isEmpty }
                    if !tokens.isEmpty {
                        sentences.append(Sentence(row: row, range: range, tokens: tokens,
                                                  start: words[row][range.lowerBound].start,
                                                  end: words[row][range.upperBound - 1].end,
                                                  speaker: ordered[row].speakerKey))
                    }
                    start = index + 1
                }
            }
        }
        sentences.sort { $0.start < $1.start }
        let takeSize = options.minRetakeWords...max(options.minRetakeWords, options.maxRetakeWords)
        for i in sentences.indices where takeSize.contains(sentences[i].tokens.count) {
            let earlier = sentences[i]
            for j in sentences.indices.dropFirst(i + 1) {
                let later = sentences[j]
                if later.start - earlier.end > options.retakeWindow { break }
                guard later.start >= earlier.end - 0.01, takeSize.contains(later.tokens.count) else { continue }
                if let a = earlier.speaker, let b = later.speaker, !a.isEmpty, !b.isEmpty, a != b { continue }
                guard similarity(earlier.tokens, later.tokens) >= options.retakeSimilarity else { continue }
                if isFree(earlier.row, earlier.range) {
                    mark(earlier.row, earlier.range, .retake)
                    retakeFollows[Position(row: earlier.row, word: earlier.range.lowerBound)] = later.start
                }
                break
            }
        }

        for row in words.indices where !spoken[row].isEmpty {
            let indices = spoken[row]
            // False starts: fragments split on long pauses.
            var fragments: [[Int]] = [[indices[0]]]
            for k in indices.indices.dropFirst() {
                let gap = words[row][indices[k]].start - words[row][indices[k - 1]].end
                if gap >= options.falseStartPause { fragments.append([]) }
                fragments[fragments.count - 1].append(indices[k])
            }
            for f in fragments.indices.dropLast() {
                let fragment = fragments[f], next = fragments[f + 1]
                guard let first = fragment.first, let last = fragment.last, let nextFirst = next.first,
                      fragment.count <= options.falseStartMaxWords, norms[row][first] == norms[row][nextFirst]
                else { continue }
                let range = first..<(last + 1)
                if isFree(row, range) { mark(row, range, .falseStart) }
            }
            // Stutters: the same word twice in a row; the first goes.
            for k in indices.indices.dropLast() {
                let a = indices[k], b = indices[k + 1]
                let token = norms[row][a]
                guard token == norms[row][b], !options.fillers.contains(token),
                      marks[row][a] == nil, marks[row][b] == nil else { continue }
                mark(row, a..<(a + 1), .repeatWord)
            }
            // Bigram fillers, then single-word fillers.
            for k in indices.indices.dropLast() {
                let a = indices[k], b = indices[k + 1]
                guard options.fillers.contains(norms[row][a] + " " + norms[row][b]),
                      marks[row][a] == nil, marks[row][b] == nil else { continue }
                mark(row, a..<(b + 1), .filler)
            }
            for a in indices where marks[row][a] == nil {
                let token = norms[row][a]
                if options.fillers.contains(token) {
                    mark(row, a..<(a + 1), .filler)
                } else if options.conditionalFillers.contains(token) {
                    let position = Position(row: row, word: a)
                    let before = previousEnd(position).map { words[row][a].start - $0 } ?? .infinity
                    let after = nextStart(position).map { $0 - words[row][a].end } ?? .infinity
                    if before >= options.conditionalPause, after >= options.conditionalPause {
                        mark(row, a..<(a + 1), .filler)
                    }
                }
            }
        }

        // Runs of one kind become one cut each.
        var proposals: [CleanupProposal] = []
        for row in words.indices {
            var index = 0
            while index < marks[row].count {
                guard let kind = marks[row][index] else { index += 1; continue }
                var end = index + 1
                while end < marks[row].count, marks[row][end] == kind { end += 1 }
                let range = index..<end
                index = end
                let first = Position(row: row, word: range.lowerBound)
                let last = Position(row: row, word: range.upperBound - 1)
                let wordStart = words[row][range.lowerBound].start
                let wordEnd = words[row][range.upperBound - 1].end
                let start = previousEnd(first).map { min($0 + options.minGap, wordStart) } ?? wordStart
                let stop = nextStart(last).map { max($0 - options.minGap, wordEnd) } ?? wordEnd
                guard start.isFinite, stop.isFinite, stop - start >= options.minCut else { continue }
                let text = range.map { words[row][$0].word.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")
                let quoted = "“\(text.count > 80 ? String(text.prefix(77)) + "…" : text)”"
                let reason: String = switch kind {
                case .retake:
                    retakeFollows[first].map { "\(quoted); said again at \($0.timecode)" } ?? quoted
                default: quoted
                }
                proposals.append(CleanupProposal(kind: kind, rowID: ordered[row].id, wordRange: range,
                                                 startTime: start, endTime: stop, reason: reason))
            }
        }
        return proposals.sorted { $0.startTime < $1.startTime }
    }

    /// The proposals as pending edit proposals, reason prefixed by the
    /// kind. A word-level cut of the same kind that overlaps one of
    /// `existing` (the segment-level analyzer's) is left out.
    static func editProposals(rows: [TranscriptRow], videoID: Int64, alongside existing: [EditProposal] = [],
                              options: Options = .init()) -> [EditProposal] {
        propose(rows: rows, options: options).compactMap { proposal in
            let kind = proposal.kind.editKind
            let duplicate = existing.contains {
                $0.kind == kind && $0.startTime < proposal.endTime && proposal.startTime < $0.endTime
            }
            guard !duplicate else { return nil }
            return EditProposal(id: 0, videoID: videoID, kind: kind, startTime: proposal.startTime,
                                endTime: proposal.endTime, reason: "\(proposal.kind.label): \(proposal.reason)",
                                decision: .pending)
        }
    }
}
