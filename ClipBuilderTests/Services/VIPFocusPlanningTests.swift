import Testing
@testable import Clip_Builder

struct VIPFocusPlanningTests {
    private func segment(_ start: Double, _ end: Double, _ talker: Int) -> CropRecipePlanner.Segment {
        .init(start: start, end: end, talker: talker, recent: [])
    }

    private func events(_ segments: [CropRecipePlanner.Segment], tiles: [Int] = [0, 1], vips: [Int] = [0],
                        range: ClosedRange<Double>) -> [(time: Double, tile: Int)] {
        VIPFocusPlanning.events(segments: segments, tiles: tiles, vipTiles: vips, range: range)
    }

    @Test func constantsMatchThePlan() {
        #expect(VIPFocusPlanning.askerShow == 2 && VIPFocusPlanning.vipStretch == 8)
        #expect(VIPFocusPlanning.cutaway == 2 && VIPFocusPlanning.minimumReturn == 2 && VIPFocusPlanning.hold == 2)
    }

    @Test func aQuestionShowsTheAskerThenReturnsToTheVIPWhoAnswers() {
        let shots = events([segment(10, 15, 0), segment(15, 22, 1), segment(22, 30, 0)], range: 10...30)
        #expect(shots.map(\.time) == [10, 15, 17] && shots.map(\.tile) == [0, 1, 0])
    }

    @Test func aShortQuestionStaysOnTheAskerUntilTheAnswer() {
        // 3 s question: returning at 2 s would leave the VIP 1 s before the answer cut.
        let shots = events([segment(0, 10, 0), segment(10, 13, 1), segment(13, 20, 0)], range: 0...20)
        #expect(shots.map(\.time) == [0, 10, 13] && shots.map(\.tile) == [0, 1, 0])
        // 4 s question: the return leaves exactly 2 s, so it happens.
        let longer = events([segment(0, 10, 0), segment(10, 14, 1), segment(14, 20, 0)], range: 0...20)
        #expect(longer.map(\.time) == [0, 10, 12] && longer.map(\.tile) == [0, 1, 0])
    }

    @Test func aLongAnswerCutsAwayToTheLastAskerEveryEightSeconds() {
        let shots = events([segment(0, 4, 1), segment(4, 30, 0)], range: 0...30)
        // Asker 0–2, VIP from 2 (the 4 s question returns), then the answer
        // from 4: cutaways at 12 and 22, each 2 s, back to the VIP after.
        #expect(shots.map(\.time) == [0, 2, 12, 14, 22, 24])
        #expect(shots.map(\.tile) == [1, 0, 1, 0, 1, 0])
    }

    @Test func aCutawayNeverStartsWhenTheVIPCannotReturnInTime() {
        // 11 s answer: 8 + 2 + 2 > 11, no cutaway.
        let short = events([segment(0, 11, 0)], range: 0...11)
        #expect(short.map(\.time) == [0] && short.map(\.tile) == [0])
        // 12 s answer but the clip's tail: the return at 10 would be inside 12 − 2.5.
        let tail = events([segment(0, 12, 0)], range: 0...12)
        #expect(tail.count == 1)
        let fits = events([segment(0, 20, 0)], range: 0...20)
        #expect(fits.map(\.time) == [0, 8, 10] && fits.map(\.tile) == [0, 1, 0])
    }

    @Test func silenceAndAnOpeningWithoutSpeechHoldOnTheVIP() {
        let late = events([segment(5, 20, 1)], range: 0...20)
        // VIP first; the asker at 5, back at 7; the asker again 8 s later at 15, back at 17.
        #expect(late.map(\.time) == [0, 5, 7, 15, 17] && late.map(\.tile) == [0, 1, 0, 1, 0])
        #expect(events([], range: 0...20).map(\.tile) == [0])
        // With speech known, the VIP who speaks first opens, not the one with more speech.
        let two = events([segment(3, 5, 2), segment(5, 30, 0)], tiles: [0, 1, 2], vips: [0, 2], range: 0...30)
        #expect(two.first?.tile == 2 && two.first?.time == 0)
    }

    @Test func returnsAndCutawaysRotateAmongSeveralPeopleVIPsFirst() {
        // Two VIPs (0, 2) and a host (1) asking the whole clip: the returns alternate VIPs.
        let hostOnly = events([segment(0, 30, 1)], tiles: [0, 1, 2], vips: [0, 2], range: 0...30)
        #expect(hostOnly.map(\.time) == [0, 2, 10, 12, 20, 22])
        #expect(hostOnly.map(\.tile) == [1, 0, 1, 2, 1, 0])
        // A VIP answering with nobody having asked cuts away to the others in turn.
        let monologue = events([segment(0, 40, 0)], tiles: [0, 1, 2], vips: [0, 2], range: 0...40)
        #expect(monologue.map(\.time) == [0, 8, 10, 18, 20, 28, 30])
        #expect(monologue.map(\.tile) == [0, 1, 0, 2, 0, 1, 0])
    }

