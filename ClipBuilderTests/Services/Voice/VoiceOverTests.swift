import Foundation
import Testing
@testable import Clip_Builder

struct VoiceOverPlacementTests {
    private func take(_ id: String = "a", video: Int64 = 1, source: Double, duration: Double = 2,
                      text: String = "", words: [TranscriptWord] = [], language: String = "pt") -> VoiceTake {
        VoiceTake(id: id, projectID: 7, videoID: video, sourceTime: source, reelTime: 0, duration: duration,
                  file: "\(id).m4a", language: language, text: text, words: words, state: text.isEmpty ? .empty : .done)
    }

    private func cut(video: Int64 = 1, _ start: Double, _ end: Double, at reel: Double, speed: Double = 1,
                     pauses: [WizardStrikePauses.Pause] = []) -> VoiceOverPlacement.Cut {
        let held = pauses.reduce(0) { $0 + $1.duration }
        return .init(videoID: video, sourceStart: start, sourceEnd: end, speed: speed, reelStart: reel,
                     reelDuration: (end - start) / speed + held, pauses: pauses)
    }

    @Test("A recording starts where its picture is, whatever the clip order")
    func followsPicture() {
        let takes = [take(source: 22)]
        let recorded = [cut(10, 15, at: 0), cut(20, 25, at: 5)]
        #expect(VoiceOverPlacement.place(takes, in: recorded).map(\.start) == [7])
        // The same footage first, behind a 3 s bumper.
        let reordered = [cut(20, 25, at: 3), cut(10, 15, at: 8)]
        #expect(VoiceOverPlacement.place(takes, in: reordered).map(\.start) == [5])
    }

    @Test("Speed and a pause before the anchor move the start")
    func speedAndPause() {
        let fast = [cut(20, 30, at: 4, speed: 2)]
        #expect(VoiceOverPlacement.place([take(source: 26)], in: fast).map(\.start) == [7])
        let held = [cut(20, 30, at: 0, pauses: [.init(time: 2, duration: 1.2)])]
        let starts = VoiceOverPlacement.place([take("early", source: 21), take("late", source: 26)], in: held).map(\.start)
        #expect(starts[0] == 1)
        #expect(abs(starts[1] - 7.2) < 1e-9)
    }

    @Test("A recording whose footage left the reel is left out, another video's clip never claims it")
    func removedFootage() {
        let cuts = [cut(10, 15, at: 0), cut(video: 2, 20, 25, at: 5)]
        #expect(VoiceOverPlacement.place([take(source: 22), take("b", source: 16)], in: cuts).isEmpty)
        #expect(VoiceOverPlacement.place([take(source: 12, duration: 0)], in: cuts).isEmpty)
    }

    @Test("Recordings come back in reel order")
    func reelOrder() {
        let cuts = [cut(20, 25, at: 0), cut(10, 15, at: 5)]
        let placed = VoiceOverPlacement.place([take("first", source: 11), take("second", source: 21)], in: cuts)
        #expect(placed.map(\.take.id) == ["second", "first"])
    }

    @Test("Reel time maps back to the video and source second under it")
    func anchor() {
        var first = WizardPreviewClip(id: "take-1-0", title: "", scene: Fixtures.scene(id: 1), start: 10, end: 14)
        first.outputStart = 0
        first.outputDuration = 4
        var second = WizardPreviewClip(id: "take-1-1", title: "", scene: Fixtures.scene(id: 2), start: 30, end: 36)
        second.outputStart = 4
        second.outputDuration = 6
        let anchor = VoiceOverPlacement.anchor(at: 5.5, in: [first, second])
        #expect(anchor?.videoID == 1)
        #expect(abs((anchor?.sourceTime ?? 0) - 31.5) < 1e-9)
        // Round trip: the take sits back where it was recorded.
        let placed = VoiceOverPlacement.place([take(source: 31.5)], in: VoiceOverPlacement.cuts(from: [first, second]))
        #expect(abs((placed.first?.start ?? 0) - 5.5) < 1e-9)
    }

    @Test("Caption words keep their clocks; one spoken across a join shows on both sides")
    func captionsAcrossJoin() {
        let words = [TranscriptWord(word: "um", start: 0.2, end: 0.6), TranscriptWord(word: "dois", start: 0.8, end: 1.2),
                     TranscriptWord(word: "tres", start: 1.6, end: 2.0)]
        let cuts = [cut(10, 15, at: 0), cut(20, 25, at: 5)]
        // Starts 1 s before the join: "dois" is spoken from 4.8 s to 5.2 s, across it.
        let placed = VoiceOverPlacement.place([take(source: 14, duration: 2.2, text: "um dois tres", words: words)], in: cuts)
        let before = VoiceOverPlacement.captions(for: cuts[0], placed: placed, language: nil)
        let after = VoiceOverPlacement.captions(for: cuts[1], placed: placed, language: nil)
        #expect(before.map(\.text) == ["um dois"])
        #expect(abs((before.first?.start ?? 0) - 4.2) < 1e-9)
        #expect(before.first?.end == 5)
        #expect(after.map(\.text) == ["dois tres"])
        #expect(after.first?.start == 0)
        #expect(abs((after.first?.words?.last?.start ?? 0) - 0.6) < 1e-9)
    }

    @Test("The caption language picks the translation and spreads it over the speech")
    func translatedCaption() {
        var spoken = take(source: 11, duration: 3, text: "boa noite",
                          words: [.init(word: "boa", start: 0.5, end: 1), .init(word: "noite", start: 1, end: 2.5)])
        spoken.translations["en"] = VoiceTakeTranslation(text: "good evening everyone")
        let english = VoiceOverPlacement.captionWords(for: spoken, language: "en-US")
        #expect(english.map(\.word) == ["good", "evening", "everyone"])
        #expect(english.first?.start == 0.5)
        #expect(abs((english.last?.end ?? 0) - 2.5) < 1e-9)
        // The spoken language, or one with no translation yet, shows the original.
        #expect(VoiceOverPlacement.captionWords(for: spoken, language: "pt-BR").map(\.word) == ["boa", "noite"])
        #expect(VoiceOverPlacement.captionWords(for: spoken, language: "es").map(\.word) == ["boa", "noite"])
        #expect(VoiceOverPlacement.captionWords(for: take(source: 1), language: nil).isEmpty)
    }

