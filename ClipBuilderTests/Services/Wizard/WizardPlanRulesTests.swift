import Foundation
import Testing

@testable import Clip_Builder

struct WizardPlanRulesTests {
    private func podcastTurns(start: Double = 100, answer: Double = 104, end: Double = 131) -> [SpeakerTurn] {
        [SpeakerTurn(videoID: 1, start: start, end: answer, cluster: 0, confidence: 1, tile: 0),
         SpeakerTurn(videoID: 1, start: answer, end: end, cluster: 0, confidence: 1, tile: 1)]
    }

    @Test func podcastKeepsWholeExchangeWithoutTargetOrWhenItFits() {
        for target: Int? in [nil, 31, 45] {
            let result = WizardPlanRules.podcastExchangeCuts(scene: 100...131, sentenceEnds: [104, 108],
                turns: podcastTurns(), proposed: [110...114], targetSeconds: target)
            #expect(result.cuts == [100...131])
            #expect(!result.exceededTarget)
        }
    }

    @Test func podcastContiguousPlannerFragmentsKeepTheAnswer() {
        let result = WizardPlanRules.podcastExchangeCuts(scene: 1419.7...1450.8,
            sentenceEnds: [1423.5, 1427.7, 1431.7, 1435.7, 1441.7],
            turns: podcastTurns(start: 1419.7, answer: 1423.5, end: 1450.8),
            proposed: [1419.7...1423.7, 1423.7...1427.7, 1427.7...1431.7, 1431.7...1435.7],
            targetSeconds: 15)
        #expect(result.cuts == [1419.7...1431.7])
        #expect(!result.exceededTarget)
    }

    @Test func podcastCompletenessOverridesLength() {
        let result = WizardPlanRules.podcastExchangeCuts(scene: 100...131, sentenceEnds: [112, 120, 125],
            turns: podcastTurns(answer: 112), proposed: [100...104], targetSeconds: 15)
        #expect(result.cuts == [100...120])
        #expect(result.exceededTarget)
    }

    @Test func podcastMissingOrSingleSpeakerFallsBackToFirstSentence() {
        let single = [SpeakerTurn(videoID: 1, start: 100, end: 131, cluster: 0, confidence: 1)]
        for turns in [[], single] {
            let result = WizardPlanRules.podcastExchangeCuts(scene: 100...131, sentenceEnds: [104, 111, 125],
                turns: turns, proposed: [100...104], targetSeconds: 6)
            #expect(result.cuts == [100...111])
            #expect(result.exceededTarget)
        }
        let unknown = WizardPlanRules.podcastExchangeCuts(scene: 100...131, sentenceEnds: [],
            turns: [], proposed: [100...104], targetSeconds: 15)
        #expect(unknown.cuts == [100...131])
        #expect(unknown.exceededTarget)
    }

    @Test func podcastClosingJumpSurvivesOnlyWhenItFits() {
        for target in [14, 15] {
            let result = WizardPlanRules.podcastExchangeCuts(scene: 100...131,
                sentenceEnds: [104, 110, 120, 125, 130], turns: podcastTurns(),
                proposed: [100...104, 125...130], targetSeconds: target)
            #expect(result.cuts == (target == 15 ? [100...110, 125...130] : [100...110]))
            #expect(!result.exceededTarget)
        }
    }

    @Test func podcastMidSceneProposalStillStartsWithQuestion() {
        let result = WizardPlanRules.podcastExchangeCuts(scene: 100...131, sentenceEnds: [104, 110, 120, 125],
            turns: podcastTurns(), proposed: [112...118], targetSeconds: 15)
        #expect(result.cuts == [100...110])
    }

    @Test func podcastSnapsMergesClampsAndLimitsCutsInSourceOrder() {
        let ends: [Double] = [2, 4, 5, 20, 22, 23, 25, 26, 28, 29, 29.5, 29.8]
        let result = WizardPlanRules.podcastExchangeCuts(scene: 0...30, sentenceEnds: ends,
            turns: podcastTurns(start: 0, answer: 2, end: 30),
            proposed: [28...29, 25.2...25.8, 20.1...21, 21...22, 22...23,
                       -10...2, 29.5...40, 29...29.5], targetSeconds: 15)
        #expect(result.cuts == [0...5, 20...23, 25...26])
        #expect(result.cuts.count <= 3)
        for cut in result.cuts {
            #expect(([0, 30] + ends).contains(cut.lowerBound))
            #expect(([0, 30] + ends).contains(cut.upperBound))
            #expect(cut.lowerBound >= 0 && cut.upperBound <= 30)
        }
        for (first, second) in zip(result.cuts, result.cuts.dropFirst()) {
            #expect(first.upperBound < second.lowerBound)
        }
        #expect(result.cuts.last!.upperBound > 2)
    }

