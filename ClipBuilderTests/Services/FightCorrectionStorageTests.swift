import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fight correction storage")
struct FightCorrectionStorageTests {
    private func seed(_ temp: TempDatabase) async throws -> FightEventRecord {
        let video = try await temp.seedVideo()
        let event = FightEventRecord(id: 0, videoID: video, time: 3, fighterKey: "a", action: "takedown_attempt", points: 4,
            provider: "test", model: "original", targetKey: "b", endTime: 5, outcome: "completed", detail: "shot", scoringVersion: 3)
        try await temp.database.replaceFightEventRecords(videoID: video, events: [event])
        return try #require(try await temp.database.fetchFightEvents(videoID: video).first)
    }

    @Test func editThenEditKeepsIdentityAndUndoRestoresAllFields() async throws {
        let temp = try await TempDatabase()
        let original = try await seed(temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        let identity = try raw.query("SELECT sync_id FROM fight_events WHERE id = ?", [.integer(original.id)]).first?["sync_id"]?.stringValue
        var replacement = original
        replacement.fighterKey = "b"
        replacement.time = 4
        replacement.action = "significant_strike"
        replacement.detail = "kick|left|legs|right"
        replacement.endTime = nil
        replacement.outcome = nil
        replacement.targetKey = "a"
        let correction = try await temp.database.saveFightCorrection(.init(event: original, kind: .edit, replacement: replacement))
        let edited = try #require(try await temp.database.fetchFightEvents(videoID: original.videoID).first)
        #expect(edited.id == original.id && edited.generation == original.generation && edited.points == 2)
        #expect(try raw.query("SELECT sync_id FROM fight_events WHERE id = ?", [.integer(original.id)]).first?["sync_id"]?.stringValue == identity)
        replacement.time = 6
        replacement.action = "knockdown"
        let second = try await temp.database.saveFightCorrection(.init(event: edited, kind: .edit, replacement: replacement))
        #expect(second.id == correction.id)
        #expect(try await temp.database.fetchFightCorrections(videoID: original.videoID).count == 1)
        try await temp.database.deleteFightCorrection(id: correction.id, videoID: original.videoID)
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID) == [original])
        #expect(try await temp.database.fetchFightCorrections(videoID: original.videoID).isEmpty)
    }

    @Test func highlightsAreInvalidatedAndStaleFinderCannotSave() async throws {
        let temp = try await TempDatabase()
        let original = try await seed(temp)
        let record = StrikeHighlightRecord(videoID: original.videoID, time: original.time, fighterKey: original.fighterKey, track: nil)
        #expect(try await temp.database.saveStrikeHighlights(videoID: original.videoID, [record], generation: original.generation!))
        var replacement = original
        replacement.detail = "changed"
        _ = try await temp.database.saveFightCorrection(.init(event: original, kind: .edit, replacement: replacement))
        #expect(try await temp.database.fetchStrikeHighlights(videoID: original.videoID).isEmpty)
        #expect(try await !temp.database.saveStrikeHighlights(videoID: original.videoID, [record], generation: original.generation!, expectedEvent: original))
    }

    @Test func correctionsSurviveRescoreAndUndoStillWorks() async throws {
        let temp = try await TempDatabase()
        let original = try await seed(temp)
        var replacement = original
        replacement.fighterKey = "b"
        replacement.time = 8
        // The attempt moved: its end moves with it (an end before the start is refused).
        replacement.endTime = 10
        replacement.outcome = "defended"
        let correction = try await temp.database.saveFightCorrection(.init(event: original, kind: .edit, replacement: replacement))
        for scored in [[original], [replacement], []] {
            try await temp.database.replaceFightEventRecords(videoID: original.videoID, events: scored)
            let events = try await temp.database.fetchFightEvents(videoID: original.videoID)
            #expect(events.count == 1 && events[0].time == 8 && events[0].fighterKey == "b" && events[0].points == 0)
            let saved = try #require(try await temp.database.fetchFightCorrections(videoID: original.videoID).first)
            #expect(saved.eventID == events[0].id && saved.generation == events[0].generation)
        }
        try await temp.database.deleteFightCorrection(id: correction.id, videoID: original.videoID)
        let restored = try #require(try await temp.database.fetchFightEvents(videoID: original.videoID).first)
        #expect(restored.time == original.time && restored.outcome == original.outcome && restored.targetKey == original.targetKey)
    }

    @Test func removeConfirmAddAndUndo() async throws {
        let temp = try await TempDatabase()
        let original = try await seed(temp)
        let confirmed = try await temp.database.saveFightCorrection(.init(event: original, kind: .confirm))
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID) == [original])
        try await temp.database.deleteFightCorrection(id: confirmed.id, videoID: original.videoID)
        let removed = try await temp.database.saveFightCorrection(.init(event: original, kind: .remove))
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID).isEmpty)
        try await temp.database.replaceFightEventRecords(videoID: original.videoID, events: [original])
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID).isEmpty)
        try await temp.database.deleteFightCorrection(id: removed.id, videoID: original.videoID)
        var added = original
        added.time = 8
        added.endTime = 9
        let addition = try await temp.database.saveFightCorrection(.init(event: added, kind: .add))
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID).count == 2)
        try await temp.database.replaceFightEventRecords(videoID: original.videoID, events: [original])
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID).count == 2)
        try await temp.database.deleteFightCorrection(id: addition.id, videoID: original.videoID)
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID).count == 1)
    }

    @Test func editingAddedAndConfirmingEditedPreserveDecisions() async throws {
        let temp = try await TempDatabase()
        let original = try await seed(temp)
        var added = original
        added.time = 8
        added.endTime = 9
        let addition = try await temp.database.saveFightCorrection(.init(event: added, kind: .add))
        let event = try #require(try await temp.database.fetchFightEvents(videoID: original.videoID).first { $0.time == 8 })
        added.time = 9
        let updated = try await temp.database.saveFightCorrection(.init(event: event, kind: .edit, replacement: added))
        #expect(updated.id == addition.id && updated.kind == .add)
        var changed = original
        changed.outcome = "defended"
        _ = try await temp.database.saveFightCorrection(.init(event: original, kind: .edit, replacement: changed))
        let edited = try #require(try await temp.database.fetchFightEvents(videoID: original.videoID).first { $0.id == original.id })
        let confirmed = try await temp.database.saveFightCorrection(.init(event: edited, kind: .confirm))
        #expect(confirmed.kind == .edit)
        try await temp.database.replaceFightEventRecords(videoID: original.videoID, events: [original])
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID).first?.outcome == "defended")
    }

    @Test func failuresRollBackCorrectionAndEventTogether() async throws {
        let temp = try await TempDatabase()
        let original = try await seed(temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.executeScript("""
            CREATE TRIGGER reject_review BEFORE UPDATE ON fight_events
            BEGIN SELECT RAISE(ABORT, 'test rollback'); END;
            """)
        var changed = original
        changed.outcome = "defended"
        await #expect(throws: (any Error).self) {
            try await temp.database.saveFightCorrection(.init(event: original, kind: .edit, replacement: changed))
        }
        #expect(try await temp.database.fetchFightCorrections(videoID: original.videoID).isEmpty)
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID) == [original])
    }

    @Test func staleSelectionsAndDuplicateAddAreRejected() async throws {
        let temp = try await TempDatabase()
        let original = try await seed(temp)
        await #expect(throws: (any Error).self) {
            try await temp.database.saveFightCorrection(.init(event: original, kind: .add))
        }
        #expect(try await temp.database.fetchFightCorrections(videoID: original.videoID).isEmpty)
        try await temp.database.replaceFightEventRecords(videoID: original.videoID, events: [original])
        await #expect(throws: (any Error).self) {
            try await temp.database.saveFightCorrection(.init(event: original, kind: .remove))
        }
        #expect(try await temp.database.fetchFightEvents(videoID: original.videoID).count == 1)
    }

    @Test func naturalKeyEditAndDeleteReachPeerWithoutDuplicate() async throws {
        let first = try await TempDatabase(), second = try await TempDatabase()
        let original = try await seed(first)
        let other = try await second.seedVideo()
        let rawA = try SQLiteConnection(path: first.path.path), rawB = try SQLiteConnection(path: second.path.path)
        try rawA.execute("UPDATE videos SET hash = 'shared-fight' WHERE id = ?", [.integer(original.videoID)])
        try rawB.execute("UPDATE videos SET hash = 'shared-fight' WHERE id = ?", [.integer(other)])
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await first.database.bindSync(to: scope)
        try await second.database.bindSync(to: scope)
        try await first.database.canonicalizeSyncIdentities(scope: scope)
        try await second.database.canonicalizeSyncIdentities(scope: scope)
        let table = try SyncTable.named("fight_events")
        func deliver() async throws {
            let changes = try await first.database.pendingSyncChanges(scope: scope, limit: 50, table: table)
            try await first.database.acknowledgeSyncChanges(changes)
            _ = try await second.database.applySyncRows(changes.map(\.wire), scope: scope, table: table, advanceCursor: false)
        }
        try await deliver()
        #expect(try await second.database.fetchFightEvents(videoID: other).count == 1)
        var replacement = original
        replacement.time = 4
        replacement.fighterKey = "b"
        replacement.action = "significant_strike"
        _ = try await first.database.saveFightCorrection(.init(event: original, kind: .edit, replacement: replacement))
        try await deliver()
        let arrived = try await second.database.fetchFightEvents(videoID: other)
        #expect(arrived.count == 1 && arrived[0].time == 4 && arrived[0].fighterKey == "b" && arrived[0].action == "significant_strike")
        let current = try #require(try await first.database.fetchFightEvents(videoID: original.videoID).first)
        _ = try await first.database.saveFightCorrection(.init(event: current, kind: .remove))
        try await deliver()
        #expect(try await second.database.fetchFightEvents(videoID: other).isEmpty)
        #expect(!SyncTable.all.contains { $0.name == "fight_corrections" || $0.name == "fight_correction_originals" })
        #expect(try await second.database.fetchFightCorrections(videoID: other).isEmpty)
    }

    private func strike(_ video: Int64, _ time: Double, _ fighter: String = "a", _ action: String = "strike",
                        _ detail: String = "punch|right|head|left") -> FightEventRecord {
        .init(id: 0, videoID: video, time: time, fighterKey: fighter, action: action,
              points: FightScoring.points(for: action), detail: detail, scoringVersion: 3)
    }

    @Test func removingOrEditingAShownStrikeCoversItsHiddenRepeat() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        let scored = [strike(video, 10), strike(video, 10.1, "a", "significant_strike"), strike(video, 12)]
        try await temp.database.replaceFightEventRecords(videoID: video, events: scored)
        var events = try await temp.database.fetchFightEvents(videoID: video)
        let shown = try #require(FightActionDetail.build(events: events, people: []).rows.first)
        #expect(shown.event.action == "significant_strike")
        let removal = try await temp.database.saveFightCorrection(.init(event: shown.stored, kind: .remove))
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.map(\.time) == [12])
        #expect(FightActionDetail.build(events: events, people: []).rows.count == 1)
        // A re-score logs the same three rows: both rows of the blow stay out.
        try await temp.database.replaceFightEventRecords(videoID: video, events: scored)
        #expect(try await temp.database.fetchFightEvents(videoID: video).map(\.time) == [12])
        try await temp.database.deleteFightCorrection(id: removal.id, videoID: video)
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.map(\.time) == [10, 10.1, 12])
        // Given to the other fighter, the blow is not also left counted for the first.
        let again = try #require(FightActionDetail.build(events: events, people: []).rows.first)
        var given = again.stored
        given.fighterKey = "b"
        _ = try await temp.database.saveFightCorrection(.init(event: again.stored, kind: .edit, replacement: given))
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.filter { $0.fighterKey == "a" }.map(\.time) == [12] && events.filter { $0.fighterKey == "b" }.count == 1)
    }

    @Test func aSubmissionChainIsCorrectedAsOneAction() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        func hold(_ start: Double, _ end: Double, _ name: String, _ outcome: String) -> FightEventRecord {
            .init(id: 0, videoID: video, time: start, fighterKey: "a", action: "submission_attempt", points: 0,
                  targetKey: "b", endTime: end, outcome: outcome, detail: name, scoringVersion: 3)
        }
        let scored = [hold(5, 8, "armbar", "unresolved"), hold(9, 14, "triangle choke", "defended")]
        try await temp.database.replaceFightEventRecords(videoID: video, events: scored)
        var events = try await temp.database.fetchFightEvents(videoID: video)
        var row = try #require(FightActionDetail.build(events: events, people: []).rows.first)
        #expect(row.event.endTime == 14 && row.stored.endTime == 8 && row.event.id == row.stored.id)
        // The trash button: the whole chain goes, and comes back whole.
        let removal = try await temp.database.saveFightCorrection(.init(event: row.stored, kind: .remove))
        #expect(try await temp.database.fetchFightEvents(videoID: video).isEmpty)
        try await temp.database.deleteFightCorrection(id: removal.id, videoID: video)
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.count == 2)
        // An edit of what the row shows leaves one row carrying it.
        row = try #require(FightActionDetail.build(events: events, people: []).rows.first)
        var replacement = row.event
        replacement.outcome = "completed"
        _ = try await temp.database.saveFightCorrection(.init(event: row.stored, kind: .edit, replacement: replacement))
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.count == 1 && events[0].endTime == 14 && events[0].outcome == "completed" && events[0].detail == "triangle choke")
        try await temp.database.replaceFightEventRecords(videoID: video, events: scored)
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.count == 1 && events[0].outcome == "completed")
    }

    @Test func anAddedActionNeverTakesAnIdAPickStillNames() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        try await temp.database.replaceFightEventRecords(videoID: video, events: [strike(video, 10), strike(video, 20)])
        let last = try #require(try await temp.database.fetchFightEvents(videoID: video).last)
        let project = try await temp.database.createProject(profileName: "test", name: "Picks", videoIDs: [video])
        _ = try await temp.database.addFightPick(projectID: project, videoID: video, start: 19, end: 21, eventIDs: [last.id])
        _ = try await temp.database.saveFightCorrection(.init(event: last, kind: .remove))
        var added = strike(video, 40, "b", "knockdown")
        added.generation = last.generation
        _ = try await temp.database.saveFightCorrection(.init(event: added, kind: .add))
        let events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.count == 2 && !events.contains { $0.id == last.id })
    }

    @Test func aPartlyFailedRetryDoesNotRepeatARemoval() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        try await temp.database.replaceFightEventRecords(videoID: video,
            events: [strike(video, 10), strike(video, 10.4, "a", "strike", "punch|left|body|left"), strike(video, 30)])
        var events = try await temp.database.fetchFightEvents(videoID: video)
        _ = try await temp.database.saveFightCorrection(.init(event: events[0], kind: .remove))
        var given = events[2]
        given.fighterKey = "b"
        _ = try await temp.database.saveFightCorrection(.init(event: events[2], kind: .edit, replacement: given))
        // Twice over: the first 20 s could not be scored and are handed back as saved.
        for _ in 0..<2 {
            let saved = try await temp.database.fetchFightEvents(videoID: video)
            let retained = FightSampling.retainedEvents(saved, unscored: [(start: 0, end: 20)])
            try await temp.database.replaceFightEventRecordsReturningGeneration(videoID: video,
                events: retained + [strike(video, 30)], kept: [(start: 0, end: 20)])
            events = try await temp.database.fetchFightEvents(videoID: video)
            #expect(events.map(\.time) == [10.4, 30] && events[1].fighterKey == "b")
            let corrections = try await temp.database.fetchFightCorrections(videoID: video)
            #expect(corrections.first { $0.kind == .edit }?.eventID == events[1].id)
        }
    }

    @Test func aBatchOfHighlightsSkipsStrikesCorrectedMeanwhile() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        try await temp.database.replaceFightEventRecords(videoID: video, events: [strike(video, 10), strike(video, 20)])
        let events = try await temp.database.fetchFightEvents(videoID: video)
        // The marker read both strikes; one becomes a kick before it saves.
        var kick = events[0]
        kick.detail = "kick|left|head|left"
        _ = try await temp.database.saveFightCorrection(.init(event: events[0], kind: .edit, replacement: kick))
        let found = events.map { StrikeHighlightRecord(videoID: video, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
        #expect(try await temp.database.saveStrikeHighlights(videoID: video, found, generation: events[0].generation!,
                                                            expectedEvents: events))
        #expect(try await temp.database.fetchStrikeHighlights(videoID: video).map(\.time) == [20])
    }

    @Test func aTeammatesEventsKeepTheLocalCorrections() async throws {
        let first = try await TempDatabase(), second = try await TempDatabase()
        let mine = try await first.seedVideo(), theirs = try await second.seedVideo()
        let rawA = try SQLiteConnection(path: first.path.path), rawB = try SQLiteConnection(path: second.path.path)
        try rawA.execute("UPDATE videos SET hash = 'shared-fight' WHERE id = ?", [.integer(mine)])
        try rawB.execute("UPDATE videos SET hash = 'shared-fight' WHERE id = ?", [.integer(theirs)])
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await first.database.bindSync(to: scope)
        try await second.database.bindSync(to: scope)
        try await first.database.canonicalizeSyncIdentities(scope: scope)
        try await second.database.canonicalizeSyncIdentities(scope: scope)
        let table = try SyncTable.named("fight_events")
        func deliver() async throws {
            let changes = try await first.database.pendingSyncChanges(scope: scope, limit: 50, table: table)
            try await first.database.acknowledgeSyncChanges(changes)
            _ = try await second.database.applySyncRows(changes.map(\.wire), scope: scope, table: table, advanceCursor: false)
        }
        let scored = [strike(mine, 10), strike(mine, 30)]
        try await first.database.replaceFightEventRecords(videoID: mine, events: scored)
        try await deliver()
        var events = try await second.database.fetchFightEvents(videoID: theirs)
        #expect(events.count == 2)
        // The second Mac corrects one action and removes the other.
        var given = events[0]
        given.fighterKey = "b"
        let edit = try await second.database.saveFightCorrection(.init(event: events[0], kind: .edit, replacement: given))
        _ = try await second.database.saveFightCorrection(.init(event: events[1], kind: .remove))
        let pendingBefore = try await second.database.pendingSyncChanges(scope: scope, limit: 50, table: table).count
        // An unrelated action arrives: the correction stays tied to its row,
        // and the pull writes nothing back.
        var extra = strike(mine, 50)
        extra.generation = try await first.database.fightEventGeneration(videoID: mine)
        _ = try await first.database.saveFightCorrection(.init(event: extra, kind: .add))
        try await deliver()
        #expect(try await second.database.pendingSyncChanges(scope: scope, limit: 50, table: table).count == pendingBefore)
        events = try await second.database.fetchFightEvents(videoID: theirs)
        var saved = try #require(try await second.database.fetchFightCorrections(videoID: theirs).first { $0.id == edit.id })
        let corrected = try #require(events.first { $0.time == 10 })
        #expect(corrected.fighterKey == "b" && saved.eventID == corrected.id && saved.generation == corrected.generation)
        #expect(!events.contains { $0.time == 30 } && events.contains { $0.time == 50 })
        // Editing it again changes the one correction, and Undo works.
        var later = corrected
        later.action = "knockdown"
        let second2 = try await second.database.saveFightCorrection(.init(event: corrected, kind: .edit, replacement: later))
        #expect(second2.id == edit.id)
        saved = try #require(try await second.database.fetchFightCorrections(videoID: theirs).first { $0.id == edit.id })
        try await second.database.deleteFightCorrection(id: saved.id, videoID: theirs)
        #expect(try await second.database.fetchFightEvents(videoID: theirs).first { $0.time == 10 }?.fighterKey == "a")
    }

    @Test func aRemovedActionDoesNotComeBackThroughACorrectionOfItsOtherRow() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        let scored = [strike(video, 10), strike(video, 12)]
        try await temp.database.replaceFightEventRecords(videoID: video, events: scored)
        var events = try await temp.database.fetchFightEvents(videoID: video)
        var knock = events[0]
        knock.detail = "punch|right|body|left"
        _ = try await temp.database.saveFightCorrection(.init(event: events[0], kind: .edit, replacement: knock))
        // The second punch is moved beside the first as its harder form: one action now.
        var upgrade = events[1]
        upgrade.time = 10.1
        upgrade.action = "significant_strike"
        upgrade.detail = knock.detail
        _ = try await temp.database.saveFightCorrection(.init(event: events[1], kind: .edit, replacement: upgrade))
        events = try await temp.database.fetchFightEvents(videoID: video)
        let rows = FightActionDetail.build(events: events, people: []).rows
        #expect(rows.count == 1)
        _ = try await temp.database.saveFightCorrection(.init(event: rows[0].stored, kind: .remove))
        #expect(try await temp.database.fetchFightEvents(videoID: video).isEmpty)
        try await temp.database.replaceFightEventRecords(videoID: video, events: scored)
        #expect(try await temp.database.fetchFightEvents(videoID: video).isEmpty)
    }

    @Test func removingAnAddedHoldRemovesEverythingItJoined() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        func hold(_ start: Double, _ end: Double) -> FightEventRecord {
            .init(id: 0, videoID: video, time: start, fighterKey: "a", action: "submission_attempt", points: 0,
                  targetKey: "b", endTime: end, outcome: "unresolved", detail: "armbar", scoringVersion: 3)
        }
        try await temp.database.replaceFightEventRecords(videoID: video, events: [hold(10, 12), hold(25, 27)])
        var long = hold(5, 30)
        long.generation = try await temp.database.fightEventGeneration(videoID: video)
        _ = try await temp.database.saveFightCorrection(.init(event: long, kind: .add))
        let events = try await temp.database.fetchFightEvents(videoID: video)
        let rows = FightActionDetail.build(events: events, people: []).rows
        #expect(events.count == 3 && rows.count == 1)
        _ = try await temp.database.saveFightCorrection(.init(event: rows[0].stored, kind: .remove))
        #expect(try await temp.database.fetchFightEvents(videoID: video).isEmpty)
    }

    @Test func aReplacingBatchKeepsTheHighlightOfAStrikeCorrectedMeanwhile() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        try await temp.database.replaceFightEventRecords(videoID: video, events: [strike(video, 10), strike(video, 20)])
        let events = try await temp.database.fetchFightEvents(videoID: video)
        var moved = events[0]
        moved.time = 11
        _ = try await temp.database.saveFightCorrection(.init(event: events[0], kind: .edit, replacement: moved))
        let fresh = StrikeHighlightRecord(videoID: video, time: 11, fighterKey: "a", track: nil)
        #expect(try await temp.database.saveStrikeHighlights(videoID: video, [fresh], generation: events[0].generation!))
        let found = events.map { StrikeHighlightRecord(videoID: video, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
        #expect(try await temp.database.saveStrikeHighlights(videoID: video, found, generation: events[0].generation!,
                                                            replacing: true, expectedEvents: events))
        #expect(try await temp.database.fetchStrikeHighlights(videoID: video).map(\.time).sorted() == [11, 20])
    }

    @Test func undoingInEitherOrderNeverDuplicatesOrLosesARow() async throws {
        for absorbedFirst in [true, false] {
            let temp = try await TempDatabase()
            let video = try await temp.seedVideo()
            let scored = [strike(video, 10), strike(video, 12)]
            try await temp.database.replaceFightEventRecords(videoID: video, events: scored)
            var events = try await temp.database.fetchFightEvents(videoID: video)
            var body = events[0]
            body.detail = "punch|right|body|left"
            let first = try await temp.database.saveFightCorrection(.init(event: events[0], kind: .edit, replacement: body))
            var upgrade = events[1]
            upgrade.time = 10.1
            upgrade.action = "significant_strike"
            upgrade.detail = body.detail
            let second = try await temp.database.saveFightCorrection(.init(event: events[1], kind: .edit, replacement: upgrade))
            events = try await temp.database.fetchFightEvents(videoID: video)
            let row = try #require(FightActionDetail.build(events: events, people: []).rows.first)
            _ = try await temp.database.saveFightCorrection(.init(event: row.stored, kind: .remove))
            // Two removals now, each undone on its own.
            let removals = try await temp.database.fetchFightCorrections(videoID: video)
            #expect(removals.count == 2 && removals.allSatisfy { $0.kind == .remove })
            for id in absorbedFirst ? [first.id, second.id] : [second.id, first.id] {
                try await temp.database.deleteFightCorrection(id: id, videoID: video)
            }
            events = try await temp.database.fetchFightEvents(videoID: video)
            #expect(events.map(\.time) == [10, 12] && events.allSatisfy { $0.detail == "punch|right|head|left" })
            try await temp.database.replaceFightEventRecords(videoID: video, events: scored)
            #expect(try await temp.database.fetchFightEvents(videoID: video).count == 2)
        }
    }

    @Test func aStrikeWithAHiddenRepeatStillGetsItsBatchHighlight() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        try await temp.database.replaceFightEventRecords(videoID: video,
            events: [strike(video, 10), strike(video, 10, "a", "significant_strike")])
        let state = try await temp.database.strikeHighlightMarkingState(videoID: video)
        let missing = WizardStrikeHighlights.missingStrikes(events: state.events, saved: state.saved)
        #expect(missing.count == 1)
        let found = missing.map { StrikeHighlightRecord(videoID: video, time: $0.time, fighterKey: $0.fighterKey, track: nil) }
        #expect(try await temp.database.saveStrikeHighlights(videoID: video, found, generation: state.generation,
                                                            expectedEvents: state.events))
        #expect(try await temp.database.fetchStrikeHighlights(videoID: video).count == 1)
    }

    @Test func aCorrectionThatLostItsRowIsNotMadeTwiceAndUndoDoesNotDuplicate() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        try await temp.database.replaceFightEventRecords(videoID: video, events: [strike(video, 10), strike(video, 30)])
        var events = try await temp.database.fetchFightEvents(videoID: video)
        var body = events[0]
        body.detail = "punch|right|body|left"
        let edit = try await temp.database.saveFightCorrection(.init(event: events[0], kind: .edit, replacement: body))
        let removal = try await temp.database.saveFightCorrection(.init(event: events[1], kind: .remove))
        // A teammate's scoring arrives: the mistakes are back under new ids, the corrections are tied to nothing.
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE fight_events SET detail = 'punch|right|head|left' WHERE video_id = ?", [.integer(video)])
        try raw.execute("""
            INSERT INTO fight_events(video_id, at_time, fighter_key, action, points, detail, scoring_version, generation)
            SELECT video_id, 30, 'a', 'strike', 1, 'punch|right|head|left', 3, generation FROM fight_events WHERE video_id = ? LIMIT 1
            """, [.integer(video)])
        try raw.execute("UPDATE fight_correction_originals SET event_id = NULL")
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.count == 2)
        // Correcting the mistake again is the same correction.
        let again = try await temp.database.saveFightCorrection(.init(event: events[0], kind: .edit, replacement: body))
        #expect(again.id == edit.id)
        #expect(try await temp.database.fetchFightCorrections(videoID: video).count == 2)
        // Undoing the removal does not add a second copy of what is already back.
        try await temp.database.deleteFightCorrection(id: removal.id, videoID: video)
        #expect(try await temp.database.fetchFightEvents(videoID: video).map(\.time) == [10, 30])
    }

    @Test func undoBringsAHandAddedPartBackWithItsAddition() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        func hold(_ start: Double, _ end: Double) -> FightEventRecord {
            .init(id: 0, videoID: video, time: start, fighterKey: "a", action: "submission_attempt", points: 0,
                  targetKey: "b", endTime: end, outcome: "unresolved", detail: "armbar", scoringVersion: 3)
        }
        try await temp.database.replaceFightEventRecords(videoID: video, events: [hold(5, 8)])
        var more = hold(9, 14)
        more.generation = try await temp.database.fightEventGeneration(videoID: video)
        _ = try await temp.database.saveFightCorrection(.init(event: more, kind: .add))
        var events = try await temp.database.fetchFightEvents(videoID: video)
        let row = try #require(FightActionDetail.build(events: events, people: []).rows.first)
        #expect(events.count == 2 && row.event.endTime == 14)
        let removal = try await temp.database.saveFightCorrection(.init(event: row.stored, kind: .remove))
        #expect(try await temp.database.fetchFightEvents(videoID: video).isEmpty)
        try await temp.database.deleteFightCorrection(id: removal.id, videoID: video)
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.count == 2 && events.allSatisfy { $0.provider == nil })
        // Scored again, the scorer logs only its own attempt: the added part stays.
        try await temp.database.replaceFightEventRecords(videoID: video, events: [hold(5, 8)])
        events = try await temp.database.fetchFightEvents(videoID: video)
        #expect(events.map(\.time) == [5, 9])
        let additions = try await temp.database.fetchFightCorrections(videoID: video)
        #expect(additions.count == 1 && additions[0].kind == .add && additions[0].eventID == events[1].id)
    }
}