    @Test("A voice line hides only the footage words under it")
    func footageUnderVoice() {
        func words(_ list: [(String, Double, Double)]) -> [TranscriptWord] { list.map { .init(word: $0.0, start: $0.1, end: $0.2) } }
        let long = TranscriptSegment(start: 20, end: 30, text: "a b c d e",
                                     words: words([("a", 20, 22), ("b", 22, 24), ("c", 24, 26), ("d", 26, 28), ("e", 28, 30)]))
        // The cut plays 20...30 at double speed; the voice talks over output 2...3 s, source 24...26.
        let timing = WizardStrikePauses.Timing(plannedDuration: 5)
        let voice = [TranscriptSegment(start: 2, end: 3, text: "voz", words: nil)]
        let kept = VoiceOverPlacement.footage([long], hiddenBy: voice, clipStart: 20, speed: 2, timing: timing)
        #expect(kept.map(\.text) == ["a b", "d e"])
        #expect(kept.map(\.start) == [20, 26] && kept.map(\.end) == [24, 30])

        // No word clocks: mostly covered goes, a little covered is shown for less time.
        let covered = TranscriptSegment(start: 24, end: 26.5, text: "por baixo", words: nil)
        let edge = TranscriptSegment(start: 25.5, end: 30, text: "depois", words: nil)
        let plain = VoiceOverPlacement.footage([covered, edge], hiddenBy: voice, clipStart: 20, speed: 2, timing: timing)
        #expect(plain.map(\.text) == ["depois"])
        #expect(plain.first?.start == 26 && plain.first?.end == 30)
        #expect(VoiceOverPlacement.footage([long], hiddenBy: [], clipStart: 20, speed: 2, timing: timing).count == 1)
    }

    @Test("A voice line spoken during a hold hides the caption on the held frame")
    func footageUnderVoiceInHold() {
        // 1 s hold at planned 2 s: output 2...3 s is all source 22 s.
        let timing = WizardStrikePauses.Timing(plannedDuration: 5, pauses: [.init(time: 2, duration: 1)])
        let footage = [TranscriptSegment(start: 20, end: 21.5, text: "antes", words: nil),
                       TranscriptSegment(start: 21.9, end: 22.05, text: "no golpe", words: nil)]
        let voice = [TranscriptSegment(start: 2.2, end: 2.8, text: "olha", words: nil)]
        let kept = VoiceOverPlacement.footage(footage, hiddenBy: voice, clipStart: 20, speed: 1, timing: timing)
        #expect(kept.map(\.text) == ["antes"])
    }

    @Test("Across a crossfade the caption words stay under the voice")
    func captionsAcrossCrossfade() {
        let words = [TranscriptWord(word: "um", start: 0.2, end: 0.6), TranscriptWord(word: "dois", start: 1.6, end: 2.0)]
        let timeline = [cut(10, 15, at: 0), cut(20, 25, at: 5)]
        // The join overlaps by half a second: the second cut starts at 4.5 s of the reel.
        let clock = RenderClock(segmentStarts: [0, 5], overlaps: [0: 0.5])
        let reel = VoiceOverPlacement.joined(timeline, clock: clock)
        #expect(reel.map(\.reelStart) == [0, 4.5])
        let recording = take(source: 14, duration: 2.2, text: "um dois", words: words)
        // The audio starts at 4 s on either clock; "dois" is heard at 5.6 s of the reel.
        #expect(clock.map(VoiceOverPlacement.place([recording], in: timeline)[0].start) == 4)
        let placed = VoiceOverPlacement.place([recording], in: reel)
        let after = VoiceOverPlacement.captions(for: reel[1], placed: placed, language: nil)
        #expect(after.map(\.text) == ["dois"])
        #expect(abs((after.first?.start ?? 0) - 1.1) < 1e-9)
        // A recording that starts after the join moves with its cut.
        let later = VoiceOverPlacement.place([take(source: 21)], in: reel)
        #expect(later.first?.start == 5.5 && clock.map(6) == 5.5)
    }

    @Test("Footage that is in the reel twice keeps the recording on the showing it was made over")
    func repeatedFootage() {
        // The rough cut shows 10...15 twice; the voice was recorded over the second showing.
        var one = WizardPreviewClip(id: "take-1-0", title: "", scene: Fixtures.scene(id: 1), start: 10, end: 15)
        one.outputStart = 0
        one.outputDuration = 5
        var two = WizardPreviewClip(id: "take-2-0", title: "", scene: Fixtures.scene(id: 1), start: 10, end: 15)
        two.outputStart = 5
        two.outputDuration = 5
        #expect(VoiceOverPlacement.anchor(at: 1, in: [one, two])?.occurrence == 0)
        let anchor = VoiceOverPlacement.anchor(at: 6, in: [one, two])
        #expect(anchor?.sourceTime == 11 && anchor?.occurrence == 1)

        var second = take(source: 11)
        second.reelTime = 6
        second.occurrence = 1
        // The final reel opens with a 4 s card: its clock is not the rough cut's.
        let reel = [cut(10, 15, at: 4), cut(10, 15, at: 9)]
        #expect(VoiceOverPlacement.place([second], in: reel).first?.start == 10)
        // One showing was removed: it goes with the one that is left.
        #expect(VoiceOverPlacement.place([second], in: [cut(10, 15, at: 4)]).first?.start == 5)
        // A recording that never noted its showing takes the nearest place.
        var old = take(source: 11)
        old.reelTime = 1.2
        #expect(VoiceOverPlacement.place([old], in: [cut(10, 15, at: 0), cut(10, 15, at: 5)]).first?.start == 1)
        // The same pause twice: the one it was recorded over.
        let held = [cut(10, 15, at: 4, pauses: [.init(time: 2, duration: 1)]),
                    cut(10, 15, at: 10, pauses: [.init(time: 2, duration: 1)])]
        var inHold = take(source: 12, duration: 0.5)
        inHold.holdOffset = 0.5
        inHold.occurrence = 1
        #expect(abs((VoiceOverPlacement.place([inHold], in: held).first?.start ?? 0) - 12.5) < 1e-9)
    }