    @Test func podcastDropsShortClosingFragments() {
        let result = WizardPlanRules.podcastExchangeCuts(scene: 0...30,
            sentenceEnds: [2, 4, 5, 20, 20.4, 25, 26],
            turns: podcastTurns(start: 0, answer: 2, end: 30),
            proposed: [20...20.4, 25...26], targetSeconds: 15)
        #expect(result.cuts == [0...5, 25...26])
    }

    @Test func podcastClampsClosingProposalToSceneEdgeAndIgnoresOutsideRanges() {
        let result = WizardPlanRules.podcastExchangeCuts(scene: 0...30, sentenceEnds: [2, 5, 20, 28],
            turns: podcastTurns(start: 0, answer: 2, end: 30),
            proposed: [-10 ... -2, 28...40, 40...50], targetSeconds: 15)
        #expect(result.cuts == [0...5, 28...30])
        #expect(!result.exceededTarget)
    }

    @Test func podcastTranscriptShowsSourceTimesSpeakersAndBothEndsWithinCap() {
        var segments = [TranscriptSegment(start: 100, end: 104, text: "Why did you start?", words: nil)]
        for index in 0..<24 {
            let start = 104 + Double(index)
            segments.append(TranscriptSegment(start: start, end: start + 1,
                text: "Answer \(index): " + String(repeating: "detail ", count: 25) + ".", words: nil))
        }
        segments.append(TranscriptSegment(start: 128, end: 131, text: "That is the key point.", words: nil))
        var turns = podcastTurns()
        turns[0].personKey = "host"
        turns[1].personKey = "guest"
        let text = WizardPlanRules.podcastTranscriptText(scene: 100...131, segments: segments,
            turns: turns, speakerNames: ["host": "Host", "guest": "Guest"])
        #expect(text.count <= 1500)
        #expect(text.contains("[100.0–104.0] Host: Why did you start?"))
        #expect(text.contains("[… transcript truncated …]"))
        #expect(text.contains("[128.0–131.0] Guest: That is the key point."))
    }

