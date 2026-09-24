import Foundation
import Observation

nonisolated enum AppJobKind: String, CaseIterable, Sendable {
    case aiFavorites, soundbites, duplicates, fileNames, gapReport, profileStarter
    case coverFrames, overlayTemplate, sceneSearch, imageSearch, fightResearch
    case generateRequest, instagramPublish, socialExport, resourceExport, resourceImport
    case mapSpeakers, suggestTrim, cameraPath, evaluateReelModel, publishLessons, transcriptAnalysis

    var postsNotice: Bool { self == .overlayTemplate }

    var shortTitle: String {
        switch self {
        case .aiFavorites: "AI Favorites"
        case .soundbites: "Soundbites"
        case .duplicates: "Duplicates"
        case .fileNames: "File Names"
        case .gapReport: "Content Gaps"
        case .profileStarter: "Starting Style"
        case .coverFrames: "Cover Frames"
        case .overlayTemplate: "Overlay Template"
        case .sceneSearch: "Scene Search"
        case .imageSearch: "Image Search"
        case .fightResearch: "Fight Research"
        case .generateRequest: "Video Request"
        case .instagramPublish: "Instagram Publish"
        case .socialExport: "Social Export"
        case .resourceExport: "Resource Export"
        case .resourceImport: "Resource Import"
        case .mapSpeakers: "Map Speakers"
        case .suggestTrim: "Suggest Trim"
        case .cameraPath: "Center Stage"
        case .evaluateReelModel: "Evaluate Model"
        case .publishLessons: "Publish AI Lessons"
        case .transcriptAnalysis: "Transcript Analysis"
        }
    }

    var channel: String {
        switch self {
        case .aiFavorites: "curate"
        case .gapReport, .generateRequest: "wizard"
        case .instagramPublish: "instagram"
        case .socialExport: "builder"
        case .profileStarter, .overlayTemplate, .imageSearch, .resourceExport, .resourceImport,
             .evaluateReelModel, .publishLessons: "app"
        default: "analysis"
        }
    }
}

nonisolated struct AppJobEmptyResult: Error {
    let message: String
}

nonisolated struct CameraPathJobKey: Equatable, Sendable {
    let sceneID: Int64
    let start: Double
    let end: Double
    let camera: String

    var subjectID: String { "\(sceneID)|\(start)|\(end)|\(camera)" }
    var groupID: String { String(sceneID) }
}

nonisolated struct SceneSearchContext: Equatable, Sendable {
    let runIDs: Set<Int64>
    let tag: String?
    let text: String
    let minimumScore: Double
    let showHidden: Bool
    let favoritesOnly: Bool
}

nonisolated enum AppJobResult: Equatable, Sendable {
    case favorites(candidates: [SceneRecord], proposals: [SceneCurator.Proposal], provenance: AIProvenance?)
    case soundbites(video: VideoRecord, items: [SoundbiteFinder.Soundbite], provenance: AIProvenance?)
    case duplicateReport(videos: [VideoRecord], groups: [DuplicateFinder.Group], provenance: AIProvenance?)
    case fileNames([RenameSuggestion])
    case gapReport([GapReporter.Section], provenance: AIProvenance?)
    case profileStarter(ProfileStarter.Result, provenance: AIProvenance?)
    case coverFrames(video: GeneratedVideoRecord, candidates: [CoverFramePicker.Candidate], provenance: AIProvenance?)
    case sceneSearch(query: String, ids: [Int64], provenance: AIProvenance?, context: SceneSearchContext)
    case imageSearch(query: String, paths: [String], folder: [String])
    case fightResearch(video: VideoRecord)
    case instagramPublished(permalink: URL?)
    case resourceExport(url: URL)
    case resourceImport(summary: ResourceImportSummary)
    case socialExport(urls: [URL])
    case trim(start: Double, end: Double, reason: String, provenance: AIProvenance)
    case generateRequest(WizardPromptHandoff)

    var committedOnCancellation: Bool {
        switch self {
        case .resourceImport, .instagramPublished: true
        default: false
        }
    }

    var needsReview: Bool {
        switch self {
        case .sceneSearch, .imageSearch, .trim, .generateRequest: false
        default: true
        }
    }
}