    @Test func changesKeepTheHoldAndNeverRepeatATile() {
        let shots = events([segment(0, 10, 0), segment(10, 11.5, 1), segment(11.5, 30, 0)], range: 0...30)
        for (from, to) in zip(shots, shots.dropFirst()) {
            #expect(to.time - from.time >= VIPFocusPlanning.hold - 1e-9)
            #expect(to.tile != from.tile)
        }
        // A recipe hold above the show length is capped at it (the asker setting
        // wins); with a matching show the wider hold spaces everything.
        let capped = VIPFocusPlanning.events(segments: [segment(0, 10, 0), segment(10, 20, 1), segment(20, 30, 0)],
            tiles: [0, 1], vipTiles: [0], range: 0...30, hold: 3)
        #expect(capped.map(\.time) == [0, 10, 12], "the return at 12 is 2 s after the cut, not 3")
        let wide = VIPFocusPlanning.events(segments: [segment(0, 10, 0), segment(10, 20, 1), segment(20, 30, 0)],
            tiles: [0, 1], vipTiles: [0], range: 0...30, hold: 3, show: 3)
        #expect(zip(wide, wide.dropFirst()).allSatisfy { $1.time - $0.time >= 3 - 1e-9 })
    }

    @Test func showAndStretchAreConfigurableAndClamped() {
        let quick = VIPFocusPlanning.events(segments: [segment(0, 4, 1), segment(4, 30, 0)], tiles: [0, 1], vipTiles: [0],
            range: 0...30, show: 1, stretch: 5)
        // Asker 0–1, VIP from 1; answer from 4: cutaways at 9 and 15, 1 s each.
        #expect(quick.map(\.time) == [0, 1, 9, 10, 15, 16, 21, 22])
        #expect(quick.map(\.tile) == [1, 0, 1, 0, 1, 0, 1, 0])
        let clamped = VIPFocusPlanning.events(segments: [segment(0, 4, 1), segment(4, 30, 0)], tiles: [0, 1], vipTiles: [0],
            range: 0...30, show: 0, stretch: 100)
        // 0 s show is 1 s; a 100 s stretch is 20 s: one cutaway at 24, back at 25.
        #expect(clamped.map(\.time) == [0, 1, 24, 25] && clamped.map(\.tile) == [1, 0, 1, 0])
        #expect(VIPFocusPlanning.clamp(.nan, to: VIPFocusPlanning.showRange) == 1)
    }

    @Test func sentenceEndsDelayReturnsAndCutawaysButNeverANewTalker() {
        // The 4 s question runs as one sentence to 3.5; the answer's sentences end at 10, 13.5 and 20.
        let ends = [3.5, 10, 13.5, 20, 27]
        let shots = VIPFocusPlanning.events(segments: [segment(0, 4, 1), segment(4, 30, 0)], tiles: [0, 1], vipTiles: [0],
            range: 0...30, sentenceEnds: ends)
        // Return at 2 waits for 3.5 (still 2 s before... no: 4 − 3.5 < 2, so
        // the asker stays until the answer cuts at 4). The cutaway due at 12
        // waits for 13.5; its return due at 15.5 waits for 20; the next
        // cutaway at 28 is past the tail.
        #expect(shots.map(\.time) == [0, 4, 13.5, 20] && shots.map(\.tile) == [1, 0, 1, 0])
        // A new talker is a cut point even mid-sentence of the transcript; the
        // return due at 8 waits for 9, and the asker's second show due at 16
        // would wait for 19, inside the tail, so the VIP keeps the picture.
        let interrupted = VIPFocusPlanning.events(segments: [segment(0, 6, 0), segment(6, 20, 1)], tiles: [0, 1], vipTiles: [0],
            range: 0...20, sentenceEnds: [9, 12, 19])
        #expect(interrupted.map(\.time) == [0, 6, 9] && interrupted.map(\.tile) == [0, 1, 0])
        // Without sentence ends the clock rules.
        let plain = VIPFocusPlanning.events(segments: [segment(0, 6, 0), segment(6, 20, 1)], tiles: [0, 1], vipTiles: [0],
            range: 0...20)
        #expect(plain.map(\.time) == [0, 6, 8, 16])
    }

    @Test func sentenceEndsComeFromPunctuatedOriginalLinesOrEveryLine() {
        func row(_ id: Int64, _ text: String, _ end: Double, translation: Bool = false) -> TranscriptRow {
            TranscriptRow(id: id, videoID: 1, language: "en", isTranslation: translation, startTime: end - 1, endTime: end, text: text)
        }
        let rows = [row(1, "So how did it start", 3), row(2, "It began in Rio.", 6), row(3, "Really?", 8),
                    row(4, "Yes!\"", 10), row(5, "Sim.", 12, translation: true)]
        #expect(VIPFocusPlanning.sentenceEnds(rows: rows) == [6, 8, 10])
        #expect(VIPFocusPlanning.sentenceEnds(rows: [row(1, "no punctuation", 3), row(2, "at all", 5)]) == [3, 5])
        #expect(VIPFocusPlanning.sentenceEnds(segments: [.init(start: 0, end: 2, text: "Hi.", words: nil)]) == [2])
    }

    @Test func withoutAVIPTheTalkerIsFollowed() {
        let shots = events([segment(2, 10, 0), segment(10, 20, 1)], vips: [], range: 0...20)
        #expect(shots.map(\.time) == [0, 10] && shots.map(\.tile) == [0, 1])
        #expect(events([], vips: [], range: 0...20).isEmpty)
    }
}
