import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fight retry rules")
struct FightRetryTests {
    private func event(_ time: Double = 7, fighter: String = "a", action: String = "strike") -> FightEventRecord {
        FightEventRecord(id: 1, videoID: 1, time: time, fighterKey: fighter, action: action, points: 1, detail: "punch|right|head|left")
    }

    @Test func notesContainOnlyWindowFactsAndSeconds() throws {
        let original = event()
        var changed = original
        changed.fighterKey = "b"
        let corrections = [FightCorrectionRecord(event: original, kind: .edit, replacement: changed),
                           .init(event: event(17), kind: .remove)]
        let roster = [VideoPersonRecord(videoID: 1, personID: 1, key: "a", name: "Alice", descriptor: "red shorts", portraitAt: 0),
                      VideoPersonRecord(videoID: 1, personID: 2, key: "b", name: "Bob", descriptor: "blue shorts", portraitAt: 0)]
        let text = try #require(FightCorrections.promptNotes(for: (0, 12), corrections: corrections, roster: roster))
        #expect(text.contains("REVIEWED BY A PERSON"))
        #expect(text.contains("7.0s") && text.contains("Alice") && text.contains("Bob"))
        #expect(text.contains("right punch to the head"))
        #expect(!text.contains("17.0s") && text.contains("Treat these as facts"))
        #expect(FightCorrections.promptNotes(for: (24, 36), corrections: corrections, roster: roster) == nil)
    }

    @Test func windowSelectionIncludesBothSidesOfTimeEditAndExcludesConfirmations() {
        var moved = event(12)
        moved.endTime = 18
        let correction = FightCorrectionRecord(event: event(11), kind: .edit, replacement: moved)
        let windows: [FightSampling.Range] = [(0, 12), (12, 24), (24, 36)]
        let selected = FightCorrections.correctedWindows(windows, corrections: [correction, .init(event: event(26), kind: .confirm)])
        #expect(selected.map(\.start) == [0, 12])
        #expect(!FightCorrections.inWindow(.init(event: event(12), kind: .add), window: (0, 12)))
        #expect(FightCorrections.RetryScope.allCases == [.wholeFight])
    }

    @Test func notesDescribeAddRemoveConfirmAndAttemptMetadata() {
        var attempt = event(5, action: "submission_attempt")
        attempt.detail = "armbar"
        attempt.endTime = 8
        attempt.outcome = "defended"
        attempt.targetKey = "b"
        let text = FightCorrections.promptNotes(for: (0, 12), corrections: [
            .init(event: event(2), kind: .add), .init(event: event(3), kind: .remove),
            .init(event: attempt, kind: .confirm)], roster: []) ?? ""
        #expect(text.contains("was missed") && text.contains("no scoring action") && text.contains("confirmed"))
        #expect(text.contains("armbar") && text.contains("8.0s") && text.contains("defended") && text.contains("receiving fighter b"))
    }

    @Test func differenceIgnoresDatabaseIdentityAndMatchesUnchangedFirst() {
        let first = event(), second = event(7.3, fighter: "b")
        var reloaded = first
        reloaded.id = 99
        reloaded.generation = 5
        reloaded.provider = "other"
        #expect(FightCorrections.difference(before: [first, second], after: [second, reloaded]).changed == 0)
        let difference = FightCorrections.difference(before: [first, second], after: [second])
        #expect(difference.removed == 1 && difference.reattributed == 0)
    }

    @Test func differenceCountsEveryChangeOnce() {
        var changed = event(2)
        changed.detail = "kick|left|legs|right"
        let difference = FightCorrections.difference(before: [event(), event(2), event(20)],
            after: [event(fighter: "b"), changed, event(30), event(40)])
        #expect(difference.added == 2 && difference.removed == 1 && difference.reattributed == 1 && difference.revised == 1)
        #expect(difference.changed == 5 && difference.summary.contains("5 actions"))
    }
}