    @Test("A pause in only one showing: the recording stays on that showing with pauses off, sound and words together")
    func showingsWithAndWithoutPause() {
        // Rough cut: the footage once whole, then again with a pause on contact at 12.
        func clip(_ id: String, _ start: Double, _ end: Double, at reel: Double, plays: Double) -> WizardPreviewClip {
            var clip = WizardPreviewClip(id: id, title: "", scene: Fixtures.scene(id: 1), start: start, end: end)
            clip.outputStart = reel
            clip.outputDuration = plays
            return clip
        }
        let rough = [clip("a", 10, 15, at: 0, plays: 5), clip("b", 10, 12, at: 5, plays: 2),
                     clip("hold", 12, 12, at: 7, plays: 1), clip("c", 12, 15, at: 8, plays: 3)]
        let cuts = VoiceOverPlacement.cuts(from: rough)
        #expect(VoiceOverPlacement.showings(videoID: 1, time: 12, hold: true, in: cuts) == [[0], [2, 3]])
        #expect(VoiceOverPlacement.showings(videoID: 1, time: 12, hold: false, in: cuts) == [[0], [3]])
        let inPause = VoiceOverPlacement.anchor(at: 7.4, in: rough)
        #expect(inPause?.occurrence == 1 && abs((inPause?.holdOffset ?? 0) - 0.4) < 1e-9)
        #expect(VoiceOverPlacement.anchor(at: 9, in: rough)?.occurrence == 1)
        #expect(VoiceOverPlacement.anchor(at: 2, in: rough)?.occurrence == 0)

        var recording = take(source: 12, duration: 0.5)
        recording.holdOffset = 0.4
        recording.occurrence = 1
        recording.reelTime = 7.4
        // Back in the rough cut: inside the pause.
        #expect(abs((VoiceOverPlacement.place([recording], in: cuts).first?.start ?? 0) - 7.4) < 1e-9)
        // The reel with pauses off, behind a 4 s card: the second showing's picture.
        let plain = [cut(10, 15, at: 4), cut(10, 15, at: 9)]
        let placed = VoiceOverPlacement.place([recording], in: plain)
        #expect(placed.first?.start == 11 && placed.first?.cut == 1)
        // With the pause in the second showing only: that far into it.
        let paused = [cut(10, 15, at: 4), cut(10, 15, at: 9, pauses: [.init(time: 2, duration: 1)])]
        #expect(abs((VoiceOverPlacement.place([recording], in: paused).first?.start ?? 0) - 11.4) < 1e-9)

        // The moment the picture moves again after the pause: after it in the reel too.
        let resumed = VoiceOverPlacement.anchor(at: 8, in: rough)
        #expect(resumed?.sourceTime == 12 && resumed?.holdOffset == nil && resumed?.occurrence == 1)
        var moving = take(source: 12, duration: 0.5)
        moving.occurrence = 1
        #expect(VoiceOverPlacement.place([moving], in: cuts).first?.start == 8)
        #expect(VoiceOverPlacement.place([moving], in: paused).first?.start == 12)
        // At double speed too: 0.03 s of source before the pause is still before it.
        let fast = [VoiceOverPlacement.Cut(videoID: 1, sourceStart: 0, sourceEnd: 6, speed: 2, reelStart: 0,
                                           reelDuration: 3.8, pauses: [.init(time: 1, duration: 0.8)])]
        #expect(abs((VoiceOverPlacement.place([take(source: 1.97, duration: 0.5)], in: fast).first?.start ?? 0) - 0.985) < 1e-9)
        #expect(abs((VoiceOverPlacement.place([take(source: 2, duration: 0.5)], in: fast).first?.start ?? 0) - 1.8) < 1e-9)
        // Just before the pause it stays before it.
        var before = take(source: 11.95, duration: 0.5)
        before.occurrence = 1
        #expect(abs((VoiceOverPlacement.place([before], in: paused).first?.start ?? 0) - 10.95) < 1e-9)

        // A first showing trimmed to start late, with its pause 0.03 s off: still one showing.
        let near = [clip("a1", 11.77, 12.03, at: 0, plays: 0.26), clip("ah", 12.03, 12.03, at: 0.26, plays: 1),
                    clip("a2", 12.03, 15, at: 1.26, plays: 2.97),
                    clip("b1", 10, 12, at: 4.23, plays: 2), clip("bh", 12, 12, at: 6.23, plays: 1), clip("b2", 12, 15, at: 7.23, plays: 3)]
        let nearCuts = VoiceOverPlacement.cuts(from: near)
        #expect(VoiceOverPlacement.showings(videoID: 1, time: 12, hold: true, in: nearCuts) == [[0, 1], [4, 5]])
        #expect(VoiceOverPlacement.anchor(at: 6.5, in: near)?.occurrence == 1)

        // A recording that never noted its showing: the words go where the sound went,
        // even when the joined clock would have made the other showing the nearer one.
        var old = take(source: 11)
        old.reelTime = 6.9
        let timeline = [cut(10, 15, at: 1), cut(10, 15, at: 11)]
        let onTimeline = VoiceOverPlacement.place([old], in: timeline)
        #expect(onTimeline.first?.start == 2)
        let joined = [cut(10, 15, at: 1), cut(10, 15, at: 10.5)]
        #expect(VoiceOverPlacement.moved(onTimeline, onto: joined).first?.start == 2)
        var late = old
        late.reelTime = 9
        let lateOnTimeline = VoiceOverPlacement.place([late], in: timeline)
        #expect(lateOnTimeline.first?.start == 12)
        #expect(VoiceOverPlacement.moved(lateOnTimeline, onto: joined).first?.start == 11.5)
    }

