import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Wizard reel batch")
struct WizardReelBatchTests {
    private final class Journal: Sendable {
        private let events = Mutex<[String]>([])
        func add(_ event: String) { events.withLock { $0.append(event) } }
        var all: [String] { events.withLock { $0 } }
    }

    /// A one-shot gate: the finish of reel 1 opens it, the render of reel 2 waits on it.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func openUp() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @Test func finishesRunWhileTheNextReelRenders() async throws {
        let journal = Journal()
        let started = Gate(), ended = Gate()
        let waiting = Mutex<[Int]>([])
        try await WizardReelBatch.run(count: 3, render: { index in
            journal.add("render \(index) start")
            // Reel 1 cannot finish rendering until reel 0's finish has started;
            // reel 2 waits for that finish to end, so only reel 1's is still writing.
            if index == 1 { await started.wait() }
            if index == 2 { await ended.wait() }
            journal.add("render \(index) end")
            if index == 2 { return nil }
            return { emit in
                journal.add("finish \(index) start")
                await started.openUp()
                try await Task.sleep(for: .milliseconds(index == 0 ? 30 : 100))
                emit("caption \(index)")
                journal.add("finish \(index) end")
                if index == 0 { await ended.openUp() }
            }
        }, finishEmit: { index, line in journal.add("log \(index): \(line)") },
           waiting: { pending in waiting.withLock { $0.append(pending) } })
        let events = journal.all
        func position(_ event: String) throws -> Int { try #require(events.firstIndex(of: event)) }
        #expect(try position("render 1 start") < position("finish 0 start"))
        #expect(try position("finish 0 start") < position("render 1 end"))
        #expect(try position("render 2 end") < position("finish 1 end"))
        #expect(events.contains("log 0: caption 0") && events.contains("log 1: caption 1"))
        #expect(events.filter { $0.hasPrefix("render") }.count == 6)
        #expect(try position("finish 0 end") < position("render 2 end"))
        // Every render was done while reel 1's finish was still writing.
        #expect(waiting.withLock { $0 } == [1])
    }

    @Test func aRenderFailureStopsRenderingButLetsEarlierFinishesComplete() async throws {
        struct RenderFailed: Error {}
        let journal = Journal()
        await #expect(throws: RenderFailed.self) {
            try await WizardReelBatch.run(count: 3, render: { index in
                if index == 1 { throw RenderFailed() }
                journal.add("render \(index)")
                return { emit in
                    try await Task.sleep(for: .milliseconds(20))
                    emit("done")
                    journal.add("finish \(index)")
                }
            }, finishEmit: { index, line in journal.add("log \(index): \(line)") })
        }
        #expect(journal.all == ["render 0", "log 0: done", "finish 0"])
    }

    @Test func aFinishFailureIsLoggedNotThrown() async throws {
        struct CaptionFailed: LocalizedError { var errorDescription: String? { "model offline" } }
        let journal = Journal()
        try await WizardReelBatch.run(count: 2, render: { index in
            { _ in if index == 0 { throw CaptionFailed() } }
        }, finishEmit: { index, line in journal.add("\(index): \(line)") })
        #expect(journal.all == ["0: Finishing failed: model offline"])
    }

    @Test func cancellationStopsRendersAndFinishes() async throws {
        let journal = Journal()
        let task = Task {
            try await WizardReelBatch.run(count: 3, render: { index in
                journal.add("render \(index)")
                return { _ in
                    journal.add("finish \(index) started")
                    do {
                        try await Task.sleep(for: .seconds(10))
                        journal.add("finish \(index) completed")
                    } catch {
                        journal.add("finish \(index) cancelled")
                        throw error
                    }
                }
            }, finishEmit: { _, line in journal.add(line) })
        }
        // Cancel once a finish is actually waiting, not after a fixed delay: under
        // load the batch may not have started yet, and cancelling then proves nothing.
        let deadline = ContinuousClock.now + .seconds(30)
        while !journal.all.contains(where: { $0.hasSuffix("started") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(journal.all.contains { $0.hasSuffix("started") })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let events = journal.all
        #expect(events.contains("finish 0 cancelled") || events.contains("finish 1 cancelled") || events.contains("finish 2 cancelled"))
        #expect(!events.contains { $0.hasSuffix("completed") })
        #expect(!events.contains { $0.hasPrefix("Finishing failed") })
    }
}