    @Test func podcastTranscriptClampsToSceneAndCapsASingleLongSentence() {
        let segments = [TranscriptSegment(start: 0, end: 10, text: "Outside.", words: nil),
                        TranscriptSegment(start: 100, end: 131,
                            text: "Opening " + String(repeating: "word ", count: 1000) + "closing.", words: nil)]
        let text = WizardPlanRules.podcastTranscriptText(scene: 102...130, segments: segments,
            turns: [], speakerNames: [:])
        #expect(text.count <= 1500)
        #expect(text.contains("[102.0–130.0]"))
        #expect(text.contains("[… transcript truncated …]"))
        #expect(text.contains("Opening") && text.contains("closing."))
        #expect(!text.contains("Outside"))
        #expect(WizardPlanRules.podcastTranscriptText(scene: 102...130, segments: [],
            turns: [], speakerNames: [:]).isEmpty)
    }

    private func scene(id: Int64, tags: [String]) -> SceneRecord {
        var scene = Fixtures.scene(id: id)
        scene.tags = tags
        return scene
    }
    private func person(_ key: String, name: String, descriptor: String = "", hidden: Bool = false) -> PersonRecord {
        var person = PersonRecord(id: Int64(key.hashValue & 0xffff), key: key, name: name, descriptor: descriptor)
        person.hidden = hidden
        return person
    }

    @Test func longestFreeGapPicksTheWidestUncoveredStretch() {
        let gap = WizardPlanRules.longestFreeGap(start: 0, end: 20, used: [(2, 4), (10, 11)])
        #expect(gap?.start == 11 && gap?.end == 20)
        #expect(WizardPlanRules.longestFreeGap(start: 0, end: 10, used: [(0, 10)]) == nil)
        // Blockers outside the window are ignored; an unsorted list is fine.
        let inner = WizardPlanRules.longestFreeGap(start: 5, end: 15, used: [(12, 30), (-5, 6)])
        #expect(inner?.start == 6 && inner?.end == 12)
    }

    @Test func templateAdherenceFlagsDurationAndCutCount() {
        var options = WizardOptions()
        options.templateJSON = #"{"duration": 20, "cut_count": 10}"#
        let short = Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 4), Fixtures.planClip(sceneID: 2, start: 0, end: 4)])
        let findings = WizardPlanRules.templateAdherenceFindings(short, options: options)
        #expect(findings.count == 2)
        #expect(findings[0].contains("8.0s") && findings[0].contains("20.0s"))
        #expect(findings[1].contains("2 clips"))
        // A user-set target duration silences the duration check; a matching cadence silences the other.
        options.targetDurationSeconds = 8
        options.templateJSON = #"{"duration": 20, "cut_count": 2}"#
        #expect(WizardPlanRules.templateAdherenceFindings(short, options: options).isEmpty)
        #expect(WizardPlanRules.templateAdherenceFindings(short, options: WizardOptions()).isEmpty)
    }

    @Test func pinnedOverlaysRestyleAndReplaceText() {
        var options = WizardOptions()
        options.enableTextOverlays = true
        var first = Fixtures.planClip(sceneID: 1)
        var second = Fixtures.planClip(sceneID: 2)
        second.textOverlay = "ORIGINAL"
        second.overlayStyle = "bold"
        let plan = Fixtures.plan(clips: [first, second])

        options.pinnedOverlayTemplate = "minimal"
        let restyled = WizardPlanRules.enforcePinnedOverlays(plan, options: options)
        #expect(restyled.clips[1].overlayStyle == "minimal")
        #expect(restyled.clips[0].textOverlay == nil)

        options.pinnedOverlayText = "PINNED"
        let replaced = WizardPlanRules.enforcePinnedOverlays(plan, options: options)
        #expect(replaced.clips[1].textOverlay == "PINNED")

        first.textOverlay = nil
        let none = Fixtures.plan(clips: [first])
        #expect(WizardPlanRules.enforcePinnedOverlays(none, options: options).clips[0].textOverlay == "PINNED")

        options.enableTextOverlays = false
        #expect(WizardPlanRules.enforcePinnedOverlays(plan, options: options).clips[1].textOverlay == "ORIGINAL")
    }

    @Test func interviewLowerThirdsIntroduceEachPersonOnce() {
        var options = WizardOptions()
        options.enableTextOverlays = true
        options.formatPreset = "interview"
        let people = [person("ana", name: "Ana", descriptor: "Coach"), person("bo", name: "Bo"),
                      person("ghost", name: "Ghost", hidden: true)]
        let scenes: [Int64: SceneRecord] = [
            1: scene(id: 1, tags: ["person:ana"]), 2: scene(id: 2, tags: ["person:ana", "person:bo"]),
            3: scene(id: 3, tags: ["person:ghost"]),
        ]
        var titled = Fixtures.planClip(sceneID: 2)
        titled.textOverlay = "KEEP"
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 1), titled, Fixtures.planClip(sceneID: 2),
                                         Fixtures.planClip(sceneID: 3)])
        let result = WizardPlanRules.addAutomaticLowerThirds(plan, options: options, people: people, sceneMap: scenes)
        #expect(result.clips[0].textOverlay == "Ana")
        #expect(result.clips[0].overlayKicker == "Coach")
        #expect(result.clips[0].overlayStyle == "lower-third")
        #expect(result.clips[1].textOverlay == "KEEP")
        #expect(result.clips[2].textOverlay == "Bo")
        #expect(result.clips[2].overlayKicker == "Guest")
        #expect(result.clips[3].textOverlay == nil)
        options.formatPreset = "custom"
        #expect(WizardPlanRules.addAutomaticLowerThirds(plan, options: options, people: people, sceneMap: scenes)
            .clips[0].textOverlay == nil)
    }

    @Test func podcastIntroductionsFollowSpeakerTurns() {
        var options = WizardOptions()
        options.enableTextOverlays = true
        options.formatPreset = "podcast"
        let people = [person("host", name: "Host", descriptor: "Presenter")]
        var turn = SpeakerTurn(videoID: 1, start: 3, end: 5, cluster: 0, confidence: 1)
        turn.personKey = "host"
        let scenes: [Int64: SceneRecord] = [1: Fixtures.scene(id: 1, start: 2, end: 8)]
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 1, start: 2, end: 8),
                                         Fixtures.planClip(sceneID: 1, start: 2, end: 8)])
        let result = WizardPlanRules.addAutomaticLowerThirds(
            plan, options: options, people: people, sceneMap: scenes, speakerTurns: [1: [turn]])
        let intro = try? #require(result.clips[0].speakerIntroductions.first)
        #expect(intro?.text == "Host")
        #expect(intro?.startTime == 1)
        #expect(intro?.endTime == 4)
        #expect(result.clips[0].textOverlay == nil)
        // Introduced once: the second clip over the same turn gets nothing.
        #expect(result.clips[1].speakerIntroductions.isEmpty)
    }

    @Test func critiqueFeedbackBlockListsEverySectionAndTruncatesThePlan() {
        let critique = ReelCritique(score: 61, summary: "Flat hook", strengths: ["Good ending"],
                                    issues: ["Hook starts on a wide shot"], notes: ["Open on clip 3"],
                                    regenerate: true)
        let block = WizardPlanRules.critiqueFeedbackBlock(critique, attempt: 2,
                                                          previousPlanJSON: String(repeating: "x", count: 5000))
        #expect(block.contains("VERSION 2"))
        #expect(block.contains("61/100: Flat hook"))
        #expect(block.contains("- Hook starts on a wide shot"))
        #expect(block.contains("- Open on clip 3"))
        #expect(block.contains("- Good ending"))
        #expect(block.contains(String(repeating: "x", count: 4000)))
        #expect(!block.contains(String(repeating: "x", count: 4001)))
        let bare = WizardPlanRules.critiqueFeedbackBlock(
            ReelCritique(score: 70, summary: "", strengths: [], issues: [], notes: [], regenerate: false),
            attempt: 1, previousPlanJSON: "{}")
        #expect(!bare.contains("Issues visible") && !bare.contains("Keep what"))
    }
}