    @Test("A recipe join the clips are too short for is predicted as the hard cut it becomes")
    func recipeFallbackClock() {
        // 0.5 s clips cannot give a whip pan its 0.2 s and keep 0.4 s; 2 s clips can.
        #expect(RenderEngine.affordableRecipes(durations: [0.5, 0.5], transitions: ["whip_left"]).recipe == [nil])
        let long = RenderEngine.affordableRecipes(durations: [2, 2, 0.5], transitions: ["whip_left", "whip_left"])
        #expect(long.recipe == ["whip_left", nil])
        #expect(long.tailTrim == [0.2, 0, 0] && long.headTrim == [0, 0.2, 0])
        func clip(_ start: Double, _ duration: Double, transIn: String?) -> TimelineClip {
            var clip = TimelineClip()
            clip.videoFile = "/reel-\(start).mp4"
            clip.sourceStart = 0
            clip.startTime = start
            clip.duration = duration
            clip.transIn = transIn
            return clip
        }
        let short = WizardPreviewClips.joinOverlaps([clip(0, 0.5, transIn: nil), clip(0.5, 0.5, transIn: "whip_left")],
                                                    xfadeDuration: 0.5)
        #expect((short[0] ?? 0) == 0)
        let roomy = WizardPreviewClips.joinOverlaps([clip(0, 2, transIn: nil), clip(2, 2, transIn: "whip_left")],
                                                    xfadeDuration: 0.5)
        #expect((roomy[0] ?? 0) == RenderEngine.consumedOverlap("whip_left", xfadeDuration: 0.5))
        // A crossfade next to a rendered recipe is fitted to what the recipe left of the clip.
        let mixed = [clip(0, 2, transIn: nil), clip(2, 0.7, transIn: "whip_left"), clip(2.7, 2, transIn: "fade")]
        let trimmed = MultitrackRenderer.crossfadeOverlaps(durations: [1.8, 0.5, 2], transitions: [nil, "fade"],
                                                           transitionDuration: 0.5)
        let whole = MultitrackRenderer.crossfadeOverlaps(durations: [2, 0.7, 2], transitions: [nil, "fade"],
                                                         transitionDuration: 0.5)
        let predicted = WizardPreviewClips.joinOverlaps(mixed, xfadeDuration: 0.5)
        #expect(abs((predicted[1] ?? 0) - (trimmed[1] ?? -1)) < 1e-9)
        #expect((trimmed[1] ?? 0) < (whole[1] ?? 0) - 0.05)
        // A reel with pauses is assembled on a 30 fps clock: 0.12 s becomes four frames.
        var held = clip(2, 1, transIn: nil)
        held.hold = true
        let flashes = [clip(0, 2, transIn: nil), held, clip(3, 2, transIn: "flash_white")]
        let onFrames = WizardPreviewClips.joinOverlaps(flashes, xfadeDuration: 0.5)
        #expect(abs((onFrames[1] ?? 0) - 4.0 / 30) < 1e-9 && (onFrames[0] ?? 0) == 0)
        let free = WizardPreviewClips.joinOverlaps([clip(0, 2, transIn: nil), clip(2, 2, transIn: "flash_white")], xfadeDuration: 0.5)
        #expect(abs((free[0] ?? 0) - 0.12) < 1e-9)
        // With a bumper the reel is not on the frame clock, and the bumper's join
        // is fitted to its own two clips: a short clip earlier does not cancel it.
        var bumper = clip(0, 2, transIn: nil)
        bumper.bumper = true
        var frozen = clip(2, 3, transIn: "flash_white")
        frozen.strikeImpactsFrozen = true
        #expect(abs((WizardPreviewClips.joinOverlaps([bumper, frozen], xfadeDuration: 0.5)[0] ?? 0) - 0.12) < 1e-9)
        var closing = clip(2.1, 2, transIn: "fade")
        closing.bumper = true
        let grouped = WizardPreviewClips.joinOverlaps([clip(0, 0.1, transIn: nil), clip(0.1, 2, transIn: "fade"), closing],
                                                      xfadeDuration: 0.5)
        #expect((grouped[0] ?? 0) == 0 && abs((grouped[1] ?? 0) - 0.5) < 1e-9)
        // B-roll cuts the clip under it into segments, and a join is fitted to
        // the segments beside it: a 0.2 s tail leaves a fade 0.08 s, two frames on the frame clock.
        func cutaway(_ start: Double, _ duration: Double) -> TimelineClip {
            var clip = clip(start, duration, transIn: nil)
            clip.role = .cutaway
            return clip
        }
        var last = clip(10, 5, transIn: "cut")
        last.strikeImpactsFrozen = true
        let underBroll = WizardPreviewClips.joinOverlaps([clip(0, 5, transIn: nil), clip(5, 5, transIn: "fade"), last],
                                                         cutaways: [cutaway(4.8, 0.2)], xfadeDuration: 0.5)
        #expect(abs((underBroll[0] ?? 0) - 2.0 / 30) < 1e-9 && (underBroll[1] ?? 0) == 0)
        // A recipe that the whole clips could carry is a hard cut next to a 0.5 s segment.
        let recipe = [clip(0, 5, transIn: nil), clip(5, 5, transIn: "whip_left")]
        #expect((WizardPreviewClips.joinOverlaps(recipe, xfadeDuration: 0.5)[0] ?? 0) > 0)
        #expect((WizardPreviewClips.joinOverlaps(recipe, cutaways: [cutaway(4.5, 0.5)], xfadeDuration: 0.5)[0] ?? 0) == 0)
        // B-roll that starts 20 ms after a join: the renderer drops that sliver, the next
        // slice no longer starts on the clip's own edge, and the fade is not rendered.
        let fadeIn = [clip(0, 5, transIn: nil), clip(5, 5, transIn: "fade")]
        #expect(abs((WizardPreviewClips.joinOverlaps(fadeIn, xfadeDuration: 0.5)[0] ?? 0) - 0.5) < 1e-9)
        #expect((WizardPreviewClips.joinOverlaps(fadeIn, cutaways: [cutaway(5.02, 0.98)], xfadeDuration: 0.5)[0] ?? 0) == 0)
        // B-roll across the join leaves it as it is.
        #expect(abs((WizardPreviewClips.joinOverlaps(fadeIn, cutaways: [cutaway(4, 2)], xfadeDuration: 0.5)[0] ?? 0) - 0.4) < 1e-9)
        // B-roll away from the joins changes nothing.
        #expect(WizardPreviewClips.joinOverlaps(recipe, cutaways: [cutaway(1, 2)], xfadeDuration: 0.5)
            == WizardPreviewClips.joinOverlaps(recipe, xfadeDuration: 0.5))
    }

    @Test("A caption field follows the stored text unless the user typed something else")
    func captionFieldArrivals() {
        // Its own save comes back while the user types on: the typing stays, spaces included.
        var sent = ["Hello"]
        #expect(VoiceOverRow.arrived("Hello", replacing: "Hi", field: "Hello ", sent: &sent, editing: true) == "Hello ")
        #expect(sent.isEmpty)
        // Saved B, typed back to the original A before B came back: A stays, and still differs from the store.
        sent = ["B"]
        #expect(VoiceOverRow.arrived("B", replacing: "A", field: "A", sent: &sent, editing: true) == "A")
        // Its own save comes back after the caret left: the field takes the stored spelling.
        sent = ["Hello world"]
        #expect(VoiceOverRow.arrived("Hello world", replacing: "Hi", field: " Hello  world", sent: &sent, editing: false) == "Hello world")
        // A caption written by the transcriber shows in an untouched field, also with the caret in it.
        sent = []
        #expect(VoiceOverRow.arrived("Jab lands", replacing: "", field: "", sent: &sent, editing: true) == "Jab lands")
        // It does not replace what the user typed.
        #expect(VoiceOverRow.arrived("Jab lands", replacing: "", field: "My words", sent: &sent, editing: false) == "My words")
        // Two saves on their way (B, then C) and the user typed back to A: neither arrival replaces it.
        sent = ["B", "C"]
        #expect(VoiceOverRow.arrived("B", replacing: "A", field: "A", sent: &sent, editing: true) == "A")
        #expect(sent == ["C"])
        #expect(VoiceOverRow.arrived("C", replacing: "B", field: "A", sent: &sent, editing: true) == "A")
        #expect(sent.isEmpty)
        // A later save arriving first (the earlier one changed nothing) clears both.
        sent = ["B", "C"]
        #expect(VoiceOverRow.arrived("C", replacing: "A", field: "C", sent: &sent, editing: false) == "C" && sent.isEmpty)
        // A translation removed because the caption changed empties an untouched field.
        #expect(VoiceOverRow.arrived("", replacing: "Hola", field: "Hola", sent: &sent, editing: false) == "")
    }

    @Test("Footage alone on another track keeps its place, and a clip under another shows only its own part")
    func tracksAndOverlaps() {
        let scene = Fixtures.scene(start: 0, end: 30)
        func clip(_ start: Double, track: Int, transIn: String = "cut") -> TimelineClip {
            var clip = TimelineClip()
            clip.sceneID = scene.id
            clip.startTime = start
            clip.duration = 5
            clip.sourceStart = start
            clip.sourceEnd = start + 5
            clip.track = track
            clip.transIn = transIn
            return clip
        }
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 15)], transitions: [])
        let take = WizardSelectionTake(id: 1, selectionID: 1, ordinal: 1, note: nil, plan: plan,
            sceneIDs: [scene.id], proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        func starts(_ track: [TimelineClip]) -> [Double?] {
            var document = TimelineDocument()
            document.videoTrack = track
            return WizardPreviewClips.rendered(document, take: take, name: "Reel", scenes: [scene], xfadeDuration: 0.5).map(\.outputStart)
        }
        // B is alone on track 1 between A and C.
        #expect(starts([clip(0, track: 0), clip(5, track: 1), clip(10, track: 0)]) == [0, 5, 10])
        // B starts over A's last second and is drawn on top: it shows from 4 s, and the reel is 14 s, not 15.
        #expect(starts([clip(0, track: 0), clip(4, track: 0), clip(9, track: 0)]) == [0, 4, 9])
        // A boundary on another track cuts A's tail to 0.2 s: the fade into B is 0.08 s, not 0.5.
        var short = clip(0, track: 1)
        short.duration = 4.8
        short.sourceEnd = 4.8
        var rest = clip(4.8, track: 1)
        rest.duration = 0.2
        rest.sourceEnd = 5
        let faded = starts([clip(0, track: 0), clip(5, track: 0, transIn: "fade"), short, rest])
        #expect(faded.count == 2 && abs((faded[1] ?? 0) - 4.92) < 1e-6)
    }

    @Test("A layout block's other areas play over its slot, not after it")
    func otherTracksShareTheSlot() {
        let scene = Fixtures.scene(start: 0, end: 30)
        func clip(_ start: Double, track: Int) -> TimelineClip {
            var clip = TimelineClip()
            clip.sceneID = scene.id
            clip.startTime = start
            clip.duration = 5
            clip.sourceStart = start
            clip.sourceEnd = start + 5
            clip.track = track
            clip.transIn = "cut"
            return clip
        }
        var document = TimelineDocument()
        document.videoTrack = [clip(0, track: 0), clip(0, track: 1), clip(5, track: 0)]
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 10)], transitions: [])
        let take = WizardSelectionTake(id: 1, selectionID: 1, ordinal: 1, note: nil, plan: plan,
            sceneIDs: [scene.id], proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let preview = WizardPreviewClips.rendered(document, take: take, name: "Reel", scenes: [scene], xfadeDuration: 0.5)
        #expect(preview.map(\.outputStart) == [0, 5])
        #expect(preview.map(\.start) == [0, 5])
        // The clip of the other area takes no number.
        #expect(preview.map(\.title) == ["Reel · 1", "Reel · 2"] && preview.map(\.id) == ["take-1-0", "take-1-1"])
    }

    @Test("A missing bumper at the start is left out of the reel, and the reel starts with the footage")
    func missingEdgeBumper() {
        func clip(_ start: Double, _ duration: Double, file: String, bumper: Bool = false) -> TimelineClip {
            var clip = TimelineClip()
            clip.videoFile = file
            clip.sourceStart = 0
            clip.startTime = start
            clip.duration = duration
            clip.bumper = bumper
            clip.transIn = "cut"
            return clip
        }
        var document = TimelineDocument()
        document.videoTrack = [clip(0, 2, file: "/intro.mp4", bumper: true), clip(2, 5, file: "/a.mp4"), clip(7, 5, file: "/b.mp4")]
        let missing = WizardPreviewClips.assembly(of: document, scenes: [], xfadeDuration: 0.5, exists: { $0 != "/intro.mp4" })
        #expect(missing.document.videoTrack.map(\.startTime) == [0, 5] && missing.outputs == [0, 5])
        let present = WizardPreviewClips.assembly(of: document, scenes: [], xfadeDuration: 0.5, exists: { _ in true })
        #expect(present.document.videoTrack.map(\.startTime) == [0, 2, 7] && present.outputs == [0, 2, 7])
        // The clock handed to the voice mix is the renderer's: segment starts and joins.
        #expect(present.clock == RenderClock(segmentStarts: [0, 2, 7], overlaps: [:]))
    }

    @Test("A recording made partway into a pause on contact stays that far into it")
    func insideHold() {
        // The rough cut: 10...12, the frame at 12 held for 1 s, then 12...15.
        var before = WizardPreviewClip(id: "take-1-0", title: "", scene: Fixtures.scene(id: 1), start: 10, end: 12)
        before.outputStart = 0
        before.outputDuration = 2
        var hold = WizardPreviewClip(id: "take-1-1", title: "", scene: Fixtures.scene(id: 1), start: 12, end: 12)
        hold.outputStart = 2
        hold.outputDuration = 1
        var after = WizardPreviewClip(id: "take-1-2", title: "", scene: Fixtures.scene(id: 1), start: 12, end: 15)
        after.outputStart = 3
        after.outputDuration = 3
        let clips = [before, hold, after]
        let anchor = VoiceOverPlacement.anchor(at: 2.6, in: clips)
        #expect(anchor?.sourceTime == 12)
        #expect(abs((anchor?.holdOffset ?? 0) - 0.6) < 1e-9)
        #expect(VoiceOverPlacement.anchor(at: 1, in: clips)?.holdOffset == nil)

        var recording = take(source: 12, duration: 0.5)
        recording.holdOffset = 0.6
        // Back in the rough cut, and in the reel, where the pause is inside one cut.
        let preview = VoiceOverPlacement.place([recording], in: VoiceOverPlacement.cuts(from: clips))
        #expect(abs((preview.first?.start ?? 0) - 2.6) < 1e-9)
        let paused = [cut(10, 15, at: 4, pauses: [.init(time: 2, duration: 1)])]
        #expect(abs((VoiceOverPlacement.place([recording], in: paused).first?.start ?? 0) - 6.6) < 1e-9)
        // A shorter pause keeps it inside the pause; no pause puts it on the picture.
        let short = [cut(10, 15, at: 4, pauses: [.init(time: 2, duration: 0.4)])]
        #expect(abs((VoiceOverPlacement.place([recording], in: short).first?.start ?? 0) - 6.35) < 1e-9)
        #expect(VoiceOverPlacement.place([recording], in: [cut(10, 15, at: 4)]).first?.start == 6)
    }

    @Test("A word a correction squeezed between two others still shows")
    func zeroGapWord() {
        let words = [TranscriptWord(word: "go", start: 0.2, end: 0.6), TranscriptWord(word: "right", start: 0.6, end: 0.6),
                     TranscriptWord(word: "now", start: 0.6, end: 1.0)]
        let cuts = [cut(10, 15, at: 0)]
        let placed = VoiceOverPlacement.place([take(source: 11, duration: 1.2, text: "go right now", words: words)], in: cuts)
        #expect(VoiceOverPlacement.captions(for: cuts[0], placed: placed, language: nil).map(\.text) == ["go right now"])
    }

    @Test("Output seconds map back to the unpaused clock, holds to the held frame")
    func plannedTime() {
        let timing = WizardStrikePauses.Timing(plannedDuration: 5, pauses: [.init(time: 2, duration: 1)])
        #expect(timing.plannedTime(forOutput: 1.5) == 1.5)
        #expect(timing.plannedTime(forOutput: 2.5) == 2)
        #expect(timing.plannedTime(forOutput: 4) == 3)
        for planned in [0.0, 1, 2.5, 4.9] {
            #expect(abs(timing.plannedTime(forOutput: timing.outputTime(planned)) - planned) < 1e-9)
        }
    }
}

