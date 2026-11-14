import Foundation
import Testing
@testable import Clip_Builder

struct TranscriptWordRulesTests {
    private func row(_ text: String, words: [TranscriptWord]?, id: Int64 = 1, translated: Bool = false, start: Double = 0) -> TranscriptRow {
        let json = words.map { String(decoding: try! JSONEncoder().encode($0), as: UTF8.self) }
        return TranscriptRow(id: id, videoID: 1, language: "pt", isTranslation: translated,
            startTime: start, endTime: start + 10, text: text, originalText: nil, wordsJSON: json, provider: nil, model: nil)
    }

    private func word(_ text: String, _ at: Double, confidence: Double? = nil, suggestion: String? = nil) -> TranscriptWord {
        TranscriptWord(word: text, start: at, end: at + 0.5, confidence: confidence,
                       suggestion: suggestion.map { .init(to: $0, reason: "heard wrong") })
    }

    @Test func oldWordsJSONDecodesWithoutMarksAndNewFieldsRoundTrip() throws {
        let old = try JSONDecoder().decode([TranscriptWord].self, from: Data(#"[{"word":"oi","start":0,"end":1}]"#.utf8))
        #expect(old == [TranscriptWord(word: "oi", start: 0, end: 1)])
        let marked = [word("oi", 0, confidence: 0.2, suggestion: "olá")]
        #expect(try JSONDecoder().decode([TranscriptWord].self, from: JSONEncoder().encode(marked)) == marked)
        // Nothing is written for a word without marks: old clients read the same JSON as before.
        #expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("confidence"))
    }

    @Test func doubtfulIsLowConfidenceOrSuggestedAndNeverMarkedRight() {
        let line = row("Peace Rpper, tá? Kemuel aqui", words: [
            word("Peace", 0, confidence: 0.9), word(" Rpper,", 1, confidence: 0.8, suggestion: "Grappler"),
            word("tá?", 2), word("Kemuel", 3, confidence: 0.3), word("aqui", 4, confidence: 1, suggestion: "ali")])
        let doubts = TranscriptWordRules.doubts(in: line)
        #expect(doubts.map(\.id.index) == [1, 3])
        #expect(doubts.map(\.text) == ["Rpper,", "Kemuel"])
        #expect(doubts[0].suggestion?.to == "Grappler" && doubts[1].suggestion == nil)
        #expect(!TranscriptWordRules.isDoubtful(word("x", 0, confidence: 0.5)))
    }

    @Test func linesWhoseWordsDoNotLineUpWithTheirTextHaveNoMarks() {
        let low = [word("um", 0, confidence: 0.1), word("dois", 1, confidence: 0.1)]
        #expect(TranscriptWordRules.doubts(in: row("um dois três", words: low)).isEmpty)
        #expect(TranscriptWordRules.doubts(in: row("um três", words: low)).isEmpty)
        #expect(TranscriptWordRules.doubts(in: row("um dois", words: nil)).isEmpty)
        #expect(TranscriptWordRules.doubts(in: row("um dois", words: low, translated: true)).isEmpty)
        #expect(TranscriptWordRules.doubts(in: row("Um, DOIS!", words: low)).count == 2)
    }

    @Test func doubtsAcrossLinesAreInTranscriptOrder() {
        let later = row("b", words: [word("b", 20, confidence: 0.1)], id: 1, start: 20)
        let earlier = row("a", words: [word("a", 5, confidence: 0.1)], id: 2, start: 5)
        #expect(TranscriptWordRules.doubts(in: [later, earlier]).map(\.id.rowID) == [2, 1])
    }

    @Test func fixKeepsPunctuationAndAnEmptyFixRemovesTheToken() {
        #expect(TranscriptWordRules.parts("“Rpper,”").core == "Rpper")
        #expect(TranscriptWordRules.replacement(for: "“Rpper,”", with: " Peace  Grappler ") == "“Peace Grappler,”")
        #expect(TranscriptWordRules.replacement(for: "um,", with: "  ") == "")
        #expect(TranscriptWordRules.replacing(text: "na Peace Rpper, tá?", fixes: [2: "Grappler,", 3: ""]) == "na Peace Grappler,")
        #expect(TranscriptWordRules.replacing(text: "a  b\nc", fixes: [:]) == "a  b\nc")
    }

    @Test func markRightNeedsTheExpectedWordAndClearsTheSuggestion() {
        let words = [word("Rpper,", 0, confidence: 0.2, suggestion: "Grappler"), word("tá", 1)]
        let confirmed = TranscriptWordRules.confirming([0: "Rpper,"], words: words)
        #expect(confirmed?[0].confidence == 1 && confirmed?[0].suggestion == nil)
        #expect(confirmed.map { TranscriptWordRules.isDoubtful($0[0]) } == false)
        #expect(TranscriptWordRules.confirming([0: "Outra"], words: words) == nil)
        #expect(TranscriptWordRules.confirming([5: "tá"], words: words) == nil)
    }

    @Test func anEditKeepsMarksOnUntouchedWordsOnly() {
        // The originals still call "Kemuel" doubtful and suggest for "Rpper"; since then the user
        // marked Kemuel right and Proofread flagged "aqui".
        let original = [word("Peace", 0), word("Rpper", 1, suggestion: "Grappler"), word("Kemuel", 2, confidence: 0.3), word("aqui", 3)]
        var current = original
        current[2].confidence = 1
        current[3].suggestion = .init(to: "ali", reason: "context")
        let text = "Peace Grappler Kemuel aqui"
        let realigned = TranscriptWordAlignment.realign(text: text, original: original, start: 0, end: 4)
        let words = TranscriptWordRules.carryingMarks(from: current, onto: realigned)
        #expect(words?.map(\.word) == ["Peace", "Grappler", "Kemuel", "aqui"])
        #expect(words?[1].suggestion == nil && words?[1].confidence == nil)
        #expect(words?[2].confidence == 1)
        #expect(words?[3].suggestion?.to == "ali")
        #expect(TranscriptWordRules.carryingMarks(from: nil, onto: realigned) == realigned)
    }

    @Test func aSecondProofreadReplacesTheFirstAndSkipsMovedOrConfirmedWords() {
        let words = [word("Rpper", 0, suggestion: "old"), word("Kemuel", 1, confidence: 1), word("aqui", 2, suggestion: "kept")]
        let result = TranscriptWordRules.suggesting(
            [0: ("Outra", .init(to: "x", reason: "r")), 1: ("Kemuel", .init(to: "Samuel", reason: "r"))],
            covered: [0, 1], words: words)
        #expect(result.count == 0)
        #expect(result.words[0].suggestion == nil && result.words[1].suggestion == nil)
        #expect(result.words[2].suggestion?.to == "kept")
        let second = TranscriptWordRules.suggesting([0: ("Rpper", .init(to: "Grappler", reason: "name"))], covered: [0], words: words)
        #expect(second.count == 1 && second.words[0].suggestion?.to == "Grappler")
    }

    @Test func proofreadLeavesALineEditedWhileItWasOut() {
        // Proofread read "cat cat"; the first one was deleted meanwhile.
        let words = [word("cat", 1, suggestion: "old")]
        let result = TranscriptWordRules.suggesting([0: ("cat", .init(to: "cap", reason: "r"))],
            covered: [0, 1], read: [0: "0|cat", 1: "1000|cat"], words: words)
        #expect(result.count == 0 && result.words == words)
        let same = TranscriptWordRules.suggesting([0: ("cat", .init(to: "cap", reason: "r"))],
            covered: [0], read: [0: "1000|cat"], words: words)
        #expect(same.count == 1 && same.words[0].suggestion?.to == "cap")
    }

    @Test func aFixedLineKeepsEachRepeatedWordsOwnClock() {
        let current = [word("cat", 0), word("cat", 1), word("dog", 2)]
        let keeping = TranscriptWordRules.keptPositions(tokenCount: 3, fixes: [0: ""])
        let words = TranscriptWordAlignment.realign(text: "cat dog", original: current, start: 0, end: 3, known: keeping)
        #expect(words?.map(\.start) == [1, 2])
    }

    @Test func aTokenOfTheFixedTextNamesTheStoredWordItCameFrom() {
        // "cat cat dog" with the first cat removed and dog split in two: "cat big fog".
        let fixes = [0: "", 2: "big fog"]
        #expect(TranscriptWordRules.origin(of: 0, tokenCount: 3, fixes: fixes).map { [$0.position, $0.offset] } == [1, 0])
        #expect(TranscriptWordRules.origin(of: 2, tokenCount: 3, fixes: fixes).map { [$0.position, $0.offset] } == [2, 1])
        #expect(TranscriptWordRules.origin(of: 3, tokenCount: 3, fixes: fixes) == nil)
    }

    @Test func aFixNeverDoublesPunctuationTheReplacementAlreadyHas() {
        #expect(TranscriptWordRules.replacement(for: "Rpper,", with: "Grappler,") == "Grappler,")
        #expect(TranscriptWordRules.replacement(for: "“Rpper,”", with: "“Grappler") == "“Grappler,”")
        #expect(TranscriptWordRules.strippingPunctuation(of: "Rpper,", from: "Grappler,") == "Grappler")
        #expect(TranscriptWordRules.strippingPunctuation(of: "us", from: "U.S.") == "U.S.")
    }

    @Test func wordFixesCarryMarksByPositionSoARepeatedWordIsTheRightOne() {
        // "cat cat": the first is deleted, the second was marked right.
        let current = [word("cat", 0, confidence: 0.2), word("cat", 1, confidence: 1)]
        let keeping = TranscriptWordRules.keptPositions(tokenCount: 2, fixes: [0: ""])
        #expect(keeping == [0: 1])
        let carried = TranscriptWordRules.carryingMarks(from: current, onto: [word("cat", 1)], keeping: keeping)
        #expect(carried?.first?.confidence == 1)
        // A fix that becomes two words moves what follows it by one.
        #expect(TranscriptWordRules.keptPositions(tokenCount: 3, fixes: [1: "Peace Grappler,"]) == [0: 0, 3: 2])
    }

    @Test func marksSurviveTheTranscribersRowsComingBackOverARecut() {
        let recut = [word("Peace", 0, confidence: 1), word("Rpper", 1, confidence: 0.8, suggestion: "Grappler"), word("novo", 2)]
        let backup = [word("Peace", 0, confidence: 0.3), word("Rpper", 1, confidence: 0.8), word("outro", 2, confidence: 0.4)]
        let restored = TranscriptWordRules.carryingMarks(fromRecut: recut, onto: backup)
        #expect(restored[0].confidence == 1)
        #expect(restored[1].suggestion?.to == "Grappler")
        #expect(restored[2] == backup[2])
    }

    @Test func listenRangeStaysInsideTheFile() {
        #expect(TranscriptWordRules.listenRange(start: 0.4, end: 0.9, duration: 60) == 0...1.9)
        #expect(TranscriptWordRules.listenRange(start: 59.5, end: 59.9, duration: 60) == 58.5...60)
    }
}

struct TranscriptSearchRulesTests {
    @Test func findsEveryOccurrenceIgnoringCaseAndAccents() {
        let text = "Patrocínios e PATROCINIOS, patrocinio"
        #expect(TranscriptSearchRules.ranges(of: " patrocinios ", in: text).map { String(text[$0]) } == ["Patrocínios", "PATROCINIOS"])
        #expect(TranscriptSearchRules.ranges(of: "  ", in: text).isEmpty)
        #expect(TranscriptSearchRules.ranges(of: "aa", in: "aaaa").count == 2)
    }

    @Test func matchesFollowLinesThenTheTextsUnderEachLine() {
        let lines = [TranscriptSearchRules.Line(id: 1, texts: [(1, "atletas e atletas"), (10, "athletes")]),
                     TranscriptSearchRules.Line(id: 2, texts: [(2, "nada"), (20, "os atletas")])]
        let matches = TranscriptSearchRules.matches(query: "atletas", lines: lines)
        #expect(matches == [.init(lineID: 1, rowID: 1, ordinal: 0), .init(lineID: 1, rowID: 1, ordinal: 1),
                            .init(lineID: 2, rowID: 20, ordinal: 0)])
        #expect(TranscriptSearchRules.matches(query: "", lines: lines).isEmpty)
    }