nonisolated struct AppJob: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case running, done, failed(String), cancelled }
    let id: UUID
    let kind: AppJobKind
    let title: String
    let channel: String
    let projectID: Int64?
    let projectName: String
    let profileGeneration: Int
    let startedAt: Date
    let subjectID: String?
    let subjectGroupID: String?
    var status: Status = .running
    var statusLine = ""
    var progress: Double?
    var result: AppJobResult?
    var reviewed = false
}

/// Owns work and its results independently of the view that requested it.
@MainActor @Observable
final class AppJobs {
    private(set) var items: [AppJob] = []
    private var activeReviewID: UUID?
    private var activeReviewSnapshot: AppJob?
    private var reviewDismissalPending = false
    private struct LiveTask {
        let kind: AppJobKind
        let projectID: Int64?
        let profileGeneration: Int
    }
    private var liveTasks: [UUID: LiveTask] = [:]
    // Views need terminal status after resultless work is removed, not its payload.
    private var completionSummaries: [AppJob] = []
    private var terminalRevisions: [AppJobKind: Int] = [:]
    private var successfulRevisions: [AppJobKind: Int] = [:]
    static let finishedLimit = 20
    private(set) var reviewQueue: [UUID] = []
    var activeProjectID: Int64?
    var profileGeneration = 0
    var presentationBlocked = false
    var setupPresentations: Set<UUID> = []
    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var progressSinks: [UUID: (Double) -> Void] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    var running: [AppJob] { items.filter { $0.status == .running } }
    var busyProjectIDs: Set<Int64> {
        Set(liveTasks.values.filter { $0.profileGeneration == currentGeneration }.compactMap(\.projectID))
    }
    var awaitingReview: [AppJob] {
        items.filter { $0.status == .done && $0.result?.needsReview == true && !$0.reviewed }
    }
    var recoverable: [AppJob] {
        Array(items.filter {
            if case .failed = $0.status { return true }
            return $0.status == .cancelled || ($0.status == .done && $0.result?.needsReview == true && !$0.reviewed)
        }.reversed())
    }

    var presentedReview: AppJob? {
        get {
            guard !reviewDismissalPending else { return nil }
            let projectID = store?.activeProjectID ?? activeProjectID
            let generation = store?.profileGeneration ?? profileGeneration
            if let activeReviewID {
                let job = items.first { $0.id == activeReviewID } ?? activeReviewSnapshot
                guard let job, job.profileGeneration == generation,
                      job.projectID == nil || job.projectID == projectID else { return nil }
                return job
            }
            guard !presentationBlocked, setupPresentations.isEmpty else { return nil }
            return reviewQueue.compactMap { id in items.first { $0.id == id } }.first {
                $0.profileGeneration == generation && ($0.projectID == nil || $0.projectID == projectID)
                    && !$0.reviewed && $0.status == .done
            }
        }
        set {
            // Closing a review removes only its automatic presentation, not its result.
            if newValue == nil, let presented = presentedReview {
                reviewQueue.removeAll { $0 == presented.id }
                reviewDismissalPending = activeReviewID != nil
                activeReviewID = nil
                activeReviewSnapshot = nil
            }
        }
    }

    func reviewDidAppear(_ id: UUID) {
        activeReviewID = id
        activeReviewSnapshot = items.first { $0.id == id }
    }

    func reviewDidDismiss() {
        if let activeReviewID { reviewQueue.removeAll { $0 == activeReviewID } }
        activeReviewID = nil
        activeReviewSnapshot = nil
        reviewDismissalPending = false
    }