struct VoiceOverTranscriberTests {
    private var take: VoiceTake {
        VoiceTake(id: "a", projectID: 1, videoID: 1, sourceTime: 0, reelTime: 0, duration: 3, file: "a.m4a",
                  language: "pt", text: "ele bate forte",
                  words: [.init(word: "ele", start: 0.2, end: 0.6), .init(word: "bate", start: 0.6, end: 1.4),
                          .init(word: "forte", start: 1.4, end: 2.4)],
                  translations: ["en": .init(text: "he hits hard"), "es": .init(text: "pega fuerte", edited: true)],
                  state: .done)
    }

    @Test("A corrected word keeps the other words' clocks and drops stale translations")
    func correction() {
        let fixed = VoiceOverTranscriber.corrected(take, text: "ele  chuta forte")
        #expect(fixed.text == "ele chuta forte")
        #expect(fixed.words.map(\.word) == ["ele", "chuta", "forte"])
        #expect(fixed.words.first?.start == 0.2)
        #expect(fixed.words.last?.end == 2.4)
        // Only the translation the user wrote survives a changed original.
        #expect(Set(fixed.translations.keys) == ["es"])
        #expect(VoiceOverTranscriber.corrected(take, text: "ele bate forte") == take)
    }

    @Test("Typing a caption for a recording with no speech found gives it words")
    func typedCaption() {
        var silent = take
        silent.text = ""
        silent.words = []
        silent.state = .empty
        let typed = VoiceOverTranscriber.corrected(silent, text: "olha isso")
        #expect(typed.state == .done)
        #expect(typed.words.map(\.word) == ["olha", "isso"])
        #expect((typed.words.last?.end ?? 0) <= 3)
    }

