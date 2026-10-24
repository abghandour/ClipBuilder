import Foundation
import CoreGraphics
import Testing
@testable import Clip_Builder

@Suite("Transcript Q&A word trim")
struct TranscriptQATrimTests {
    private func section(_ id: Int64, _ start: Double, _ end: Double, videoID: Int64 = 1) -> TranscriptQASections.Section {
        var scene = Fixtures.scene(id: id, start: start, end: end)
        scene.videoID = videoID
        return TranscriptQASections.Section(scene: scene, question: "Question?")
    }

    private func word(_ start: Double, _ end: Double) -> TranscriptQATrim.Word {
        TranscriptQATrim.Word(id: 0, text: "word", start: start, end: end)
    }

    private func row(_ start: Double, _ end: Double, _ text: String, wordsJSON: String? = nil) -> TranscriptRow {
        TranscriptRow(id: 1, videoID: 1, language: "en", isTranslation: false,
                      startTime: start, endTime: end, text: text, originalText: nil,
                      wordsJSON: wordsJSON, provider: nil, model: nil)
    }

    private func translation(_ start: Double, _ end: Double, _ text: String,
                             language: String = "en", id: Int64 = 100) -> TranscriptRow {
        var row = row(start, end, text)
        row.id = id
        row.language = language
        row.isTranslation = true
        return row
    }

    private func lines(_ rows: [TranscriptRow]) -> [TranscriptQATrim.Line] {
        TranscriptQATrim.Transcript(.init(rows: rows, labels: [:], videoID: 1)).lines
    }

    @Test func consecutiveRowsOfTheSameSpeakerFormOneBlockBrokenByTheOtherSpeaker() {
        var rows = [row(0, 2, "Hello there"), row(2, 5, "how are you"), row(5, 8, "I am fine"),
                    row(8, 9, "good"), row(9, 11, "no speaker here")]
        for index in rows.indices { rows[index].id = Int64(index + 1) }
        let labels: [Int64: String] = [1: "Marcello", 2: "Marcello", 3: "Tanner", 4: "Marcello"]
        let transcript = TranscriptQATrim.Transcript(.init(rows: rows, labels: labels, videoID: 1))
        #expect(transcript.lines.map(\.speaker) == ["Marcello", "Tanner", "Marcello", nil])
        #expect(transcript.lines.map(\.start) == [0, 5, 8, 9])
        #expect(transcript.lines.map(\.end) == [5, 8, 9, 11])
        #expect(transcript.lines[0].words.map(\.text) == ["Hello", "there", "how", "are", "you"])
        #expect(transcript.words.map(\.id) == Array(0..<transcript.words.count), "word ids stay contiguous across the merge")
        #expect(transcript.lineID(at: 3.5) == 0 && transcript.lineID(at: 6) == 1)
        // Rows without a known speaker never merge, even with each other.
        let unlabelled = TranscriptQATrim.Transcript(.init(rows: rows, labels: [:], videoID: 1))
        #expect(unlabelled.lines.count == rows.count)
        // Translations of merged rows join the block in time order.
        let translations = [translation(0, 2, "Olá", id: 101), translation(2, 5, "como vai", id: 102),
                            translation(5, 8, "estou bem", id: 103)]
        let text = TranscriptQATrim.translations(for: transcript.lines, rows: rows + translations, language: "en")
        #expect(text[0] == "Olá como vai" && text[1] == "estou bem")
    }

    @Test func transcriptIgnoresTranslationsWithoutChangingLinesWordsOrPlayback() throws {
        let timed = [TranscriptWord(word: "Olá", start: 0.2, end: 0.8),
                     TranscriptWord(word: "mundo", start: 1.2, end: 1.8)]
        let json = String(decoding: try JSONEncoder().encode(timed), as: UTF8.self)
        var first = row(0, 2, "Olá mundo", wordsJSON: json)
        first.language = "pt"
        var second = row(2, 6, "Como vai você?")
        second.id = 2
        second.language = "pt"
        var english = translation(0, 2, "Hello world")
        english.wordsJSON = json // Even translations with recorded words must be excluded.
        let translated = [translation(2, 6, "How are you?"), english,
                          translation(0, 2, "Bonjour", language: "fr")]
        let originals = [second, first]
        let baseline = TranscriptQATrim.Transcript(.init(rows: originals, labels: [1: "Host", 2: "Guest"], videoID: 1))
        let mixed = TranscriptQATrim.Transcript(.init(rows: translated + originals,
            labels: [1: "Host", 2: "Guest", 100: "Translated speaker"], videoID: 1))
        #expect(mixed.lines == baseline.lines)
        #expect(mixed.words == baseline.words)
        #expect(mixed.words.map(\.id) == [0, 1, 2, 3, 4])
        #expect(mixed.lines.map(\.speaker) == ["Host", "Guest"])
        for time in [0.2, 1.9, 2, 5.9, 6] {
            #expect(mixed.lineID(at: time) == baseline.lineID(at: time))
        }
        #expect(TranscriptQATrim.snap(1.1, edge: .start, words: mixed.words) == 1.2)
        #expect(TranscriptQATrim.Transcript(.init(rows: translated, labels: [:], videoID: 1)).lines.isEmpty)
    }

