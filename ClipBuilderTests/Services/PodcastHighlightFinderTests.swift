import Foundation
import Testing
import Synchronization
@testable import Clip_Builder

@Suite("Podcast highlight finder")
struct PodcastHighlightFinderTests {
    private var rows: [TranscriptSegment] {
        (0..<8).map { index in
            let start = Double(index * 5)
            return TranscriptSegment(start: start, end: start + 5, text: "Sentence \(index).",
                words: [.init(word: "Sentence", start: start, end: start + 2),
                        .init(word: "\(index).", start: start + 2, end: start + 5)])
        }
    }
    private func exchange(end: Double = 40, score: Double = 8) -> PodcastExchange {
        PodcastExchange(start: 0, end: end, title: "A surprising lesson", summary: "A quotable answer.", score: score, speakerKeys: [])
    }

    @Test func wholeExchangeNeedsNoAI() async throws {
        let stub = try StubAI(response: "invalid")
        let found = try await PodcastHighlightFinder.find(exchanges: [exchange(end: 20)], segments: rows,
            turns: [], roster: [], maxSeconds: 30, threshold: 7, ai: stub.service)
        #expect(found.count == 1)
        #expect(found.first?.kind == .whole)
        #expect(found.first?.sourceStart == 0 && found.first?.sourceEnd == 20)
        #expect(!FileManager.default.fileExists(atPath: stub.calls.path))
    }

    @Test func longExchangeFallsBackAtSentenceEnds() async throws {
        let found = try await PodcastHighlightFinder.find(exchanges: [exchange()], segments: rows,
            turns: [], roster: [], maxSeconds: 12, threshold: 7)
        #expect(found.count == 1)
        #expect(found.first?.kind == .subcut)
        #expect(found.first?.sourceStart == 0 && found.first?.sourceEnd == 10)
    }

    @Test func modelChoosesStrongRunAndRapidFraming() async throws {
        let stub = try StubAI(response: #"{"highlights":[{"first_sentence":3,"last_sentence":4,"title":"The turning point","reason":"A strong hook.","score":9,"rapid_exchange":true}]}"#)
        let statuses = Mutex<[String]>([])
        let found = try await PodcastHighlightFinder.find(exchanges: [exchange()], segments: rows,
            turns: [], roster: [], maxSeconds: 12, threshold: 7, ai: stub.service,
            progress: { message, _ in statuses.withLock { $0.append(message) } })
        #expect(statuses.withLock { $0 }.contains("Finding highlights · exchange 1 of 1 · model call 1 of 1"))
        #expect(statuses.withLock { $0.last } == "Finding highlights · done")
        #expect(found.count == 1)
        #expect(found.first?.sourceStart == 15 && found.first?.sourceEnd == 25)
        #expect(found.first?.framing == .talkerAndPrevious)
        #expect(found.first?.title == "The turning point")
        let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
        #expect(prompt.contains("[3]") && prompt.contains("12.0"))
    }

    @Test func belowThresholdDroppedAndEmptyAIResultFallsBack() async throws {
        let found = try await PodcastHighlightFinder.find(exchanges: [exchange(end: 20, score: 6.9)], segments: rows,
            turns: [], roster: [], maxSeconds: 30, threshold: 7)
        #expect(found.isEmpty)
        let stub = try StubAI(response: #"{"highlights":[]}"#)
        let empty = try await PodcastHighlightFinder.find(exchanges: [exchange()], segments: rows,
            turns: [], roster: [], maxSeconds: 10, threshold: 7, ai: stub.service)
        #expect(empty.count == 1 && empty.first?.sourceEnd == 10)
    }

    @Test func malformedAndOverlongRangesRejected() {
        let valid: [String: Any] = ["first_sentence": 1, "last_sentence": 2, "title": "Title", "reason": "Reason", "score": 8.0]
        for (key, value) in [("first_sentence", -1 as Any), ("last_sentence", 20 as Any), ("first_sentence", 1.5 as Any),
                             ("score", 11 as Any), ("score", "8" as Any)] {
            var bad = valid; bad[key] = value
            var logs: [String] = []
            let result = PodcastHighlightFinder.validated([bad, valid], exchange: exchange(), rows: rows,
                maxSeconds: 12, turns: [], log: { logs.append($0) })
            #expect(result.count == 1 && result.first?.framing == .talker)
            #expect(logs.filter { $0.contains("rejected") }.count == 1)
        }
        #expect(PodcastHighlightFinder.validated([valid], exchange: exchange(), rows: rows, maxSeconds: 9.9, turns: []).isEmpty)
    }

    @Test func fourValidEntriesSurviveOneOverLimitEntry() async throws {
        let entries: [[String: Any]] = [0, 2, 4, 6, 1].map { first in
            ["first_sentence": first, "last_sentence": first == 1 ? 3 : first + 1,
             "title": "Choice \(first)", "reason": "Strong answer", "score": 8]
        }
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["highlights": entries]), as: UTF8.self)
        let stub = try StubAI(response: response)
        let logs = Mutex<[String]>([])
        let found = try await PodcastHighlightFinder.find(exchanges: [exchange()], segments: rows,
            turns: [], roster: [], maxSeconds: 14.9, threshold: 7, ai: stub.service,
            log: { message in logs.withLock { $0.append(message) } })
        #expect(found.count == 4)
        #expect(found.allSatisfy { $0.framing == .talker && $0.title.hasPrefix("Choice") })
        let messages = logs.withLock { $0 }
        #expect(messages.filter { $0.contains("rejected") }.count == 1)
        #expect(messages.contains { $0.contains("exceeds 14.9s") })
        #expect(!messages.contains { $0.contains("fallback") || $0.contains("AI unavailable") })
    }

