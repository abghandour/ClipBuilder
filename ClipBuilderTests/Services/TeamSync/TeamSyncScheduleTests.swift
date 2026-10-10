import Testing
@testable import Clip_Builder

struct TeamSyncScheduleTests {
    @Test("An active app with no pending changes skips automatic sync")
    func noPendingChanges() {
        #expect(!TeamSyncSchedule.shouldRunAutomaticCycle(pendingChanges: 0, appActive: true))
    }

    @Test("An active app with pending changes runs automatic sync")
    func pendingChangesWhileActive() {
        #expect(TeamSyncSchedule.shouldRunAutomaticCycle(pendingChanges: 3, appActive: true))
    }

    @Test("An inactive app skips automatic sync even with pending changes")
    func pendingChangesWhileInactive() {
        #expect(!TeamSyncSchedule.shouldRunAutomaticCycle(pendingChanges: 3, appActive: false))
    }
}
