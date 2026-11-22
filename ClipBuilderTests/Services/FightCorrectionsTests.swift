import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fight corrections")
struct FightCorrectionsTests {
    private func event(_ time: Double = 10, fighter: String = "a", action: String = "strike") -> FightEventRecord {
        .init(id: 1, videoID: 1, time: time, fighterKey: fighter, action: action,
              points: FightScoring.points(for: action), detail: "punch|right|head|left", scoringVersion: 3)
    }

    @Test func everyKindAndPoints() {
        let original = event()
        let replacement = event(10.2, fighter: "b", action: "knockdown")
        let edit = FightCorrectionRecord(event: original, kind: .edit, replacement: replacement)
        let result = FightCorrections.apply([edit], to: [original])
        #expect(result.count == 1 && result[0].fighterKey == "b" && result[0].points == 8)
        #expect(result[0].id == original.id)
        #expect(FightCorrections.apply([.init(event: original, kind: .remove)], to: [original]).isEmpty)
        #expect(FightCorrections.apply([.init(event: original, kind: .confirm)], to: [original]) == [original])
        #expect(FightCorrections.apply([.init(event: replacement, kind: .add)], to: []).first?.points == 8)
        var td = event(action: "takedown_attempt")
        td.outcome = "completed"
        td.points = 999
        #expect(FightCorrections.apply([.init(event: td, kind: .add)], to: []).first?.points == 4)
    }

    @Test func nearestSameFighterFamilyWithinSixTenths() {
        let correction = FightCorrectionRecord(event: event(), kind: .remove)
        var near = event(10.6, action: "significant_strike")
        near.id = 2
        let far = event(10.601)
        let other = event(10, fighter: "b")
        let td = event(10, action: "takedown_attempt")
        #expect(Set(FightCorrections.apply([correction], to: [far, near, other, td])) == Set([other, td, far]))
        #expect(FightCorrections.apply([correction], to: [far]) == [far])
    }

    @Test func rescoreRepeatsFixesOrDropsMistake() {
        let original = event()
        let corrected = event(11, fighter: "b", action: "significant_strike")
        let correction = FightCorrectionRecord(event: original, kind: .edit, replacement: corrected)
        let repeated = FightCorrections.apply([correction], to: [original])
        #expect(repeated.count == 1 && repeated[0].fighterKey == "b")
        #expect(FightCorrections.apply([correction], to: [corrected]).count == 1)
        #expect(FightCorrections.apply([correction], to: []).first?.time == 11)
        #expect(FightCorrections.apply([correction], to: repeated) == repeated)
        #expect(FightCorrections.apply([.init(event: original, kind: .remove)], to: []).isEmpty)
    }

    @Test func additionsDoNotDuplicateNearbySameFamily() {
        let add = FightCorrectionRecord(event: event(), kind: .add)
        #expect(FightCorrections.apply([add], to: [event(10.5, action: "significant_strike")]).count == 1)
        #expect(FightCorrections.apply([add], to: [event(10.7)]).count == 2)
        #expect(FightCorrections.apply([add], to: [event(10, fighter: "b")]).count == 2)
    }

    @Test func editingDecisionPreservesItsOriginalAnchor() {
        var correction = FightCorrectionRecord(event: event(), kind: .edit, replacement: event(11, fighter: "b"))
        correction.setReplacement(event(12, fighter: "c", action: "hurt"))
        #expect(correction.time == 10 && correction.fighterKey == "a")
        let result = FightCorrections.apply([correction], to: [event()])
        #expect(result.count == 1 && result[0].fighterKey == "c" && result[0].points == 5)
    }
    @Test func removedEditAlsoSuppressesAnAlreadyCorrectedRescore() {
        let original = event()
        let corrected = event(12, fighter: "b")
        var correction = FightCorrectionRecord(event: original, kind: .edit, replacement: corrected)
        correction.kind = .remove
        #expect(FightCorrections.apply([correction], to: [corrected]).isEmpty)
    }


    private func blow(_ id: Int64, _ time: Double, _ fighter: String = "a", _ action: String = "strike",
                      _ detail: String = "punch|right|head|left") -> FightEventRecord {
        .init(id: id, videoID: 1, time: time, fighterKey: fighter, action: action,
              points: FightScoring.points(for: action), detail: detail, scoringVersion: 3)
    }

    /// The popup shows a repeat of one blow as one row: the correction covers both stored rows.
    @Test func correctionCoversTheRowsOneActionStandsFor() {
        let plain = blow(1, 10), upgraded = blow(2, 10.1, "a", "significant_strike"), later = blow(3, 10.5)
        let events = [plain, upgraded, later]
        #expect(StrikeStatsSummary.deduplicatedStrikes(events).map(\.id) == [2, 3])
        let removed = FightCorrections.apply([.init(event: upgraded, kind: .remove)], to: events)
        #expect(removed.map(\.id) == [3])
        var given = upgraded
        given.fighterKey = "b"
        let moved = FightCorrections.apply([.init(event: upgraded, kind: .edit, replacement: given)], to: events)
        #expect(moved.map(\.fighterKey).sorted() == ["a", "b"] && moved.first { $0.fighterKey == "a" }?.id == 3)
        #expect(FightCorrections.apply([.init(event: upgraded, kind: .confirm)], to: events).count == 3)
    }