    @Test func logsExchangeWithoutContainedSentencesAndReportsProgress() async throws {
        let logs = Mutex<[String]>([])
        let statuses = Mutex<[String]>([])
        var cut = exchange(end: 9)
        cut.start = 1
        let found = try await PodcastHighlightFinder.find(exchanges: [cut, exchange(end: 10)],
            segments: [.init(start: 0, end: 10, text: "One complete sentence.", words: nil)],
            turns: [], roster: [], maxSeconds: 10, threshold: 7,
            log: { message in logs.withLock { $0.append(message) } },
            progress: { message, _ in statuses.withLock { $0.append(message) } })
        #expect(found.count == 1)
        #expect(logs.withLock { $0.contains { $0.contains("skipped") && $0.contains("no sentence rows") } })
        #expect(statuses.withLock { $0 } == ["Finding highlights · exchange 1 of 2", "Finding highlights · exchange 2 of 2", "Finding highlights · done"])
    }

    @Test func severalLongExchangesShareOneCallAndRangesMapBack() async throws {
        // Two 40 s exchanges over the same 8 rows each (rows 0–7 then 8–15 in the prompt).
        let second = (0..<8).map { index -> TranscriptSegment in
            let start = 40 + Double(index * 5)
            return TranscriptSegment(start: start, end: start + 5, text: "Later \(index).",
                words: [.init(word: "Later", start: start, end: start + 2), .init(word: "\(index).", start: start + 2, end: start + 5)])
        }
        var late = exchange(); late.start = 40; late.end = 80; late.title = "The second lesson"
        let stub = try StubAI(response: #"{"highlights":[{"first_sentence":1,"last_sentence":2,"title":"Early","reason":"Hook","score":8},{"first_sentence":9,"last_sentence":10,"title":"Late","reason":"Hook","score":9},{"first_sentence":6,"last_sentence":9,"title":"Crossing","reason":"Bad","score":9}]}"#)
        let logs = Mutex<[String]>([])
        let found = try await PodcastHighlightFinder.find(exchanges: [exchange(), late], segments: rows + second,
            turns: [], roster: [], maxSeconds: 12, threshold: 7, ai: stub.service,
            log: { message in logs.withLock { $0.append(message) } })
        let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
        #expect(prompt.components(separatedBy: "Find worthwhile").count == 2, "one model call for both exchanges")
        #expect(prompt.contains("[0–7] A surprising lesson · [8–15] The second lesson"))
        #expect(found.map(\.title).sorted() == ["Early", "Late"])
        #expect(found.first { $0.title == "Late" }?.sourceStart == 45 && found.first { $0.title == "Late" }?.sourceEnd == 55)
        let messages = logs.withLock { $0 }
        #expect(messages.contains { $0.contains("not inside one exchange") })
        #expect(messages.contains { $0.contains("The second lesson: 1 candidate") })
    }

    @Test func wholeExchangesBetweenLongOnesDoNotSplitTheBatch() async throws {
        // Score order interleaves a fitting exchange between two long ones; both long ones still share one call.
        let second = (0..<8).map { index -> TranscriptSegment in
            let start = 100 + Double(index * 5)
            return TranscriptSegment(start: start, end: start + 5, text: "Later \(index).",
                words: [.init(word: "Later", start: start, end: start + 2), .init(word: "\(index).", start: start + 2, end: start + 5)])
        }
        let fitting = TranscriptSegment(start: 60, end: 68, text: "Short answer.", words: [.init(word: "Short", start: 60, end: 64), .init(word: "answer.", start: 64, end: 68)])
        var late = exchange(score: 8); late.start = 100; late.end = 140; late.title = "The second lesson"
        var short = exchange(end: 68, score: 8.5); short.start = 60; short.title = "Short one"
        let stub = try StubAI(response: #"{"highlights":[{"first_sentence":0,"last_sentence":1,"title":"Early","reason":"Hook","score":8},{"first_sentence":8,"last_sentence":9,"title":"Late","reason":"Hook","score":8.2}]}"#)
        let found = try await PodcastHighlightFinder.find(exchanges: [exchange(score: 9), short, late], segments: rows + [fitting] + second,
            turns: [], roster: [], maxSeconds: 12, threshold: 7, ai: stub.service)
        let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
        #expect(prompt.components(separatedBy: "Find worthwhile").count == 2, "one model call for both long exchanges")
        #expect(found.map(\.title).sorted() == ["Early", "Late", "Short one"])
    }

    @Test func overlapsPreferScoreThenEarlierWithoutCap() {
        func item(_ start: Double, _ end: Double, _ score: Double) -> HighlightCandidate {
            HighlightCandidate(sourceStart: start, sourceEnd: end, title: "Test", reason: "Test", score: score, kind: .whole, speakerKeys: [])
        }
        let found = PodcastHighlightFinder.resolveOverlaps([
            item(5, 15, 9), item(0, 10, 8), item(20, 25, 8), item(18, 23, 8), item(15, 18, 7), item(40, 45, 6)
        ], threshold: 7)
        #expect(found.map(\.sourceStart) == [5, 18, 15])
        let many = (0..<40).map { item(Double($0 * 5), Double($0 * 5 + 5), 8) }
        #expect(PodcastHighlightFinder.resolveOverlaps(many, threshold: 7).count == 40)
    }

    @Test func promptChunksRespectBudgetIncludingSpeakerNames() {
        let long = (0..<200).map { TranscriptSegment(start: Double($0), end: Double($0 + 1), text: String(repeating: "word ", count: 80), words: nil) }
        let chunks = PodcastHighlightFinder.chunks(long, turns: [], names: [:])
        #expect(chunks.count > 1)
        #expect(chunks.flatMap { $0 }.count == long.count)
        #expect(chunks.allSatisfy { PodcastHighlightFinder.lines($0, turns: [], names: [:]).count <= 12_000 })
    }
}

extension PodcastHighlightFinderTests {
    private var questionTurns: [SpeakerTurn] {
        [.init(videoID: 1, start: 0, end: 15, cluster: 0, confidence: 1),
         .init(videoID: 1, start: 15, end: 40, cluster: 1, confidence: 1)]
    }

    @Test func questionExtensionUsesFullQuestionThenLongestTailThenLeavesAnswer() throws {
        let raw: [[String: Any]] = [["first_sentence": 3, "last_sentence": 4, "score": 8.7, "title": "Answer", "reason": "Useful"]]
        for (limit, start, flag) in [(30.0, 0.0, true), (20, 5, true), (15, 10, true), (12, 15, false)] {
            var logs: [String] = []
            let item = try #require(PodcastHighlightFinder.validated(raw, exchange: exchange(), rows: rows,
                maxSeconds: limit, turns: questionTurns, log: { logs.append($0) }).first)
            #expect(item.sourceStart == start && item.sourceEnd == 25)
            #expect(item.includesQuestion == flag)
            #expect(item.duration <= limit)
            #expect(logs.contains { $0.contains("question does not fit") } == !flag)
        }
    }