    @discardableResult
    func start(_ kind: AppJobKind, title: String, project: ProjectRecord?, profileGeneration: Int,
               subjectID: String? = nil, subjectGroupID: String? = nil,
               reportsFailure: Bool = true, progress: ((Double) -> Void)? = nil,
               cleanup: @escaping @MainActor () -> Void = {},
               body: @escaping @MainActor (@escaping @Sendable (String) -> Void) async throws -> AppJobResult?) -> UUID {
        if let subjectID, let existing = items.first(where: {
            $0.kind == kind && $0.subjectID == subjectID && $0.profileGeneration == profileGeneration
                && $0.status == .running && tasks[$0.id] != nil
        }) { return existing.id }
        if let subjectGroupID {
            for job in running where job.kind == kind && job.subjectGroupID == subjectGroupID
                && job.profileGeneration == profileGeneration && job.subjectID != subjectID {
                cancel(job.id)
            }
        }
        let id = UUID()
        items.append(AppJob(id: id, kind: kind, title: title, channel: kind.channel,
                            projectID: project?.id, projectName: project?.name ?? "Profile",
                            profileGeneration: profileGeneration, startedAt: .now, subjectID: subjectID,
                            subjectGroupID: subjectGroupID))
        liveTasks[id] = LiveTask(kind: kind, projectID: project?.id, profileGeneration: profileGeneration)
        progressSinks[id] = progress
        let relay = LogRelay(includeProgress: true) { [self] lines in
            for line in lines.flatMap({ $0.components(separatedBy: .newlines) }) { receive(line, id: id) }
        }
        let log = relay.sink
        tasks[id] = Task { [self] in
            defer {
                finish(id)
                tasks[id] = nil
                liveTasks[id] = nil
                progressSinks[id] = nil
                cleanup()
            }
            do {
                try Task.checkCancellation()
                guard store == nil || store?.profileGeneration == profileGeneration else { throw CancellationError() }
                let result = try await body(log)
                // A completed external write must still be reported if Stop raced its completion.
                if result?.committedOnCancellation != true { try Task.checkCancellation() }
                relay.flush()
                if result?.committedOnCancellation != true { try Task.checkCancellation() }
                guard store == nil || store?.profileGeneration == profileGeneration else { throw CancellationError() }
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].result = result
                items[index].status = .done
                items[index].progress = 1
                progress?(1)
                if result?.needsReview == true { reviewQueue.append(id) }
                else if kind.postsNotice {
                    store?.presentNotice(title, items[index].statusLine.isEmpty ? "Finished." : items[index].statusLine)
                }
            } catch {
                relay.flush()
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                if error is CancellationError || Task.isCancelled {
                    items[index].status = .cancelled
                } else if let empty = error as? AppJobEmptyResult {
                    items[index].status = .done
                    items[index].result = nil
                    items[index].statusLine = empty.message
                    store?.presentNotice(title, empty.message)
                } else {
                    items[index].status = .failed(error.userMessage)
                    items[index].statusLine = error.userMessage
                    if reportsFailure { store?.presentError(title, error) }
                }
            }
        }
        return id
    }

    private func receive(_ line: String, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .running else { return }
        let marker = line.trimmingCharacters(in: .whitespaces)
        if marker.hasPrefix("PROGRESS:") {
            if let fraction = Double(marker.dropFirst(9)) { updateProgress(id, fraction: fraction) }
            return
        }
        items[index].statusLine = AIProgressLine.from(line) ?? line
        store?.recordUnifiedLog(channel: items[index].channel, text: line)
    }

    func updateProgress(_ id: UUID, fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .running else { return }
        items[index].progress = min(1, max(0, fraction))
        progressSinks[id]?(min(1, max(0, fraction)))
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        if let index = items.firstIndex(where: { $0.id == id }), items[index].status == .running {
            items[index].status = .cancelled
            if items[index].kind == .generateRequest {
                store?.wizardPromptRequests[items[index].projectID ?? 0] = nil
            }
        }
    }

    func dismiss(_ id: UUID) {
        guard let job = items.first(where: { $0.id == id }), job.status != .running else { return }
        removeItem(id)
    }

    func markReviewed(_ id: UUID) {
        if var job = items.first(where: { $0.id == id }), job.status == .done {
            job.reviewed = true
            rememberCompletion(job)
            removeItem(id)
        }
    }

    func requestReview(_ id: UUID) {
        guard let job = awaitingReview.first(where: { $0.id == id }) else { return }
        Task { [self] in
            if let store {
                guard job.profileGeneration == store.profileGeneration else { return }
                if let projectID = job.projectID { await store.selectProject(projectID)?.value }
                guard job.profileGeneration == store.profileGeneration,
                      job.projectID == nil || job.projectID == store.activeProjectID else { return }
            }
            guard awaitingReview.contains(where: { $0.id == id }) else { return }
            reviewQueue.removeAll { $0 == id }
            reviewQueue.insert(id, at: 0)
        }
    }

    private var currentGeneration: Int { store?.profileGeneration ?? profileGeneration }

    var hasLiveTasks: Bool { !liveTasks.isEmpty }

    func hasLiveTask(kind: AppJobKind) -> Bool {
        liveTasks.values.contains { $0.kind == kind }
    }

    func latest(_ kind: AppJobKind, subjectID: String? = nil, subjectGroupID: String? = nil) -> AppJob? {
        let generation = currentGeneration
        let matches: (AppJob) -> Bool = { job in
            job.kind == kind && job.profileGeneration == generation
                && (subjectID == nil || job.subjectID == subjectID)
                && (subjectGroupID == nil || job.subjectGroupID == subjectGroupID)
        }
        return newest(items.filter(matches) + completionSummaries.filter(matches))
    }

    func latestFinished(_ kind: AppJobKind, projectID: Int64?) -> AppJob? {
        // Include consumed summaries so an older result cannot replace a newer search.
        newest((items + completionSummaries).filter {
            $0.kind == kind && $0.profileGeneration == currentGeneration && $0.projectID == projectID
                && $0.status == .done
        })
    }

    private func newest(_ candidates: [AppJob]) -> AppJob? {
        guard let job = candidates.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        return items.first { $0.id == job.id } ?? job
    }

    func terminalIDs(_ kind: AppJobKind, successfulOnly: Bool = false) -> [UUID] {
        completionSummaries.filter {
            $0.kind == kind && $0.profileGeneration == currentGeneration
                && (!successfulOnly || $0.status == .done)
        }.map(\.id)
    }

    func completionRevision(_ kind: AppJobKind, successfulOnly: Bool = false) -> Int {
        (successfulOnly ? successfulRevisions : terminalRevisions)[kind, default: 0]
    }

    private func rememberCompletion(_ job: AppJob) {
        var summary = job
        summary.result = nil
        completionSummaries.removeAll { $0.id == job.id }
        completionSummaries.append(summary)
        if completionSummaries.count > Self.finishedLimit {
            completionSummaries.removeFirst(completionSummaries.count - Self.finishedLimit)
        }
    }

    private func finish(_ id: UUID) {
        guard let live = liveTasks[id], live.profileGeneration == currentGeneration else { return }
        // Even a dismissed, cancelled task can finish an in-flight file write before it exits.
        terminalRevisions[live.kind, default: 0] &+= 1
        guard let job = items.first(where: { $0.id == id }) else { return }
        if job.status == .done { successfulRevisions[job.kind, default: 0] &+= 1 }
        rememberCompletion(job)
        if job.status == .done && (job.kind == .sceneSearch || job.kind == .imageSearch) {
            // A search replaces its filter; superseded payloads must never reappear after pruning.
            let sameSearch = (items + completionSummaries).filter {
                $0.kind == job.kind && $0.projectID == job.projectID
                    && $0.profileGeneration == job.profileGeneration && $0.status == .done
            }
            let newest = sameSearch.max { $0.startedAt < $1.startedAt }?.id
            for previous in sameSearch where previous.id != newest { removeItem(previous.id) }
        }
        if job.status == .done && job.result == nil { removeItem(id) }
        let finished = items.filter { $0.status != .running }
        for job in finished.prefix(max(0, finished.count - Self.finishedLimit)) { removeItem(job.id) }
    }

    private func removeItem(_ id: UUID) {
        reviewQueue.removeAll { $0 == id }
        items.removeAll { $0.id == id }
    }

    func profileDidChange() {
        for task in tasks.values { task.cancel() }
        reviewQueue = []
        activeReviewID = nil
        activeReviewSnapshot = nil
        reviewDismissalPending = false
        items = []
        completionSummaries = []
        terminalRevisions = [:]
        successfulRevisions = [:]
    }
}