    @Test("A corrected translation is marked and is not asked for again")
    func translationCorrection() {
        let fixed = VoiceOverTranscriber.corrected(take, translation: "he strikes hard", language: "en-US")
        #expect(fixed.translations["en"] == VoiceTakeTranslation(text: "he strikes hard", edited: true))
        #expect(VoiceOverTranscriber.needingTranslation([fixed], target: "en").isEmpty)
        #expect(VoiceOverTranscriber.needingTranslation([take], target: "fr").map(\.id) == ["a"])
        // Spoken in the target language, or not transcribed yet: nothing to translate.
        #expect(VoiceOverTranscriber.needingTranslation([take], target: "pt-BR").isEmpty)
        var pending = take
        pending.text = ""
        #expect(VoiceOverTranscriber.needingTranslation([pending], target: "fr").isEmpty)
    }
}

struct VoiceOverMixerTests {
    private let lines = [VoiceOverMixer.Line(url: URL(fileURLWithPath: "/a.m4a"), start: 2, duration: 3),
                         VoiceOverMixer.Line(url: URL(fileURLWithPath: "/b.m4a"), start: 9, duration: 4)]

    @Test("The reel's own sound is lowered under each recording with a ramp")
    func bed() {
        #expect(VoiceOverMixer.bedExpression(lines: [], level: 0.25) == "1")
        #expect(VoiceOverMixer.bedExpression(lines: [lines[0]], level: 0.25)
            == "1-0.750*min(1,clip((t-1.850)/0.150,0,1)*clip((5.150-t)/0.150,0,1))")
    }

    @Test("Each recording is delayed to its start and one that would overrun is cut with a fade")
    func filter() {
        let filter = VoiceOverMixer.filter(lines: lines, level: 0.4, reelHasAudio: true, reelDuration: 11)
        #expect(filter.contains("[1:a]atrim=duration=3.000,asetpts=PTS-STARTPTS,aresample=48000,"
            + "aformat=channel_layouts=stereo,adelay=2000:all=1[voice0]"))
        #expect(filter.contains(":eval=frame,apad[bed]"))
        #expect(filter.contains("[2:a]atrim=duration=2.000,asetpts=PTS-STARTPTS,afade=t=out:st=1.850:d=0.150,"))
        #expect(filter.contains("adelay=9000:all=1[voice1]"))
        #expect(filter.hasSuffix("[bed][voice0][voice1]amix=inputs=3:duration=first:dropout_transition=0:normalize=0[aout]"))
        let silent = VoiceOverMixer.filter(lines: [lines[0]], level: 0.4, reelHasAudio: false, reelDuration: 11)
        #expect(silent.hasPrefix("anullsrc=r=48000:cl=stereo:d=11.000,asetpts=PTS-STARTPTS[bed];"))
    }

    @Test("Preferences: included at the default level until the user says otherwise")
    func preferences() throws {
        let suite = "VoiceOverMixerTests.preferences"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VoiceOverPreferences.bedLevel(profile: "P", defaults: defaults) == VoiceOverMixer.defaultBedLevel)
        defaults.set(0.6, forKey: VoiceOverPreferences.levelKey(profile: "P"))
        #expect(VoiceOverPreferences.bedLevel(profile: "P", defaults: defaults) == 0.6)
        defaults.set(false, forKey: VoiceOverPreferences.includeKey(profile: "P"))
        #expect(VoiceOverPreferences.bedLevel(profile: "P", defaults: defaults) == nil)
        #expect(VoiceOverPreferences.bedLevel(profile: "Other", defaults: defaults) == VoiceOverMixer.defaultBedLevel)
    }

    @Test("The voice is audible at its start and the reel's sound is lowered under it")
    func mixesIntoReel() async throws {
        let directory = try TempDirectory(prefix: "VoiceOverMix")
        let reel = directory.url.appendingPathComponent("reel.mp4")
        let voice = directory.url.appendingPathComponent("voice.m4a")
        let output = directory.url.appendingPathComponent("out.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=black:s=160x90:r=30:d=6",
                              "-f", "lavfi", "-i", "sine=frequency=220:sample_rate=48000:duration=6",
                              "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", reel.path], timeout: 120)
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "sine=frequency=1760:sample_rate=48000:duration=2",
                              "-c:a", "aac", voice.path], timeout: 120)
        try await VoiceOverMixer.mix(video: reel, lines: [.init(url: voice, start: 3, duration: 2)], level: 0.1, output: output)

        #expect(abs(await FFmpeg.duration(of: output) - (await FFmpeg.duration(of: reel))) < 0.1)
        // The 1760 Hz voice exists only between 3 s and 5 s; the 220 Hz bed is quieter there.
        func level(_ band: String, from start: Double) async throws -> Double {
            // astats accumulates over the excerpt; the last printed value is its RMS level.
            let log = try await FFmpeg.run(["-hide_banner", "-ss", String(start), "-t", "1", "-i", output.path,
                "-af", "\(band),astats=metadata=1:reset=0,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-",
                "-vn", "-f", "null", "-"], timeout: 120)
            let match = try #require(log.matches(of: /RMS_level=(-?[\d.]+)/).last)
            return try #require(Double(match.1))
        }
        let voiceBefore = try await level("highpass=f=1200", from: 1)
        let voiceDuring = try await level("highpass=f=1200", from: 3.5)
        let bedBefore = try await level("lowpass=f=500", from: 1)
        let bedDuring = try await level("lowpass=f=500", from: 3.5)
        #expect(voiceDuring > voiceBefore + 20)
        #expect(bedDuring < bedBefore - 12)
    }
}