    @Test func steppingWrapsAndStartsAtTheNearEnd() {
        #expect(TranscriptSearchRules.step(from: nil, count: 3, forward: true) == 0)
        #expect(TranscriptSearchRules.step(from: nil, count: 3, forward: false) == 2)
        #expect(TranscriptSearchRules.step(from: 2, count: 3, forward: true) == 0)
        #expect(TranscriptSearchRules.step(from: 0, count: 3, forward: false) == 2)
        #expect(TranscriptSearchRules.step(from: 0, count: 0, forward: true) == nil)
    }

    @Test func aReplacedMatchHandsOverToTheNextOneAtOrAfterItsLine() {
        let gone = TranscriptSearchRules.Match(lineID: 2, rowID: 2, ordinal: 0)
        let left: [TranscriptSearchRules.Match] = [.init(lineID: 1, rowID: 1, ordinal: 0), .init(lineID: 3, rowID: 3, ordinal: 0)]
        #expect(TranscriptSearchRules.settle(previous: gone, in: left, lineOrder: [1, 2, 3]) == 1)
        #expect(TranscriptSearchRules.settle(previous: left[0], in: left, lineOrder: [1, 2, 3]) == 0)
        #expect(TranscriptSearchRules.settle(previous: nil, in: left, lineOrder: [1, 2, 3]) == 0)
        #expect(TranscriptSearchRules.settle(previous: gone, in: [], lineOrder: [1, 2, 3]) == nil)
    }