    @Test func questionWithoutTurnsUsesOnlyFirstSentenceAndFallbackMarksIt() throws {
        #expect(PodcastHighlightFinder.questionRows(rows, turns: []).count == 1)
        let item = try #require(PodcastHighlightFinder.fallback(exchange(), rows: rows, maxSeconds: 10, turns: []))
        #expect(item.includesQuestion && item.sourceStart == 0)
        let whole = try #require(PodcastHighlightFinder.candidate(exchange(), rows: rows, kind: .whole, turns: []))
        #expect(PodcastHighlightFinder.includingQuestion(whole, rows: rows, maxSeconds: 40, turns: []).includesQuestion)
    }

    @Test func partialQuestionSentenceIsIncludedAndExtendedWhenItFits() throws {
        var candidate = try #require(PodcastHighlightFinder.candidate(exchange(), rows: Array(rows[2...4]), kind: .subcut, turns: questionTurns))
        candidate.sourceStart = 12
        let repaired = PodcastHighlightFinder.includingQuestion(candidate, rows: rows, maxSeconds: 15, turns: questionTurns)
        #expect(repaired.includesQuestion && repaired.sourceStart == 10 && repaired.sourceEnd == 25)
        let partial = PodcastHighlightFinder.includingQuestion(candidate, rows: rows, maxSeconds: 13, turns: questionTurns)
        #expect(partial.includesQuestion && partial.sourceStart == 12 && partial.duration == 13)
    }

