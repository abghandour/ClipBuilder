import Foundation
import Testing
@testable import Clip_Builder

@Suite("Scene blurbs")
struct SceneBlurbTests {
    @Test("a podcast narrative splits into title and summary; a plain one is all text")
    func narrative() {
        let split = SceneBlurb.fromNarrative("Cutting weight — Why the last five pounds are the hardest.")
        #expect(split.title == "Cutting weight" && split.text == "Why the last five pounds are the hardest." && !split.isExcerpt)
        let plain = SceneBlurb.fromNarrative("A takedown into side control.")
        #expect(plain.title == nil && plain.text == "A takedown into side control.")
        #expect(split.accessibilityText == "Cutting weight. Why the last five pounds are the hardest.")
    }

    @Test("a transcript excerpt takes the words inside the scene, in order, up to the limit")
    func excerpt() {
        func row(_ id: Int64, _ start: Double, _ end: Double, _ text: String, translation: Bool = false) -> TranscriptRow {
            TranscriptRow(id: id, videoID: 1, language: "en", isTranslation: translation, startTime: start, endTime: end,
                          text: text, originalText: nil, wordsJSON: nil, provider: nil, model: nil)
        }
        let rows = [row(2, 4, 6, "three four"), row(1, 0, 3, "one two"), row(3, 8, 9, "outside"),
                    row(4, 4, 6, "übersetzung", translation: true)]
        let blurb = SceneBlurb.fromTranscript(rows, start: 1, end: 7)
        #expect(blurb?.text == "one two three four" && blurb?.isExcerpt == true && blurb?.title == nil)
        #expect(SceneBlurb.fromTranscript(rows, start: 1, end: 7, words: 3)?.text == "one two three…")
        #expect(SceneBlurb.fromTranscript(rows, start: 20, end: 30) == nil)
    }

    @Test("a talk scene's poster is the speaker's crop half a second in; other scenes keep the middle frame")
    func poster() throws {
        var scene = Fixtures.scene(id: 1, start: 10, end: 20)
        scene.centerStagePathJSON = String(decoding: try JSONEncoder().encode(SceneCameraPath(camera: "podcast",
            keyframes: [CameraPathKeyframe(t: 0, x: 0.5, y: 0, w: 0.158, h: 0.5),
                        CameraPathKeyframe(t: 10, x: 0.5, y: 0, w: 0.158, h: 0.5)])), as: UTF8.self)
        let talk = scene.posterFrame(videoType: .podcast)
        #expect(talk.time == 10.5 && talk.window?.xFrac == 0.5 && talk.window?.hFrac == 0.5)
        let fight = scene.posterFrame(videoType: .fight)
        #expect(fight.time == 15 && fight.window == nil)
        scene.centerStagePathJSON = nil
        #expect(scene.posterFrame(videoType: .podcast).window == nil)
    }

    @Test("talk footage is a podcast or interview file, or a podcast exchange")
    func talk() {
        var scene = Fixtures.scene()
        #expect(!scene.isTalk(videoType: .fight))
        #expect(scene.isTalk(videoType: .interview) && scene.isTalk(videoType: .podcast))
        scene.tags.append("podcast:grid")
        #expect(scene.isTalk(videoType: nil))
    }
}