    @Test func aMatchNamesTheWordsItTouches() {
        let words = ["Peace", "Grappler,", "patrocínios", "e", "peace"]
        #expect(TranscriptSearchRules.wordMatches(query: "peace", words: words) == [[0], [4]])
        #expect(TranscriptSearchRules.wordMatches(query: "grappler, patroc", words: words) == [[1, 2]])
        #expect(TranscriptSearchRules.wordMatches(query: "patrocinios", words: words) == [[2]])
        #expect(TranscriptSearchRules.wordMatches(query: " ", words: words).isEmpty)
    }

    @Test func replaceNeedsAWholeWordMatch() {
        let text = "na Peace Rpper, e os rppers"
        #expect(TranscriptSearchRules.replaceableToken(query: "rpper", text: text, ordinal: 0) == 2)
        #expect(TranscriptSearchRules.replaceableToken(query: "rpper", text: text, ordinal: 1) == nil)
        #expect(TranscriptSearchRules.replaceableToken(query: "pper", text: text, ordinal: 0) == nil)
        #expect(TranscriptSearchRules.tokenIndex(in: "a  b", at: "a  b".index("a  b".startIndex, offsetBy: 3)) == 1)
    }
}

struct TranscriptLineFilterTests {
    private func row(_ id: Int64, edited: Bool = false, translated: Bool = false) -> TranscriptRow {
        TranscriptRow(id: id, videoID: 1, language: "pt", isTranslation: translated, startTime: Double(id), endTime: Double(id) + 1,
            text: "t", originalText: edited ? "o" : nil, wordsJSON: nil, provider: nil, model: nil)
    }

