import Foundation

/// A CTC model's output for a whole file: one row of log-probabilities per
/// frame, row-major.
nonisolated struct CTCEmissions: Sendable {
    var frames: Int
    var classes: Int
    var values: [Float]
    var secondsPerFrame: Double
}

/// The letters a word aligner knows, as shipped beside its model.
nonisolated struct WordAlignerVocabulary: Codable, Sendable {
    var vocab: [String: Int]
    var blank: Int
    var sampleRate: Int
    var windowSeconds: Int

    enum CodingKeys: String, CodingKey {
        case vocab, blank
        case sampleRate = "sample_rate"
        case windowSeconds = "window_seconds"
    }

    /// Single letters only: "<pad>", "<unk>" and the word separator are
    /// never part of a word's spelling.
    var letters: [Character: Int] {
        var letters: [Character: Int] = [:]
        for (key, index) in vocab where key.count == 1 && key != "|" { letters[Character(key)] = index }
        return letters
    }
}

/// How a long file is cut into the model's fixed windows. The model emits
/// one frame per `stride` samples, so every boundary here is a whole number
/// of frames and frame `n` of the stitched result is always sample
/// `n * stride`: rounding per window would drift by milliseconds per window
/// and by more than half a second over a long interview.
nonisolated enum WordAlignerWindows {
    struct Window: Equatable, Sendable {
        /// First sample read into the window.
        var start: Int
        /// Samples of real audio in it; the rest is silence padding.
        var count: Int
        /// Rows of the window's output that are kept.
        var rows: Range<Int>
    }

    /// The model's stride: a window of `window` samples yields `rows` frames.
    static func stride(window: Int, rows: Int) -> Int { max(1, window / (rows + 1)) }

    static func plan(total: Int, window: Int, rows: Int) -> [Window] {
        guard total > 0, window > 0, rows > 0 else { return [] }
        let stride = stride(window: window, rows: rows)
        // Each window keeps its middle four fifths, in whole frames.
        let keepFrames = max(1, window * 4 / 5 / stride)
        let edgeFrames = max(0, (window / stride - keepFrames) / 2)
        let totalFrames = (total + stride - 1) / stride
        var windows: [Window] = []
        var frame = 0
        while frame < totalFrames {
            let startFrame = max(0, frame - edgeFrames)
            let start = startFrame * stride
            let from = frame - startFrame
            let to = min(rows, from + keepFrames, totalFrames - startFrame)
            guard to > from else { break }
            windows.append(Window(start: start, count: min(window, total - start), rows: from..<to))
            frame += to - from
        }
        return windows
    }
}

