import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard footage review adapter")
struct WizardFootageReviewTests {
    private func summary(id: Int64 = 1, name: String = "Knockouts", takes: [[WizardPlanClip]] = [[Fixtures.planClip()]],
                         bestOrdinal: Int? = 1) -> WizardSelectionSummary {
        var selection = WizardSelectionRecord(id: id, projectID: 1, name: name, recipe: "custom",
                                              step1Options: WizardStep1Options())
        let takeRecords = takes.enumerated().map { offset, clips -> WizardSelectionTake in
            var plan = Fixtures.plan(clips: clips, transitions: clips.count > 1 ? ["dissolve"] : [])
            plan.rationale = "Setup and payoff \(offset + 1)"
            var take = WizardSelectionTake(id: id * 100 + Int64(offset + 1), selectionID: id, ordinal: offset + 1,
                                           plan: plan, sceneIDs: clips.map(\.sceneID))
            if offset == 1 { take.note = "Tighter" }
            return take
        }
        selection.bestTakeID = bestOrdinal.flatMap { ordinal in takeRecords.first { $0.ordinal == ordinal }?.id }
        return WizardSelectionSummary(selection: selection, takes: takeRecords)
    }

    @Test func oneRowPerTakeWithCutsAsChildren() throws {
        let summary = summary(takes: [[Fixtures.planClip()],
                                      [Fixtures.planClip(start: 2, end: 5.2), Fixtures.planClip(sceneID: 2, start: 7, end: 9)]])
        var secondScene = Fixtures.scene(id: 2, start: 6, end: 10)
        secondScene.videoID = 2
        secondScene.videoPath = "/tmp/second.mp4"
        secondScene.videoFilename = "second.mp4"
        let items = WizardFootageReview.items(selections: [summary], scenes: [Fixtures.scene(), secondScene],
                                              videos: [Fixtures.video()])
        #expect(items.count == 2)
        #expect(items.map(\.title) == ["Knockouts · Take 1", "Knockouts · Take 2"])
        #expect(items[0].id == .init(ownerID: 101, revisionID: 101))
        #expect(items[0].keepLabel == "Use Take 1 of Knockouts")
        #expect(items[0].captions[0].text == "4.0 s · 1 cut")
        #expect(items[0].captions[1].text == "Setup and payoff 1")
        #expect(items[0].children.isEmpty && items[0].range == 2...6 && items[0].isAvailable)
        #expect(items[1].children.count == 2)
        #expect(items[1].children.map(\.title) == ["Cut 1 · 3.2 s", "Cut 2 · 2.0 s"])
        #expect(items[1].children[1].video.path == "/tmp/second.mp4")
        #expect(items[1].captions.last?.text == "Asked: Tighter")
        // A single take uses the selection name alone.
        let single = WizardFootageReview.items(selections: [self.summary()], scenes: [Fixtures.scene()], videos: [Fixtures.video()])
        #expect(single.first?.title == "Knockouts")
    }

    @Test func missingFootageIsUnavailableNotCrashing() {
        let items = WizardFootageReview.items(selections: [summary()], scenes: [], videos: [])
        #expect(items.count == 1 && items[0].isAvailable == false)
        #expect(WizardFootageReview.trimming(items[0].id, to: 2...4, take: summary().takes[0], scenes: []) == nil)
    }

    @Test func keptMeansBestTakeAndTogglingMovesIt() {
        let two = summary(takes: [[Fixtures.planClip()], [Fixtures.planClip()]], bestOrdinal: 1)
        let other = summary(id: 2, name: "Scrambles", bestOrdinal: nil)
        #expect(WizardFootageReview.keptIDs([two, other]) == [101])
        // Keep take 2 instead: its selection's best take changes; the other stays unset.
        let changes = WizardFootageReview.bestTakeChanges(from: [102], in: [two, other])
        #expect(changes.count == 1 && changes[0].selectionID == 1 && changes[0].takeID == 102)
        // Keeping both prefers the newer take; unkeeping all clears it.
        #expect(WizardFootageReview.bestTakeChanges(from: [101, 102], in: [two]).first?.takeID == 102)
        #expect(WizardFootageReview.bestTakeChanges(from: [], in: [two]).first.map { $0.takeID == nil } == true)
        #expect(WizardFootageReview.bestTakeChanges(from: [101], in: [two]).isEmpty)
        // Keeping the other selection's take sets its best take.
        let both = WizardFootageReview.bestTakeChanges(from: [101, 201], in: [two, other])
        #expect(both.count == 1 && both[0].selectionID == 2 && both[0].takeID == 201)
    }

    @Test func footageFollowsTheChosenSources() {
        // Recorded footage names the video; otherwise the take's scenes resolve to one.
        var recorded = summary(id: 1, name: "From video 7")
        recorded.takes[0].plan.footage = [WizardFootageReference(sceneID: nil, videoID: 7)]
        let byScene = summary(id: 2, name: "From the fixture scene")
        var orphan = summary(id: 3, name: "Untraceable")
        orphan.takes[0].sceneIDs = []
        orphan.takes[0].plan.clips = []
        let scenes = [Fixtures.scene()]
        let fixtureVideo = Fixtures.scene().videoID
        #expect(WizardFootageReview.videoIDs(of: recorded, scenes: scenes) == [7])
        #expect(WizardFootageReview.videoIDs(of: byScene, scenes: scenes) == [fixtureVideo])
        #expect(WizardFootageReview.videoIDs(of: orphan, scenes: scenes).isEmpty)
        let all = [recorded, byScene, orphan]
        #expect(WizardFootageReview.selections(all, usingVideos: [7], scenes: scenes).map(\.id) == [1, 3])
        #expect(WizardFootageReview.selections(all, usingVideos: [fixtureVideo], scenes: scenes).map(\.id) == [2, 3])
        #expect(WizardFootageReview.selections(all, usingVideos: [], scenes: scenes).map(\.id) == [3])
        #expect(WizardFootageReview.selections(all, usingVideos: [7, fixtureVideo], scenes: scenes).map(\.id) == [1, 2, 3])
    }

    @Test func trimmingChangesOnlyTheTargetedCut() throws {
        let summary = summary(takes: [[Fixtures.planClip(start: 2, end: 5), Fixtures.planClip(sceneID: 2, start: 7, end: 9)]])
        var secondScene = Fixtures.scene(id: 2, start: 6, end: 10)
        secondScene.videoID = 2
        let take = summary.takes[0]
        let plan = try #require(WizardFootageReview.trimming(.init(ownerID: take.id, revisionID: take.id, cutIndex: 1),
                                                             to: 6.5...9.5, take: take, scenes: [Fixtures.scene(), secondScene]))
        #expect(plan.clips[0].start == 2 && plan.clips[0].end == 5)
        #expect(plan.clips[1].start == 6.5 && plan.clips[1].end == 9.5)
        // Out of the scene's bounds clamps; a wrong take id is refused.
        let clamped = try #require(WizardFootageReview.trimming(.init(ownerID: take.id, revisionID: take.id, cutIndex: 1),
                                                                to: 0...20, take: take, scenes: [Fixtures.scene(), secondScene]))
        #expect(clamped.clips[1].start == 6 && clamped.clips[1].end == 10)
        #expect(WizardFootageReview.trimming(.init(ownerID: 999, revisionID: 999), to: 2...4, take: take, scenes: [Fixtures.scene()]) == nil)
        let found = WizardFootageReview.take(.init(ownerID: take.id, cutIndex: 1), in: [summary])
        #expect(found?.1.id == take.id && found?.0.id == summary.id)
    }
}