struct VoiceTakeStoreTests {
    @Test("A recording round-trips with its words and translations, per project and video")
    func roundTrip() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        var take = VoiceTake(id: "one", projectID: 3, videoID: videoID, sourceTime: 4.5, reelTime: 9, duration: 2.5,
                             file: "one.m4a")
        try await temp.database.saveVoiceTake(take)
        #expect(try await temp.database.fetchVoiceTakes(projectID: 3, videoIDs: [videoID]).first?.state == .pending)

        take.language = "pt"
        take.text = "boa noite"
        take.words = [.init(word: "boa", start: 0.1, end: 0.5), .init(word: "noite", start: 0.5, end: 1.2)]
        take.translations = ["en": .init(text: "good evening", edited: true)]
        take.state = .done
        try await temp.database.saveVoiceTake(take)
        let stored = try #require(try await temp.database.fetchVoiceTakes(projectID: 3, videoIDs: [videoID]).first)
        #expect(stored.text == "boa noite")
        #expect(stored.words == take.words)
        #expect(stored.translations == take.translations)
        #expect(stored.sourceTime == 4.5 && stored.reelTime == 9 && stored.duration == 2.5)
        #expect(!stored.createdAt.isEmpty)

        // Another project, or another video, never sees it.
        #expect(try await temp.database.fetchVoiceTakes(projectID: 4, videoIDs: [videoID]).isEmpty)
        #expect(try await temp.database.fetchVoiceTakes(projectID: 3, videoIDs: [videoID + 100]).isEmpty)
        #expect(try await temp.database.fetchVoiceTakes(projectID: 3, videoIDs: []).isEmpty)

