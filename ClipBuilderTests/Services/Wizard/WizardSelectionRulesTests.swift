import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard selection rules")
struct WizardSelectionRulesTests {
    @Test func takeLabelsUseTrimmedDurationAndSpeed() {
        var clip = Fixtures.planClip()
        clip.speed = 0.5
        let plan = Fixtures.plan(clips: [clip], targetDuration: 30)
        let take = WizardSelectionTake(id: 1, selectionID: 2, ordinal: 3, plan: plan, sceneIDs: [1])
        #expect(WizardSelectionRules.takeLabel(take) == "Take 3 · 8 s · 1 cut")
        #expect(WizardSelectionRules.duration(plan) == 8)
    }

    @Test func reanalysisRemapsSceneIDsForIdenticalVideoAndTimeRanges() throws {
        let source = Fixtures.scene()
        let saved = WizardSelectionRules.snapshot(Fixtures.plan(), scenes: [source])
        var reanalyzed = source
        reanalyzed.id = 99
        reanalyzed.runID = 27
        let remapped = try #require(WizardSelectionRules.resolvedPlan(saved, scenes: [reanalyzed]))
        #expect(remapped.clips[0].sceneID == 99)
        #expect(remapped.clips[0].start == 2 && remapped.clips[0].end == 6)
        #expect(remapped.footage?.first?.sceneID == 99)
    }

    @Test func identicalSceneIDEvenWithDifferentFootageIsInvalid() {
        let source = Fixtures.scene()
        let saved = WizardSelectionRules.snapshot(Fixtures.plan(), scenes: [source])
        var changed = source
        changed.videoID = 2
        #expect(WizardSelectionRules.resolvedPlan(saved, scenes: [changed]) == nil)
        changed = source
        changed.videoPath = "/tmp/replacement.mp4"
        #expect(WizardSelectionRules.resolvedPlan(saved, scenes: [changed]) == nil)
        changed = source
        changed.startTime = 3
        #expect(WizardSelectionRules.resolvedPlan(saved, scenes: [changed]) == nil)
        changed = source
        changed.videoDuration = 4
        #expect(WizardSelectionRules.resolvedPlan(saved, scenes: [changed]) == nil)
        #expect(WizardSelectionRules.resolvedPlan(saved, scenes: []) == nil)
    }

    @Test func allLayoutAreasMustStillExistAndAreRemapped() throws {
        let source = Fixtures.scene()
        var side = Fixtures.scene(id: 2)
        side.videoID = 2
        side.videoPath = "/tmp/other.mp4"
        var plan = Fixtures.plan()
        plan.clips[0].areaClips = [WizardPlanAreaClip(area: "Right", sceneID: 2, start: 2, end: 6)]
        let saved = WizardSelectionRules.snapshot(plan, scenes: [source, side])
        #expect(WizardSelectionRules.resolvedPlan(saved, scenes: [source]) == nil)
        side.id = 88
        let remapped = try #require(WizardSelectionRules.resolvedPlan(saved, scenes: [source, side]))
        #expect(remapped.clips[0].areaClips[0].sceneID == 88)
    }

    @Test func handTrimsPreserveSourceIdentityAndDoNotAllowOutOfBoundsCuts() throws {
        let source = Fixtures.scene()
        var edited = WizardSelectionRules.snapshot(Fixtures.plan(), scenes: [source])
        edited.clips[0].start = 3
        edited.clips[0].end = 5
        let saved = WizardSelectionRules.snapshot(edited, scenes: [])
        let resolved = try #require(WizardSelectionRules.resolvedPlan(saved, scenes: [source]))
        #expect(resolved.clips[0].start == 3 && resolved.clips[0].end == 5)
        edited.clips[0].end = 7
        #expect(WizardSelectionRules.resolvedPlan(edited, scenes: [source]) == nil)
    }

    @Test func legacyPlansCanAcquireFootageReferencesWhileTheirSourcesStillExist() throws {
        let old = Fixtures.plan()
        #expect(old.footage == nil)
        let resolved = try #require(WizardSelectionRules.resolvedPlan(old, scenes: [Fixtures.scene()]))
        let roundTrip = try JSONDecoder().decode(WizardPlan.self, from: JSONEncoder().encode(resolved))
        #expect(roundTrip.footage?.first?.videoPath == "/tmp/fixture.mp4")
        #expect(WizardSelectionRules.resolvedPlan(old, scenes: []) == nil)
    }
}
