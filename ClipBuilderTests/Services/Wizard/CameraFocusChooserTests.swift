import Foundation
import Testing
@testable import Clip_Builder

struct CameraFocusChooserTests {
    @Test func promptIncludesEveryExchangeAndOnlyAvailableLayouts() {
        let exchanges = [
            CameraFocusChooser.Exchange(id: 11, duration: 12,
                speakers: [.init(name: "Ana", seconds: 3, turns: 1), .init(name: "João", seconds: 9, turns: 2)],
                asker: "Ana", answerer: "João", transcript: "Por quê? Porque sim."),
            CameraFocusChooser.Exchange(id: 22, duration: 30, speakers: [], transcript: "Outra troca.")
        ]
        let single = CameraFocusChooser.prompt(exchanges: exchanges, feeds: [11: 1, 22: 1], options: WizardOptions())
        #expect(single.contains("id: 11") && single.contains("id: 22"))
        #expect(single.contains("duration: 12.0s"))
        #expect(single.contains("Ana: 25% talk time, 1 turns"))
        #expect(single.contains("João: 75% talk time, 2 turns"))
        #expect(single.contains("asks: Ana; answers: João"))
        #expect(single.contains("Por quê? Porque sim."))
        #expect(single.contains("recording feeds/tiles: 1"))
        #expect(single.contains(CropRecipe.Kind.talker.summary))
        for kind in CropRecipe.Kind.allCases where kind != .talker {
            #expect(!single.contains(kind.rawValue))
        }
        let multi = CameraFocusChooser.prompt(exchanges: exchanges, feeds: [11: 2, 22: 3], options: WizardOptions())
        for kind in CropRecipe.Kind.allCases {
            #expect(multi.contains(kind.rawValue) && multi.contains(kind.name) && multi.contains(kind.summary))
        }
    }

    @Test func parserValidatesIDsAndLayouts() {
        let response = """
        ```json
        {"choices":[
          {"id":11,"framing":"talker_and_previous","reason":"Keep the questioner visible."},
          {"id":22,"framing":"grid","reason":"Both feeds matter."},
          {"id":999,"framing":"talker","reason":"Unknown exchange."},
          {"id":33,"framing":"invented","reason":"Unknown layout."}
        ]}
        ```
        """
        let choices = CameraFocusChooser.parse(response, ids: [11, 22, 33], allowed: [.talker, .talkerAndPrevious])
        #expect(choices.count == 1)
        #expect(choices[11]?.kind == .talkerAndPrevious)
        #expect(choices[11]?.reason == "Keep the questioner visible.")
        #expect(CameraFocusChooser.parse("invalid", ids: [11], allowed: [.talker]).isEmpty)
        #expect(CameraFocusChooser.parse(response, ids: [22], allowed: [.grid])[22]?.kind == .grid)
    }

    @Test(arguments: [0, 1, 2, 3, 5])
    func fallbackUsesSpeakerCountAndAvailableFeeds(speakers: Int) {
        let expected: CropRecipe.Kind = speakers >= 3 ? .talkerAndRotation : speakers == 2 ? .talkerAndPrevious : .talker
        #expect(CameraFocusChooser.fallback(speakers: speakers,
            allowed: CameraFocusChooser.allowedLayouts(feeds: 3)) == expected)
        #expect(CameraFocusChooser.fallback(speakers: speakers,
            allowed: CameraFocusChooser.allowedLayouts(feeds: 1)) == .talker)
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
        let excerpt = CameraFocusChooser.excerpt(exchange.transcript)
        #expect(excerpt.count == 400)
        #expect(excerpt.hasPrefix("Abertura") && excerpt.hasSuffix("Encerramento"))
        #expect(!excerpt.contains("Translation"))
    }
}
