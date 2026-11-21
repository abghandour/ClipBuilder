import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct FightWorkCoordinatorTests {
    @Test("The same database and video wait; other videos and databases do not")
    func keyedClaims() async throws {
        let temp = try await TempDatabase()
        let other = try await TempDatabase()
        let coordinator = FightWorkCoordinator()
        let key = FightWorkCoordinator.Key(database: temp.database, videoID: 1)
        let entered = StrikeMarkingGate(), finish = StrikeMarkingGate()
        let secondEntered = Mutex(false)
        let first = Task {
            try await coordinator.withClaim(key: key) {
                await entered.open()
                await finish.wait()
            }
        }
        await entered.wait()
        let second = Task {
            try await coordinator.withClaim(key: key) { secondEntered.withLock { $0 = true } }
        }
        while await coordinator.waitingCount(for: key) == 0 { await Task.yield() }
        #expect(!secondEntered.withLock { $0 })
        let differentVideo = try await coordinator.withClaim(key: .init(database: temp.database, videoID: 2)) { true }
        let differentDatabase = try await coordinator.withClaim(key: .init(database: other.database, videoID: 1)) { true }
        #expect(differentVideo && differentDatabase)
        #expect(!secondEntered.withLock { $0 })
        await finish.open()
        try await first.value
        try await second.value
        #expect(secondEntered.withLock { $0 })
    }

    @Test("Cancelling a waiter returns without waiting for its owner and leaves the owner intact")
    func cancelWaiter() async throws {
        let temp = try await TempDatabase()
        let coordinator = FightWorkCoordinator()
        let key = FightWorkCoordinator.Key(database: temp.database, videoID: 1)
        let entered = StrikeMarkingGate(), finish = StrikeMarkingGate()
        let owner = Task {
            try await coordinator.withClaim(key: key) {
                await entered.open()
                await finish.wait()
            }
        }
        await entered.wait()
        let waiter = Task {
            try await coordinator.withClaim(key: key) { Issue.record("A cancelled waiter must not start work") }
        }
        while await coordinator.waitingCount(for: key) == 0 { await Task.yield() }
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("The waiter should be cancelled while the owner is still working")
        } catch is CancellationError {}
        #expect(await coordinator.waitingCount(for: key) == 0)
        await finish.open()
        try await owner.value
        #expect(try await coordinator.withClaim(key: key) { true })
    }

    @Test("A failing owner releases its claim")
    func failedOwner() async throws {
        let temp = try await TempDatabase()
        let coordinator = FightWorkCoordinator()
        let key = FightWorkCoordinator.Key(database: temp.database, videoID: 1)
        do {
            try await coordinator.withClaim(key: key) { throw OwnerFailure() }
        } catch is OwnerFailure {}
        #expect(try await coordinator.withClaim(key: key) { true })
    }

    @Test("Marking waits for scoring and reads the scorer's completed results")
    func markingWaitsForScoring() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let database = temp.database
        let video = try #require(try await database.video(id: id))
        let key = FightWorkCoordinator.Key(database: database, videoID: id)
        let entered = StrikeMarkingGate(), finish = StrikeMarkingGate()
        let event = FightEventRecord(id: 0, videoID: id, time: 4, fighterKey: "a", action: "strike", points: 1)
        let scorer = Task {
            try await FightWorkCoordinator.shared.withClaim(key: key) {
                await entered.open()
                await finish.wait()
                let generation = try #require(try await database.replaceFightEventRecordsReturningGeneration(videoID: id, events: [event]))
                try await database.saveStrikeHighlights(videoID: id,
                    [.init(videoID: id, time: 4, fighterKey: "a", track: nil)], generation: generation)
            }
        }
        await entered.wait()
        let marker = Task {
            try await StrikeHighlightMarker.mark(video: video, database: database,
                finder: { _, _, _, _ in
                    Issue.record("The completed scorer already marked this strike")
                    return []
                }, log: { _ in })
        }
        while await FightWorkCoordinator.shared.waitingCount(for: key) == 0 { await Task.yield() }
        await finish.open()
        try await scorer.value
        _ = try await marker.value
        #expect(try await database.fetchStrikeHighlights(videoID: id).count == 1)
    }

    private nonisolated struct OwnerFailure: Error {}
}
