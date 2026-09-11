import Foundation

/// A job captures its complete environment before the first suspension. The
/// injected service must write only to context.database, never AppStore state.
@MainActor
struct BuilderPrerequisiteContext {
    let database: Database
    let profile: BrandProfile
    let projectID: Int64?
    let language: String
    let isCurrent: @MainActor () -> Bool
    let perform: @MainActor (BuilderPrerequisiteKind, VideoRecord) async throws -> Void
}

@MainActor
final class BuilderPrerequisites {
    private struct Key: Hashable { var kind: BuilderPrerequisiteKind; var video: Int64 }
    private struct Job {
        let id: String
        let task: Task<PrerequisiteReport, Never>
    }
    private var jobs: [Key: Job] = [:]
    private let capture: @MainActor () -> BuilderPrerequisiteContext?
    static let maximumJobs = 3

    init(capture: @escaping @MainActor () -> BuilderPrerequisiteContext?) { self.capture = capture }

    func status(kind: BuilderPrerequisiteKind, video: Int64) -> PrerequisiteOutcome? {
        jobs[Key(kind: kind, video: video)].map { .running(jobID: $0.id) }
    }
    func cancelAll() { for job in jobs.values { job.task.cancel() } }
    func ensureTranscript(video: Int64) async -> PrerequisiteReport { await ensure(.transcript, video: video) }
    func ensurePeople(video: Int64) async -> PrerequisiteReport { await ensure(.people, video: video) }
    func ensureAnalysis(video: Int64) async -> PrerequisiteReport { await ensure(.analysis, video: video) }

    /// Cancellation by any waiter cancels the shared job for all waiters. We
    /// drain it before returning so a late service write cannot escape effects
    /// accounting or revive a cancelled preview. Running is never success.
    func ensure(_ kind: BuilderPrerequisiteKind, video: Int64,
                onStatus: ((PrerequisiteOutcome) -> Void)? = nil) async -> PrerequisiteReport {
        guard !Task.isCancelled else { return .init(outcome: .failed(reason: "Cancelled.")) }
        let key = Key(kind: kind, video: video)
        let job: Job
        if let existing = jobs[key] { job = existing }
        else {
            guard jobs.count < Self.maximumJobs else {
                return .init(outcome: .unavailable(reason: "Prerequisite job limit reached."))
            }
            guard let context = capture(), context.isCurrent() else {
                return .init(outcome: .unavailable(reason: "The captured Library is no longer available."))
            }
            let id = UUID().uuidString
            let task = Task { await Self.perform(kind, videoID: video, context: context) }
            // Separate prerequisite budget; mutation previews retain their much
            // shorter synchronous budget. Cancellation always drains the service.
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(600)); task.cancel() }
                catch { }
            }
            Task { _ = await task.value; deadline.cancel() }
            job = Job(id: id, task: task)
            jobs[key] = job
        }
        onStatus?(.running(jobID: job.id))
        let sharedTask = job.task
        let report = await withTaskCancellationHandler {
            await sharedTask.value
        } onCancel: { sharedTask.cancel() }
        if jobs[key]?.id == job.id { jobs[key] = nil }
        return report
    }

    private static func perform(_ kind: BuilderPrerequisiteKind, videoID: Int64,
                                context: BuilderPrerequisiteContext) async -> PrerequisiteReport {
        let database = context.database
        var before: PrerequisiteInventory?
        var signature: String?
        var outcome: PrerequisiteOutcome
        do {
            try Task.checkCancellation()
            let videos = try await database.fetchVideos(projectID: context.projectID)
            guard let video = videos.first(where: { $0.id == videoID }), context.isCurrent() else {
                return .init(outcome: .unavailable(reason: "Video is outside the captured project or the profile changed."))
            }
            let jobSignature = "v1:\(video.hash):\(kind == .transcript ? context.language : "")"
            if let existing = try await database.prerequisiteResult(kind: kind, video: video,
                                                                   signature: jobSignature, language: context.language) {
                guard context.isCurrent(), !Task.isCancelled else {
                    return .init(outcome: .unavailable(reason: "Profile changed or work was cancelled."))
                }
                return .init(outcome: existing)
            }
            signature = jobSignature
            before = try await database.prerequisiteInventory(videoID: videoID)
            try Task.checkCancellation()
            guard context.isCurrent() else { throw ScriptError.invalid("Profile changed.") }
            try await database.savePrerequisiteResult(kind: kind, videoID: videoID, signature: jobSignature,
                                                      outcome: .running(jobID: UUID().uuidString))
            try Task.checkCancellation()
            guard context.isCurrent() else { throw ScriptError.invalid("Profile changed.") }
            try await context.perform(kind, video)
            try Task.checkCancellation()
            guard context.isCurrent() else { throw ScriptError.invalid("Profile changed; any saved Library work belongs to the original profile.") }
            let hasData = try await database.prerequisiteHasData(kind: kind, videoID: videoID, language: context.language)
            outcome = hasData ? .completedWithData(dataVersion: UUID().uuidString) : .completedEmpty
            try Task.checkCancellation()
            guard context.isCurrent() else { throw ScriptError.invalid("Profile changed.") }
            try await database.savePrerequisiteResult(kind: kind, videoID: videoID, signature: jobSignature, outcome: outcome)
        } catch is CancellationError {
            outcome = .failed(reason: "Cancelled. Any Library work already saved remains.")
        } catch let error as TranscriptionError {
            outcome = .unavailable(reason: error.description)
        } catch FFmpegError.toolNotFound(let tool) {
            outcome = .unavailable(reason: "Required tool is unavailable: " + tool)
        } catch AIError.notConfigured(let reason) {
            outcome = .unavailable(reason: reason)
        } catch {
            outcome = .failed(reason: String(describing: error))
        }
        if let signature, !outcome.isComplete {
            // A partial transcript/batch must not be mistaken for a successful
            // legacy result on the next ensure, including after relaunch.
            do { try await database.savePrerequisiteResult(kind: kind, videoID: videoID, signature: signature, outcome: outcome) }
            catch { outcome = .failed(reason: "Could not save prerequisite failure state: \(error)") }
        }
        // Deliberately read the captured DB even after cancellation/profile
        // changes: effects already saved must be reported, never hidden.
        var effects: [PrerequisiteEffect] = []
        if let before {
            do {
                effects = try await database.prerequisiteInventory(videoID: videoID)
                    .effects(since: before, kind: kind, videoID: videoID)
            } catch {
                effects = [.init(kind: kind, videoID: videoID, scope: "Library",
                                 beforeCount: 0, afterCount: 0,
                                 summary: "Library work may have been saved; effect verification failed.")]
                outcome = .failed(reason: "Could not verify persistent Library effects.")
            }
        }
        if !context.isCurrent() { outcome = .failed(reason: "Profile changed. Saved work remains in the original Library.") }
        else if Task.isCancelled { outcome = .failed(reason: "Cancelled. Any saved Library work remains.") }
        return .init(outcome: outcome, effects: effects)
    }
}
