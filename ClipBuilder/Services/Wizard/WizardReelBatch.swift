import Foundation
import Synchronization

/// Runs a batch of reels one after another while each reel's finishing work
/// (the social caption request and run report) overlaps the next render.
/// Rendering stays serial because the encoder budget is already shared by
/// the clips of one reel; the model wait is what used to sit idle between reels.
nonisolated enum WizardReelBatch {
    /// Work a render hands back instead of awaiting: it needs nothing but
    /// its own emit sink and the records already written.
    typealias Finish = @Sendable (_ emit: @escaping @Sendable (String) -> Void) async throws -> Void

    /// `render(index)` renders one reel and may return its deferred finish.
    /// `finishEmit(index, line)` receives that finish's log lines.
    /// `waiting(count)` fires once when every render is done but `count`
    /// finishes are still running, so the caller can say so.
    ///
    /// A render failure stops further renders but lets the finishes of the
    /// reels already rendered complete; cancellation stops everything.
    /// A finish's own failure is logged, not thrown: the video exists.
    static func run(count: Int,
                    render: @Sendable (Int) async throws -> Finish?,
                    finishEmit: @escaping @Sendable (Int, String) -> Void,
                    waiting: @Sendable (Int) -> Void = { _ in }) async throws {
        let running = Mutex(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var renderError: Error?
            do {
                for index in 0..<count {
                    try Task.checkCancellation()
                    guard let finish = try await render(index) else { continue }
                    running.withLock { $0 += 1 }
                    group.addTask {
                        defer { running.withLock { $0 -= 1 } }
                        do {
                            try await finish { finishEmit(index, $0) }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            finishEmit(index, "Finishing failed: \(error.userMessage)")
                        }
                    }
                }
            } catch {
                renderError = error
            }
            if renderError is CancellationError {
                group.cancelAll()
            } else {
                let pending = running.withLock { $0 }
                if pending > 0 { waiting(pending) }
            }
            try await group.waitForAll()
            if let renderError { throw renderError }
        }
    }
}
