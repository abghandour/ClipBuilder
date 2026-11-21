import Foundation

extension AppStore {
    /// Runs voice-over work (the preview's sound mix, caption translation) as
    /// a job, so it has a status-bar row with Stop and does not belong to the
    /// sheet that asked for it. Returns when the work ends; throws
    /// `CancellationError` when it was stopped or replaced by a newer run of
    /// the same `group`.
    func runVoiceOverJob(title: String, group: String,
                         work: @escaping @MainActor () async throws -> Void) async throws {
        let waiter = VoiceOverJobWaiter()
        let generation = profileGeneration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiter.continuation = continuation
                // A subject of its own: a job with a running twin is never started,
                // and this caller would wait for ever. The group stops the older run.
                waiter.jobID = jobs.start(.voiceOver, title: title, project: activeProject,
                                          profileGeneration: profileGeneration,
                                          subjectID: UUID().uuidString, subjectGroupID: group,
                                          reportsFailure: false,
                                          cleanup: { waiter.finish(.failure(CancellationError())) }) { _ in
                    do {
                        try await work()
                        // Work that swallows a Stop (a translation keeps what it has)
                        // still ends as stopped for whoever is waiting.
                        try Task.checkCancellation()
                        guard self.profileGeneration == generation else { throw CancellationError() }
                        waiter.finish(.success(()))
                    } catch {
                        waiter.finish(.failure(error))
                        throw error
                    }
                    return nil
                }
            }
        } onCancel: {
            Task { @MainActor in
                if let id = waiter.jobID { self.jobs.cancel(id) }
            }
        }
    }
}

/// Hands a job's outcome to the one caller waiting for it, once.
@MainActor
private final class VoiceOverJobWaiter {
    var continuation: CheckedContinuation<Void, Error>?
    var jobID: UUID?

    func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