/// Places the words of an existing transcript on the audio. The recognizer
/// decides the text; a CTC acoustic model decides where each letter is heard
/// (docs/Word-Alignment-Plan.md). Pure: emissions in, timed words out.
nonisolated enum CTCForcedAligner {
    /// A token that matches any frame at no cost: speech the transcript does
    /// not spell (the audio around a block, a number written in digits).
    static let wildcard = -1

    struct Span: Equatable, Sendable {
        var first: Int
        /// One past the last frame.
        var end: Int
        /// The best log-probability the token reached on its frames.
        var confidence: Float
    }

    struct Options: Sendable {
        /// Words are aligned in blocks of about this much audio.
        var blockSeconds = 12.0
        /// Neighbouring words aligned with each block and then discarded, so
        /// a block's own words never touch the wildcard at its edges.
        var contextWords = 3
        /// Audio searched before and after a block's recognizer times.
        var marginSeconds = 2.0
        /// The model stops a word about this long before the ear does
        /// (measured on hand-marked words, 2026-11-09).
        var tailPadding = 0.06
        /// A word the model barely heard keeps its recognizer time when the
        /// alignment would move it further than `maxDrift` outside it.
        var minConfidence: Float = -6
        var maxDrift = 0.5
        /// A word the model stretches this far past the recognizer's
        /// length was spelled unlike it is said ("UFC"): it keeps its time.
        var maxGrowth = 1.0
        var minDuration = 0.02
    }

    struct Result: Sendable {
        var words: [TranscriptWord]
        /// Words placed by the model, and words left on recognizer time.
        var aligned = 0
        var kept = 0
    }

    /// The best monotonic path of `tokens` (with optional blanks between
    /// them) through `frames`. nil when the tokens cannot fit.
    static func align(_ emissions: CTCEmissions, frames: Range<Int>, tokens: [Int], blank: Int) -> [Span]? {
        let frameCount = frames.count, tokenCount = tokens.count
        guard tokenCount > 0, frameCount >= tokenCount, frames.lowerBound >= 0, frames.upperBound <= emissions.frames else { return nil }
        let states = 2 * tokenCount + 1
        let classes = emissions.classes
        let negative: Float = -1e30
        // A token may follow the previous one directly unless they are the
        // same letter, which needs a blank between to be heard twice.
        var skips = [Bool](repeating: false, count: states)
        for state in stride(from: 3, to: states, by: 2) {
            let token = tokens[(state - 1) / 2]
            skips[state] = token == wildcard || token != tokens[(state - 3) / 2]
        }
        var back = [UInt8](repeating: 0, count: frameCount * states)
        var score = [Float](repeating: negative, count: states)
        var next = score
        return emissions.values.withUnsafeBufferPointer { values -> [Span]? in
            func emission(_ frame: Int, _ state: Int) -> Float {
                let row = (frames.lowerBound + frame) * classes
                if state % 2 == 0 { return values[row + blank] }
                let token = tokens[(state - 1) / 2]
                return token == wildcard ? 0 : values[row + token]
            }
            score[0] = emission(0, 0)
            score[1] = emission(0, 1)
            for frame in 1..<frameCount {
                // A state is reachable only once enough frames have passed
                // and while enough remain to finish.
                let low = max(0, states - 2 * (frameCount - frame) - 1)
                let high = min(states - 1, 2 * frame + 1)
                for state in 0..<states { next[state] = negative }
                guard low <= high else { continue }
                for state in low...high {
                    var best = score[state]
                    var step: UInt8 = 0
                    if state >= 1, score[state - 1] > best { best = score[state - 1]; step = 1 }
                    if state >= 2, skips[state], score[state - 2] > best { best = score[state - 2]; step = 2 }
                    guard best > negative else { continue }
                    next[state] = best + emission(frame, state)
                    back[frame * states + state] = step
                }
                swap(&score, &next)
            }
            var state = score[states - 1] >= score[states - 2] ? states - 1 : states - 2
            guard score[state] > negative else { return nil }
            var spans = [Span?](repeating: nil, count: tokenCount)
            for frame in stride(from: frameCount - 1, through: 0, by: -1) {
                if state % 2 == 1 {
                    let index = (state - 1) / 2
                    let value = emission(frame, state)
                    let absolute = frames.lowerBound + frame
                    if let span = spans[index] {
                        spans[index] = Span(first: absolute, end: span.end, confidence: max(span.confidence, value))
                    } else {
                        spans[index] = Span(first: absolute, end: absolute + 1, confidence: value)
                    }
                }
                state -= Int(back[frame * states + state])
                if state < 0 { return nil }
            }
            let found = spans.compactMap { $0 }
            return found.count == tokenCount ? found : nil
        }
    }

    /// The model's letters for a word; empty when it spells none of them
    /// (digits, symbols), which aligns as a wildcard.
    static func tokens(for word: String, letters: [Character: Int]) -> [Int] {
        word.lowercased().compactMap { letters[$0] }
    }

    /// Re-times `words` against the emissions. Text and order never change.
    static func retime(words: [TranscriptWord], emissions: CTCEmissions, vocabulary: WordAlignerVocabulary,
                       options: Options = Options()) -> Result {
        guard !words.isEmpty, emissions.frames > 0, emissions.secondsPerFrame > 0 else {
            return Result(words: words, kept: words.count)
        }
        let letters = vocabulary.letters
        let spelled = words.map { tokens(for: $0.word, letters: letters) }
        let step = emissions.secondsPerFrame
        let duration = Double(emissions.frames) * step
        var starts = words.map(\.start), ends = words.map(\.end)
        var placed = [Bool](repeating: false, count: words.count)

        var first = 0
        while first < words.count, !Task.isCancelled {
            var last = first
            while last + 1 < words.count, words[last + 1].end - words[first].start <= options.blockSeconds { last += 1 }
            let contextStart = max(0, first - options.contextWords)
            let contextEnd = min(words.count - 1, last + options.contextWords)
            let from = max(0, Int((words[contextStart].start - options.marginSeconds) / step))
            let to = min(emissions.frames, Int(((words[contextEnd].end + options.marginSeconds) / step).rounded(.up)))
            var tokens = [wildcard], owners = [-1]
            for index in contextStart...contextEnd {
                for token in spelled[index].isEmpty ? [wildcard] : spelled[index] {
                    tokens.append(token)
                    owners.append(index)
                }
            }
            tokens.append(wildcard)
            owners.append(-1)
            if from < to, let spans = align(emissions, frames: from..<to, tokens: tokens, blank: vocabulary.blank) {
                var position = 0
                while position < owners.count {
                    let owner = owners[position]
                    var end = position
                    while end + 1 < owners.count, owners[end + 1] == owner { end += 1 }
                    defer { position = end + 1 }
                    guard owner >= first, owner <= last, !spelled[owner].isEmpty else { continue }
                    let start = Double(spans[position].first) * step
                    let finish = Double(spans[end].end) * step
                    let confidence = spans[position...end].map(\.confidence).reduce(0, +) / Float(end - position + 1)
                    let drifted = finish < words[owner].start - options.maxDrift || start > words[owner].end + options.maxDrift
                    if confidence < options.minConfidence && drifted { continue }
                    if finish - start > words[owner].end - words[owner].start + options.maxGrowth { continue }
                    starts[owner] = start
                    ends[owner] = finish
                    placed[owner] = true
                }
            }
            first = last + 1
        }

        // A word left on recognizer time sits between its placed
        // neighbours; it never pushes a word the model did hear.
        var lower = 0.0
        var index = 0
        while index < words.count {
            if placed[index] { lower = ends[index]; index += 1; continue }
            var run = index
            while run + 1 < words.count, !placed[run + 1] { run += 1 }
            let upper = run + 1 < words.count ? starts[run + 1] : max(duration, ends[run])
            if upper >= lower {
                for kept in index...run {
                    starts[kept] = min(max(starts[kept], lower), upper)
                    ends[kept] = min(max(ends[kept], starts[kept]), upper)
                }
            }
            index = run + 1
        }

        // Words stay in order and never overlap the next one; then each
        // gets the tail the model clips, up to the next word.
        for index in words.indices {
            if index > 0 { starts[index] = max(starts[index], starts[index - 1]) }
            ends[index] = max(ends[index], starts[index] + options.minDuration)
        }
        for index in words.indices {
            let next = index + 1 < words.count ? starts[index + 1] : duration
            // No room before the next word leaves this one empty, never overlapping.
            if index + 1 < words.count { ends[index] = max(starts[index], min(ends[index], next)) }
            if placed[index] { ends[index] = min(ends[index] + options.tailPadding, max(next, ends[index])) }
        }
        var result = Result(words: words)
        for index in words.indices {
            result.words[index].start = starts[index].rounded(toPlaces: 2)
            result.words[index].end = max(ends[index].rounded(toPlaces: 2), result.words[index].start)
            if placed[index] { result.aligned += 1 } else { result.kept += 1 }
        }
        return result
    }

    /// Re-times every timed word of a transcript and moves each segment's
    /// edges to its first and last word. Segments without words are untouched.
    static func retime(segments: [TranscriptSegment], emissions: CTCEmissions, vocabulary: WordAlignerVocabulary,
                       options: Options = Options()) -> (segments: [TranscriptSegment], aligned: Int, kept: Int) {
        let flat = segments.flatMap { $0.words ?? [] }
        let result = retime(words: flat, emissions: emissions, vocabulary: vocabulary, options: options)
        var output = segments
        var cursor = 0
        for index in output.indices {
            guard let count = output[index].words?.count, count > 0 else { continue }
            let words = Array(result.words[cursor..<cursor + count])
            cursor += count
            output[index].words = words
            output[index].start = words[0].start
            output[index].end = max(words[count - 1].end, words[0].start)
        }
        return (output, result.aligned, result.kept)
    }
}