    private let labels: [Int64: String] = [1: "Marcello", 2: "Alice", 3: "Marcello"]

    @Test func oneSpeakerCombinesWithTheShowChoiceAndTranslationsNeverShow() {
        let rows = [row(1), row(2, edited: true), row(3, edited: true), row(4), row(5, translated: true)]
        func lines(_ show: TranscriptLineFilter.Show, _ speaker: String?) -> [Int64] {
            TranscriptLineFilter.lines(rows, show: show, speaker: speaker, label: { labels[$0.id] },
                tags: { $0 == 4 ? ["reel-highlight"] : [] }, changedByMap: [1], doubtful: [3]).map(\.id)
        }
        #expect(lines(.all, nil) == [1, 2, 3, 4])
        #expect(lines(.all, "Marcello") == [1, 3])
        #expect(lines(.edited, "Marcello") == [3])
        #expect(lines(.all, TranscriptLineFilter.unknown) == [4])
        #expect(lines(.tag("reel-highlight"), nil) == [4])
        #expect(lines(.changedByMap, nil) == [1] && lines(.doubtful, nil) == [3])
    }

    @Test func speakersAreCountedInOrderOfAppearanceWithUnknownLast() {
        let rows = [row(4), row(1), row(2), row(3), row(5, translated: true)]
        let speakers = TranscriptLineFilter.speakers(rows) { labels[$0.id] }
        #expect(speakers.map(\.name) == ["Marcello", "Alice", TranscriptLineFilter.unknown])
        #expect(speakers.map(\.count) == [2, 1, 1])
    }
}