    @Test func translationsPreferExactRangeOverAnEarlierContainingLine() {
        let lines = lines([row(0, 10, "Broad line"), row(2, 4, "Exact line")])
        let matched = TranscriptQATrim.translations(for: lines,
            rows: [translation(2, 4, "Exact translation")], language: "en")
        #expect(matched == [1: "Exact translation"])
    }

    @Test func translationsChooseGreatestOverlapAndOnlyOneLine() {
        let lines = lines([row(0, 4, "First"), row(4, 10, "Second")])
        let matched = TranscriptQATrim.translations(for: lines,
            rows: [translation(3, 8, "Mostly second")], language: "en")
        #expect(matched == [1: "Mostly second"])
        let tied = TranscriptQATrim.translations(for: lines,
            rows: [translation(3, 5, "Equal overlap")], language: "en")
        #expect(tied == [0: "Equal overlap"])
    }

    @Test func translationsConcatenateSeveralRowsInTimeOrder() {
        let lines = lines([row(0, 10, "Original")])
        let rows = [translation(6, 10, " third\n", id: 101),
                    translation(0, 3, "first", id: 103),
                    translation(3, 6, "second", id: 102)]
        #expect(TranscriptQATrim.translations(for: lines, rows: rows, language: "en")
            == [0: "first second third"])
    }

    @Test func missingTranslationsStayMissingWithoutNearestLineFallback() {
        let lines = lines([row(0, 4, "First"), row(4, 8, "Second")])
        let rows = [translation(0, 4, "First translation"), translation(8, 10, "Outside"),
                    translation(4, 8, " \n "), translation(5, 5, "Zero duration"),
                    translation(7, 6, "Inverted"), translation(.nan, 8, "Invalid")]
        #expect(TranscriptQATrim.translations(for: lines, rows: rows, language: "en")
            == [0: "First translation"])
        #expect(TranscriptQATrim.translations(for: lines, rows: [], language: "en").isEmpty)
        #expect(TranscriptQATrim.translations(for: [], rows: rows, language: "en").isEmpty)
    }

    @Test func translationsFilterLanguageAndExcludeOriginalRows() {
        let original = row(0, 4, "Original with the requested language code")
        let lines = lines([original])
        let rows = [original, translation(0, 4, "English"), translation(0, 4, "Français", language: "fr")]
        #expect(TranscriptQATrim.translations(for: lines, rows: rows, language: "en") == [0: "English"])
        #expect(TranscriptQATrim.translations(for: lines, rows: rows, language: "fr") == [0: "Français"])
        #expect(TranscriptQATrim.translations(for: lines, rows: rows, language: "es").isEmpty)
    }

    @Test func availableTranslationLanguagesDriveCheckboxAndMenuVisibility() {
        let original = row(0, 4, "Original")
        #expect(TranscriptQATrim.availableTranslationLanguages(rows: []).isEmpty)
        #expect(TranscriptQATrim.availableTranslationLanguages(rows: [original]).isEmpty)
        let english = [original, translation(0, 4, "Hello"), translation(4, 8, "World")]
        let one = TranscriptQATrim.availableTranslationLanguages(rows: english)
        #expect(one == ["en"]) // Nonempty: checkbox. Count == 1: no menu.
        let two = TranscriptQATrim.availableTranslationLanguages(rows:
            [translation(0, 4, "Bonjour", language: "fr")] + english)
        #expect(two == ["en", "fr"]) // Count > 1: show the language menu too.
    }

    @Test func translationLanguagePrefersVideoSelectionThenProfileThenFirstAvailable() {
        #expect(TranscriptQATrim.translationLanguage(available: [], selected: "en", preferred: "en") == nil)
        #expect(TranscriptQATrim.translationLanguage(available: ["en", "fr"], selected: nil, preferred: "fr") == "fr")
        #expect(TranscriptQATrim.translationLanguage(available: ["en", "fr"], selected: "en", preferred: "fr") == "en")
        #expect(TranscriptQATrim.translationLanguage(available: ["en", "fr"], selected: "es", preferred: "fr") == "fr")
        #expect(TranscriptQATrim.translationLanguage(available: ["en", "fr"], selected: nil, preferred: "es") == "en")
        #expect(TranscriptQATrim.translationLanguage(available: ["en"], selected: nil, preferred: nil) == "en")
    }

    @Test func limitsIgnoreNeighboursAndUseRecordingEnds() {
        var previous = section(1, 5, 15)
        previous.scene.endTime = 18
        let selected = section(2, 20, 30)
        var next = section(3, 40, 50)
        next.scene.startTime = 36
        let sections = [next, section(4, 25, 26, videoID: 2), selected, previous]
        #expect(TranscriptQATrim.limits(for: selected, in: sections, duration: 60) == 0...60)
        #expect(TranscriptQATrim.limits(for: previous, in: sections, duration: 60) == 0...60)
        #expect(TranscriptQATrim.limits(for: next, in: sections, duration: 60) == 0...60)
        #expect(TranscriptQATrim.limits(for: selected, in: [selected], duration: 60) == 0...60)
    }

    @Test func movesPastTouchingNeighboursAreAccepted() {
        let selected = section(2, 10, 20)
        let limits = TranscriptQATrim.limits(for: selected, in: [section(1, 0, 10), selected, section(3, 20, 30)], duration: 30)
        #expect(limits == 0...30)
        #expect(TranscriptQATrim.range(10...20, movingStartTo: word(3, 4), limits: limits) == 3...20)
        #expect(TranscriptQATrim.range(10...20, movingEndTo: word(25, 26), limits: limits) == 10...26)
        #expect(TranscriptQATrim.setting(.start, at: 2, in: 10...20, limits: limits) == 2...20)
        #expect(TranscriptQATrim.setting(.end, at: 28, in: 10...20, limits: limits) == 10...28)
        #expect(TranscriptQATrim.setting(.start, at: 25, in: 10...20, limits: limits) == 19...20)
        #expect(TranscriptQATrim.setting(.end, at: 5, in: 10...20, limits: limits) == 10...11)
        #expect(TranscriptQATrim.releasing(3.2...25.8, from: 10...20,
            words: [word(3, 4), word(25, 26)], limits: limits) == 3...26)
    }

    @Test func startSnapsToWordStartAndClampsWithoutMovingEnd() {
        let limits = 8.0...32.0
        #expect(TranscriptQATrim.range(10...20, movingStartTo: word(12.25, 12.75), limits: limits) == 12.25...20)
        #expect(TranscriptQATrim.range(10...20, movingStartTo: word(2, 3), limits: limits) == 8...20)
        #expect(TranscriptQATrim.range(10...20, movingStartTo: word(19.5, 19.8), limits: limits) == 19...20)
        #expect(TranscriptQATrim.range(10...20, movingStartTo: word(35, 36), limits: limits) == 19...20)
    }

    @Test func endSnapsToWordEndAndClampsWithoutMovingStart() {
        let limits = 8.0...32.0
        #expect(TranscriptQATrim.range(10...20, movingEndTo: word(15.25, 15.75), limits: limits) == 10...15.75)
        #expect(TranscriptQATrim.range(10...20, movingEndTo: word(35, 36), limits: limits) == 10...32)
        #expect(TranscriptQATrim.range(10...20, movingEndTo: word(10.1, 10.5), limits: limits) == 10...11)
        #expect(TranscriptQATrim.range(10...20, movingEndTo: word(2, 3), limits: limits) == 10...11)
    }

    @Test func recordingBoundsAndOneSecondMinimumStillApply() {
        #expect(TranscriptQATrim.range(10...11, movingStartTo: word(10.2, 10.8), limits: 10...20) == 10...11)
        #expect(TranscriptQATrim.range(10...11, movingEndTo: word(10, 10.4), limits: 0...11) == 10...11)
        #expect(TranscriptQATrim.range(10...20, movingStartTo: word(7.5, 8.5), limits: 8...30) == 8...20)
        #expect(TranscriptQATrim.range(10...20, movingEndTo: word(29.5, 30.5), limits: 8...30) == 10...30)
        #expect(TranscriptQATrim.clamped(0...40, limits: 8...30) == 8...30)
        #expect(TranscriptQATrim.clamped(0...1, limits: 0...0) == 0...0)
        #expect(TranscriptQATrim.clamped(0...1, limits: 0...0.4) == 0...0.4)
    }

    @Test func nearerEdgeUsesWordMidpointAndTiesChooseStart() {
        #expect(TranscriptQATrim.nearestEdge(for: word(1, 2), in: 10...20) == .start)
        #expect(TranscriptQATrim.nearestEdge(for: word(11, 12), in: 10...20) == .start)
        #expect(TranscriptQATrim.nearestEdge(for: word(14, 16), in: 10...20) == .start)
        #expect(TranscriptQATrim.nearestEdge(for: word(18, 19), in: 10...20) == .end)
        #expect(TranscriptQATrim.nearestEdge(for: word(30, 31), in: 10...20) == .end)
    }

    @Test func fallbackSplitsWhitespaceAndEvenlySpansTheRow() {
        let words = TranscriptQATrim.words(for: row(10, 16, " One  two\nthree! "), startingAt: 7)
        #expect(words.map(\.id) == [7, 8, 9])
        #expect(words.map(\.text) == ["One", "two", "three!"])
        #expect(words.map(\.start) == [10, 12, 14])
        #expect(words.map(\.end) == [12, 14, 16])
        #expect(TranscriptQATrim.words(for: row(10, 16, " \n ")).isEmpty)
        #expect(TranscriptQATrim.words(for: row(10, 10, "Zero span")).isEmpty)
        #expect(TranscriptQATrim.words(for: row(12, 10, "Inverted span")).isEmpty)
    }

    @Test func recordedTimingsWinAndInvalidJSONFallsBack() throws {
        let timed = [TranscriptWord(word: " second ", start: 13, end: 13.7),
                     TranscriptWord(word: "first", start: 10.2, end: 10.5)]
        let json = String(decoding: try JSONEncoder().encode(timed), as: UTF8.self)
        let words = TranscriptQATrim.words(for: row(10, 16, "first second", wordsJSON: json))
        #expect(words.map(\.text) == ["first", "second"])
        #expect(words.map(\.start) == [10.2, 13])
        #expect(words.map(\.end) == [10.5, 13.7])
        #expect(TranscriptQATrim.words(for: row(10, 16, "first second", wordsJSON: "bad")).map(\.start) == [10, 13])
    }

    @Test func transcriptHasStableUniqueWordIDsAndSpeakerNames() {
        let first = row(0, 4, "First question")
        var next = row(4, 8, "The answer")
        next.id = 2
        var other = row(0, 8, "Other video")
        other.videoID = 2
        let transcript = TranscriptQATrim.Transcript(.init(rows: [next, other, first], labels: [1: "Host", 2: "Guest"], videoID: 1))
        #expect(transcript.words.map(\.id) == [0, 1, 2, 3])
        #expect(transcript.lines.map(\.speaker) == ["Host", "Guest"])
        #expect(transcript.lineID(at: 3.9) == 0)
        #expect(transcript.lineID(at: 4) == 1)
        #expect(transcript.lineID(at: 9) == nil)
        #expect(TranscriptQATrim.contains(transcript.words[1], in: 0...3) == false)
        #expect(TranscriptQATrim.contains(transcript.words[1], in: 3...4))
    }

    @Test func pointLookupUsesActualWordRectsAndStableTieBreaking() {
        let frames = [1: CGRect(x: 10, y: 10, width: 30, height: 18),
                      2: CGRect(x: 44, y: 10, width: 40, height: 18),
                      3: CGRect(x: 10, y: 34, width: 50, height: 18)]
        #expect(TranscriptQATrim.word(at: CGPoint(x: 20, y: 15), frames: frames) == 1)
        #expect(TranscriptQATrim.word(at: CGPoint(x: 50, y: 15), frames: frames) == 2)
        #expect(TranscriptQATrim.word(at: CGPoint(x: 20, y: 40), frames: frames) == 3)
        #expect(TranscriptQATrim.word(at: CGPoint(x: 42, y: 15), frames: frames) == nil)
        #expect(TranscriptQATrim.word(at: CGPoint(x: 20, y: 30), frames: frames) == nil)
        #expect(TranscriptQATrim.word(at: .zero, frames: [:]) == nil)
        let overlap = [4: CGRect(x: 0, y: 0, width: 20, height: 20), 2: CGRect(x: 0, y: 0, width: 20, height: 20)]
        #expect(TranscriptQATrim.word(at: CGPoint(x: 10, y: 10), frames: overlap) == 2)
    }

    @Test func filmstripReleaseSnapsOnlyMovedEndsAndHonoursLimits() {
        let words = [word(8, 9), word(12, 13), word(19, 20), word(25, 26)]
        #expect(TranscriptQATrim.releasing(11.5...20, from: 10...20, words: words, limits: 9...24) == 12...20)
        #expect(TranscriptQATrim.releasing(10...25.5, from: 10...20, words: words, limits: 9...24) == 10...24)
        #expect(TranscriptQATrim.releasing(19.5...20, from: 10...20, words: words, limits: 9...24) == 19...20)
        #expect(TranscriptQATrim.releasing(11.5...25.5, from: 10...20, words: words, limits: 9...24) == 12...24)
        #expect(TranscriptQATrim.releasing(10.5...20, from: 10...20, words: [], limits: 9...24) == 10.5...20)
    }
}

