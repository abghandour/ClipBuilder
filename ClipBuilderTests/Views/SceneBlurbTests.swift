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

@Suite("Transcript speakers")
struct TranscriptSpeakersTests {
    private func row(_ id: Int64, _ start: Double, _ end: Double) -> TranscriptRow {
        TranscriptRow(id: id, videoID: 1, language: "en", isTranslation: false, startTime: start, endTime: end,
                      text: "line \(id)", originalText: nil, wordsJSON: nil, provider: nil, model: nil)
    }

    @Test("a line is labelled with the person of the turn that overlaps it most; repeats stay blank")
    func labels() {
        var ann = SpeakerTurn(videoID: 1, start: 0, end: 5, cluster: 0, confidence: 1); ann.personKey = "ann"
        var feed = SpeakerTurn(videoID: 1, start: 5, end: 9, cluster: 1, confidence: 1); feed.tile = 2
        let voice = SpeakerTurn(videoID: 1, start: 9, end: 12, cluster: 3, confidence: 1)
        let roster = [VideoPersonRecord(videoID: 1, personID: 1, key: "ann", name: "Ann Lee", descriptor: "", portraitAt: 0, portraitBox: nil)]
        let rows = [row(1, 0, 2), row(2, 2, 4.5), row(3, 4.5, 8), row(4, 8, 11), row(5, 20, 22)]
        #expect(TranscriptSpeakers.label(for: rows[0], turns: [ann, feed, voice], roster: roster) == "Ann Lee")
        #expect(TranscriptSpeakers.label(for: rows[2], turns: [ann, feed, voice], roster: roster) == "Feed 3")
        #expect(TranscriptSpeakers.label(for: rows[3], turns: [ann, feed, voice], roster: roster) == "Speaker 4")
        #expect(TranscriptSpeakers.label(for: rows[4], turns: [ann, feed, voice], roster: roster) == nil)
        let labels = TranscriptSpeakers.labels(for: rows, turns: [ann, feed, voice], roster: roster)
        #expect(labels == [1: "Ann Lee", 3: "Feed 3", 4: "Speaker 4"])
    }

    @Test("the user's attribution beats the turns: a roster person, someone else in the library, or Unknown")
    func attribution() {
        var ann = SpeakerTurn(videoID: 1, start: 0, end: 5, cluster: 0, confidence: 1); ann.personKey = "ann"
        let roster = [VideoPersonRecord(videoID: 1, personID: 1, key: "ann", name: "Ann Lee", descriptor: "", portraitAt: 0, portraitBox: nil)]
        let people = [PersonRecord(id: 2, key: "bob", name: "Bob Ray", descriptor: "")]
        var line = row(1, 0, 2)
        #expect(TranscriptSpeakers.label(for: line, turns: [ann], roster: roster, people: people) == "Ann Lee")
        line.speaker = .unknown
        #expect(TranscriptSpeakers.label(for: line, turns: [ann], roster: roster, people: people) == "Unknown")
        line.speaker = .person(key: "bob")
        #expect(TranscriptSpeakers.label(for: line, turns: [ann], roster: roster, people: people) == "Bob Ray")
        // A key nobody in the library carries any more still shows, as the key.
        line.speaker = .person(key: "gone")
        #expect(TranscriptSpeakers.label(for: line, turns: [ann], roster: roster, people: people) == "gone")
        line.speaker = .automatic
        #expect(TranscriptSpeakers.label(for: line, turns: [], roster: roster, people: people) == nil)
        // A line with no turn under it stays unlabelled unless the user says Unknown.
        var silent = row(2, 20, 22); silent.speaker = .unknown
        let labels = TranscriptSpeakers.labels(for: [line, silent], turns: [ann], roster: roster, people: people)
        #expect(labels == [1: "Ann Lee", 2: "Unknown"])
    }
}

@Suite("Transcript line tags")
struct TranscriptLineTagsTests {
    @Test("a line takes the content tags of the scenes holding its midpoint; bookkeeping tags stay out; Reel leads")
    func lineTags() {
        #expect(TranscriptSheet.lineTags(["question", "person:ann", "podcast:grid", "portrait-fit:good",
                                          "reel-highlight", "answer", "auto-hidden", "center-stage:poor", "vip:x"])
                == ["reel-highlight", "answer", "question"])
        let row = TranscriptRow(id: 1, videoID: 1, language: "en", isTranslation: false, startTime: 10, endTime: 14,
                                text: "", originalText: nil, wordsJSON: nil, provider: nil, model: nil)
        func scene(_ id: Int64, _ start: Double, _ end: Double) -> SceneRecord {
            SceneRecord(id: id, videoID: 1, runID: nil, startTime: start, endTime: end, excluded: false, ignored: false,
                        favorite: false, tags: [], gradeCount: 0, videoPath: "/v.mp4", videoFilename: "v.mp4",
                        videoDuration: 100, wide: true)
        }
        // Midpoint 12: the first two hold it, the edge scene ending at 11 does not.
        let covering = TranscriptSheet.scenes(covering: row, in: [scene(1, 0, 30), scene(2, 11.5, 13), scene(3, 0, 11)])
        #expect(covering.map(\.id) == [1, 2])
    }
}

@Suite("Transcript video panel")
struct TranscriptVideoPanelTests {
    @Test("the talker frame maps onto the picture inside a letterboxed player")
    func videoRect() {
        // 16:9 picture in a 400×300 box: full width, bars top and bottom.
        let wide = TranscriptSheet.videoRect(in: CGSize(width: 400, height: 300), videoWidth: 1920, videoHeight: 1080)
        #expect(wide == CGRect(x: 0, y: 37.5, width: 400, height: 225))
        // 9:16 picture in a 400×225 box: full height, bars left and right.
        let tall = TranscriptSheet.videoRect(in: CGSize(width: 400, height: 225), videoWidth: 1080, videoHeight: 1920)
        #expect(abs(tall.width - 126.5625) < 0.001)
        #expect(tall.height == 225)
        #expect(abs(tall.minX - (400 - 126.5625) / 2) < 0.001)
        // Unknown dimensions: the whole box.
        #expect(TranscriptSheet.videoRect(in: CGSize(width: 10, height: 5), videoWidth: 0, videoHeight: 0)
                == CGRect(x: 0, y: 0, width: 10, height: 5))
    }
}
