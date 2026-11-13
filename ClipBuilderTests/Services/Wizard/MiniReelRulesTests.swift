import Foundation
import Testing
@testable import Clip_Builder

@Suite("Express reel rules")
struct MiniReelRulesTests {
    private func item(_ kind: MiniWizardFlow.FootageKind, _ id: Int64, start: Double = 0, end: Double = 1,
                      title: String = "") -> MiniReelItem {
        MiniReelItem(kind: kind, itemID: id, sceneID: nil, start: start, end: end, title: title)
    }

    private func candidate(_ id: Int64, name: String, clips: [WizardPlanClip], kept: Bool = true) -> MiniWizardCandidate {
        let selection = WizardSelectionRecord(id: id, projectID: 1, name: name, recipe: "custom",
                                               step1Options: WizardStep1Options(), miniBatch: "hl")
        let take = WizardSelectionTake(id: id, selectionID: id, ordinal: 1,
                                       plan: Fixtures.plan(clips: clips), sceneIDs: clips.map(\.sceneID))
        return MiniWizardCandidate(selection: selection, take: take, kept: kept)
    }

    @Test func undoPutsBackOnlyWhatItRestored() {
        func keys(_ items: [MiniReelItem]) -> [MiniReelRules.Key] { items.map(\.key) }
        let a = item(.transcript, 1), b = item(.transcript, 2), q = item(.qa, 7)
        let saved = keys([a, q, b])
        // A deleted pick comes back at the end; Undo returns it to the front.
        #expect(keys(MiniReelRules.restoringPlacement([q, b, a], saved: saved, restored: [a.key])) == saved)
        // Between its old neighbours when both are still there.
        #expect(keys(MiniReelRules.restoringPlacement([a, b, q], saved: saved, restored: [q.key])) == saved)
        // Nothing came back (a trim was undone): an order arranged since stays.
        #expect(keys(MiniReelRules.restoringPlacement([a, b, q], saved: saved, restored: [])) == keys([a, b, q]))
        // Its old neighbour is gone: after the nearest earlier item that is left.
        #expect(keys(MiniReelRules.restoringPlacement([q, b], saved: keys([a, b, q]), restored: [q.key])) == keys([b, q]))
        // Two came back: each in its saved place, positions renumbered.
        let both = MiniReelRules.restoringPlacement([q, b, a], saved: saved, restored: [a.key, b.key])
        #expect(keys(both) == saved)
        #expect(both.map(\.position) == [0, 1, 2])
    }