        try await temp.database.deleteVoiceTake(id: "one")
        #expect(try await temp.database.fetchVoiceTakes(projectID: 3, videoIDs: [videoID]).isEmpty)
    }

    @Test("Late results never bring back a deleted recording or overwrite a correction")
    func conditionalUpdates() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        var take = VoiceTake(id: "one", projectID: 3, videoID: videoID, sourceTime: 1, reelTime: 1, duration: 2, file: "one.m4a")
        take.holdOffset = 0.6
        try await temp.database.saveVoiceTake(take)
        #expect(try await temp.database.fetchVoiceTake(id: "one")?.holdOffset == 0.6)

        // The user typed a caption before the transcriber answered: theirs stays.
        var typed = take
        typed.text = "minha legenda"
        typed.state = .done
        #expect(try await temp.database.updateVoiceTake(typed))
        take.text = "transcrito"
        take.state = .done
        #expect(try await temp.database.setVoiceTakeTranscript(take) == false)
        #expect(try await temp.database.fetchVoiceTake(id: "one")?.text == "minha legenda")

        // A translation of text that has since changed is refused; a current one is kept once.
        #expect(try await temp.database.setVoiceTakeTranslation(id: "one", language: "en", text: "old", of: "transcrito") == false)
        #expect(try await temp.database.setVoiceTakeTranslation(id: "one", language: "en", text: "my caption", of: "minha legenda"))
        #expect(try await temp.database.setVoiceTakeTranslation(id: "one", language: "en", text: "again", of: "minha legenda") == false)
        #expect(try await temp.database.fetchVoiceTake(id: "one")?.translations["en"]?.text == "my caption")

        // Deleted while work was out: nothing puts it back.
        try await temp.database.deleteVoiceTake(id: "one")
        #expect(try await temp.database.updateVoiceTake(typed) == false)
        #expect(try await temp.database.setVoiceTakeTranscript(take) == false)
        #expect(try await temp.database.setVoiceTakeTranslation(id: "one", language: "fr", text: "x", of: "minha legenda") == false)
        #expect(try await temp.database.fetchVoiceTakes(projectID: 3, videoIDs: [videoID]).isEmpty)
    }

    /// Two stored recordings with audio, shown in a library.
    @MainActor private func shownLibrary() async throws
        -> (temp: TempDatabase, library: VoiceOverLibrary, owner: VoiceOverLibrary.Owner, ai: AIService, takes: [VoiceTake]) {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let database = temp.database
        try FileManager.default.createDirectory(at: database.voiceTakesDirectory, withIntermediateDirectories: true)
        for (index, id) in ["one", "two"].enumerated() {
            var take = VoiceTake(id: id, projectID: 3, videoID: videoID, sourceTime: 1, reelTime: Double(index + 1), duration: 2,
                                 file: "\(id).m4a")
            take.text = "oi"
            take.state = .done
            try await database.saveVoiceTake(take)
            try Data([1]).write(to: database.voiceTakeURL(take))
        }
        let library = VoiceOverLibrary()
        let owner = VoiceOverLibrary.Owner(projectID: 3, videoIDs: [videoID], library: await database.path.path)
        let ai = AIService(config: AppSettings().ai)
        await library.load(owner, database: database, language: "pt", ai: ai)
        return (temp, library, owner, ai, library.takes)
    }

    private func audioExists(_ take: VoiceTake, _ database: Database) -> Bool {
        FileManager.default.fileExists(atPath: database.voiceTakeURL(take).path)
    }

    @Test("Delete and Undo, however fast, reach the database in order; audio goes only when Undo is given up")
    @MainActor func deleteUndoOrder() async throws {
        let (temp, library, owner, ai, takes) = try await shownLibrary()
        let database = temp.database
        #expect(takes.map(\.id) == ["one", "two"])

        // Delete and Undo in the same breath, many times: the row is there at the end.
        for _ in 0..<20 {
            library.delete(takes[0], database: database)
            library.undoDelete(database: database)
        }
        await library.settle()
        #expect(library.takes.map(\.id) == ["one", "two"])
        #expect(library.lastDeleted == nil)
        #expect(try await database.fetchVoiceTake(id: "one") != nil)
        #expect(audioExists(takes[0], database))

        // Delete pressed twice on one row deletes it once, and Undo is still offered with its audio.
        library.delete(takes[1], database: database)
        library.delete(takes[1], database: database)
        // A reload asked for before the delete has landed does not show the deleted one again.
        await library.load(owner, database: database, language: "pt", ai: ai)
        #expect(library.takes.map(\.id) == ["one"])
        #expect(library.lastDeleted?.id == "two")
        #expect(try await database.fetchVoiceTake(id: "two") == nil)
        #expect(audioExists(takes[1], database))

        // The next delete takes Undo's place: the first one's audio goes, its own stays.
        library.delete(takes[0], database: database)
        await library.settle()
        #expect(library.takes.isEmpty && library.lastDeleted?.id == "one")
        #expect(!audioExists(takes[1], database))
        #expect(audioExists(takes[0], database))

        // Undo, a correction typed at once, and a reload: the correction is on the restored row.
        library.undoDelete(database: database)
        library.setText("boa noite", for: "one", database: database)
        await library.load(owner, database: database, language: "pt", ai: ai)
        #expect(library.takes.map(\.text) == ["boa noite"])
        #expect(try await database.fetchVoiceTake(id: "one")?.text == "boa noite")
        #expect(library.lastDeleted == nil)

        // A translation written from elsewhere (Generate) is not lost to a correction of another language.
        #expect(try await database.setVoiceTakeTranslation(id: "one", language: "en", text: "good night", of: "boa noite"))
        library.setTranslation("bonne nuit", language: "fr", for: "one", database: database)
        await library.settle()
        #expect(library.takes.first?.translations["en"]?.text == "good night")
        #expect(library.takes.first?.translations["fr"]?.text == "bonne nuit")

        // Corrections made one after another all land, in order.
        library.setText("um", for: "one", database: database)
        library.setTranslation("one", language: "en", for: "one", database: database)
        library.setText("um dois", for: "one", database: database)
        await library.settle()
        #expect(library.takes.first?.text == "um dois")
        #expect(try await database.fetchVoiceTake(id: "one") == library.takes.first)
    }

    @Test("A delete another copy of the app made first leaves that copy's Undo audio alone")
    func staleDelete() async throws {
        let (temp, library, owner, ai, takes) = try await shownLibrary()
        let database = temp.database
        let take = try #require(takes.first)
        // Another copy deletes the row and keeps the audio for its Undo.
        #expect(try await database.deleteVoiceTake(id: take.id))
        library.delete(take, database: database)
        await library.settle()
        #expect(!library.takes.contains { $0.id == take.id } && library.lastDeleted == nil)
        #expect(audioExists(take, database))
        // This copy deletes it, the other copy puts it back, and this copy
        // then gives its Undo up: the restored recording keeps its audio.
        try await database.saveVoiceTake(take)
        await library.load(owner, database: database, language: "pt", ai: ai)
        library.delete(take, database: database)
        await library.settle()
        #expect(library.lastDeleted?.id == take.id)
        try await database.saveVoiceTake(take)
        await library.load(VoiceOverLibrary.Owner(projectID: owner.projectID + 1, videoIDs: owner.videoIDs, library: owner.library),
                           database: database, language: "pt", ai: ai)
        #expect(library.lastDeleted == nil && audioExists(take, database))
        // Of two deletes of one recording only the first removes a row, and a
        // correction never brings a deleted recording back.
        #expect(try await database.deleteVoiceTake(id: take.id))
        #expect(try await database.deleteVoiceTake(id: take.id) == false)
        #expect(try await database.correctVoiceTake(id: take.id) { var changed = $0; changed.text = "back"; return changed } == false)
        #expect(try await database.fetchVoiceTake(id: take.id) == nil)
        // Undo puts a recording back only while its audio is there.
        #expect(try await database.restoreVoiceTake(take))
        try await database.deleteVoiceTake(id: take.id)
        try await database.discardVoiceTakeAudio(take)
        #expect(!audioExists(take, database))
        #expect(try await database.restoreVoiceTake(take) == false)
        #expect(try await database.fetchVoiceTake(id: take.id) == nil)
        // A delete nobody put back loses its audio when its Undo is given up.
        let other = try #require(takes.last)
        await library.load(owner, database: database, language: "pt", ai: ai)
        library.delete(other, database: database)
        await library.settle()
        await library.load(VoiceOverLibrary.Owner(projectID: owner.projectID + 1, videoIDs: owner.videoIDs, library: owner.library),
                           database: database, language: "pt", ai: ai)
        #expect(!audioExists(other, database))
    }

    @Test("Another reel or another library never shows these recordings, and cannot undo their delete")
    @MainActor func otherOwner() async throws {
        let (temp, library, owner, ai, takes) = try await shownLibrary()
        let database = temp.database
        // The same project and videos in another library file.
        var other = owner
        other.library = "/elsewhere/library.db"
        // A delete still waiting when the reel changes is not carried out.
        library.delete(takes[1], database: database)
        await library.load(other, database: database, language: "pt", ai: ai)
        #expect(library.lastDeleted == nil)
        #expect(try await database.fetchVoiceTake(id: "two") != nil)
        #expect(audioExists(takes[1], database))

        await library.load(owner, database: database, language: "pt", ai: ai)
        library.delete(takes[0], database: database)
        await library.settle()
        #expect(library.lastDeleted?.id == "one")
        await library.load(other, database: database, language: "pt", ai: ai)
        #expect(library.lastDeleted == nil)
        // The delete it could not undo any more gave up its audio; the row is gone.
        #expect(try await database.fetchVoiceTake(id: "one") == nil)
        #expect(!audioExists(takes[0], database))
        // A correction arriving for the library that is no longer shown changes its row, not this list.
        library.setText("tchau", for: "two", database: database)
        await library.settle()
        #expect(try await database.fetchVoiceTake(id: "two")?.text == "tchau")
        await library.load(owner, database: database, language: "pt", ai: ai)
        #expect(library.takes.map(\.text) == ["tchau"])
    }

    @Test("A recording must name a file inside the recordings folder")
    func leafOnly() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let take = VoiceTake(id: "x", projectID: 1, videoID: videoID, sourceTime: 0, reelTime: 0, duration: 1,
                             file: "../x.m4a")
        await #expect(throws: (any Error).self) { try await temp.database.saveVoiceTake(take) }
    }

    @Test("The voice-over level travels with the run options and stays off by default")
    func optionsCarryLevel() throws {
        #expect(WizardOptions().voiceOverBedLevel == nil)
        var options = WizardOptions()
        options.voiceOverBedLevel = 0.3
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.voiceOverBedLevel == 0.3)
        #expect(WizardOptions.merge(step1: options.step1, step2: options.step2, base: WizardOptions()).voiceOverBedLevel == 0.3)
        #expect(WizardSettingsTab.available(audio: true) == [.picture, .audio, .overlays, .package])
    }
}
