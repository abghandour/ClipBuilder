import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Highlights review adapter")
struct MiniHighlightReviewTests {
    private func candidate(id: Int64 = 1, clips: [WizardPlanClip] = [Fixtures.planClip()],
                           kept: Bool = true) -> MiniWizardCandidate {
        let selection = WizardSelectionRecord(id: id, projectID: 1, name: "The turning point", recipe: "custom",
                                               step1Options: WizardStep1Options())
        var plan = Fixtures.plan(clips: clips, transitions: clips.count > 1 ? ["dissolve"] : [])
        plan.rationale = "A clear setup and payoff worth keeping."
        plan.headline = "A different planner headline"
        let take = WizardSelectionTake(id: id + 100, selectionID: id, ordinal: 2, plan: plan,
                                       sceneIDs: clips.map(\.sceneID))
        return MiniWizardCandidate(selection: selection, take: take, kept: kept, note: "Keep the answer")
    }

    @Test func singleCutUsesCandidateNameAndCaptionsWithoutSubrows() throws {
        let candidate = candidate()
        let item = try #require(MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(),
                                                         scenes: [Fixtures.scene()]).first)
        #expect(item.id.ownerID == candidate.id)
        #expect(item.id.revisionID == candidate.take.id)
        #expect(item.id.cutIndex == nil)
        #expect(item.title == "The turning point")
        #expect(item.titleHelp == item.title)
        #expect(item.keepLabel == "Keep The turning point")
        #expect(item.captions[0].text == "4.0 s · Take 2")
        #expect(item.captions[1].text == candidate.take.plan.rationale)
        #expect(item.captions[1].lineLimit == 2)
        #expect(item.children.isEmpty)
        #expect(item.range == 2...6)
        #expect(item.originalRange == 2...6)
        #expect(item.isAvailable)
    }

    @Test func multiCutItemsCarryIndependentVideosBoundsAndResetRanges() throws {
        let candidate = candidate(clips: [Fixtures.planClip(start: 2, end: 5.2),
                                          Fixtures.planClip(sceneID: 2, start: 7, end: 9)])
        var secondScene = Fixtures.scene(id: 2, start: 6, end: 10)
        secondScene.videoID = 2
        secondScene.videoPath = "/tmp/second.mp4"
        secondScene.videoFilename = "second.mp4"
        let item = try #require(MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(),
            scenes: [Fixtures.scene(), secondScene]).first)
        #expect(item.children.count == 2)
        #expect(item.children.map(\.title) == ["Cut 1 · 3.2 s", "Cut 2 · 2.0 s"])
        #expect(item.children.map { $0.id.cutIndex } == [0, 1])
        #expect(item.children.allSatisfy { $0.id.ownerID == candidate.id && $0.id.revisionID == candidate.take.id })
        #expect(item.children[0].limits == 2...6)
        #expect(item.children[1].limits == 6...10)
        #expect(item.children[1].video.id == 2)
        #expect(item.children[1].video.url == URL(fileURLWithPath: "/tmp/second.mp4"))
        #expect(item.children[1].originalRange == 7...9)
    }

    @Test func keptBindingDoesNotChangeNotesPlansTakesOrSelection() throws {
        let candidates = [candidate(id: 1), candidate(id: 2, kept: false)]
        var run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .highlights,
            length: .automatic, batchID: "review", candidates: candidates, options: WizardOptions(), selectedSelectionID: 1)
        #expect(MiniHighlightReview.keptIDs(run.candidates) == [1])
        run.candidates = MiniHighlightReview.settingKept([2, 999], in: run.candidates)
        #expect(MiniHighlightReview.keptIDs(run.candidates) == [2])
        #expect(run.selectedSelectionID == 1)
        #expect(run.keptCount == 1)
        for (before, after) in zip(candidates, run.candidates) {
            #expect(after.note == before.note)
            #expect(after.take.id == before.take.id)
            #expect(try encoded(after.take.plan) == encoded(before.take.plan))
            #expect(try encoded(after.suggestedPlan) == encoded(before.suggestedPlan))
        }
    }

    @Test func selectAllCountsCandidatesRatherThanCutsAndIgnoresUnknownIDs() {
        let candidates = [candidate(id: 1, clips: [Fixtures.planClip(), Fixtures.planClip()]),
                          candidate(id: 2, kept: false)]
        let items = MiniHighlightReview.items(candidates: candidates, video: Fixtures.video(), scenes: [Fixtures.scene()])
        #expect(!RangeReviewItem.allKept([1, 999], items: items))
        let all = RangeReviewItem.togglingAll([1, 999], items: items)
        #expect(all == [1, 2])
        #expect(RangeReviewItem.allKept(all, items: items))
        #expect(RangeReviewItem.allKept([1, 2, 999], items: items))
        #expect(RangeReviewItem.togglingAll(all, items: items).isEmpty)
        #expect(MiniHighlightReview.keptIDs(MiniHighlightReview.settingKept(all, in: candidates)) == all)
        #expect(MiniHighlightReview.keptIDs(MiniHighlightReview.settingKept([], in: candidates)).isEmpty)
        #expect(RangeReviewItem.togglingAll([], items: []).isEmpty)
    }

    @Test func trimmingOnlyUpdatesTheTargetCutAndPreservesPlanMetadata() throws {
        let scenes = [Fixtures.scene(id: 1, start: 0, end: 10), Fixtures.scene(id: 2, start: 3, end: 9)]
        var candidate = candidate(clips: [Fixtures.planClip(), Fixtures.planClip(sceneID: 2, start: 4, end: 8)])
        candidate.take.plan = WizardSelectionRules.snapshot(candidate.take.plan, scenes: scenes)
        let before = candidate.take.plan
        let id = RangeReviewItem.ID(ownerID: candidate.id, revisionID: candidate.take.id, cutIndex: 1)
        let trimmed = try #require(MiniHighlightReview.trimming(id, to: 5...7, candidate: candidate, scenes: scenes))
        var expected = before
        expected.clips[1].start = 5
        expected.clips[1].end = 7
        #expect(try encoded(trimmed) == encoded(expected))
        #expect(trimmed.transitions == ["dissolve"])
        #expect(WizardSelectionRules.resolvedPlan(trimmed, scenes: scenes) != nil)
        candidate.take.plan = trimmed
        let items = MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(), scenes: scenes)
        #expect(items[0].children[1].originalRange == 4...8)
        #expect(items[0].children[1].isTrimmed)
        let reset = try #require(MiniHighlightReview.trimming(id, to: items[0].children[1].originalRange,
                                                             candidate: candidate, scenes: scenes))
        #expect(try encoded(reset) == encoded(before))
    }

    @Test func singleCutTrimsAndAnchorsUseSceneBoundsIncludingWholeRecordingScenes() throws {
        let candidate = candidate()
        let id = RangeReviewItem.ID(ownerID: candidate.id, revisionID: candidate.take.id)
        let bounded = try #require(MiniHighlightReview.trimming(id, to: 0...10, candidate: candidate,
                                                               scenes: [Fixtures.scene()]))
        #expect(bounded.clips[0].start == 2 && bounded.clips[0].end == 6)
        let wholeRecording = Fixtures.scene(start: 0, end: 10)
        let extended = try #require(MiniHighlightReview.trimming(id, to: 0...10, candidate: candidate,
                                                                scenes: [wholeRecording]))
        #expect(extended.clips[0].start == 0 && extended.clips[0].end == 10)
        let policy = RangeReviewItem.TrimPolicy.wizard
        #expect(policy.clamp(3...3.1, limits: 2...6) == 3...3.5)
        #expect(policy.setting(.start, at: -20, in: 3...5, limits: 2...6) == 2...5)
        #expect(policy.setting(.end, at: 90, in: 3...5, limits: 2...6) == 3...6)
        #expect(policy.clamp(3...5, limits: 2...2.2) == 2...2.2)
        #expect(RangeReviewItem.TrimPolicy.qa.clamp(3...3.1, limits: 0...10) == 3...4)
    }

    @Test func changedFootageRemainsListedButCannotSave() throws {
        let scenes = [Fixtures.scene()]
        var candidate = candidate()
        candidate.take.plan = WizardSelectionRules.snapshot(candidate.take.plan, scenes: scenes)
        let changed = [Fixtures.scene(start: 1, end: 9)]
        let item = try #require(MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(), scenes: changed).first)
        #expect(item.title == candidate.selection.name)
        #expect(!item.isAvailable)
        #expect(MiniHighlightReview.trimming(item.id, to: 3...5, candidate: candidate, scenes: changed) == nil)
        let missing = MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(), scenes: [])
        #expect(missing.count == 1 && !missing[0].isAvailable)
    }

    @Test func staleTakeCannotSaveAndRegenerationReplacesSuggestedRange() throws {
        var candidate = candidate()
        let oldID = RangeReviewItem.ID(ownerID: candidate.id, revisionID: candidate.take.id)
        candidate.take.plan.clips[0].start = 3
        #expect(candidate.suggestedPlan.clips[0].start == 2)
        var newTake = candidate.take
        newTake.id += 1
        newTake.plan.clips[0].start = 4
        candidate.take = newTake
        #expect(candidate.suggestedPlan.clips[0].start == 4)
        #expect(MiniHighlightReview.trimming(oldID, to: 3...5, candidate: candidate, scenes: [Fixtures.scene()]) == nil)
        let item = try #require(MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(),
                                                         scenes: [Fixtures.scene()]).first)
        #expect(item.id != oldID)
        #expect(item.originalRange == 4...6)
        #expect(!item.isTrimmed)
    }

    @Test func podcastFinderPlanUsesTheSameAdapterAndSavePath() throws {
        var scene = Fixtures.scene(start: 0, end: 10)
        scene.tags = ["podcast-exchange"]
        let highlight = HighlightCandidate(sourceStart: 2, sourceEnd: 6, title: "A complete answer",
            reason: "The guest explains why.", score: 8, kind: .subcut, speakerKeys: [])
        let plan = try #require(WizardEngine.miniHighlightPlans([highlight], videoID: 1, scenes: [scene]).first)
        var candidate = candidate()
        var take = candidate.take
        take.id += 1
        take.plan = plan
        candidate.take = take
        candidate.selection.name = highlight.title
        let item = try #require(MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(),
                                                         scenes: [scene]).first)
        #expect(item.title == highlight.title)
        #expect(item.captions[1].text == highlight.reason)
        #expect(item.children.isEmpty)
        #expect(item.limits == 0...10)
        let edited = try #require(MiniHighlightReview.trimming(item.id, to: 1...8, candidate: candidate, scenes: [scene]))
        #expect(edited.clips[0].start == 1 && edited.clips[0].end == 8)
        #expect(WizardSelectionRules.resolvedPlan(edited, scenes: [scene]) != nil)
    }

    @Test func reanalysisWithIdenticalFootageResolvesNewSceneIDs() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        var candidate = candidate()
        candidate.take.plan = WizardSelectionRules.snapshot(candidate.take.plan, scenes: [scene])
        var replacement = scene
        replacement.id = 99
        let item = try #require(MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(),
                                                         scenes: [replacement]).first)
        #expect(item.isAvailable)
        let edited = try #require(MiniHighlightReview.trimming(item.id, to: 3...7, candidate: candidate, scenes: [replacement]))
        #expect(edited.clips[0].sceneID == 99)
        #expect(edited.clips[0].start == 3 && edited.clips[0].end == 7)
        #expect(item.originalRange == 2...6)
        #expect(WizardSelectionRules.resolvedPlan(edited, scenes: [replacement]) != nil)
    }

    private func encoded(_ plan: WizardPlan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(plan)
    }
}