struct TranscriptProofreadingTests {
    private func row(_ id: Int64, _ words: [String], start: Double = 0, translated: Bool = false) -> TranscriptRow {
        let timed = words.enumerated().map { TranscriptWord(word: $1, start: start + Double($0), end: start + Double($0) + 0.5) }
        return TranscriptRow(id: id, videoID: 1, language: "pt", isTranslation: translated, startTime: start, endTime: start + 60,
            text: words.joined(separator: " "), originalText: nil,
            wordsJSON: String(decoding: try! JSONEncoder().encode(timed), as: UTF8.self), provider: nil, model: nil)
    }

    @Test func partsAreBoundedInTranscriptOrderAndSkipLinesWithoutWords() {
        var bare = row(3, ["sem", "palavras"], start: 5)
        bare.wordsJSON = nil
        let chunks = TranscriptProofreading.chunks(rows: [row(2, ["c", "d", "e"], start: 10), row(1, ["a", "b"]), bare,
                                                          row(4, ["x"], translated: true)], limit: 2)
        #expect(chunks.map { $0.tokens.map(\.text) } == [["a", "b"], ["c", "d"], ["e"]])
        #expect(chunks.map(\.number) == [1, 2, 3])
        #expect(chunks[1].covered == [2: [0, 1]] && chunks[2].covered == [2: [2]])
    }

    @Test func promptCarriesTheWordsPeopleAndCorrectionsAsData() throws {
        let chunk = TranscriptProofreading.chunks(rows: [row(7, ["Peace", "Rpper"])])[0]
        let prompt = try TranscriptProofreading.prompt(chunk: chunk, total: 1, names: ["Alice Pereira"],
                                                       corrections: [.init(from: "jiu", to: "jiu-jitsu")])
        #expect(prompt.contains(#""row_id":7"#) && prompt.contains(#"[1,"Rpper"]"#))
        #expect(prompt.contains("Alice Pereira") && prompt.contains("jiu-jitsu") && prompt.contains(#""language":"pt""#))
    }

    @Test func onlyRealChangesToWordsThisPartSentAreKept() throws {
        let chunk = TranscriptProofreading.chunks(rows: [row(7, ["Peace", "Rpper,", "tá"])])[0]
        let response = """
        {"suggestions":[
          {"row_id":7,"word_index":1,"heard":"Rpper,","suggestion":" Grappler ","reason":"channel name"},
          {"row_id":7,"word_index":1,"heard":"Rpper,","suggestion":"Rapper","reason":"duplicate"},
          {"row_id":7,"word_index":0,"heard":"peace","suggestion":"Piece","reason":"wrong heard"},
          {"row_id":7,"word_index":2,"heard":"tá","suggestion":"Tá!","reason":"cosmetic"},
          {"row_id":9,"word_index":0,"heard":"Peace","suggestion":"Piece","reason":"wrong row"},
          {"row_id":7,"word_index":true,"heard":"Peace","suggestion":"Piece","reason":"boolean index"},
          {"row_id":7,"word_index":0,"heard":"Peace","suggestion":"Piece","reason":" "}
        ]}
        """
        let suggestions = try TranscriptProofreading.parse(response, chunk: chunk)
        #expect(suggestions == [.init(id: .init(rowID: 7, index: 1), heard: "Rpper,", suggestion: .init(to: "Grappler", reason: "channel name"))])
        #expect(TranscriptProofreading.grouped(suggestions)[7]?[1]?.suggestion.to == "Grappler")
        #expect(throws: (any Error).self) { try TranscriptProofreading.parse("no json here", chunk: chunk) }
    }

    @Test func aChangeOfWordBoundaryIsARealChangeAndEchoedPunctuationIsDropped() throws {
        let chunk = TranscriptProofreading.chunks(rows: [row(7, ["nowhere", "Rpper,"])])[0]
        let response = """
        {"suggestions":[
          {"row_id":7,"word_index":0,"heard":"nowhere","suggestion":"now here","reason":"two words"},
          {"row_id":7,"word_index":1,"heard":"Rpper,","suggestion":"Grappler,","reason":"channel name"}
        ]}
        """
        #expect(try TranscriptProofreading.parse(response, chunk: chunk).map(\.suggestion.to) == ["now here", "Grappler"])
    }
}