    @Test func fallbackInsideLongQuestionIsIncluded() throws {
        let item = try #require(PodcastHighlightFinder.fallback(exchange(), rows: rows, maxSeconds: 10, turns: questionTurns))
        #expect(item.sourceStart == 0 && item.sourceEnd == 10 && item.includesQuestion)
        let later = try #require(PodcastHighlightFinder.fallback(exchange(), rows: Array(rows[1...]), maxSeconds: 5,
            turns: questionTurns, questionContext: rows))
        #expect(later.sourceStart == 5 && later.sourceEnd == 10 && later.includesQuestion)
    }

    @Test func standaloneAssessmentIsPreservedAndMissingContextIsLogged() throws {
        let raw: [String: Any] = ["first_sentence": 3, "last_sentence": 4, "score": 8.7, "title": "Answer", "reason": "Useful"]
        for assessment in [nil, true, false] as [Bool?] {
            var entry = raw
            entry["standalone"] = assessment
            var logs: [String] = []
            let item = try #require(PodcastHighlightFinder.validated([entry], exchange: exchange(), rows: rows,
                maxSeconds: 10, turns: questionTurns, log: { logs.append($0) }).first)
            #expect(item.standalone == assessment && !item.includesQuestion)
            #expect(logs.contains { $0.contains("standalone=false") } == (assessment == false))
        }
        var entry = raw
        entry["standalone"] = false
        var logs: [String] = []
        let repaired = try #require(PodcastHighlightFinder.validated([entry], exchange: exchange(), rows: rows,
            maxSeconds: 30, turns: questionTurns, log: { logs.append($0) }).first)
        #expect(repaired.standalone == false && repaired.includesQuestion)
        #expect(!logs.contains { $0.contains("standalone=false") })
        entry["standalone"] = "maybe"
        #expect(PodcastHighlightFinder.validated([entry], exchange: exchange(), rows: rows, maxSeconds: 30, turns: questionTurns).isEmpty)
    }

    @Test func laterChunkUsesOriginalQuestionAndNeverInventsOne() throws {
        let batch = [PodcastHighlightFinder.Entry(index: 0, exchange: exchange(), rows: Array(rows[3...]), questionContext: rows)]
        let raw: [[String: Any]] = [["first_sentence": 0, "last_sentence": 1, "score": 8.3, "title": "Answer", "reason": "Useful"]]
        let item = try #require(PodcastHighlightFinder.validatedBatch(raw, batch: batch, maxSeconds: 20, turns: questionTurns).first?.first)
        #expect(item.sourceStart == 5 && item.sourceEnd == 25 && item.includesQuestion)
        var logs: [String] = []
        let fallback = try #require(PodcastHighlightFinder.fallback(exchange(), rows: Array(rows[3...]), maxSeconds: 10,
            turns: questionTurns, questionContext: rows, log: { logs.append($0) }))
        #expect(fallback.sourceStart == 15 && !fallback.includesQuestion)
        #expect(logs.contains { $0.contains("question does not fit") })
    }

    @Test func rawScoreDistributionAndFlatScoresAreLogged() {
        var logs: [String] = []
        PodcastHighlightFinder.logScores([["score": 7.0], ["score": 9.0], ["score": 8.0], ["score": 8.4]], log: { logs.append($0) })
        #expect(logs.first == "Podcast highlights raw scores: min=7.0 median=8.2 max=9.0 count=4")
        PodcastHighlightFinder.logScores([["score": 7.0], ["score": 7.0]], log: { logs.append($0) })
        #expect(logs.contains { $0.contains("flat scores") })
    }

    @Test(arguments: [2, 3])
    func capStopsCallsAfterEligibleNonoverlappingCandidatesAndUsesScoreOrder(_ cap: Int) async throws {
        // Each exchange fills a separate prompt. Lower-ranked exchanges must never be requested.
        let segments = (0..<12).map { index in
            TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 10),
                              text: String(repeating: "context ", count: 350) + ".", words: nil)
        }
        let exchanges: [PodcastExchange] = (0..<3).map { index in
            let start = Double(index) * 40
            return PodcastExchange(start: start, end: start + 40,
                title: "Exchange \(index)", summary: "Answer", score: 7 + Double(index), speakerKeys: [])
        }
        let stub = try StubAI(response: #"{"highlights":[{"first_sentence":0,"last_sentence":0,"title":"Best","reason":"Useful","score":9.4},{"first_sentence":0,"last_sentence":0,"title":"Duplicate","reason":"Overlap","score":8.4},{"first_sentence":1,"last_sentence":1,"title":"Weak","reason":"Skip","score":6.0},{"first_sentence":2,"last_sentence":2,"title":"Second","reason":"Useful","score":8.2}]}"#)
        let logs = Mutex<[String]>([])
        let found = try await PodcastHighlightFinder.find(exchanges: exchanges, segments: segments, turns: [], roster: [],
            maxSeconds: 10, threshold: 7, maxCount: cap, ai: stub.service,
            log: { message in logs.withLock { $0.append(message) } })
        #expect(found.map(\.title) == (cap == 2 ? ["Best", "Second"] : ["Best", "Best", "Second"]))
        #expect(found.map(\.sourceStart) == (cap == 2 ? [80, 100] : [40, 80, 60]))
        let calls = cap == 2 ? 1 : 2
        #expect(try String(contentsOf: stub.calls, encoding: .utf8) == String(repeating: "call\n", count: calls))
        #expect(logs.withLock { $0.contains { $0.contains("cap reached after \(calls) calls") } })
        let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
        #expect(prompt.contains("Exchange 2") && !prompt.contains("Exchange 0"))
        #expect(prompt.contains("10 = must post, 8–9 = strong, 7 = worth posting, below 7 = skip"))
        #expect(prompt.contains("decimal score") && prompt.contains("standalone") && prompt.contains("did not hear the rest"))
    }

    @Test func wholeCandidatesReachCapWithoutCallsAndZeroMeansUnlimited() async throws {
        let exchanges = (0..<4).map { index in
            PodcastExchange(start: Double(index * 5), end: Double(index * 5 + 5),
                title: "\(index)", summary: "Useful", score: 8, speakerKeys: [])
        }
        let stub = try StubAI(response: "{}")
        let capped = try await PodcastHighlightFinder.find(exchanges: exchanges.reversed(), segments: rows, turns: [], roster: [],
            maxSeconds: 10, threshold: 7, maxCount: 2, ai: stub.service)
        #expect(capped.map(\.sourceStart) == [0, 5])
        #expect(!FileManager.default.fileExists(atPath: stub.calls.path))
        let all = try await PodcastHighlightFinder.find(exchanges: exchanges, segments: rows, turns: [], roster: [],
            maxSeconds: 10, threshold: 7, maxCount: 0)
        #expect(all.count == 4)
    }

    @Test func fixedFramingOverridesWholeFallbackAndRapidModelCandidates() async throws {
        let response = #"{"highlights":[{"first_sentence":2,"last_sentence":3,"title":"Choice","reason":"Hook","score":9,"rapid_exchange":true,"framing":"talker"}]}"#
        for kind in CropRecipe.Kind.allCases {
            for mode in 0..<3 {
                let stub = try StubAI(response: mode == 2 ? "invalid" : response)
                let found = try await PodcastHighlightFinder.find(exchanges: [exchange(end: mode == 0 ? 20 : 40)],
                    segments: rows, turns: [], roster: [], maxSeconds: 20, threshold: 7,
                    highlightFraming: kind, ai: stub.service)
                #expect(!found.isEmpty && found.allSatisfy { $0.framing == kind })
            }
        }
    }

    @Test func aiFramingIDsAreValidatedWithRapidFallback() async throws {
        for kind in CropRecipe.Kind.allCases {
            let stub = try StubAI(response: """
            {"highlights":[{"first_sentence":2,"last_sentence":3,"title":"Choice","reason":"Hook","score":9,"rapid_exchange":true,"framing":"\(kind.rawValue)"}]}
            """)
            let found = try await PodcastHighlightFinder.find(exchanges: [exchange()], segments: rows,
                turns: [], roster: [], maxSeconds: 12, threshold: 7, ai: stub.service)
            #expect(found.first?.framing == kind)
            // The stub records the prompt inside a JSON envelope, where "/" is escaped.
            let prompt = try String(contentsOf: stub.prompts, encoding: .utf8).replacingOccurrences(of: "\\/", with: "/")
            let missing = CropRecipe.Kind.allCases.filter { !prompt.contains($0.rawValue + ": " + $0.summary) }
            #expect(missing.isEmpty, "missing \(missing.map(\.rawValue))")
        }
        for rapid in [false, true] {
            let raw: [String: Any] = ["first_sentence": 2, "last_sentence": 3, "title": "Choice", "reason": "Hook",
                                       "score": 9, "rapid_exchange": rapid, "framing": "unknown"]
            let found = PodcastHighlightFinder.validated([raw], exchange: exchange(), rows: rows, maxSeconds: 12, turns: [])
            #expect(found.first?.framing == (rapid ? .talkerAndPrevious : .talker))
        }
    }

}
