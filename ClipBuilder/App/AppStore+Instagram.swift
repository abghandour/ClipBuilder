import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Instagram

    /// Load cached accounts (+ media for the remembered selection) — called
    /// from openActiveProfile alongside the other list loads.
    func loadInstagramCache() {
        guard let database else { return }
        igReport = nil
        Task {
            // Account ids collide across profiles and the service is shared,
            // so the cached inputs go before anything is read.
            await instagram.invalidateReportInputs()
            do {
                let accounts = try await database.fetchIGAccounts()
                igAccounts = accounts
                if igSelectedAccountID == nil || !accounts.contains(where: { $0.id == igSelectedAccountID }) {
                    igSelectedAccountID = accounts.first?.id
                }
                try await reloadIGMedia()
            } catch {
                presentError("Could not load Instagram cache", error)
            }
            // The report waits for the Reports tab (`ensureIGReportLoaded`);
            // the benchmarks feed the wizard and critic so they build at
            // launch — after a beat, so the library and first frame win.
            try? await Task.sleep(for: .seconds(2))
            await reloadIGBenchmarks()
        }
    }

    /// Build the report the first time the Reports tab shows (or after it
    /// was reset), instead of at launch for every user. The inputs the
    /// launch-time benchmarks fetched are reused when they match.
    func ensureIGReportLoaded() {
        guard igReport == nil, !isLoadingIGReport else { return }
        Task { await reloadIGReport(reuseInputs: true) }
    }

    func reloadIGMedia() async throws {
        guard let database, let accountID = igSelectedAccountID else {
            igMedia = []
            igTemplatedMediaIDs = []
            return
        }
        igMedia = try await database.fetchIGMedia(accountID: accountID)
        igTemplatedMediaIDs = try await database.fetchIGTemplateMediaIDs(accountID: accountID)
    }

    /// Rebuild the Reports tab from the stored rows (after a refresh, an
    /// import, an account switch, or a period change).
    func reloadIGReport(reuseInputs: Bool = false) async {
        guard let database, let account = igAccounts.first(where: { $0.id == igSelectedAccountID }) else {
            igReport = nil
            return
        }
        isLoadingIGReport = true
        logEvent("instagram-reports", "Building Instagram report")
        defer { isLoadingIGReport = false }
        do {
            let report = try await instagram.buildReport(account: account, period: igReportPeriod,
                                                         database: database, reuseInputs: reuseInputs)
            // The account may have changed while the report was building.
            if igSelectedAccountID == account.id { igReport = report }
            logEvent("instagram-reports", "Instagram report ready")
        } catch {
            logEvent("instagram-reports", "Report failed: \(error.userMessage)")
            presentError("Could not build the Instagram report", error)
        }
    }

    /// The connected (else first own) account's benchmarks, plus the
    /// audience scores of published reels for critic calibration.
    func reloadIGBenchmarks(reuseInputs: Bool = false) async {
        guard let database else { igBenchmarks = nil; return }
        let connected = settings.instagram.connectedUsername
        guard let account = igAccounts.first(where: { $0.username.caseInsensitiveCompare(connected) == .orderedSame })
            ?? igAccounts.first(where: \.isOwn) else {
            igBenchmarks = nil
            return
        }
        igBenchmarks = try? await instagram.buildBenchmarks(account: account, database: database,
                                                            reuseInputs: reuseInputs)
        LearnedCache.invalidate(profile: activeProfile.profileName)
        await recordAudienceScores()
    }

    /// Published reels get their real audience outcome (quality + percentile
    /// among the account's reels) so the critic's forecast can be judged.
    private func recordAudienceScores() async {
        guard let database, let scores = igBenchmarks?.reelScores, !scores.isEmpty else { return }
        // Mutate a local copy and publish once — per-row writes to the
        // observed array between awaits meant one re-render per reel.
        // Collect per-reel patches, then merge them by id into whatever
        // `generatedVideos` holds after the awaits — a wizard render or a
        // delete during the writes must not be clobbered by a stale copy.
        struct Patch { var score: Double; var percentile: Int; var stats: IGStats? }
        var patches: [Int64: Patch] = [:]
        for video in generatedVideos {
            guard let mediaID = video.instagramMediaID, let score = scores[mediaID] else { continue }
            if video.audienceScore != score.quality || video.audiencePercentile != score.percentile {
                try? await database.updateGeneratedAudience(id: video.id, score: score.quality,
                                                            percentile: score.percentile)
            }
            patches[video.id] = Patch(score: score.quality, percentile: score.percentile, stats: score.stats)
        }
        guard !patches.isEmpty else { return }
        var merged = generatedVideos
        var changed = false
        for index in merged.indices {
            guard let patch = patches[merged[index].id] else { continue }
            if merged[index].audienceScore != patch.score || merged[index].audiencePercentile != patch.percentile {
                merged[index].audienceScore = patch.score
                merged[index].audiencePercentile = patch.percentile
                changed = true
            }
            if merged[index].instagramStats == nil, let stats = patch.stats {
                merged[index].instagramStats = stats
                changed = true
            }
        }
        if changed { generatedVideos = merged }
    }

    /// Sync/import log stream: "IGPROGRESS:<0-1>:<stage>" lines drive the
    /// bottom status bar; everything else lands in the visible log. When the
    /// history import runs as the first phase of a refresh, its markers are
    /// rescaled into the front of the refresh bar (`importScale`).
    func handleIGLog(_ message: String, importScale: Double? = nil) {
        guard message.hasPrefix("IGPROGRESS:") else {
            appendLog(\.igLog, [message])
            return
        }
        let parts = message.dropFirst("IGPROGRESS:".count).split(separator: ":", maxSplits: 1)
        guard var fraction = parts.first.flatMap({ Double($0) }), var status = igStatus else { return }
        var stage = parts.count > 1 ? String(parts[1]) : ""
        if let importScale {
            fraction *= importScale
            stage = "Importing history — \(stage)"
        }
        status.stage = stage
        status.fraction = min(1, max(status.fraction, fraction))   // monotonic within a run
        if igStatus != status { igStatus = status }
    }

    private func finishIGStatus(_ stage: String) {
        guard var status = igStatus else { return }
        status.stage = stage
        status.running = false
        if stage == "done" { status.fraction = 1 }
        igStatus = status
    }

    func dismissIGStatusBar() {
        igStatus = nil
    }

    /// A peace-grappler checkout is configured (or sits at the default
    /// location) — the Reports banner offers the history import.
    var canImportPeaceGrapplerHistory: Bool {
        !settings.instagram.peaceGrapplerRepoPath.trimmingCharacters(in: .whitespaces).isEmpty
            || PeaceGrapplerImporter.defaultRepoPath() != nil
    }

    /// Stop whichever Instagram job is running (refresh or import).
    func cancelInstagramWork() {
        if isImportingPeaceGrappler {
            cancelPeaceGrapplerImport()
        } else {
            cancelInstagramFetch()
        }
    }

    func setIGReportPeriod(_ period: ReportPeriod) {
        guard period != igReportPeriod else { return }
        igReportPeriod = period
        UserDefaults.standard.set(period.id, forKey: "instagram.reportPeriod")
        // Same rows, different window: rebuild from the cached inputs.
        Task { await reloadIGReport(reuseInputs: true) }
    }

    /// Whether the account fetches through the Graph API — the only path
    /// that yields report data.
    func isGraphAccount(_ account: IGAccountRecord) -> Bool {
        settings.instagram.isGraphConnected
            && settings.instagram.connectedUsername.caseInsensitiveCompare(account.username) == .orderedSame
    }

    /// Backfill report history from the peace-grappler checkout (Settings →
    /// Instagram → Report History). Targets the connected account, else the
    /// selected own account.
    func importPeaceGrapplerReports() {
        guard let database, !isImportingPeaceGrappler else { return }
        let configured = settings.instagram.peaceGrapplerRepoPath.trimmingCharacters(in: .whitespaces)
        guard let repoPath = configured.isEmpty ? PeaceGrapplerImporter.defaultRepoPath() : configured else {
            igImportStatus = "Choose the peace-grappler checkout folder first"
            return
        }
        let connected = settings.instagram.connectedUsername
        guard let account = igAccounts.first(where: { $0.username.caseInsensitiveCompare(connected) == .orderedSame })
            ?? igAccounts.first(where: { $0.id == igSelectedAccountID && $0.isOwn })
            ?? igAccounts.first(where: \.isOwn) else {
            igImportStatus = "Add your own Instagram account on the Instagram screen first"
            return
        }
        isImportingPeaceGrappler = true
        igImportStatus = "Importing…"
        igLog = []
        igStatus = IGSyncStatus(title: "Report History Import", stage: "Starting", fraction: 0)
        let instagram = instagram
        igImportTask = Task {
            do {
                let summary = try await instagram.importPeaceGrapplerHistory(
                    repoPath: repoPath, account: account, database: database, log: igLogSink(channel: "instagram-reports"))
                igImportStatus = summary.description
                finishIGStatus("done")
                await reloadIGReport()
                await reloadIGBenchmarks()
            } catch is CancellationError {
                igImportStatus = "Import stopped"
                appendLog(\.igLog, ["Import stopped."], channel: "instagram-reports")
                finishIGStatus("stopped")
                await reloadIGReport()
            } catch {
                igImportStatus = "Import failed: \(error)"
                finishIGStatus("failed")
                presentError("Report history import failed", error)
            }
            isImportingPeaceGrappler = false
        }
    }

    func cancelPeaceGrapplerImport() {
        igImportTask?.cancel()
    }

    func addIGIgnoredAccount(_ username: String) {
        let handle = username.trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
        guard let database, let accountID = igSelectedAccountID, !handle.isEmpty else { return }
        Task {
            try? await database.addIGIgnoredAccount(accountID: accountID, username: handle, reason: nil)
            await reloadIGReport()
        }
    }

    func removeIGIgnoredAccount(_ username: String) {
        guard let database, let accountID = igSelectedAccountID else { return }
        Task {
            try? await database.removeIGIgnoredAccount(accountID: accountID, username: username)
            await reloadIGReport()
        }
    }

    func igIgnoredAccounts() async -> [String] {
        guard let database, let accountID = igSelectedAccountID else { return [] }
        return (try? await database.fetchIGIgnoredAccounts(accountID: accountID)) ?? []
    }

    func selectInstagramAccount(_ id: Int64?) {
        igSelectedAccountID = id
        igReport = nil
        guard let account = igAccounts.first(where: { $0.id == id }) else {
            igMedia = []
            return
        }
        Task {
            try? await reloadIGMedia()
            await reloadIGReport()
            // Auto-refresh only when stale — the grid shows cache instantly.
            let stale = account.lastFetchedAt.map {
                Date().timeIntervalSince($0) > InstagramService.autoRefreshInterval
            } ?? true
            if stale && !isFetchingInstagram {
                refreshInstagram(username: account.username)
            }
        }
    }

    func addInstagramAccount(handle: String) {
        let username = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
        guard !username.isEmpty else { return }
        let ownHandle = activeProfile.socials["instagram"]?.handle
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) ?? ""
        let isOwn = username.caseInsensitiveCompare(ownHandle) == .orderedSame
            || username.caseInsensitiveCompare(settings.instagram.connectedUsername) == .orderedSame
        let kind = isOwn ? "own" : "public"
        guard let database else { return }
        Task {
            do {
                let id = try await database.upsertIGAccount(username: username, kind: kind,
                                                            displayName: nil, igUserID: nil, followers: nil)
                igAccounts = try await database.fetchIGAccounts()
                igSelectedAccountID = id
                igMedia = []
                refreshInstagram(username: username)
            } catch {
                presentError("Could not add the account", error)
            }
        }
    }

    func removeInstagramAccount(_ account: IGAccountRecord) {
        guard let database else { return }
        Task {
            try? await database.deleteIGAccount(id: account.id)
            igAccounts = (try? await database.fetchIGAccounts()) ?? []
            if igSelectedAccountID == account.id {
                igSelectedAccountID = igAccounts.first?.id
                igReport = nil
                try? await reloadIGMedia()
                await reloadIGReport()
            }
        }
    }

    /// The first refresh of the connected (or own) account backfills the
    /// peace-grappler report history automatically, then remembers it
    /// (`import_as_of` in ig_report_sync_state) and never auto-runs again.
    /// Only cancellation escapes — an import failure logs and the live
    /// refresh proceeds (it retries on the next refresh).
    private func autoImportPeaceGrapplerIfNeeded(username: String, database: Database) async throws {
        guard !isImportingPeaceGrappler,
              let account = igAccounts.first(where: { $0.username.caseInsensitiveCompare(username) == .orderedSame }),
              account.isOwn || settings.instagram.connectedUsername
                  .caseInsensitiveCompare(username) == .orderedSame else { return }
        let configured = settings.instagram.peaceGrapplerRepoPath.trimmingCharacters(in: .whitespaces)
        guard let repoPath = configured.isEmpty ? PeaceGrapplerImporter.defaultRepoPath() : configured else { return }
        let state = (try? await database.igSyncState(accountID: account.id)) ?? [:]
        guard state["import_as_of"] == nil else { return }   // imported once already — never again

        appendLog(\.igLog, ["First refresh — importing report history from \(repoPath)…"], channel: "instagram-reports")
        do {
            let summary = try await instagram.importPeaceGrapplerHistory(
                repoPath: repoPath, account: account, database: database, log: igLogSink(importScale: 0.3, channel: "instagram-reports"))
            igImportStatus = summary.description
            appendLog(\.igLog, [summary.description], channel: "instagram-reports")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            appendLog(\.igLog, ["History import failed (\(error)) — continuing with the live refresh; it retries next time"], channel: "instagram-reports")
        }
    }

    func downloadInstagramTraitFiles(account: IGAccountRecord) {
        guard let database, !isFetchingInstagram else { return }
        let configuration = settings.instagram
        isFetchingInstagram = true
        igLog = []
        igStatus = IGSyncStatus(title: "Reel traits", stage: "Downloading missing reels", fraction: 0)
        igFetchTask = Task {
            defer { isFetchingInstagram = false }
            do {
                try await instagram.computeReelTraits(account: account, database: database,
                    settings: configuration, downloadMissing: true, log: igLogSink())
                try await reloadIGMedia()
                await reloadIGBenchmarks()
                finishIGStatus("done")
            } catch is CancellationError {
                finishIGStatus("stopped")
            } catch {
                finishIGStatus("failed")
                presentError(error.localizedDescription)
            }
        }
    }

    func refreshInstagram(username: String) {
        guard let database, !isFetchingInstagram else { return }
        isFetchingInstagram = true
        igLog = []
        igStatus = IGSyncStatus(title: "Instagram Refresh", stage: "Starting — @\(username)", fraction: 0)
        let settings = settings.instagram
        let account = igAccounts.first { $0.username.caseInsensitiveCompare(username) == .orderedSame }
        let kind = account?.kind ?? "public"
        let instagram = instagram
        igFetchTask = Task {
            do {
                try await autoImportPeaceGrapplerIfNeeded(username: username, database: database)
                try await instagram.refreshAccount(username: username, kind: kind,
                                                   database: database, settings: settings,
                                                   limit: settings.fetchLimit, log: igLogSink())
                igAccounts = try await database.fetchIGAccounts()
                try await reloadIGMedia()
                await reloadIGReport()
                await reloadIGBenchmarks()
                finishIGStatus("done")
            } catch is CancellationError {
                appendLog(\.igLog, ["Fetch stopped."])
                finishIGStatus("stopped")
                await reloadIGReport()   // keep whatever the stopped sync stored
                await reloadIGBenchmarks()
            } catch {
                finishIGStatus("failed")
                // The history import phase may have written rows before the
                // live sync failed; a period change must not serve old inputs.
                await instagram.invalidateReportInputs()
                // InstagramError descriptions already carry the "Instagram
                // fetch failed" context; only other error types need it.
                if error is InstagramError {
                    presentError(error.userMessage)
                } else {
                    presentError("Instagram fetch failed", error)
                }
            }
            isFetchingInstagram = false
        }
    }

    func cancelInstagramFetch() {
        igFetchTask?.cancel()
    }

    /// Download (if needed) and AI-analyze one reel into a cached template.
    func analyzeInstagramTemplate(media: IGMediaRecord, force: Bool = false,
                                  provider: String? = nil, model: String? = nil) {
        guard let database,
              let account = igAccounts.first(where: { $0.id == media.accountID }),
              !igAnalyzingMediaIDs.contains(media.id) else { return }
        igAnalyzingMediaIDs.insert(media.id)
        let settings = settings.instagram
        let instagram = instagram
        igAnalyzeTasks[media.id] = Task {
            do {
                try await instagram.analyzeTemplate(media: media, account: account,
                                                    database: database, settings: settings,
                                                    force: force,
                                                    provider: provider, model: model, log: logSink(\.igLog, channel: "instagram-analysis"))
                igTemplatedMediaIDs.insert(media.id)
                // Pick up the local_video_path the download wrote.
                try? await reloadIGMedia()
            } catch {
                presentError("Template analysis failed", error)
            }
            igAnalyzingMediaIDs.remove(media.id)
            igAnalyzeTasks[media.id] = nil
        }
    }

    func cancelInstagramAnalysis(mediaID: Int64) {
        igAnalyzeTasks[mediaID]?.cancel()
    }

    /// Download a reel without analyzing it — enough for inline playback.
    /// Returns the local file URL, or nil on failure (error already shown).
    func downloadInstagramReel(media: IGMediaRecord) async -> URL? {
        guard let database,
              let account = igAccounts.first(where: { $0.id == media.accountID }) else { return nil }
        igDownloadingMediaIDs.insert(media.id)
        defer { igDownloadingMediaIDs.remove(media.id) }
        do {
            let url = try await instagram.ensureDownloaded(
                media: media, account: account, database: database,
                settings: settings.instagram, log: logSink(\.igLog, channel: "instagram-download"))
            try? await reloadIGMedia()
            return url
        } catch {
            presentError("Reel download failed", error)
            return nil
        }
    }

    /// The cached template analysis for a reel, decoded — nil if never analyzed.
    func instagramTemplate(mediaID: Int64) async -> ReelTemplate? {
        guard let database,
              let record = try? await database.fetchIGTemplate(mediaID: mediaID) else { return nil }
        return try? JSONDecoder().decode(ReelTemplate.self, from: Data(record.templateJSON.utf8))
    }
}
