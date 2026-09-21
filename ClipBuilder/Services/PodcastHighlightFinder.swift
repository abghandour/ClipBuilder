import Foundation

/// Pure selection and validation, with an optional AI boundary around long exchanges.
nonisolated enum PodcastHighlightFinder {
    static func resolveOverlaps(_ candidates: [HighlightCandidate], threshold: Double) -> [HighlightCandidate] {
        let ranked = candidates.enumerated().filter {
            $0.element.score.isFinite && $0.element.score >= threshold
                && $0.element.sourceStart.isFinite && $0.element.sourceEnd.isFinite
                && $0.element.sourceStart >= 0 && $0.element.duration > 0
        }.sorted {
            if $0.element.score != $1.element.score { return $0.element.score > $1.element.score }
            if $0.element.sourceStart != $1.element.sourceStart { return $0.element.sourceStart < $1.element.sourceStart }
            return $0.offset < $1.offset
        }
        var kept: [HighlightCandidate] = []
        for (_, item) in ranked where !kept.contains(where: {
            $0.sourceStart < item.sourceEnd && item.sourceStart < $0.sourceEnd
        }) { kept.append(item) }
        return kept
    }

    static func candidate(_ exchange: PodcastExchange, rows: [TranscriptSegment], kind: HighlightCandidate.Kind,
                          turns: [SpeakerTurn]) -> HighlightCandidate? {
        guard let first = rows.first, let last = rows.last else { return nil }
        let keys = Set(turns.filter { $0.end > first.start && $0.start < last.end }.compactMap(\.personKey))
        return HighlightCandidate(sourceStart: first.start, sourceEnd: last.end, title: exchange.title,
                                  reason: exchange.summary, score: exchange.score, kind: kind,
                                  speakerKeys: keys.isEmpty ? exchange.speakerKeys : keys.sorted())
    }

    /// The question is the sentence span before the first speaker change.
    /// Always use the full exchange, including when the model sees a later chunk.
    static func questionRows(_ rows: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard let first = rows.first, let last = rows.last else { return [] }
        let covering = turns.filter { $0.end > first.start && $0.start < last.end }.sorted { $0.start < $1.start }
        guard let speaker = covering.first else { return [first] }
        let change = covering.dropFirst().first { turn in
            if let key = turn.personKey, let firstKey = speaker.personKey { return key != firstKey }
            return turn.cluster != speaker.cluster
        }?.start ?? last.end
        return rows.filter { $0.start < change }
    }

    static func includingQuestion(_ candidate: HighlightCandidate, rows: [TranscriptSegment],
                                  maxSeconds: Double, turns: [SpeakerTurn],
                                  log: (String) -> Void = { _ in }) -> HighlightCandidate {
        var item = candidate
        let question = questionRows(rows, turns: turns)
        guard let last = question.last else { return item }
        // Even a partial question sentence (or a fallback entirely inside the
        // question) contains context. Repair its opening boundary when it fits.
        if let overlapping = question.first(where: { $0.start < item.sourceEnd && $0.end > item.sourceStart }) {
            if overlapping.start < item.sourceStart, item.sourceEnd - overlapping.start <= maxSeconds {
                item.sourceStart = overlapping.start
                let keys = turns.filter { $0.end > item.sourceStart && $0.start < item.sourceEnd }.compactMap(\.personKey)
                item.speakerKeys = Array(Set(item.speakerKeys + keys)).sorted()
            }
            item.includesQuestion = true
            return item
        }
        guard item.sourceStart >= last.end else { return item }
        if let start = question.first(where: { item.sourceEnd - $0.start <= maxSeconds }) {
            item.sourceStart = start.start
            item.includesQuestion = true
            let keys = turns.filter { $0.end > item.sourceStart && $0.start < item.sourceEnd }.compactMap(\.personKey)
            item.speakerKeys = Array(Set(item.speakerKeys + keys)).sorted()
        } else {
            log("Podcast highlights · \(item.title): question does not fit; answer only (answer start preserved).")
        }
        return item
    }

    static func logScores(_ raw: [Any], log: (String) -> Void) {
        let scores = raw.compactMap { ($0 as? [String: Any])?["score"] as? Double }.filter(\.isFinite).sorted()
        guard let low = scores.first, let high = scores.last else {
            log("Podcast highlights raw scores: min=n/a median=n/a max=n/a count=0")
            return
        }
        let middle = scores.count / 2
        let median = scores.count.isMultiple(of: 2) ? (scores[middle - 1] + scores[middle]) / 2 : scores[middle]
        log("Podcast highlights raw scores: min=\(low) median=\(median) max=\(high) count=\(scores.count)")
        if scores.count > 1 && low == high { log("Podcast highlights: flat scores") }
    }

    /// Never invent a timestamp: even fallback cuts use the numbered sentence partition.
    static func fallback(_ exchange: PodcastExchange, rows: [TranscriptSegment], maxSeconds: Double,
                         turns: [SpeakerTurn], questionContext: [TranscriptSegment]? = nil,
                         log: (String) -> Void = { _ in }) -> HighlightCandidate? {
        for first in rows.indices {
            let run = Array(rows[first...].prefix { $0.end - rows[first].start <= maxSeconds })
            if let result = candidate(exchange, rows: run, kind: .subcut, turns: turns) {
                return includingQuestion(result, rows: questionContext ?? rows, maxSeconds: maxSeconds, turns: turns, log: log)
            }
        }
        return nil
    }

    static func validated(_ raw: [Any], exchange: PodcastExchange, rows: [TranscriptSegment],
                          maxSeconds: Double, turns: [SpeakerTurn], questionContext: [TranscriptSegment]? = nil,
                          log: (String) -> Void = { _ in }) -> [HighlightCandidate] {
        raw.enumerated().compactMap { index, value in
            func reject(_ reason: String) -> HighlightCandidate? {
                log("Podcast highlight rejected · \(exchange.title) · entry \(index + 1): \(reason)")
                return nil
            }
            guard let entry = value as? [String: Any] else { return reject("expected an object") }
            guard let a = entry["first_sentence"] as? NSNumber, let b = entry["last_sentence"] as? NSNumber,
                  a.doubleValue == Double(a.intValue), b.doubleValue == Double(b.intValue),
                  rows.indices.contains(a.intValue), rows.indices.contains(b.intValue), a.intValue <= b.intValue else {
                return reject("invalid sentence range")
            }
            guard let score = (entry["score"] as? NSNumber)?.doubleValue, score.isFinite, (0...10).contains(score) else {
                return reject("score must be a number from 0 to 10")
            }
            guard let title = entry["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let reason = entry["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return reject("title and reason must be nonempty strings")
            }
            guard entry["rapid_exchange"] == nil || entry["rapid_exchange"] is Bool else {
                return reject("rapid_exchange must be a boolean when supplied")
            }
            guard entry["standalone"] == nil || entry["standalone"] is Bool else {
                return reject("standalone must be a boolean when supplied")
            }
            let selected = Array(rows[a.intValue...b.intValue])
            guard var item = candidate(exchange, rows: selected, kind: .subcut, turns: turns),
                  item.sourceStart.isFinite, item.sourceEnd.isFinite, item.duration > 0 else {
                return reject("invalid sentence timestamps")
            }
            guard item.duration <= maxSeconds else {
                return reject("duration \(item.duration)s exceeds \(maxSeconds)s limit")
            }
            guard zip(selected, selected.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
                return reject("unordered sentences")
            }
            item.title = title; item.reason = reason; item.score = score
            item.framing = (entry["framing"] as? String).flatMap(CropRecipe.Kind.init(rawValue:))
                ?? ((entry["rapid_exchange"] as? Bool ?? false) ? .talkerAndPrevious : .talker)
            item.standalone = entry["standalone"] as? Bool
            item = includingQuestion(item, rows: questionContext ?? rows, maxSeconds: maxSeconds, turns: turns, log: log)
            if item.standalone == false, !item.includesQuestion {
                log("Podcast highlights · \(item.title): model says needs context (standalone=false); question not included.")
            }
            return item
        }
    }

    /// Budget includes numbering, timestamps and names; no sentence is split to fit a prompt.
    static func chunks(_ rows: [TranscriptSegment], turns: [SpeakerTurn], names: [String: String]) -> [[TranscriptSegment]] {
        var chunks: [[TranscriptSegment]] = [], current: [TranscriptSegment] = []
        for row in rows {
            let proposed = current + [row]
            if lines(proposed, turns: turns, names: names).count > 12_000 {
                if !current.isEmpty { chunks.append(current) }
                current = lines([row], turns: turns, names: names).count <= 12_000 ? [row] : []
            } else { current = proposed }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func lines(_ rows: [TranscriptSegment], turns: [SpeakerTurn], names: [String: String]) -> String {
        var text = PodcastExchangeSegmenter.speakerLines(rows, turns: turns).joined(separator: "\n")
        for (key, name) in names { text = text.replacingOccurrences(of: "<\(key)>", with: "<\(name)>") }
        return text
    }

    /// One exchange's sentence rows, as they go to the model.
    struct Entry: Sendable {
        var index: Int
        var exchange: PodcastExchange
        var rows: [TranscriptSegment]
        var questionContext: [TranscriptSegment]? = nil
    }

    /// Several long exchanges share one model call while their rows fit the
    /// prompt budget; an exchange too long for one prompt is split on its
    /// own. Row numbering runs through the whole batch.
    static func batches(_ entries: [Entry], turns: [SpeakerTurn], names: [String: String]) -> [[Entry]] {
        var result: [[Entry]] = []
        var current: [Entry] = []
        func size(_ list: [Entry]) -> Int { lines(list.flatMap(\.rows), turns: turns, names: names).count }
        for entry in entries {
            if size([entry]) > 12_000 {
                if !current.isEmpty { result.append(current); current = [] }
                for chunk in chunks(entry.rows, turns: turns, names: names) {
                    result.append([Entry(index: entry.index, exchange: entry.exchange, rows: chunk, questionContext: entry.questionContext ?? entry.rows)])
                }
                continue
            }
            if !current.isEmpty, size(current + [entry]) > 12_000 { result.append(current); current = [] }
            current.append(entry)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The rows of a batch numbered through, with the exchange each range
    /// of numbers belongs to.
    static func batchLines(_ batch: [Entry], turns: [SpeakerTurn], names: [String: String]) -> (header: String, body: String) {
        var offset = 0
        var spans: [String] = []
        for entry in batch {
            let last = offset + entry.rows.count - 1
            spans.append("[\(offset)–\(last)] \(entry.exchange.title)")
            offset += entry.rows.count
        }
        return (spans.joined(separator: " · "), lines(batch.flatMap(\.rows), turns: turns, names: names))
    }

    /// Validates a batch response: every range must sit inside one exchange
    /// of the batch, then passes through the single-exchange rules with
    /// that exchange's local numbering. Returns candidates per batch slot.
    static func validatedBatch(_ raw: [Any], batch: [Entry], maxSeconds: Double, turns: [SpeakerTurn],
                               log: (String) -> Void = { _ in }) -> [[HighlightCandidate]] {
        var offsets: [Int] = []
        var offset = 0
        for entry in batch { offsets.append(offset); offset += entry.rows.count }
        var result = [[HighlightCandidate]](repeating: [], count: batch.count)
        for (position, value) in raw.enumerated() {
            guard var entry = value as? [String: Any],
                  let a = entry["first_sentence"] as? NSNumber, let b = entry["last_sentence"] as? NSNumber,
                  a.doubleValue == Double(a.intValue), b.doubleValue == Double(b.intValue) else {
                log("Podcast highlight rejected · entry \(position + 1): expected an object with sentence indices")
                continue
            }
            guard let slot = batch.indices.first(where: {
                let lower = offsets[$0], upper = offsets[$0] + batch[$0].rows.count - 1
                return a.intValue >= lower && b.intValue <= upper && a.intValue <= b.intValue
            }) else {
                log("Podcast highlight rejected · entry \(position + 1): range \(a.intValue)–\(b.intValue) is not inside one exchange")
                continue
            }
            entry["first_sentence"] = a.intValue - offsets[slot]
            entry["last_sentence"] = b.intValue - offsets[slot]
            result[slot] += validated([entry], exchange: batch[slot].exchange, rows: batch[slot].rows,
                                      maxSeconds: maxSeconds, turns: turns, questionContext: batch[slot].questionContext, log: log)
        }
        return result
    }

    static func describe(_ item: HighlightCandidate) -> String {
        String(format: "“%@” %@–%@ (%.0f s, score %.1f)", item.title, item.sourceStart.timecode,
               item.sourceEnd.timecode, item.duration, item.score)
    }

    static func find(exchanges: [PodcastExchange], segments: [TranscriptSegment], turns: [SpeakerTurn],
                     roster: [VideoPersonRecord], maxSeconds: Double, threshold: Double, maxCount: Int? = nil, highlightFraming: CropRecipe.Kind? = nil,
                     ai: AIService? = nil, model: String? = nil,
                     log: @escaping @Sendable (String) -> Void = { _ in },
                     progress: @Sendable (String, Double) async -> Void = { _, _ in }) async throws -> [HighlightCandidate] {
        let limit = min(120, max(5, maxSeconds))
        let sentences = PodcastExchangeSegmenter.sentenceSegments(segments, turns: turns).sorted { $0.start < $1.start }
        let names = Dictionary(roster.map { ($0.key, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let total = max(1, exchanges.count)
        var found: [HighlightCandidate] = []
        var done = Set<Int>()
        var pending: [Entry] = []
        let cap = maxCount.flatMap { $0 > 0 ? $0 : nil }
        let ranked = exchanges.sorted { $0.score == $1.score ? $0.start < $1.start : $0.score > $1.score }
        var jobs: [[Entry]] = []
        func flushPending() {
            jobs += batches(pending, turns: turns, names: names)
            pending = []
        }
        for (index, exchange) in ranked.enumerated() {
            await progress("Finding highlights · exchange \(index + 1) of \(exchanges.count)", Double(done.count) / Double(total))
            try Task.checkCancellation()
            let rows = sentences.filter { $0.start >= exchange.start && $0.end <= exchange.end }
            guard let whole = candidate(exchange, rows: rows, kind: .whole, turns: turns) else {
                log("Podcast highlights · \(exchange.title): skipped, no sentence rows inside \(exchange.start.timecode)–\(exchange.end.timecode).")
                done.insert(index)
                continue
            }
            let entry = Entry(index: index, exchange: exchange, rows: rows)
            // Exchanges that fit cost no model call, so they never break a
            // batch: they are queued as they come (score order) and every
            // long exchange is batched at the end, still in score order.
            if exchange.end - exchange.start <= limit, whole.duration <= limit {
                jobs.append([entry])
            } else { pending.append(entry) }
        }
        flushPending()
        var callCount = 0
        var loggedCap = false
        let modelJobs = jobs.filter { job in
            job.count > 1 || (job.first.map { $0.exchange.end - $0.exchange.start > limit } ?? false)
        }.count
        for batch in jobs {
            if let cap, resolveOverlaps(found, threshold: threshold).count >= cap {
                log("Podcast highlights: cap reached after \(callCount) calls")
                loggedCap = true
                break
            }
            try Task.checkCancellation()
            if batch.count == 1, let entry = batch.first,
               entry.exchange.end - entry.exchange.start <= limit,
               let whole = candidate(entry.exchange, rows: entry.rows, kind: .whole, turns: turns) {
                let item = includingQuestion(whole, rows: entry.rows, maxSeconds: limit, turns: turns, log: log)
                found.append(item)
                log("Podcast highlights · \(entry.exchange.title): fits whole, \(describe(item))")
                done.insert(entry.index)
                continue
            }
            guard let ai else {
                for entry in batch {
                    if let item = fallback(entry.exchange, rows: entry.rows, maxSeconds: limit, turns: turns,
                                           questionContext: entry.questionContext, log: log) {
                        found.append(item)
                        log("Podcast highlights · \(entry.exchange.title): no provider, first sentence run \(describe(item))")
                    } else { log("Podcast highlights · \(entry.exchange.title): no sentence run fits \(Int(limit)) s.") }
                    done.insert(entry.index)
                }
                continue
            }
            callCount += 1
            let first = batch.first!.index + 1, last = batch.last!.index + 1
            let which = first == last ? "exchange \(first)" : "exchanges \(first)–\(last)"
            await progress("Finding highlights · \(which) of \(exchanges.count) · model call \(callCount) of \(modelJobs)",
                           Double(done.count) / Double(total))
            let numbered = batchLines(batch, turns: turns, names: names)
            let prompt = """
            Find worthwhile, self-contained reels from these podcast exchanges. Rows by exchange: \(numbered.header).
            Select the strongest contiguous sentence run inside a longer answer, with a compelling opening hook.
            Return every worthwhile distinct candidate, no quota. Each range must be <= \(limit) seconds and stay inside one exchange.
            Use inclusive first_sentence and last_sentence indices from the rows. Never invent times or split a sentence.
            Each candidate must make sense to someone who did not hear the rest. Start with the question or the sentence
            that sets up the answer unless the answer is self-explanatory. Include the full question when it fits;
            otherwise include the longest tail of the question that fits, at least its last sentence, without trimming the answer's start.
            Give each a short title, one-line reason, decimal score 0–10, standalone boolean, and rapid_exchange=true only for rapid back-and-forth.
            Choose a framing id for every candidate from:
            \(CropRecipe.Kind.allCases.map { "\($0.rawValue): \($0.summary)" }.joined(separator: "\n"))
            \(highlightFraming.map { "Use the requested framing \($0.rawValue) for every candidate." } ?? "Choose the best framing for the exchange.")
            Score rubric: 10 = must post, 8–9 = strong, 7 = worth posting, below 7 = skip.
            Scores must not all be identical: distinguish candidates using the rubric and decimal precision.
            Return only JSON: {"highlights":[{"first_sentence":0,"last_sentence":1,"title":"...","reason":"...","score":8.4,"standalone":true,"rapid_exchange":false,"framing":"talker"}]}.
            An empty highlights array is valid when nothing is worthwhile.

            \(numbered.body)
            """
            var perSlot: [[HighlightCandidate]]?
            do {
                let response = try await ai.call(prompt: prompt, task: "highlights", model: model, timeout: 240, log: log).text
                if let raw = AIResponseParser.jsonObject(from: response)?["highlights"] as? [Any] {
                    logScores(raw, log: log)
                    perSlot = validatedBatch(raw, batch: batch, maxSeconds: limit, turns: turns, log: log)
                } else {
                    log("Podcast highlights response rejected: expected a highlights array.")
                }
            } catch is CancellationError { throw CancellationError() }
            catch { log("Podcast highlights AI call failed: \(error)") }
            // Nothing usable from the call: every exchange in it takes the
            // sentence-safe fallback. A valid answer that names no run for
            // an exchange means the model found nothing worthwhile there.
            let usable = perSlot?.contains { !$0.isEmpty } ?? false
            for (slot, entry) in batch.enumerated() {
                let items = usable ? perSlot![slot] : []
                if !items.isEmpty {
                    found += items
                    log("Podcast highlights · \(entry.exchange.title): \(items.count) candidate\(items.count == 1 ? "" : "s") — "
                        + items.map(describe).joined(separator: "; "))
                } else if !usable, let item = fallback(entry.exchange, rows: entry.rows, maxSeconds: limit, turns: turns,
                                                     questionContext: entry.questionContext, log: log) {
                    found.append(item)
                    log("Podcast highlights · \(entry.exchange.title): model gave nothing usable, first sentence run \(describe(item))")
                } else {
                    log("Podcast highlights · \(entry.exchange.title): no candidates.")
                }
                done.insert(entry.index)
            }
        }
        let eligible = found.filter { $0.score >= threshold }
        let nonoverlapping = resolveOverlaps(found, threshold: threshold)
        let kept = cap.map { Array(nonoverlapping.prefix($0)) } ?? nonoverlapping
        if let cap, kept.count >= cap, !loggedCap {
            log("Podcast highlights: cap reached after \(callCount) calls")
        }
        await progress("Finding highlights · done", 1)
        log("Podcast highlights: \(found.count) candidates found; \(found.count - eligible.count) below threshold; \(eligible.count - nonoverlapping.count) dropped for overlap; \(nonoverlapping.count - kept.count) above cap; \(kept.count) kept.")
        return kept.map { candidate in
            var candidate = candidate
            if let highlightFraming { candidate.framing = highlightFraming }
            return candidate
        }
    }
}