extension TranscriptQATrimTests {
    @Test func rowCrossingASpeakerChangeSplitsIntoOneLinePerSpeaker() throws {
        // "Yeah. How did you start? Only a couple street bars." — the asker
        // stops after "start?" and the answer begins mid-row.
        let timed = [("Yeah.", 0.0, 0.4), ("How", 0.5, 0.7), ("did", 0.7, 0.9), ("you", 0.9, 1.1), ("start?", 1.1, 1.6),
                     ("Only", 2.0, 2.3), ("a", 2.3, 2.4), ("couple", 2.4, 2.8), ("street", 2.8, 3.2), ("bars.", 3.2, 3.8)]
            .map { TranscriptWord(word: $0.0, start: $0.1, end: $0.2) }
        let json = String(decoding: try JSONEncoder().encode(timed), as: UTF8.self)
        var crossing = row(0, 4, timed.map(\.word).joined(separator: " "), wordsJSON: json)
        crossing.id = 1
        var next = row(4, 6, "Then I moved.")
        next.id = 2
        let spans = [TranscriptQATrim.SpeakerSpan(start: 0, end: 1.8, label: "Marcello"),
                     TranscriptQATrim.SpeakerSpan(start: 1.9, end: 6, label: "John")]
        let transcript = TranscriptQATrim.Transcript(.init(rows: [crossing, next], labels: [1: "Marcello", 2: "John"],
                                                           videoID: 1, speakerSpans: spans))
        #expect(transcript.lines.map(\.speaker) == ["Marcello", "John"])
        #expect(transcript.lines[0].words.map(\.text) == ["Yeah.", "How", "did", "you", "start?"])
        #expect(transcript.lines[1].words.map(\.text) == ["Only", "a", "couple", "street", "bars.", "Then", "I", "moved."],
                "the answer run merges with the next row by the same speaker")
        #expect(transcript.lines[0].start == 0 && transcript.lines[0].end == 1.6)
        #expect(transcript.lines[1].start == 2.0 && transcript.lines[1].end == 6)
        #expect(transcript.words.map(\.id) == Array(0..<transcript.words.count))
        // A row the user attributed by hand keeps its one label.
        var attributed = crossing
        attributed.speaker = .person(key: "marcello")
        let manual = TranscriptQATrim.Transcript(.init(rows: [attributed], labels: [1: "Marcello"], videoID: 1, speakerSpans: spans))
        #expect(manual.lines.map(\.speaker) == ["Marcello"])
        // Without timed words there is nothing to split on.
        let untimed = TranscriptQATrim.Transcript(.init(rows: [row(0, 4, "Yeah. How did you start? Only a couple.")],
                                                        labels: [1: "Marcello"], videoID: 1, speakerSpans: spans))
        #expect(untimed.lines.count == 1)
        // A word in a gap between spans stays with the words before it ("start?"
        // ends at 1.6, after Marcello's span); a word touching the next span joins it.
        let gap = [TranscriptQATrim.SpeakerSpan(start: 0, end: 1.0, label: "Marcello"),
                   TranscriptQATrim.SpeakerSpan(start: 2.2, end: 6, label: "John")]
        let gapped = TranscriptQATrim.Transcript(.init(rows: [crossing], labels: [1: "Marcello"], videoID: 1, speakerSpans: gap))
        #expect(gapped.lines.map(\.speaker) == ["Marcello", "John"])
        #expect(gapped.lines[0].words.map(\.text) == ["Yeah.", "How", "did", "you", "start?"])
        // Only one speaker covers the row: nothing to split.
        let single = TranscriptQATrim.Transcript(.init(rows: [crossing], labels: [1: "Marcello"], videoID: 1,
                                                       speakerSpans: [.init(start: 0, end: 6, label: "Marcello")]))
        #expect(single.lines.count == 1)
    }
}
