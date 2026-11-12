import Foundation
import Testing
@testable import Clip_Builder

@Suite("Transcript picks added as one unit")
struct TranscriptPickGroupTests {
    private func pick(_ id: Int64, group: String? = nil, kept: Bool = true) -> TranscriptPick {
        TranscriptPick(id: id, videoID: 1, position: Int(id), start: Double(id), end: Double(id) + 1,
                       originalStart: Double(id), originalEnd: Double(id) + 1, sceneID: nil, kept: kept, groupKey: group)
    }

    @Test("Shift adds a passage; numbers follow the order marked, not the document")
    func composingOrder() {
        var selection = TranscriptDraftSelection()
        selection.set(1...2)
        #expect(selection.currentNumber == nil, "one passage carries no number")
        selection.begin()
        #expect(selection.currentRange == nil && selection.startedAt == 2)
        #expect(selection.others == [TranscriptDraftSpan(number: 1, range: 1...2)])
        #expect(selection.currentNumber == 2)
        selection.set(40...44)
        selection.begin()
        selection.set(10...12)
        #expect(selection.spans == [1...2, 40...44, 10...12], "row 2 marked third stays third")
        #expect(selection.currentNumber == 3)
        #expect(selection.others.map(\.number) == [1, 2])
    }

    @Test("A drag without Shift redoes the passage being adjusted; each adjusts on its own")
    func adjustingOne() {
        var selection = TranscriptDraftSelection()
        selection.set(1...2)
        selection.begin()
        selection.set(40...44)
        selection.select(number: 1)
        selection.set(0...3)
        #expect(selection.spans == [0...3, 40...44])
        #expect(selection.currentNumber == 1)
        selection.set(5...9)
        #expect(selection.spans == [5...9, 40...44], "a new span replaces the current passage only")
    }

    @Test("Removing a passage renumbers the ones after it and keeps the adjusted one")
    func removing() {
        var selection = TranscriptDraftSelection()
        for range in [1.0...2.0, 40.0...44.0, 10.0...12.0] {
            selection.begin()
            selection.set(range)
        }
        selection.remove(number: 2)
        #expect(selection.spans == [1...2, 10...12])
        #expect(selection.currentNumber == 2, "the third passage, still the one adjusted, is now #2")
        selection.remove(number: 2)
        #expect(selection.spans == [1...2])
        #expect(selection.currentNumber == nil && selection.currentRange == 1...2)
        selection.set(3...3)
        #expect(selection.spans.isEmpty && selection.currentRange == nil, "an empty range removes the passage")
    }

    @Test("Neighbours sharing a key are one unit; order and keep act on the unit")
    func units() {
        let picks = [pick(1), pick(2, group: "g"), pick(3, group: "g", kept: false), pick(4)]
        #expect(TranscriptPickUnits.units(picks).map { $0.map(\.id) } == [[1], [2, 3], [4]])
        #expect(TranscriptPickUnits.order(picks, unitOwners: [4, 2]) == [4, 2, 3, 1])
        // Two Macs added a unit each at the same positions: after the sync their picks alternate.
        let synced = [pick(10, group: "a"), pick(20, group: "b"), pick(11, group: "a"), pick(21, group: "b")]
        #expect(TranscriptPickUnits.units(synced).map { $0.map(\.id) } == [[10, 11], [20, 21]])
        #expect(TranscriptPickUnits.contiguous(synced).map(\.id) == [10, 11, 20, 21])
        #expect(TranscriptPickUnits.kept(picks, owners: [2, 4]) == [2, 4], "a checked unit keeps its cuts as they were")
        let unkept = [pick(2, group: "g", kept: false), pick(3, group: "g", kept: false)]
        #expect(TranscriptPickUnits.kept(unkept, owners: [2]) == [2, 3], "a newly checked unit keeps every cut")
    }

    @Test("Removing a passage keeps the passage on screen selected, whatever its new place")
    func selectionAfterRemoving() {
        func next(_ unit: [Int64], removed: Int, selected: Int) -> [Int64?] {
            TranscriptPickUnits.selectionAfterRemoving(unit: unit, removed: removed, selected: selected)
                .map { [$0.owner, $0.cut.map(Int64.init)] } ?? []
        }
        #expect(next([1, 2, 3, 4], removed: 1, selected: 2) == [1, 1], "C moves up with its selection")
        #expect(next([1, 2, 3, 4], removed: 2, selected: 2) == [1, 2], "the removed passage hands over to the next")
        #expect(next([1, 2, 3], removed: 2, selected: 2) == [1, 1], "the last one hands over to the one before")
        #expect(next([1, 2, 3], removed: 0, selected: 2) == [2, 1], "the row is now named by the new first pick")
        #expect(next([1, 2], removed: 0, selected: 1) == [2, nil], "one passage left: an ordinary pick")
        #expect(next([1], removed: 0, selected: 0).isEmpty)
    }

