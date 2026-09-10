import Foundation
import Observation

nonisolated struct DriveTransfer: Codable, Identifiable, Sendable {
    enum Operation: String, Codable, Sendable { case download, fetch, upload }
    // Separate asset operations keep the media-only switch in DriveMediaStore unchanged.
    enum AssetOperation: String, Codable, Sendable { case assetDownload, assetUpload }
    enum Status: String, Codable, Sendable { case waiting, running, reconnect, stopped, failed, complete }
    var id = UUID()
    var profile: String
    var projectID: Int64?
    var projectName: String
    var operation: Operation
    var file: DriveFile?
    var media: DriveMedia?
    var folder: String?
    var status: Status = .running
    var totalBytes: Int64?
    var progress = 0.0
    var message = ""
    var assetOperation: AssetOperation?
    var assetPath: String?
    var groupID: UUID?
    var isAsset: Bool { assetOperation != nil }
    var isUpload: Bool { operation == .upload }
    var title: String { assetPath ?? file?.name ?? URL(fileURLWithPath: media?.path ?? "").lastPathComponent }
}

@MainActor @Observable
final class GoogleDriveTransfers {
    static let shared = GoogleDriveTransfers()
    let auth: GoogleDriveAuth
    var jobs: [DriveTransfer] = [] {
        didSet { BugReporting.logDriveChanges(from: oldValue, to: jobs) }
    }
    var states: [String: DriveConnectionState] = [:]
    var connecting: Set<String> = []
    var connectionError: String?
    var revision = 0
    var assetHomes: [String: AssetSyncHome] = [:]
    @ObservationIgnored private var assetWork:
        [UUID: @MainActor (@escaping @Sendable (Double) async -> Void) async throws -> DriveFile] = [:]
    @ObservationIgnored private var assetWaiters: [UUID: CheckedContinuation<DriveFile, Error>] = [:]
    @ObservationIgnored private var assetGroupStops: [UUID: () -> Void] = [:]
    @ObservationIgnored private var connectionGenerations: [String: Int] = [:]
    @ObservationIgnored private var contexts: [String: Context] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<URL, Error>] = [:]
    @ObservationIgnored private var reconnectWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var offlineRetries: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var signIns: [String: GoogleDriveSignIn] = [:]

    struct Context {
        var database: Database
        var client: GoogleDriveClient
        var media: DriveMediaStore
        var profile: BrandProfile
    }

    init(auth: GoogleDriveAuth = GoogleDriveAuth()) { self.auth = auth }

    func attach(profile: BrandProfile, database: Database, client suppliedClient: GoogleDriveClient? = nil) async {
        let name = profile.profileName
        if contexts[name]?.database.path == database.path { return }
        let client = suppliedClient ?? GoogleDriveClient(auth: auth, profile: name)
        let media = DriveMediaStore(database: database, client: client, inputFolder: profile.sourceFolderURL)
        contexts[name] = Context(database: database, client: client, media: media, profile: profile)
        await DriveMediaResolver.shared.register(database: database, profile: name)
        await refreshState(profile: name)
        // Reading the opt-in setting does not initialize or run sync for an unset profile.
        assetHomes[name] = nil
        if let json = try? await database.driveSetting("assetHome"), !json.isEmpty {
            assetHomes[name] = await AssetSyncHome.restore(json: json, database: database)
        }
        if let json = try? await database.driveSetting("transferQueue"),
            let saved = try? JSONDecoder().decode([DriveTransfer].self, from: Data(json.utf8))
        {
            for var job in saved
            where job.status != .complete && !job.isAsset && !jobs.contains(where: { $0.id == job.id }) {
                job.status = .stopped
                job.message = job.isAsset ? "Interrupted — Refresh to continue" : "Interrupted — Resume to continue"
                jobs.append(job)
            }
        }
    }

    func client(profile: String) -> GoogleDriveClient? { contexts[profile]?.client }
    func refreshState(profile: String) async { states[profile] = await auth.state(profile: profile) }

    func refreshAllStates(including activeProfile: String? = nil) async {
        connectionError = nil
        var profiles = Set(contexts.keys)
        if let activeProfile { profiles.insert(activeProfile) }
        for profile in profiles { await refreshState(profile: profile) }
    }

    func connect(profile: String) {
        guard !connecting.contains(profile) else { return }
        connecting.insert(profile)
        connectionError = nil
        let signIn = GoogleDriveSignIn()
        signIns[profile] = signIn
        Task {
            defer {
                connecting.remove(profile)
                signIns[profile] = nil
            }
            do {
                try await signIn.connect(auth: auth, profile: profile)
                await refreshState(profile: profile)
                connectionGenerations[profile, default: 0] += 1
                for job in jobs where job.profile == profile && job.status == .reconnect {
                    if let waiter = reconnectWaiters.removeValue(forKey: job.id) {
                        waiter.resume()
                    } else {
                        resume(job.id)
                    }
                }
            } catch { connectionError = GoogleDriveError.message(for: error) }
        }
    }
    func disconnect(profile: String) {
        for job in jobs where job.profile == profile { stop(job.id) }
        Task {
            do { try await auth.disconnect(profile: profile) } catch {
                connectionError = GoogleDriveError.message(for: error)
            }
            await refreshState(profile: profile)
        }
    }

    func enqueue(files: [DriveFile], profile: String, projectID: Int64?, projectName: String) {
        for file in files {
            if jobs.contains(where: {
                $0.profile == profile && $0.file?.id == file.id && $0.projectID == projectID && $0.status != .complete
            }) {
                continue
            }
            let job = DriveTransfer(
                profile: profile, projectID: projectID, projectName: projectName,
                operation: .download, file: file)
            jobs.append(job)
            start(job.id)
        }
    }
    func enqueueUpload(_ media: [DriveMedia], folder: String, profile: String, projectID: Int64?, projectName: String) {
        for item in Self.uploadCandidates(media) {
            if jobs.contains(where: {
                $0.profile == profile && $0.media?.id == item.id && $0.operation == .upload && $0.status != .complete
            }) {
                continue
            }
            let job = DriveTransfer(
                profile: profile, projectID: projectID, projectName: projectName,
                operation: .upload, media: item, folder: folder)
            jobs.append(job)
            start(job.id)
        }
    }

    nonisolated static func uploadCandidates(_ media: [DriveMedia]) -> [DriveMedia] {
        media.filter { $0.fileID == nil }
    }

    func uploadJob(for media: DriveMedia, profile: String) -> DriveTransfer? {
        jobs.last {
            $0.profile == profile && $0.media?.id == media.id && $0.operation == .upload && $0.status != .complete
        }
    }

    private func pumpUploads() {
        for job in jobs where job.isUpload && job.status == .waiting { start(job.id) }
    }

    func fetch(_ media: DriveMedia, profile: String) async throws -> URL {
        if let existing = jobs.first(where: {
            $0.profile == profile && $0.media?.path == media.path && $0.operation == .fetch && tasks[$0.id] != nil
        }),
            let task = tasks[existing.id]
        {
            return try await task.value
        }
        let job = DriveTransfer(
            profile: profile, projectName: profile, operation: .fetch, media: media,
            message: "Fetching from Drive")
        jobs.append(job)
        start(job.id)
        guard let task = tasks[job.id] else { throw GoogleDriveError.notFound }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in self.stop(job.id) }
        }
    }

    func stop(_ id: UUID) {
        if let job = jobs.first(where: { $0.id == id }), job.isAsset {
            if let group = job.groupID { assetGroupStops[group]?() }
            if tasks[id] == nil {
                assetWork[id] = nil
                assetWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        offlineRetries.removeValue(forKey: id)?.cancel()
        if tasks[id] == nil, let job = jobs.first(where: { $0.id == id }) {
            update(id) {
                $0.status = .stopped
                $0.message = job.isAsset ? "Stopped — Refresh to continue" : "Stopped — Resume to continue"
            }
            Task { await persist(profile: job.profile) }
        }
        tasks[id]?.cancel()
        reconnectWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    /// Cancel is final: the job leaves the list and its partial files are
    /// discarded, unlike Stop which keeps everything for Resume.
    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if job.isAsset { stop(id) }
        offlineRetries.removeValue(forKey: id)?.cancel()
        tasks[id]?.cancel()
        reconnectWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        jobs.removeAll { $0.id == id }
        let context = contexts[job.profile]
        Task {
            _ = await tasks[id]?.result
            if !job.isAsset { await context?.media.discardArtifacts(for: job) }
            await persist(profile: job.profile)
            revision += 1
        }
    }

    func resume(_ id: UUID) {
        // Asset groups are replanned by manual Refresh; stale actions must never resume alone.
        guard jobs.first(where: { $0.id == id })?.isAsset != true else { return }
        offlineRetries.removeValue(forKey: id)?.cancel()
        if tasks[id] == nil { start(id) }
    }

    private func update(_ id: UUID, _ body: (inout DriveTransfer) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }
    private func persist(profile: String) async {
        // Asset rows are replanned by the next Refresh; only media transfers need recovery.
        guard let context = contexts[profile],
            let data = try? JSONEncoder().encode(
                jobs.filter { $0.profile == profile && $0.status != .complete && !$0.isAsset })
        else { return }
        do {
            try await context.database.setDriveSetting("transferQueue", value: String(decoding: data, as: UTF8.self))
        } catch {
            connectionError = "Could not save Drive transfer recovery state: \(GoogleDriveError.message(for: error))"
        }
    }

    private func start(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), let context = contexts[job.profile] else { return }
        guard tasks[id] == nil else { return }
        if job.isUpload {
            let active = jobs.filter { $0.isUpload && tasks[$0.id] != nil }.count
            if active >= 2 {
                update(id) {
                    $0.status = .waiting
                    $0.message = "Waiting"
                }
                Task { await persist(profile: job.profile) }
                return
            }
        }
        update(id) {
            $0.status = .running
            $0.message = job.operation == .fetch ? "Fetching from Drive" : job.operation.rawValue.capitalized
        }
        let task = Task<URL, Error> {
            defer {
                tasks[id] = nil
                assetWork[id] = nil
                pumpUploads()
            }
            await persist(profile: job.profile)
            do {
                while true {
                    try Task.checkCancellation()
                    let connectionGeneration = connectionGenerations[job.profile, default: 0]
                    do {
                        let throttle = DriveProgressThrottle()
                        // The enclosing task already holds self strongly for
                        // the transfer's lifetime; a weak capture here adds nothing.
                        let progress: @Sendable (Double) async -> Void = { value in
                            guard await throttle.acceptsUpdate() else { return }
                            await self.reportProgress(id, value: value)
                        }
                        let url: URL
                        var assetResult: DriveFile?
                        if job.isAsset {
                            guard let work = assetWork[id] else { throw CancellationError() }
                            let result = try await work(progress)
                            assetResult = result
                            url = URL(fileURLWithPath: job.assetPath ?? "")
                        } else {
                            switch job.operation {
                            case .download:
                                guard let file = job.file else { throw GoogleDriveError.invalidResponse }
                                url = try await context.media.download(
                                    file, projectID: job.projectID, progress: progress)
                            case .fetch:
                                guard let media = job.media else { throw GoogleDriveError.invalidResponse }
                                url = try await context.media.ensure(media, progress: progress)
                            case .upload:
                                guard let media = job.media, let folder = job.folder else {
                                    throw GoogleDriveError.invalidResponse
                                }
                                let size = try await context.media.byteCount(media)
                                update(id) { $0.totalBytes = size }
                                _ = try await context.media.upload(media, folder: folder, progress: progress)
                                url = URL(fileURLWithPath: media.path)
                            }
                        }
                        update(id) {
                            $0.status = .complete
                            $0.progress = 1
                            $0.message = "Complete"
                        }
                        revision += 1
                        await persist(profile: job.profile)
                        if let assetResult {
                            assetWaiters.removeValue(forKey: id)?.resume(returning: assetResult)
                        }
                        return url
                    } catch GoogleDriveError.offline where job.isAsset {
                        update(id) {
                            $0.status = .waiting
                            $0.message = GoogleDriveError.offline.localizedDescription
                        }
                        await persist(profile: job.profile)
                        try await Task.sleep(for: .seconds(15))
                        update(id) { $0.status = .running }
                    } catch GoogleDriveError.reconnect {
                        update(id) {
                            $0.status = .reconnect
                            $0.message = "Paused — Reconnect Google Drive"
                        }
                        await refreshState(profile: job.profile)
                        await persist(profile: job.profile)
                        try Task.checkCancellation()
                        if connectionGenerations[job.profile, default: 0] != connectionGeneration {
                            update(id) {
                                $0.status = .running
                                $0.message = "Resuming"
                            }
                            continue
                        }
                        // Uploads do not occupy a queue slot while awaiting sign-in.
                        if job.operation == .upload && !job.isAsset { throw GoogleDriveError.reconnect }
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            reconnectWaiters[id] = continuation
                        }
                        update(id) {
                            $0.status = .running
                            $0.message = "Resuming"
                        }
                    }
                }
            } catch {
                if error as? GoogleDriveError == .reconnect {
                    // The reconnect state was already persisted above.
                    throw error
                }
                assetWaiters.removeValue(forKey: id)?.resume(throwing: error)
                update(id) {
                    $0.status =
                        error is CancellationError || error as? GoogleDriveError == .cannotReplaceAsset
                        ? .stopped : .failed
                    $0.message =
                        error is CancellationError
                        ? (job.isAsset ? "Stopped — Refresh to continue" : "Stopped — Resume to continue")
                        : GoogleDriveError.message(for: error)
                }
                await persist(profile: job.profile)
                if !job.isAsset && error as? GoogleDriveError == .offline {
                    offlineRetries[id] = Task {
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        guard self.jobs.first(where: { $0.id == id })?.status == .failed else { return }
                        self.resume(id)
                    }
                }
                throw error
            }
        }
        tasks[id] = task
        // Observe errors for queued work; callers awaiting a fetch get the same error.
        Task { _ = try? await task.value }
    }

    private func reportProgress(_ id: UUID, value: Double) { update(id) { $0.progress = value } }

    func chooseAssetHome(_ folder: DriveFile, breadcrumb: String, profile: String) async throws {
        guard folder.isFolder, let context = contexts[profile], assetHomes[profile]?.isRefreshing != true else {
            throw GoogleDriveError.conflict
        }
        let home = AssetSyncHome(folder: folder, breadcrumb: breadcrumb)
        try await home.remember(database: context.database)
        assetHomes[profile] = home
    }

    func forgetAssetHome(profile: String) async throws {
        guard let context = contexts[profile], assetHomes[profile]?.isRefreshing != true else {
            throw GoogleDriveError.conflict
        }
        try await context.database.setDriveSetting("assetHome", value: "")
        assetHomes[profile] = nil
        try await context.database.setDriveSetting("assetSyncJournal", value: "")
    }

    func refreshAssets(profile: String, log: @escaping (String) -> Void) {
        guard let context = contexts[profile], let home = assetHomes[profile],
            !assetHomes.values.contains(where: { $0.isRefreshing })
        else { return }
        home.refresh(client: context.client, database: context.database, transfers: self, profile: profile,
            learnedStep: { runner in
                let current = ProfileStore.load(name: profile) ?? context.profile
                // No nickname yet: others' lessons still come down; publishing needs the user-entered identity.
                guard !current.learnedSharing.deviceNickname.isEmpty else {
                    try await LearnedSync.pull(executor: runner, profile: current)
                    log("AI Lessons: downloaded shared lessons; enter a device nickname on AI Lessons to publish yours")
                    return
                }
                let wizard = WizardEngine(ai: AIService(config: SettingsStore.loadSettings().ai), render: RenderEngine())
                try await LearnedSync.run(executor: runner, profile: current, database: context.database, log: log, config: SettingsStore.loadSettings().ai) {
                    _ = try await wizard.distillLessons(database: context.database, emit: { _ in })
                }
            }, log: log)
    }

    func publishLearned(profile: BrandProfile, benchmarks: AccountBenchmarks?,
                        library: LearnedLibrary = LearnedLibrary()) async throws {
        guard let context = contexts[profile.profileName], let home = assetHomes[profile.profileName],
              !assetHomes.values.contains(where: { $0.isRefreshing }),
              try await home.validate(client: context.client) else { throw GoogleDriveError.notFound }
        home.isRefreshing = true
        defer { home.isRefreshing = false }
        let group = UUID()
        let task = Task {
            let runner = AssetSyncExecutor(roots: AssetSyncRoots(), client: context.client, transfers: self,
                profile: profile.profileName, group: group, journal: AssetSyncJournal(homeID: home.selection.id))
            let wizard = WizardEngine(ai: AIService(config: SettingsStore.loadSettings().ai), render: RenderEngine())
            try await LearnedSync.run(executor: runner, profile: profile, database: context.database,
                                      library: library, benchmarks: benchmarks, config: SettingsStore.loadSettings().ai) {
                _ = try await wizard.distillLessons(database: context.database, emit: { _ in })
            }
        }
        home.learnedStop = { task.cancel() }
        beginAssetGroup(group) { home.stop() }
        defer { home.learnedStop = nil; endAssetGroup(group) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func beginAssetGroup(_ id: UUID, stop: @escaping () -> Void) { assetGroupStops[id] = stop }
    func endAssetGroup(_ id: UUID) { assetGroupStops[id] = nil }

    func assetTransfer(
        profile: String, group: UUID, path: String, upload: Bool, size: Int64,
        work: @escaping @MainActor (@escaping @Sendable (Double) async -> Void) async throws -> DriveFile
    ) async throws -> DriveFile {
        try Task.checkCancellation()
        guard contexts[profile] != nil else { throw GoogleDriveError.notFound }
        let job = DriveTransfer(
            profile: profile, projectName: "Asset library",
            operation: upload ? .upload : .download, totalBytes: size,
            assetOperation: upload ? .assetUpload : .assetDownload, assetPath: path, groupID: group)
        jobs.append(job)
        assetWork[job.id] = work
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                assetWaiters[job.id] = continuation
                start(job.id)
            }
        } onCancel: {
            Task { @MainActor in self.stop(job.id) }
        }
    }

    func assetReport(profile: String, group: UUID, path: String, message: String) {
        if let job = jobs.last(where: { $0.groupID == group && $0.assetPath == path && $0.status != .complete }) {
            update(job.id) { $0.message = message }
        } else {
            jobs.append(
                DriveTransfer(
                    profile: profile, projectName: "Asset library", operation: .download,
                    status: .stopped, message: message, assetOperation: .assetDownload, assetPath: path, groupID: group)
            )
        }
        Task { await persist(profile: profile) }
    }

    func offload(_ media: [DriveMedia], profile: String) async throws {
        guard let context = contexts[profile] else { throw GoogleDriveError.notFound }
        for item in media {
            guard !jobs.contains(where: { $0.profile == profile && $0.media?.path == item.path && tasks[$0.id] != nil })
            else {
                throw GoogleDriveError.conflict
            }
            try await context.media.offload(item)
        }
        revision += 1
    }

    func uploadFolder(profile: String, project: String) async throws -> DriveFile {
        guard let context = contexts[profile] else { throw GoogleDriveError.notFound }
        if let remembered = try await context.database.driveSetting("uploadFolder"), !remembered.isEmpty {
            return try await context.client.metadata(id: remembered)
        }
        let root = try await context.client.findOrCreateFolder(name: "Clip Builder", parent: "root")
        let brand = try await context.client.findOrCreateFolder(name: profile, parent: root.id)
        let folder = try await context.client.findOrCreateFolder(name: project, parent: brand.id)
        try await rememberFolder(folder, profile: profile)
        return folder
    }
    func rememberFolder(_ folder: DriveFile, profile: String) async throws {
        guard folder.isFolder, let context = contexts[profile] else { throw GoogleDriveError.invalidResponse }
        try await context.database.setDriveSetting("uploadFolder", value: folder.id)
    }
}
