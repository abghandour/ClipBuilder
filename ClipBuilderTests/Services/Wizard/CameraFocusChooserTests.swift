import Foundation
import Testing
@testable import Clip_Builder

struct CameraFocusChooserTests {
    @Test func promptIncludesEveryExchangeAndOnlyAvailableSubjects() {
        let exchanges = [CameraFocusChooser.Exchange(id: 11, duration: 12,
            speakers: [.init(name: "Ana", seconds: 3, turns: 1), .init(name: "João", seconds: 9, turns: 2)],
            asker: "Ana", answerer: "João", transcript: "Por quê? Porque sim."),
            CameraFocusChooser.Exchange(id: 22, duration: 30, speakers: [], transcript: "Outra troca.")]
        let prompt = CameraFocusChooser.prompt(exchanges: exchanges, feeds: [11: 1, 22: 1], options: WizardOptions())
        #expect(prompt.contains("id: 11") && prompt.contains("id: 22"))
        #expect(prompt.contains("Ana: 25% talk time, 1 turns") && prompt.contains("João: 75% talk time, 2 turns"))
        #expect(prompt.contains("asks: Ana; answers: João") && prompt.contains("Por quê? Porque sim."))
        #expect(prompt.contains("speakerFocus") && prompt.contains("centerStage"))
        #expect(!prompt.contains("vipFocus") && !prompt.contains("talker_and_previous"))
    }

    @Test(arguments: VideoType.allCases)
    func chooserRestrictsSubjectsToTheKind(type: VideoType) {
        let allowed = CameraFocusChooser.allowedSubjects(type: type, hasTurns: true, hasVIP: true)
        #expect(allowed == FramingMenu.allowed(type: type).filter { $0 != .auto })
        let missing = CameraFocusChooser.allowedSubjects(type: type, hasTurns: false, hasVIP: false)
        #expect(!missing.contains(.speakerFocus))
        #expect(type == .fight || !missing.contains(.vipFocus))
        #expect(missing.contains(CameraFocusChooser.fallback(type: type, allowed: missing)))
    }

    @Test func parserValidatesIDsSubjectsAndReasons() {
        let response = #"{"choices":[{"id":11,"framing":"speakerFocus","reason":"Follow the answer."},{"id":22,"framing":"vipFocus","reason":"Unavailable."},{"id":999,"framing":"original","reason":"Unknown."},{"id":33,"framing":"auto","reason":"Unresolved."}]}"#
        let choices = CameraFocusChooser.parse(response, ids: [11, 22, 33], allowed: [.speakerFocus, .original])
        #expect(choices.count == 1 && choices[11]?.kind == .speakerFocus)
        #expect(choices[11]?.reason == "Follow the answer.")
        #expect(CameraFocusChooser.parse("invalid", ids: [11], allowed: [.original]).isEmpty)
    }

    @Test func evidenceUsesTrimmedSpeechAndOriginalOpeningAndClosing() {
        var scene = Fixtures.scene(id: 1, start: 0, end: 20)
        scene.tags = ["podcast", "q&a"]
        let turns = [
            SpeakerTurn(videoID: scene.videoID, start: 0, end: 4, cluster: 0, confidence: 1, personKey: "host"),
            SpeakerTurn(videoID: scene.videoID, start: 4, end: 10, cluster: 1, confidence: 1, personKey: "guest"),
            SpeakerTurn(videoID: scene.videoID, start: 10, end: 12, cluster: 0, confidence: 1, personKey: "host"),
            SpeakerTurn(videoID: scene.videoID, start: 15, end: 20, cluster: 2, confidence: 1)
        ]
        let roster = [VideoPersonRecord(videoID: scene.videoID, personID: 1, key: "host", name: "Ana",
                                       descriptor: "", portraitAt: 0, portraitBox: nil)]
        let original = "Abertura " + String(repeating: "palavra ", count: 100) + " Encerramento"
        let rows = [
            TranscriptRow(id: 1, videoID: scene.videoID, language: "pt", isTranslation: false,
                          startTime: 2, endTime: 12, text: original),
            TranscriptRow(id: 2, videoID: scene.videoID, language: "en", isTranslation: true,
                          startTime: 2, endTime: 12, text: "Translation must not be included")
        ]
        let exchange = CameraFocusChooser.exchange(id: 9,
            clips: [Fixtures.planClip(sceneID: scene.id, start: 2, end: 12)], sceneMap: [scene.id: scene],
            turns: [scene.videoID: turns], rosters: [scene.videoID: roster], rows: [scene.videoID: rows])
        #expect(exchange.duration == 10)
        #expect(exchange.speakers.map(\.seconds) == [4, 6])
        #expect(exchange.speakers.map(\.turns) == [2, 1])
        #expect(exchange.asker == "Ana" && exchange.answerer == "guest")
        #expect(exchange.nonVIPPeople == 1)
        let excerpt = CameraFocusChooser.excerpt(exchange.transcript)
        #expect(excerpt.count == 400)
        #expect(excerpt.hasPrefix("Abertura") && excerpt.hasSuffix("Encerramento"))
        #expect(!excerpt.contains("Translation"))
    }
}
