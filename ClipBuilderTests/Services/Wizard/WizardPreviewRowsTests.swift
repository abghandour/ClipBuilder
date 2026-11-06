import Foundation
import Testing
@testable import Clip_Builder

@Suite("Preview clip list rows")
struct WizardPreviewRowsTests {
    private func clip(_ id: String, scene: SceneRecord, start: Double, end: Double) -> WizardPreviewClip {
        WizardPreviewClip(id: id, title: id, scene: scene, start: start, end: end)
    }

    @Test func textIsTranscriptThenNarrativeThenNothing() {
        var spoken = Fixtures.scene(id: 1, start: 0, end: 10)
        spoken.narrative = "A takes the back."
        var silent = Fixtures.scene(id: 2, start: 20, end: 30)
        silent.narrative = "  B sweeps and passes.  "
        var empty = Fixtures.scene(id: 3, start: 40, end: 50)
        empty.narrative = nil
        let words = [Int64(1): [
            TranscriptQATrim.Word(id: 0, text: "hello", start: 1, end: 2),
            TranscriptQATrim.Word(id: 1, text: "there", start: 2, end: 3),
            TranscriptQATrim.Word(id: 2, text: "late", start: 60, end: 61)
        ]]
        let rows = WizardPreviewRows.rows(clips: [
            clip("pick-1", scene: spoken, start: 0, end: 5),
            clip("pick-2", scene: silent, start: 20, end: 30),
            clip("pick-3", scene: empty, start: 40, end: 50)
        ], words: words)
        #expect(rows.map(\.text) == ["hello there", "B sweeps and passes.", ""])
        #expect(rows.map(\.textKind) == [.transcript, .description, .none])
        #expect(rows[0].start == 0 && rows[0].duration == 5)
    }

    @Test func speakerNamesStartTheirStretches() {
        let scene = Fixtures.scene(id: 1, start: 0, end: 10)
        func word(_ id: Int, _ text: String, _ start: Double) -> TranscriptQATrim.Word {
            TranscriptQATrim.Word(id: id, text: text, start: start, end: start + 0.5)
        }
        let lines = [Int64(1): [
            WizardPreviewRows.Line(speaker: "Alice", words: [word(0, "hello", 0), word(1, "there", 1)]),
            WizardPreviewRows.Line(speaker: "Alice", words: [word(2, "again", 2)]),
            WizardPreviewRows.Line(speaker: "Marcello", words: [word(3, "hi", 3), word(4, "late", 20)]),
            WizardPreviewRows.Line(speaker: nil, words: [word(5, "unknown", 4)])
        ]]
        let rows = WizardPreviewRows.rows(clips: [WizardPreviewClip(id: "pick-1", title: "p", scene: scene, start: 0, end: 5)],
                                          lines: lines)
        #expect(rows[0].segments == [.init(speaker: "Alice", text: "hello there again"),
                                     .init(speaker: "Marcello", text: "hi"),
                                     .init(speaker: nil, text: "unknown")],
                "consecutive rows of one speaker merge; words outside the range are left out")
        #expect(rows[0].text == "Alice: hello there again Marcello: hi unknown")
    }

    @Test func reorderDropSlots() {
        let ids = ["a", "b", "c", "d"]
        #expect(WizardPreviewRows.reorderedIDs(ids, moving: "a", toSlot: 4) == ["b", "c", "d", "a"])
        #expect(WizardPreviewRows.reorderedIDs(ids, moving: "d", toSlot: 0) == ["d", "a", "b", "c"])
        #expect(WizardPreviewRows.reorderedIDs(ids, moving: "b", toSlot: 3) == ["a", "c", "b", "d"])
        #expect(WizardPreviewRows.reorderedIDs(ids, moving: "b", toSlot: 1) == ids, "dropping on its own top edge")
        #expect(WizardPreviewRows.reorderedIDs(ids, moving: "b", toSlot: 2) == ids, "dropping on its own bottom edge")
        #expect(WizardPreviewRows.reorderedIDs(ids, moving: "zz", toSlot: 0) == ids)
    }

    @Test func mergingKeepsUnlistedSlots() {
        // Kept picks 2 and 4 swap; unchecked picks 1 and 3 keep their places.
        #expect(WizardPreviewRows.merging([4, 2], into: [1, 2, 3, 4]) == [1, 4, 3, 2])
        #expect(WizardPreviewRows.merging([9, 2], into: [1, 2, 3]) == [1, 2, 3], "unknown ids are dropped")
        #expect(WizardPreviewRows.merging([], into: [1, 2]) == [1, 2])
    }

    @Test func qaPlansFollowTheKeptOrder() {
        let sections = [10.0, 20.0, 30.0].enumerated().map { index, start in
            TranscriptQASections.Section(scene: Fixtures.scene(id: Int64(index + 1), start: start, end: start + 5),
                                         question: "Q\(index + 1)", asker: nil, answerer: nil)
        }
        #expect(MiniWizardQARules.ordering(sections, by: []).map(\.id) == [1, 2, 3])
        #expect(MiniWizardQARules.ordering(sections.reversed(), by: [3, 1]).map(\.id) == [3, 1, 2],
                "named ids first in that order, the rest in transcript order")
        let plans = MiniWizardQARules.plans(sections: sections, kept: [1, 2, 3], order: [2, 3, 1], rows: [], turns: [])
        #expect(plans.map { $0.clips[0].sceneID } == [2, 3, 1])
    }

    @Test func takesWithSeveralCutsMoveAsOneBlock() {
        let scene = Fixtures.scene()
        let rows = WizardPreviewRows.rows(clips: ["take-1-0", "take-1-1", "take-2-0"].map {
            WizardPreviewClip(id: $0, title: $0, scene: scene, start: 0, end: 1)
        }, words: [:])
        let blocks = WizardPreviewRows.blocks(rows).map { $0.map(\.id) }
        #expect(blocks == [["take-1-0", "take-1-1"], ["take-2-0"]])
        #expect(WizardPreviewRows.reorderedIDs(blocks: blocks, moving: "take-1-0", toSlot: 2)
                == ["take-2-0", "take-1-0", "take-1-1"], "both cuts of take 1 land after take 2")
        #expect(WizardPreviewRows.reorderedIDs(blocks: blocks, moving: "take-1-1", toSlot: 1)
                == ["take-1-0", "take-1-1", "take-2-0"], "dropping on its own bottom edge changes nothing")
    }

    @Test func ownersFromClipIDs() {
        #expect(WizardPreviewRows.owner(of: "qa-12") == .qa(12))
        #expect(WizardPreviewRows.owner(of: "pick-3") == .transcriptPick(3))
        #expect(WizardPreviewRows.owner(of: "fight-9") == .fightPick(9))
        #expect(WizardPreviewRows.owner(of: "take-44-1") == .take(44))
        #expect(WizardPreviewRows.owner(of: "scene-1") == nil)
        #expect(WizardPreviewRows.ownerIDs(["take-44-0", "take-44-1", "take-45-0"]) == [44, 45],
                "a take's cuts move as one")
    }
}
