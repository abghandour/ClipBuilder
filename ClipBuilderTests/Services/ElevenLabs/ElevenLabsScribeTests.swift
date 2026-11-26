import Foundation
import Testing
@testable import Clip_Builder

struct ElevenLabsScribeTests {
    private func word(_ text: String, _ start: Double, _ end: Double, speaker: String? = "speaker_0",
                      logprob: Double? = -0.1) -> ElevenLabsScribe.Response.Word {
        .init(text: text, type: "word", start: start, end: end, speakerID: speaker, logprob: logprob)
    }
    private var space: ElevenLabsScribe.Response.Word { .init(text: " ", type: "spacing") }
    private func response(_ words: [ElevenLabsScribe.Response.Word]) -> ElevenLabsScribe.Response {
        .init(languageCode: "por", text: nil, words: words)
    }

    @Test func decodesTheAnswerAndCutsItIntoALine() throws {
        let json = Data(#"""
            {"language_code":"por","language_probability":0.98,"text":"Olá, tudo bem?",
             "words":[{"text":"Olá,","start":0.119,"end":0.5,"type":"word","speaker_id":"speaker_0","logprob":-0.02},
                      {"text":" ","start":0.5,"end":0.6,"type":"spacing","speaker_id":"speaker_0","logprob":0},
                      {"text":"(risos)","start":0.6,"end":0.9,"type":"audio_event","speaker_id":"speaker_0","logprob":0},
                      {"text":"tudo","start":0.9,"end":1.1,"type":"word","speaker_id":"speaker_0","logprob":-1.2},
                      {"text":" ","type":"spacing","logprob":0},
                      {"text":"bem?","start":1.1,"end":1.4,"type":"word","speaker_id":"speaker_0","logprob":0}]}
            """#.utf8)
        let decoded = try JSONDecoder().decode(ElevenLabsScribe.Response.self, from: json)
        let segments = ElevenLabsScribe.segments(decoded)
        #expect(segments.count == 1)
        #expect(segments[0].text == "Olá, tudo bem?")
        #expect(segments[0].start == 0.12 && segments[0].end == 1.4)
        let words = try #require(segments[0].words)
        #expect(words.map(\.word) == ["Olá,", "tudo", "bem?"])
        // exp(logprob), and never the 1 that means "marked right by the user".
        #expect(abs((words[1].confidence ?? 0) - exp(-1.2)) < 0.0001)
        #expect(words[2].confidence == 0.99)
        #expect(ElevenLabsScribe.language(decoded.languageCode) == "pt")
    }

    @Test func aLineEndsAtASpeakerChangeAndALongSilence() {
        let segments = ElevenLabsScribe.segments(response([
            word("Tudo", 0, 0.3), space, word("certo", 0.3, 0.7), space,
            word("Sim", 0.8, 1.0, speaker: "speaker_1"), space,
            word("claro", 3.0, 3.4, speaker: "speaker_1"),
        ]))
        #expect(segments.map(\.text) == ["Tudo certo", "Sim", "claro"])
    }

    @Test func aShortSentenceStaysOnItsLineAndALongOneEndsIt() {
        let segments = ElevenLabsScribe.segments(response([
            word("Sure.", 0, 0.4), space, word("We", 0.5, 0.7), space, word("trained", 0.7, 3.2), space,
            word("hard.", 3.2, 3.6), space, word("Next", 3.7, 4.0),
        ]))
        #expect(segments.map(\.text) == ["Sure. We trained hard.", "Next"])
    }

    @Test func noLineRunsPastTheMaximumAndACommaEndsALongOne() {
        let run = (0..<30).flatMap { index in [word(index == 12 ? "w12," : "w\(index)", Double(index), Double(index) + 0.9), space] }
        let segments = ElevenLabsScribe.segments(response(run))
        #expect(segments.allSatisfy { $0.end - $0.start <= 20 })
        #expect(segments.first?.text.hasSuffix("w12,") == true)
        #expect(segments.flatMap { $0.words ?? [] }.count == 30)
    }

    @Test func wordsWithoutTimesAreLeftOutAndUnspacedLanguagesAreNotSpaced() {
        let segments = ElevenLabsScribe.segments(response([
            word("你", 0, 0.2), .init(text: "x", type: "word"), word("好", 0.2, 0.4),
        ]))
        #expect(segments.map(\.text) == ["你好"])
        #expect(ElevenLabsScribe.segments(response([])).isEmpty)
    }

    @Test func languageCodesAndHints() {
        #expect(ElevenLabsScribe.language("eng") == "en")
        #expect(ElevenLabsScribe.language("pt") == "pt")
        #expect(ElevenLabsScribe.language(nil) == "")
        #expect(ElevenLabsScribe.languageHint("pt-BR") == "pt")
        #expect(ElevenLabsScribe.languageHint("") == nil)
    }

    @Test func keytermsAreCleanedDedupedAndCapped() {
        let terms = ElevenLabsScribe.keyterms(["Peace  Grappler", "peace grappler", "A", "bad<term>", "one two three four five six",
                                               String(repeating: "x", count: 51), "Kemuel"])
        #expect(terms == ["Peace Grappler", "Kemuel"])
        #expect(ElevenLabsScribe.keyterms((0..<150).map { "name\($0)" }).count == 100)
    }

    @Test func transcribePostsTheAudioWithWordTimesAndHints() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(UUID().uuidString).m4a")
        try Data("AUDIO".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = ElevenLabsTransportStub([(200, Data(#"{"language_code":"en","text":"Hi","words":[{"text":"Hi","start":0,"end":0.3,"type":"word","logprob":0}]}"#.utf8))])
        let response = try await stub.client().transcribe(audio: file, model: "scribe_v3", language: "pt", keyterms: ["Kemuel"])
        #expect(response.words?.count == 1)
        let request = try #require(await stub.requests.first)
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key")
        #expect(request.timeoutInterval == 1800)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        for part in ["name=\"model_id\"\r\n\r\nscribe_v3", "name=\"language_code\"\r\n\r\npt", "name=\"diarize\"\r\n\r\ntrue",
                     "name=\"timestamps_granularity\"\r\n\r\nword", "name=\"tag_audio_events\"\r\n\r\nfalse",
                     "name=\"keyterms\"\r\n\r\nKemuel", "name=\"file\"; filename=\"audio.m4a\"", "AUDIO"] {
            #expect(body.contains(part), "missing \(part)")
        }
    }
}
