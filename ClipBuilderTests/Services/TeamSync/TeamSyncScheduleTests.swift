import Testing
@testable import Clip_Builder

struct TeamSyncScheduleTests {
    @Test("Team sync never runs on its own")
    func manualOnly() {
        #expect(TeamSyncSchedule.manualOnly)
    }

    @Test("The idle status tells the user whether Sync Now has work")
    func idleStatus() {
        #expect(TeamSyncSchedule.idleStatus(pendingChanges: 0) == "Ready to sync")
        #expect(TeamSyncSchedule.idleStatus(pendingChanges: 1) == "1 change waiting")
        #expect(TeamSyncSchedule.idleStatus(pendingChanges: 12) == "12 changes waiting")
    }
}