    @Test("Moving a passage inside its pick reorders only that pick and follows the selected passage")
    func movingAPassage() {
        let picks = [pick(1), pick(2, group: "g"), pick(3, group: "g"), pick(4, group: "g"), pick(5)]
        // The third passage (old place 2) dragged to the top while the second (old place 1) is selected.
        let moved = TranscriptPickUnits.moving(picks, unit: [2, 3, 4], order: [2, 0, 1], selected: 1)
        #expect(moved?.ids == [1, 4, 2, 3, 5])
        #expect(moved?.owner == 4, "the row is named by the pick now first")
        #expect(moved?.cut == 2)
        #expect(TranscriptPickUnits.moving(picks, unit: [2, 3, 4], order: [0, 1], selected: nil) == nil)
    }

    @Test("A group is stored in the order given, shares a key, and a split stays in it")
    func stored() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Test", name: "Groups", videoIDs: [videoID])
        let single = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 1)
        let group = try await database.addTranscriptPickGroup(projectID: projectID, videoID: videoID,
                                                              ranges: [1...2, 40...44, 10...12])
        #expect(single.groupKey == nil)
        #expect(group.map(\.start) == [1, 40, 10])
        #expect(group.map(\.position) == [1, 2, 3])
        #expect(Set(group.map(\.groupKey)).count == 1 && group[0].groupKey != nil)
        let alone = try await database.addTranscriptPickGroup(projectID: projectID, videoID: videoID, ranges: [20...21])
        #expect(alone.first?.groupKey == nil, "one passage is an ordinary pick")
        let order = try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).map(\.id)
        let half = try await database.splitTranscriptPick(projectID: projectID, videoID: videoID, id: group[1].id,
            start: 40, at: 42, end: 44, kept: true, order: order, index: 3, set: .active)
        #expect(half.groupKey == group[0].groupKey)
        let units = TranscriptPickUnits.units(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID))
        #expect(units.map(\.count) == [1, 4, 1])
        #expect(try SyncTable.named("transcript_picks").columns.contains("group_key"))
    }

    @Test("A passage added to a saved pick lands after its last one; a pick alone becomes a unit")
    func passageAdded() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Test", name: "Passages", videoIDs: [videoID])
        let group = try await database.addTranscriptPickGroup(projectID: projectID, videoID: videoID, ranges: [1...2, 40...44])
        let single = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 50, end: 51)
        let added = try await database.addTranscriptPassage(projectID: projectID, videoID: videoID,
                                                            unit: group.map(\.id), range: 10...12)
        #expect(added.position == 2 && added.groupKey == group[0].groupKey && added.kept)
        var picks = try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID)
        #expect(picks.map(\.start) == [1, 40, 10, 50])
        #expect(picks.map(\.position) == [0, 1, 2, 3])
        _ = try await database.addTranscriptPassage(projectID: projectID, videoID: videoID, unit: [single.id], range: 60...61)
        picks = try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID)
        #expect(TranscriptPickUnits.units(picks).map { $0.map(\.start) } == [[1, 40, 10], [50, 60]])
        #expect(picks[3].groupKey != nil && picks[3].groupKey != group[0].groupKey)
        // The list on screen changed while the write ran: the new pick joins it as it is now.
        let edited = Array(picks.dropFirst())   // the unit's first passage was deleted meanwhile
        var late = picks[2]
        late.id = 999
        #expect(TranscriptPickUnits.adding(late, to: edited, unit: group.map(\.id) + [added.id]).map(\.id)
                == [edited[0].id, edited[1].id, 999, edited[2].id, edited[3].id])
    }

    @Test("Linked picks become one unit where the first stood; unlinked they are picks again; Undo restores the link")
    func linking() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Test", name: "Links", videoIDs: [videoID])
        var made: [TranscriptPick] = []
        for start in [0.0, 10, 20, 30] {
            made.append(try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: start, end: start + 1))
        }
        func stored() async throws -> [TranscriptPick] { try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID) }
        let before = try await stored()
        try await database.setTranscriptPicksLinked(projectID: projectID, videoID: videoID, ids: [made[1].id, made[3].id], key: "k")
        let linked = try await stored()
        #expect(TranscriptPickUnits.units(linked).map { $0.map(\.start) } == [[0], [10, 30], [20]])
        #expect(linked.map(\.position) == [0, 1, 2, 3])
        #expect(linked == TranscriptPickUnits.linking(before, ids: [made[1].id, made[3].id], key: "k"), "the screen and the table agree")
        let restored = try await database.restoreTranscriptPicks(projectID: projectID, videoID: videoID,
                                                                 expected: linked, picks: before).picks
        #expect(restored.map(\.start) == [0, 10, 20, 30] && restored.allSatisfy { $0.groupKey == nil })
        try await database.setTranscriptPicksLinked(projectID: projectID, videoID: videoID, ids: [made[0].id, made[1].id], key: "k2")
        try await database.setTranscriptPicksLinked(projectID: projectID, videoID: videoID, ids: [made[0].id, made[1].id], key: nil)
        let apart = try await stored()
        #expect(apart.map(\.start) == [0, 10, 20, 30] && apart.allSatisfy { $0.groupKey == nil })
        #expect(TranscriptPickUnits.linking(before, ids: [made[0].id], key: "x") == before, "one pick alone is not a link")
    }
}
