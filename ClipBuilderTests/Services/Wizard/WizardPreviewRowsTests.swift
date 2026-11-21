import Foundation
import Testing
@testable import Clip_Builder

@Suite("Preview clip list rows")
struct WizardPreviewRowsTests {
    @Test func selectionFollowsTheAcceptedOrder() {
        let before = ["A1", "A2", "B"]
        #expect(WizardPreviewRows.reconciledIndex(1, previousIDs: before, ids: before) == 1,
                "a proposed A1, B, A2 order regrouped by the store still selects A2")
        #expect(WizardPreviewRows.reconciledIndex(1, previousIDs: before, ids: ["B", "A1", "A2"]) == 2)
        #expect(WizardPreviewRows.reconciledIndex(2, previousIDs: before, ids: ["A2", "B"]) == 1,
                "removing an earlier clip keeps the selected clip")
    }

    @Test func selectionClampsWhenItsClipLeaves() {
        #expect(WizardPreviewRows.reconciledIndex(1, previousIDs: ["A", "B", "C"], ids: ["A", "C"]) == 1)
        #expect(WizardPreviewRows.reconciledIndex(2, previousIDs: ["A", "B", "C"], ids: ["A", "B"]) == 1)
        #expect(WizardPreviewRows.reconciledIndex(8, previousIDs: ["A"], ids: ["A", "B"]) == 1)
        #expect(WizardPreviewRows.reconciledIndex(-1, previousIDs: [], ids: ["A"]) == 0)
        #expect(WizardPreviewRows.reconciledIndex(1, previousIDs: ["A", "B"], ids: []) == 0)
    }

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

    @Test("A fight clip without words says what the scorer logged in it")
    func fightActions() {
        func event(_ time: Double, _ fighter: String, _ action: String, detail: String? = nil, outcome: String? = nil) -> FightEventRecord {
            var record = FightEventRecord(id: Int64(time * 100), videoID: 1, time: time, fighterKey: fighter, action: action, points: 1)
            record.detail = detail
            record.outcome = outcome
            return record
        }
        let events = [Int64(1): [event(12, "jan", "significant_strike", detail: "kick|right|body|left"),
                                 event(13.5, "", "strike"),
                                 event(14, "carlos", "takedown_attempt", outcome: "defended"),
                                 event(30, "jan", "submission_attempt", detail: "rear-naked choke", outcome: "unresolved")]]
        let names = ["jan": "Jan", "carlos": "Carlos"]
        var scene = Fixtures.scene(id: 1, start: 0, end: 60)
        scene.narrative = "They circle."
        let rows = WizardPreviewRows.rows(clips: [
            clip("fight-1", scene: scene, start: 11, end: 15),
            clip("fight-2", scene: scene, start: 12.1, end: 12.1), // the held frame of the kick
            clip("fight-3", scene: scene, start: 29, end: 31),
            clip("fight-4", scene: scene, start: 40, end: 45)
        ], lines: [:], events: events, names: names)
        #expect(rows.map(\.text) == ["Jan: big right kick to the body; strike landed; Carlos: takedown attempt, defended",
                                     "Jan: big right kick to the body",
                                     "Jan: submission attempt, unresolved, rear-naked choke",
                                     "They circle."])
        #expect(rows.map(\.textKind) == [.action, .action, .action, .description])

        // An action with a length is still going on in a clip trimmed inside it.
        var hold = event(50, "jan", "submission_attempt", detail: "armbar", outcome: "unresolved")
        hold.endTime = 60
        let trimmed = WizardPreviewRows.rows(clips: [clip("fight-5", scene: scene, start: 55, end: 58),
                                                     clip("fight-6", scene: scene, start: 60, end: 62)],
                                             lines: [:], events: [1: [hold]], names: names)
        #expect(trimmed.map(\.text) == ["Jan: submission attempt, unresolved, armbar", "They circle."])
        // A held frame inside it says so too, unless a blow landed on that frame.
        let frozen = WizardPreviewRows.rows(clips: [clip("fight-7", scene: scene, start: 55, end: 55),
                                                    clip("fight-8", scene: scene, start: 57, end: 57)],
                                            lines: [:], events: [1: [hold, event(57.1, "carlos", "strike")]], names: names)
        #expect(frozen.map(\.text) == ["Jan: submission attempt, unresolved, armbar", "Carlos: strike landed"])
        // A Fight metrics pick says its action even when the commentary talks over it;
        // any other clip with words keeps them.
        let spoken = [Int64(1): WizardPreviewRows.lines(words: [.init(id: 1, text: "Deep", start: 12, end: 12.4)])]
        let talked = WizardPreviewRows.rows(clips: [clip("fight-1", scene: scene, start: 11.5, end: 12.5),
                                                    clip("pick-1", scene: scene, start: 11.5, end: 12.5),
                                                    clip("fight-4", scene: scene, start: 11.9, end: 11.95)],
                                            lines: spoken, events: events, names: names)
        #expect(talked.map(\.text) == ["Jan: big right kick to the body", "Deep", "Jan: big right kick to the body"])
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
