import Foundation
import Testing
@testable import Clip_Builder

private actor SyncCycleProbe {
    var entered = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var releaseWaiter: CheckedContinuation<Void, Never>?
    var calls = 0

    func enter() async {
        calls += 1
        entered = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForStart() async {
        if entered { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

struct TeamSyncCoordinatorTests {
    @Test("Profile replacement blocks Resume until every replacement has finished")
    @MainActor
    func profileReplacementBlocksResume() async {
        let state = TeamSyncState()
        await state.suspendForProfileReplacement()
        #expect(state.replacingProfile)
        #expect(state.paused)
        state.setPaused(false)
        #expect(state.paused)
        await state.suspendForProfileReplacement()
        state.finishProfileReplacement()
        #expect(state.replacingProfile)
        state.setPaused(false)
        #expect(state.paused)
        state.finishProfileReplacement()
        #expect(!state.replacingProfile)
        state.setPaused(false)
        #expect(!state.paused)
    }

    @Test("Launch, timer, reconnect and manual requests cannot overlap a suspended cycle")
    func neverOverlaps() async throws {
        let coordinator = TeamSyncCoordinator(), probe = SyncCycleProbe()
        let first = Task { try await coordinator.run { await probe.enter() } }
        await probe.waitForStart()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { try await coordinator.run { await probe.enter() } } }
            for try await admitted in group { #expect(!admitted) }
        }
        #expect(await probe.calls == 1)
        await probe.release()
        #expect(try await first.value)
        #expect(try await coordinator.run { })
    }
}
