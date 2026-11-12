import Foundation
import Testing
@testable import Clip_Builder

@Suite("Speaker colours")
struct SpeakerColorAssignmentTests {
    private let count = 8

    @Test("Two speakers whose names hash to one slot are moved apart, the same way every time")
    func collidingPair() {
        // The pair from the Express list of November 12, 2026: both were pink.
        let names: Set<String> = ["Marcello Spinelli", "ailin"]
        #expect(SpeakerColorAssignment.hashSlot("Marcello Spinelli", count: count)
                == SpeakerColorAssignment.hashSlot("ailin", count: count))
        var first = SpeakerColorAssignment(), second = SpeakerColorAssignment()
        first.register(names, count: count)
        second.register(names, count: count)
        #expect(first.slot("Marcello Spinelli", count: count) != first.slot("ailin", count: count))
        #expect(first == second)
        #expect(first.slot("Marcello Spinelli", count: count) == SpeakerColorAssignment.hashSlot("Marcello Spinelli", count: count),
                "the first name in order keeps its own colour")
    }

    @Test("A full palette of speakers shown together all differ, and stay put when seen again")
    func wholeGroup() {
        let names = Set((1...8).map { "Speaker \($0)" })
        var assignment = SpeakerColorAssignment()
        assignment.register(names, count: count)
        #expect(Set(names.map { assignment.slot($0, count: count) }).count == 8)
        let settled = assignment
        assignment.register(names, count: count)
        #expect(assignment == settled)
    }

    @Test("A name moved for one group keeps clear of the names it met before")
    func remembersPeers() {
        var assignment = SpeakerColorAssignment()
        assignment.register(["Marcello Spinelli", "ailin"], count: count)
        let ailin = assignment.slot("ailin", count: count)
        // A third speaker sitting on ailin's new slot joins ailin in another video.
        let other = (0..<500).map { "Guest \($0)" }.first { SpeakerColorAssignment.hashSlot($0, count: count) == ailin }!
        assignment.register([other, "ailin"], count: count)
        let slots = ["Marcello Spinelli", "ailin", other].map { assignment.slot($0, count: count) }
        #expect(slots[1] != slots[2])
        #expect(slots[0] != slots[1], "still apart from the speaker of the first video")
    }

    @Test("A speaker alone keeps the hash colour")
    func alone() {
        var assignment = SpeakerColorAssignment()
        assignment.register(["ailin"], count: count)
        #expect(assignment.slots.isEmpty)
    }
}