    @Test func picksOfOneUnitShareItsPlaceAndColour() {
        func pick(_ id: Int64, _ group: String?) -> TranscriptPick {
            TranscriptPick(id: id, videoID: 1, position: Int(id), start: 0, end: 1, originalStart: 0, originalEnd: 1,
                           sceneID: nil, groupKey: group)
        }
        let run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .transcript, length: .automatic,
                                batchID: "t", candidates: [], options: WizardOptions(),
                                transcript: MiniWizardTranscript(rows: [], labels: [:],
                                                                 picks: [pick(1, nil), pick(2, "g"), pick(3, "g"), pick(4, nil)]))
        let places = [1, 2, 3, 4].map { MiniReelRules.sectionIndex(of: item(.transcript, $0), runs: [.transcript: run]) }
        #expect(places == [0, 1, 1, 2])
    }

    @Test func unitPassagesStayTogetherAndTakeTheReelsOrder() {
        let unit: [[Int64]] = [[1, 2, 3]]
        func ids(_ items: [MiniReelItem]) -> [String] { items.map { "\($0.kind == .transcript ? "t" : "q")\($0.itemID)" } }
        // Passage 3 dragged above 1 inside the block: the pick's order becomes 3, 1, 2.
        let inside = [item(.transcript, 3), item(.transcript, 1), item(.transcript, 2), item(.qa, 9)]
        let moved = MiniReelRules.unitOrders(inside, units: unit)
        #expect(moved == [[3, 1, 2]])
        #expect(ids(MiniReelRules.groupingUnits(inside, units: moved)) == ["t3", "t1", "t2", "q9"])
        // Passage 1 dragged below another clip: it rejoins the block, now last.
        let outside = [item(.transcript, 2), item(.transcript, 3), item(.qa, 9), item(.transcript, 1)]
        let after = MiniReelRules.unitOrders(outside, units: unit)
        #expect(after == [[2, 3, 1]])
        #expect(ids(MiniReelRules.groupingUnits(outside, units: after)) == ["t2", "t3", "t1", "q9"])
        // Another clip dropped among the passages ends up beside the block.
        let split = [item(.transcript, 1), item(.transcript, 2), item(.qa, 9), item(.transcript, 3)]
        #expect(ids(MiniReelRules.groupingUnits(split, units: unit)) == ["t1", "t2", "t3", "q9"])
        // An unchecked passage is not in the reel and keeps its place after the shown ones.
        #expect(MiniReelRules.unitOrders([item(.transcript, 3), item(.transcript, 1)], units: unit) == [[3, 1, 2]])
        // A drag of another clip leaves a pick with an unchecked passage as it was.
        #expect(MiniReelRules.unitOrders([item(.qa, 9), item(.transcript, 2), item(.transcript, 3)], units: unit) == [[1, 2, 3]])
        // A two-passage pick: the passage dragged away comes back; the block stays put.
        let pair: [[Int64]] = [[1, 2]]
        let old = [item(.qa, 9), item(.transcript, 1), item(.transcript, 2)]
        let dragged = [item(.transcript, 2), item(.qa, 9), item(.transcript, 1)]
        let which = MiniReelRules.movedItem(from: old, to: dragged, units: pair)
        #expect(which == .init(kind: .transcript, itemID: 2))
        let order = MiniReelRules.unitOrders(dragged, units: pair)
        #expect(ids(MiniReelRules.groupingUnits(dragged, units: order, moved: which)) == ["q9", "t2", "t1"])
        // A clip that swapped places with a passage is the one that moved.
        #expect(MiniReelRules.movedItem(from: old, to: [item(.transcript, 1), item(.qa, 9), item(.transcript, 2)], units: pair)
                == .init(kind: .qa, itemID: 9))
        // The list's order wins for a reel that still has the old one.
        #expect(ids(MiniReelRules.groupingUnits([item(.transcript, 1), item(.transcript, 2), item(.transcript, 3)],
                                                units: [[2, 1, 3]])) == ["t2", "t1", "t3"])
    }

    @Test func replacedHighlightBatchLeavesTheReel() {
        let reel = [item(.highlights, 1065), item(.transcript, 1065), item(.highlights, 1071), item(.qa, 3)]
        // 1065 was a candidate of the batch that Generate replaced.
        let result = MiniReelRules.droppingHighlights(reel, notIn: [1071, 1072])
        #expect(result.map(\.key) == [.init(kind: .transcript, itemID: 1065), .init(kind: .highlights, itemID: 1071),
                                      .init(kind: .qa, itemID: 3)])
        #expect(result.map(\.position) == [0, 1, 2])
        #expect(MiniReelRules.droppingHighlights(reel, notIn: [1065, 1071]) == reel)
    }

    @Test func reconcileDropsUnkeptAppendsNewAndRefreshesSnapshots() {
        let reel = [item(.qa, 1, title: "Q1"), item(.transcript, 7, start: 10, end: 20), item(.qa, 2, title: "Q2")]
        // Q&A now keeps 2 and 3 (1 was unticked); 2's range moved.
        let kept = [item(.qa, 3, title: "Q3"), item(.qa, 2, start: 5, end: 9, title: "Q2")]
        let result = MiniReelRules.reconcile(reel, kind: .qa, kept: kept)
        #expect(result.map(\.key) == [.init(kind: .transcript, itemID: 7), .init(kind: .qa, itemID: 2), .init(kind: .qa, itemID: 3)],
                "the transcript row keeps its place, 1 leaves, 3 joins at the end")
        #expect(result[1].range == 5...9)
        #expect(result.map(\.position) == [0, 1, 2])
        #expect(MiniReelRules.reconcile(result, kind: .qa, kept: kept) == result, "a second pass changes nothing")
    }

    @Test func reconcileLeavesAnotherBatchsHighlightsAlone() {
        // The 30 s batch's candidates are 40 and 41; 60 s loaded with 50 kept and 51 unkept.
        let reel = [item(.highlights, 40), item(.qa, 1), item(.highlights, 51)]
        let result = MiniReelRules.reconcile(reel, kind: .highlights, kept: [item(.highlights, 50)], known: [50, 51])
        #expect(result.map(\.key) == [.init(kind: .highlights, itemID: 40), .init(kind: .qa, itemID: 1),
                                      .init(kind: .highlights, itemID: 50)],
                "the other batch's item stays, the loaded batch's unkept one leaves and its kept one joins")
    }

    @Test func reconcileLeavesOtherSectionsAlone() {
        let reel = [item(.highlights, 40), item(.fightMetrics, 3)]
        #expect(MiniReelRules.reconcile(reel, kind: .transcript, kept: []) == MiniReelRules.renumbered(reel))
    }

    @Test func reorderFollowsClipIDsAndTreatsATakesCutsAsOne() {
        let reel = [item(.qa, 1), item(.highlights, 40), item(.transcript, 7)]
        let dropped = MiniReelRules.reordered(reel, clipIDs: ["take-40-0", "take-40-1", "pick-7", "qa-1"])
        #expect(dropped.map(\.key) == [.init(kind: .highlights, itemID: 40), .init(kind: .transcript, itemID: 7), .init(kind: .qa, itemID: 1)])
        #expect(dropped.map(\.position) == [0, 1, 2])
        let partial = MiniReelRules.reordered(reel, clipIDs: ["pick-7"])
        #expect(partial.map(\.itemID) == [7, 1, 40], "unnamed items follow in their old order")
    }

    @Test func removingAndLookupUseTheClipID() {
        let reel = [item(.qa, 1), item(.highlights, 40), item(.fightMetrics, 3)]
        #expect(MiniReelRules.item(reel, clipID: "take-40-1")?.kind == .highlights)
        #expect(MiniReelRules.item(reel, clipID: "scene-1") == nil)
        #expect(MiniReelRules.removing(reel, clipID: "fight-3").map(\.itemID) == [1, 40])
        #expect(MiniReelRules.removing(reel, clipID: "fight-99") == MiniReelRules.renumbered(reel))
        #expect(MiniReelRules.kinds(reel + [item(.qa, 5)]) == [.qa, .highlights, .fightMetrics])
        #expect(item(.highlights, 40).clipID == "take-40-0")
    }

    @Test func keptDraftsComeFromEachSection() {
        let first = Fixtures.scene(id: 1, start: 0, end: 10)
        let second = Fixtures.scene(id: 2, start: 20, end: 30)
        let qa = MiniWizardQA(sections: [
            TranscriptQASections.Section(scene: first, question: "First?"),
            TranscriptQASections.Section(scene: second, question: "Second?"),
        ], rows: [], labels: [:], turns: [], kept: [1, 2], keptOrder: [2, 1])
        let qaRun = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .qa, length: .automatic,
                                  batchID: "qa", candidates: [], options: WizardOptions(), qa: qa)
        #expect(MiniReelRules.kept(run: qaRun).map(\.itemID) == [2, 1], "the Q&A tick order")
        #expect(MiniReelRules.kept(run: qaRun).first?.title == "Second?")

        let picks = [TranscriptPick(id: 7, videoID: 1, position: 0, start: 1, end: 2, originalStart: 1, originalEnd: 2, sceneID: nil, kept: false),
                     TranscriptPick(id: 8, videoID: 1, position: 1, start: 3, end: 4, originalStart: 3, originalEnd: 4, sceneID: 1)]
        let transcriptRun = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .transcript, length: .automatic,
                                          batchID: "t", candidates: [], options: WizardOptions(),
                                          transcript: MiniWizardTranscript(rows: [], labels: [:], picks: picks))
        let drafts = MiniReelRules.kept(run: transcriptRun)
        #expect(drafts.map(\.itemID) == [8], "unchecked picks are not in the reel")
        #expect(drafts[0].sceneID == 1 && drafts[0].range == 3...4)

        let highlights = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .highlights, length: .automatic,
            batchID: "hl", candidates: [
                candidate(40, name: "Skipped", clips: [Fixtures.planClip(sceneID: 1, start: 0, end: 5)], kept: false),
                candidate(41, name: "Two parts", clips: [Fixtures.planClip(sceneID: 1, start: 1, end: 2),
                                                         Fixtures.planClip(sceneID: 2, start: 21, end: 22)]),
            ], options: WizardOptions())
        let hl = MiniReelRules.kept(run: highlights)
        #expect(hl.map(\.itemID) == [41] && hl[0].title == "Two parts" && hl[0].range == 1...2)
    }

    @Test func candidatesFollowTheReelAcrossSections() {
        var pickClip = Fixtures.planClip(sceneID: 1, start: 3, end: 4)
        pickClip.miniPickID = 8
        let transcriptRun = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .transcript, length: .automatic,
            batchID: "t", candidates: [candidate(90, name: "Passage 1", clips: [pickClip])], options: WizardOptions(),
            transcript: MiniWizardTranscript(rows: [], labels: [:], picks: []))
        let highlights = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .highlights, length: .automatic,
            batchID: "hl", candidates: [candidate(41, name: "Hook", clips: [Fixtures.planClip(sceneID: 2, start: 21, end: 22)])],
            options: WizardOptions())
        let reel = [item(.highlights, 41), item(.qa, 5), item(.transcript, 8)]
        let found = MiniReelRules.candidates(items: reel, runs: [.transcript: transcriptRun, .highlights: highlights])
        #expect(found.map(\.id) == [41, 90], "reel order; the Q&A item has no loaded section")
    }

    @Test func anotherLengthsHighlightsResolveFromItsBatch() {
        // 60 s is loaded (50); 40 was kept at 30 s, 42 was unkept there since.
        let loaded = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .highlights, length: .automatic,
            batchID: "hl60", candidates: [candidate(50, name: "Loaded", clips: [Fixtures.planClip(sceneID: 1, start: 1, end: 2)])],
            options: WizardOptions())
        let others = [candidate(40, name: "Other", clips: [Fixtures.planClip(sceneID: 1, start: 5, end: 9)]),
                      candidate(42, name: "Unkept", clips: [Fixtures.planClip(sceneID: 1, start: 9, end: 10)], kept: false)]
        let reel = [item(.highlights, 40), item(.highlights, 50), item(.highlights, 42)]
        #expect(MiniReelRules.candidates(items: reel, runs: [.highlights: loaded]).map(\.id) == [50])
        #expect(MiniReelRules.candidates(items: reel, runs: [.highlights: loaded], otherHighlights: others).map(\.id) == [40, 50],
                "reel order; an unkept candidate of the other batch stays out")
    }

    @Test func reelDrawsAnotherLengthsHighlightFromItsSnapshot() {
        let scene = Fixtures.scene(id: 1, start: 0, end: 50)
        let loaded = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .highlights, length: .automatic,
            batchID: "hl60", candidates: [candidate(50, name: "Loaded", clips: [Fixtures.planClip(sceneID: 1, start: 1, end: 2)])],
            options: WizardOptions())
        let reel = [
            MiniReelItem(kind: .highlights, itemID: 40, position: 0, sceneID: 1, start: 5, end: 9, title: "Other"),
            MiniReelItem(kind: .highlights, itemID: 50, position: 1, sceneID: 1, start: 1, end: 2, title: "Loaded"),
        ]
        let clips = WizardPreviewClips.reel(items: reel, runs: [.highlights: loaded], videoID: 1, scenes: [scene])
        #expect(clips.map(\.id) == ["take-40-0", "take-50-0"], "the other batch's item is drawn from its snapshot")
        #expect(clips[0].range == 5...9)
    }

    @Test func sectionIndexIsTheItemsPlaceInItsLoadedSection() {
        let highlights = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .highlights, length: .automatic,
            batchID: "hl", candidates: [candidate(40, name: "A", clips: [Fixtures.planClip(sceneID: 1, start: 0, end: 1)]),
                                         candidate(41, name: "B", clips: [Fixtures.planClip(sceneID: 1, start: 1, end: 2)])],
            options: WizardOptions())
        let runs: [MiniWizardFlow.FootageKind: MiniWizardRun] = [.highlights: highlights]
        #expect(MiniReelRules.sectionIndex(of: item(.highlights, 41), runs: runs) == 1)
        #expect(MiniReelRules.sectionIndex(of: item(.highlights, 99), runs: runs) == nil, "another batch's item")
        #expect(MiniReelRules.sectionIndex(of: item(.qa, 1), runs: runs) == nil, "Q&A is not loaded")
        let cached: [MiniReelRules.Key: Int] = [.init(kind: .qa, itemID: 1): 4, .init(kind: .highlights, itemID: 41): 0]
        #expect(MiniReelRules.paletteIndex(of: item(.qa, 1), runs: runs, cached: cached) == 4, "read ahead for an unloaded section")
        #expect(MiniReelRules.paletteIndex(of: item(.highlights, 41), runs: runs, cached: cached) == 1, "the live order wins")
    }

    @Test func reelClipsUseLiveRangesAndFallBackToSnapshots() {
        let first = Fixtures.scene(id: 1, start: 0, end: 50)
        let second = Fixtures.scene(id: 2, start: 50, end: 120)
        let picks = [TranscriptPick(id: 7, videoID: 1, position: 0, start: 60, end: 80, originalStart: 60, originalEnd: 80, sceneID: nil)]
        let transcriptRun = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .transcript, length: .automatic,
            batchID: "t", candidates: [], options: WizardOptions(),
            transcript: MiniWizardTranscript(rows: [], labels: [:], picks: picks))
        let reel = [
            MiniReelItem(kind: .highlights, itemID: 41, position: 0, sceneID: 1, start: 5, end: 9, title: "Hook"),
            MiniReelItem(kind: .transcript, itemID: 7, position: 1, sceneID: nil, start: 0, end: 1, title: "stale"),
            MiniReelItem(kind: .qa, itemID: 99, position: 2, sceneID: 99, start: 900, end: 901, title: "gone"),
        ]
        let clips = WizardPreviewClips.reel(items: reel, runs: [.transcript: transcriptRun], videoID: 1, scenes: [first, second])
        #expect(clips.map(\.id) == ["take-41-0", "pick-7"], "the snapshot draws Highlights; a range outside every scene is skipped")
        #expect(clips[0].range == 5...9 && clips[0].scene.id == 1)
        #expect(clips[1].range == 60...80 && clips[1].scene.id == 2, "the loaded section's range wins over the snapshot")
    }
}