    @Test func twoBlowsAtOneTimestampKeepTheirOwnCorrection() {
        let punch = blow(1, 10), kick = blow(2, 10, "a", "strike", "kick|left|body|left")
        var down = kick
        down.action = "knockdown"
        var correction = FightCorrectionRecord(event: kick, kind: .edit, replacement: down)
        correction.id = 1
        let result = FightCorrections.apply([correction], to: [punch, kick])
        #expect(result.first { $0.id == 1 }?.action == "strike" && result.first { $0.id == 2 }?.action == "knockdown")
        // Attribution swapped between two simultaneous opposing blows: one each, never both on one row.
        let a = blow(1, 10, "a"), b = blow(2, 10, "b")
        var toB = a, toA = b
        toB.fighterKey = "b"
        toA.fighterKey = "a"
        var first = FightCorrectionRecord(event: a, kind: .edit, replacement: toB)
        var second = FightCorrectionRecord(event: b, kind: .edit, replacement: toA)
        first.id = 1
        second.id = 2
        let swapped = FightCorrections.resolve([first, second], in: [a, b])
        #expect(swapped.events.first { $0.id == 1 }?.fighterKey == "b" && swapped.events.first { $0.id == 2 }?.fighterKey == "a")
        #expect(Set(swapped.bound.values).count == 2)
    }

    @Test func removalNeverTakesAnotherTechniqueOrAKeptStretch() {
        var removal = FightCorrectionRecord(event: blow(9, 10), kind: .remove)
        removal.id = 1
        let kick = blow(0, 10.4, "a", "strike", "kick|left|body|left")
        #expect(FightCorrections.apply([removal], to: [kick]) == [kick])
        // The retry kept this stretch: the removal is already in it, and the
        // genuine punch 0.4 s later is not removed in its place.
        let genuine = blow(5, 10.4)
        let kept = FightCorrections.resolve([removal], in: [genuine], settled: [0], kept: [(start: 0, end: 20)])
        #expect(kept.events == [genuine] && kept.removed.isEmpty)
        // Nor a newly scored blow just across the boundary.
        let across = blow(0, 20.1)
        var late = FightCorrectionRecord(event: blow(9, 19.9), kind: .remove)
        late.id = 2
        #expect(FightCorrections.resolve([late], in: [across], kept: [(start: 0, end: 20)]).events == [across])
        #expect(FightCorrections.resolve([late], in: [across]).events.isEmpty)
    }

    @Test func keptCorrectedRowIsClaimedNotCorrectedTwice() {
        var original = blow(4, 10)
        original.generation = 7
        var corrected = original
        corrected.fighterKey = "b"
        var edit = FightCorrectionRecord(event: original, kind: .edit, replacement: corrected)
        edit.id = 1
        edit.eventID = 4
        // Another punch by the first fighter sits right beside the corrected row.
        var neighbour = blow(6, 10.3)
        neighbour.generation = 7
        let result = FightCorrections.resolve([edit], in: [corrected, neighbour], settled: [0, 1], kept: [(start: 0, end: 20)])
        #expect(result.events == [corrected, neighbour] && result.bound[1] == 0)
        #expect(result.entries.filter { $0.changed }.isEmpty)
    }

    @Test func severityFixIsVisibleToTheRetry() {
        var down = blow(1, 10)
        down.action = "knockdown"
        let note = FightCorrections.note(.init(event: blow(1, 10), kind: .edit, replacement: down), roster: [])
        #expect(note.contains("scored as strike") && note.contains("scored as knockdown"))
    }

    @Test func selectionFollowsTheActionAcrossARescore() {
        func row(_ event: FightEventRecord) -> FightActionDetail.Row {
            .init(event: event, stored: event, fighter: event.fighterKey, sentence: "", impact: "")
        }
        var wanted = blow(3, 10, "b")
        wanted.generation = 1
        var reused = blow(3, 4, "a"), same = blow(8, 10.1, "b")
        reused.generation = 2
        same.generation = 2
        // After a re-score id 3 is another action; the punch by b at about 10 s is the one.
        #expect(FightActionDetail.row(for: wanted, in: [row(reused), row(same)])?.id == 8)
        var other = blow(5, 10.1, "b")
        other.generation = 1
        // Same list, the row is gone (removed): nothing is selected in its place.
        #expect(FightActionDetail.row(for: wanted, in: [row(other)]) == nil)
        #expect(FightActionDetail.row(for: wanted, in: [row(other), row(wanted)])?.id == 3)
    }

    @Test func aConfirmationNeverTakesTheRowAnEditNeeds() {
        var confirm = FightCorrectionRecord(event: blow(1, 10, "a", "strike", "kick|left|body|left"), kind: .confirm)
        confirm.id = 1
        let punch = blow(2, 10.4)
        var given = punch
        given.fighterKey = "b"
        var edit = FightCorrectionRecord(event: punch, kind: .edit, replacement: given)
        edit.id = 2
        // The retry logs only the punch: it is corrected, not confirmed as the kick and then added again.
        let result = FightCorrections.resolve([confirm, edit], in: [blow(0, 10.4)])
        #expect(result.events.count == 1 && result.events[0].fighterKey == "b" && result.bound[1] == nil)
    }

