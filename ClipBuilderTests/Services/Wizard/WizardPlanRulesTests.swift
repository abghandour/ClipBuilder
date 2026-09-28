import Foundation
import Testing

@testable import Clip_Builder

struct WizardPlanRulesTests {
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
