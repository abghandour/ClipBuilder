import Foundation
import Testing
@testable import Clip_Builder

struct WizardPreviewClipsTests {
    private func candidate(_ id: Int64, name: String, clips: [WizardPlanClip], kept: Bool = true) -> MiniWizardCandidate {
        let selection = WizardSelectionRecord(id: id, projectID: 1, name: name, recipe: "custom",
                                               step1Options: WizardStep1Options())
        let take = WizardSelectionTake(id: id, selectionID: id, ordinal: 1,
                                       plan: Fixtures.plan(clips: clips), sceneIDs: clips.map(\.sceneID))
        return MiniWizardCandidate(selection: selection, take: take, kept: kept)
    }

    @Test func keptTakesBecomeClipsInOutputOrderWithTheirTrimmedRanges() {
        let scenes = [Fixtures.scene(id: 1, start: 0, end: 90), Fixtures.scene(id: 2, start: 100, end: 160)]
        let run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .highlights, length: .automatic,
            batchID: "b", candidates: [
                candidate(10, name: "Skipped", clips: [Fixtures.planClip(sceneID: 1, start: 0, end: 5)], kept: false),
                candidate(11, name: "Hello", clips: [Fixtures.planClip(sceneID: 1, start: 1.32, end: 89.46)]),
                candidate(12, name: "Two parts", clips: [Fixtures.planClip(sceneID: 2, start: 110, end: 120),
                                                         Fixtures.planClip(sceneID: 2, start: 130, end: 140)]),
                candidate(13, name: "Unknown scene", clips: [Fixtures.planClip(sceneID: 99, start: 0, end: 5)]),
            ], options: WizardOptions())
        let clips = WizardPreviewClips.kept(run: run, scenes: scenes)
        #expect(clips.map(\.title) == ["Hello", "Two parts · 1", "Two parts · 2"])
        #expect(clips.map(\.start) == [1.32, 110, 130])
        #expect(clips.map(\.end) == [89.46, 120, 140])
        #expect(clips.map(\.scene.id) == [1, 2, 2])
        #expect(Set(clips.map(\.id)).count == 3)
        #expect(abs(clips[0].duration - 88.14) < 0.001)
    }

    @Test func keptExchangesStandInUntilSelectionsExist() {
        let first = Fixtures.scene(id: 1, start: 1.32, end: 89.46)
        let second = Fixtures.scene(id: 2, start: 100, end: 160)
        let qa = MiniWizardQA(sections: [
            TranscriptQASections.Section(scene: first, question: "How did you start?"),
            TranscriptQASections.Section(scene: second, question: "Not kept"),
        ], rows: [], labels: [:], turns: [], kept: [1, 999])
        let run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .qa, length: .automatic,
            batchID: "qa", candidates: [], options: WizardOptions(), qa: qa)
        let clips = WizardPreviewClips.kept(run: run, scenes: [first, second])
        #expect(clips.count == 1)
        #expect(clips.first?.title == "How did you start?")
        #expect(clips.first?.range == 1.32...89.46)
        #expect(clips.first?.scene.id == 1)
    }

    @Test func picksWithoutASceneBorrowTheOverlappingScene() {
        let scenes = [Fixtures.scene(id: 1, start: 0, end: 50), Fixtures.scene(id: 2, start: 50, end: 120)]
        let picks = [TranscriptPick(id: 7, videoID: 1, position: 0, start: 60, end: 80, originalStart: 60, originalEnd: 80, sceneID: nil),
                     TranscriptPick(id: 8, videoID: 1, position: 1, start: 500, end: 520, originalStart: 500, originalEnd: 520, sceneID: nil)]
        let run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .transcript, length: .automatic,
            batchID: "t", candidates: [], options: WizardOptions(),
            transcript: MiniWizardTranscript(rows: [], labels: [:], picks: picks))
        let clips = WizardPreviewClips.kept(run: run, scenes: scenes)
        #expect(clips.map(\.scene.id) == [2])
        #expect(clips.first?.range == 60...80)
        #expect(clips.first?.title == "Passage 1")
    }

    @Test func noKeptFootageMeansNoClips() {
        let run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .highlights, length: .automatic,
            batchID: "b", candidates: [], options: WizardOptions())
        #expect(WizardPreviewClips.kept(run: run, scenes: [Fixtures.scene()]).isEmpty)
    }

    @Test func clockReadsLikeAPlayer() {
        #expect(WizardPreviewClips.clock(0) == "0:00")
        #expect(WizardPreviewClips.clock(88.14) == "1:28")
        #expect(WizardPreviewClips.clock(3725) == "1:02:05")
        #expect(WizardPreviewClips.clock(-3) == "0:00")
    }

    @Test func previewKeyFollowsTheScrubbedMoment() {
        let scene = Fixtures.scene(id: 1, start: 0, end: 90)
        let options = WizardOptions()
        let profile = Fixtures.brand()
        let middle = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        let explicit = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [], time: 45)
        let early = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [], time: 2)
        #expect(middle == explicit)
        #expect(middle != early)
        #expect(early.time == 2)
    }

    @Test func picksNeverBorrowAnotherVideosSceneAndWinOverSavedTakes() {
        var other = Fixtures.scene(id: 9, start: 50, end: 200)
        other.videoID = 2
        let own = Fixtures.scene(id: 1, start: 55, end: 70)
        let pick = TranscriptPick(id: 7, videoID: 1, position: 0, start: 60, end: 80, originalStart: 60, originalEnd: 80, sceneID: nil)
        // A stale saved take from before the pick was trimmed.
        let selection = WizardSelectionRecord(id: 10, projectID: 1, name: "Old take", recipe: "custom", step1Options: WizardStep1Options())
        let take = WizardSelectionTake(id: 10, selectionID: 10, ordinal: 1,
                                       plan: Fixtures.plan(clips: [Fixtures.planClip(sceneID: 1, start: 60, end: 90)]), sceneIDs: [1])
        let run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .transcript, length: .automatic,
            batchID: "t", candidates: [MiniWizardCandidate(selection: selection, take: take)], options: WizardOptions(),
            transcript: MiniWizardTranscript(rows: [], labels: [:], picks: [pick]))
        let clips = WizardPreviewClips.kept(run: run, scenes: [other, own])
        #expect(clips.map(\.scene.id) == [1], "the other video's longer overlapping scene is ignored")
        #expect(clips.first?.range == 60...80, "the current pick, not the stale take")
        // With no picks the saved take still serves.
        let emptyRun = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .transcript, length: .automatic,
            batchID: "t", candidates: [MiniWizardCandidate(selection: selection, take: take)], options: WizardOptions(),
            transcript: MiniWizardTranscript(rows: [], labels: [:], picks: []))
        #expect(WizardPreviewClips.kept(run: emptyRun, scenes: [other, own]).first?.range == 60...90)
    }
}