    @Test func anActionMovedThenRemovedStaysOutWhereItWasScoredAgain() {
        var moved = blow(1, 30)
        moved.fighterKey = "a"
        var removal = FightCorrectionRecord(event: blow(1, 10), kind: .remove)
        removal.setReplacement(moved)
        removal.id = 1
        // The stretch around 10 s was kept; the one around 30 s was scored again and logs it.
        let result = FightCorrections.resolve([removal], in: [blow(0, 30)], kept: [(start: 0, end: 20)])
        #expect(result.events.isEmpty)
    }

    @Test func afterAPullACorrectionKeepsItsRowOrNoneNeverANeighbour() {
        var original = blow(4, 10)
        original.generation = 7
        var corrected = original
        corrected.fighterKey = "b"
        var edit = FightCorrectionRecord(event: original, kind: .edit, replacement: corrected)
        edit.id = 1
        edit.eventID = 4
        edit.generation = 7
        var removal = FightCorrectionRecord(event: blow(9, 30), kind: .remove)
        removal.id = 2
        // Its row is still there, whatever a teammate made of it.
        var theirs = corrected
        theirs.action = "hurt"
        #expect(FightCorrections.rebind([edit, removal], in: [blow(2, 5), theirs], boundGeneration: 7) == [1: 1])
        // The row was deleted. A kick by the same fighter 0.4 s later is another action.
        let kick = blow(6, 10.4, "b", "strike", "kick|left|body|left")
        #expect(FightCorrections.rebind([edit], in: [kick], boundGeneration: 7).isEmpty)
        // It comes back under another id, exactly as corrected: tied again.
        var back = corrected
        back.id = 12
        #expect(FightCorrections.rebind([edit], in: [kick, back], boundGeneration: 7) == [1: 1])
        // An id from an older generation proves nothing (ids are handed out again).
        #expect(FightCorrections.rebind([edit], in: [blow(4, 50)], boundGeneration: 8).isEmpty)
    }

    @Test func aBlowAcrossARoundEdgeIsOneRowInOneRound() {
        let plain = blow(1, 59.9), upgraded = blow(2, 60.05, "a", "significant_strike")
        let rounds = [FightRoundRange(round: 1, start: 0, end: 60), FightRoundRange(round: 2, start: 60, end: 120)]
        let first = FightActionDetail.build(events: [plain, upgraded], people: [], rounds: rounds, round: 1)
        let second = FightActionDetail.build(events: [plain, upgraded], people: [], rounds: rounds, round: 2)
        #expect(first.rows.isEmpty && second.rows.map(\.id) == [2])
    }

    @Test func aRemovalOfAMovedActionFindsItsCorrectedFormPastANearerBlow() {
        var moved = blow(1, 30, "a", "strike", "punch|right|body|left")
        var removal = FightCorrectionRecord(event: blow(1, 10), kind: .remove)
        removal.setReplacement(moved)
        removal.id = 1
        moved.id = 0
        moved.time = 30.15
        // A head punch sits nearer the corrected time; the body punch is the one.
        let head = blow(0, 29.91)
        #expect(FightCorrections.resolve([removal], in: [head, moved]).events == [head])
        // A reused row id proves nothing after a pull.
        var edit = FightCorrectionRecord(event: blow(4, 10), kind: .edit, replacement: blow(4, 10, "b"))
        edit.id = 3
        edit.eventID = 4
        edit.generation = 1
        #expect(FightCorrections.rebind([edit], in: [blow(4, 50)], boundGeneration: 1, sameRows: []).isEmpty)
    }

    @Test func attemptsAreNotMistakenForEachOther() {
        func attempt(_ id: Int64, _ time: Double, _ action: String, _ hold: String?) -> FightEventRecord {
            .init(id: id, videoID: 1, time: time, fighterKey: "a", action: action, points: 0, endTime: time + 2,
                  outcome: "defended", detail: hold, scoringVersion: 3)
        }
        var done = attempt(0, 20, "takedown", nil)
        done.outcome = nil
        done.endTime = nil
        var add = FightCorrectionRecord(event: done, kind: .add)
        add.id = 1
        // A failed attempt nearby is not the takedown that was added by hand.
        let result = FightCorrections.resolve([add], in: [attempt(0, 20.3, "takedown_attempt", "shot")])
        #expect(result.events.count == 2 && result.events.contains { $0.action == "takedown" })
        var edit = FightCorrectionRecord(event: attempt(5, 10, "submission_attempt", "armbar"),
                                         kind: .edit, replacement: attempt(5, 20, "submission_attempt", "armbar"))
        edit.id = 2
        // Another hold near the corrected time is another action: the correction is added, not written over it.
        let other = attempt(0, 20.2, "submission_attempt", "triangle choke")
        let moved = FightCorrections.resolve([edit], in: [other])
        #expect(moved.events.count == 2 && moved.events.contains(other))
    }
}
