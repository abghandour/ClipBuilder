import AppKit
import Foundation
import Network
import Observation

nonisolated enum TeamSyncSchedule {
    static func shouldRunAutomaticCycle(pendingChanges: Int, appActive: Bool) -> Bool {
        appActive && pendingChanges > 0
    }
}

@Observable
final class TeamSyncState {
    var email = ""
    var signedIn = false
    var busy = false
    var message: String?
    var teams: [TeamSyncTeam] = []
    var selectedTeamID: UUID?
    var remoteProfiles: [TeamSyncProfile] = []
    var selectedProfileID: UUID?
    var members: [TeamSyncMember] = []
    var inviteCode: String?
    var counts: [String: Int] = [:]
    var status = "Team sync"
    var paused = false
    var attached = false
    var syncing = false
    var attaching = false
    private var profileReplacements = 0
    var replacingProfile: Bool { profileReplacements > 0 }
    var assetMetadataRevision = 0
    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var auth: TeamSyncSession?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var automaticCycle: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cycleToken = UUID()
    @ObservationIgnored private var online = true
    @ObservationIgnored private var configuredURL: String?
    @ObservationIgnored private var configuredKey: String?
    let coordinator = TeamSyncCoordinator()

    private func session() throws -> TeamSyncSession {
        guard let store, let url = URL(string: store.settings.teamSyncURL), url.scheme == "https",
              !store.settings.teamSyncKey.isEmpty else {
            throw SyncError.invalidRow("Supabase publishable key is missing in Team settings")
        }
        if auth == nil || configuredURL != store.settings.teamSyncURL || configuredKey != store.settings.teamSyncKey {
            auth = TeamSyncSession(url: url, publishableKey: store.settings.teamSyncKey)
            configuredURL = store.settings.teamSyncURL
            configuredKey = store.settings.teamSyncKey
        }
        return auth!
    }

    func configure(store: AppStore, startImmediately: Bool = true) {
        self.store = store
        generation += 1
        let configuredGeneration = generation
        automaticCycle?.cancel()
        automaticCycle = nil
        cycleToken = UUID()
        timer?.cancel()
        monitor?.cancel()
        monitor = nil
        attached = store.activeProfile.teamID != nil && store.activeProfile.profileID != nil
        paused = store.activeProfile.teamSyncPaused ?? false
        selectedTeamID = store.activeProfile.teamID
        selectedProfileID = store.activeProfile.profileID
        remoteProfiles = []
        inviteCode = nil
        counts = [:]
        members = []
        message = nil
        syncing = false
        status = paused ? "Sync paused" : attached ? "Sync pending" : "Team sync"
        guard attached else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.generation == configuredGeneration else { return }
                let returned = !self.online && available
                self.online = available
                if returned { self.syncNow() }
                else if !available { await self.showOffline() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ClipBuilder.TeamSync.Network"))
        self.monitor = monitor
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                guard self.generation == configuredGeneration, !Task.isCancelled else { return }
                guard NSApp.isActive, let db = self.store?.database else { continue }
                let pending = (try? await db.syncPendingCount()) ?? 0
                guard self.generation == configuredGeneration, !Task.isCancelled else { return }
                if TeamSyncSchedule.shouldRunAutomaticCycle(pendingChanges: pending, appActive: NSApp.isActive) {
                    self.syncNow()
                }
            }
        }
        if startImmediately { syncNow() }
    }

    private func showOffline() async {
        guard attached, !paused, let db = store?.database else { return }
        let captured = generation
        let pending = (try? await db.syncPendingCount()) ?? 0
        guard captured == generation, !paused, !online else { return }
        status = "Offline · \(pending) changes waiting"
    }

    func restore() async {
        await action {
            if let value = try await self.session().restore() {
                self.signedIn = true
                self.email = value.email ?? ""
                try await self.loadTeams()
            }
        }
    }

    func sendCode() async {
        await action {
            try await self.session().sendCode(email: self.email.trimmingCharacters(in: .whitespacesAndNewlines))
            self.message = "Code sent. Check your email."
        }
    }

    func verify(code: String) async {
        await action {
            try await self.session().verify(email: self.email.trimmingCharacters(in: .whitespacesAndNewlines), code: code)
            self.signedIn = true
            self.message = "Signed in."
            try await self.loadTeams()
            self.syncNow()
        }
    }

    private func loadTeams() async throws {
        let client = try await session().client()
        teams = try await client.teams()
        if selectedTeamID == nil { selectedTeamID = teams.first?.id }
        try await loadTeamDetails()
    }

    func selectTeam() async {
        await action { try await self.loadTeamDetails() }
    }

    private func loadTeamDetails() async throws {
        guard let team = selectedTeamID else { return }
        let client = try await session().client()
        let profiles = try await client.profiles(teamID: team)
        guard team == selectedTeamID else { return }
        remoteProfiles = profiles.compactMap { row in
            guard let id = row["profile_id"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
            let document = row["document_json"]?.string.flatMap { try? JSONDecoder().decode(SyncMapping.WireRow.self, from: Data($0.utf8)) }
            return TeamSyncProfile(id: id, name: document?["brand_name"]?.string ?? "Shared profile")
        }
        selectedProfileID = store?.activeProfile.profileID ?? remoteProfiles.first?.id
        let loadedMembers = try await client.members(teamID: team)
        guard team == selectedTeamID else { return }
        members = loadedMembers
    }

    func createTeam(name: String) async {
        await action {
            let client = try await self.session().client()
            self.selectedTeamID = try await client.createTeam(name: name)
            try await self.loadTeams()
        }
    }

    func joinTeam(code: String) async {
        await action {
            guard let code = UUID(uuidString: code.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SyncError.invalidRow("invite code") }
            let client = try await self.session().client()
            self.selectedTeamID = try await client.redeemInvite(code: code)
            try await self.loadTeams()
        }
    }

    func createInvite(email: String) async {
        await action {
            guard let team = self.selectedTeamID else { return }
            let client = try await self.session().client()
            self.inviteCode = try await client.createInvite(teamID: team, email: email).uuidString
        }
    }

    func prepareAttachment() async -> Bool {
        guard let db = store?.database else { return false }
        do {
            counts = try await db.syncRowCounts()
            counts["profile_documents"] = 1
            return true
        } catch { message = error.localizedDescription; return false }
    }

    /// Called only after the row-count/privacy confirmation has dismissed.
    func attach() {
        guard let store, !attached, !attaching, !replacingProfile, let team = selectedTeamID, let db = store.database else { return }
        let profileID = selectedProfileID ?? store.activeProfile.profileID ?? UUID()
        let scope = SyncScope(teamID: team, profileID: profileID)
        let capturedGeneration = store.profileGeneration
        attaching = true
        store.jobs.start(.teamSync, title: "Attach profile to team", project: nil, profileGeneration: capturedGeneration,
                         subjectID: store.activeProfile.profileName, cleanup: { [weak self] in self?.attaching = false }) { [weak self] log in
            guard let self else { throw CancellationError() }
            log("Preparing brand knowledge…")
            let client = try await self.session().client()
            let version = try await client.schemaVersion()
            guard version <= SyncEngine.understoodSchemaVersion else { throw SyncError.needsUpdate(version) }
            guard version >= SyncEngine.understoodSchemaVersion else { throw SyncError.serverNotReady }
            try Task.checkCancellation()
            guard store.profileGeneration == capturedGeneration else { throw CancellationError() }
            try await db.bindSync(to: scope)
            guard store.profileGeneration == capturedGeneration else { throw CancellationError() }
            // Merge only attachment fields into the current profile, after awaits.
            store.activeProfile.profileID = profileID
            store.activeProfile.teamID = team
            store.activeProfile.teamSyncPaused = false
            store.saveActiveProfile()
            self.attached = true
            self.paused = false
            log("Uploading and merging brand knowledge…")
            do {
                try await self.performCycle(log: log)
                try Task.checkCancellation()
            } catch {
                if store.profileGeneration == capturedGeneration {
                    if error is CancellationError || Task.isCancelled { self.setPaused(true) }
                    let finalStatus = self.status
                    self.configure(store: store, startImmediately: false)
                    self.status = finalStatus
                }
                throw error
            }
            guard store.profileGeneration == capturedGeneration else { throw CancellationError() }
            let finalStatus = self.status
            self.configure(store: store, startImmediately: false)
            self.status = finalStatus
            log("Team sync ready")
            return nil
        }
    }

    func setPaused(_ value: Bool) {
        guard value || !replacingProfile else {
            paused = true
            return
        }
        paused = value
        store?.activeProfile.teamSyncPaused = value
        store?.saveActiveProfile()
        if value {
            automaticCycle?.cancel()
            Task {
                await store?.jobs.cancelAndWait(kind: .teamSync)
                await coordinator.cancelAndWait()
            }
            status = "Sync paused"
        } else { syncNow() }
    }

    /// The import must pair this with finishProfileReplacement, including on error or Stop.
    func suspendForProfileReplacement() async {
        profileReplacements += 1
        setPaused(true)
        await store?.jobs.cancelAndWait(kind: .teamSync)
        await automaticCycle?.value
        await coordinator.cancelAndWait()
    }

    func finishProfileReplacement() {
        profileReplacements -= 1
    }

    func syncNow() {
        guard attached, !paused, !attaching, !replacingProfile, automaticCycle == nil else { return }
        let token = UUID()
        let captured = generation
        cycleToken = token
        automaticCycle = Task { [weak self] in
            guard let self else { return }
            defer { if self.cycleToken == token { self.automaticCycle = nil } }
            guard self.generation == captured, let store = self.store, let db = store.database else { return }
            let backlog = (try? await db.initialSyncPending()) ?? false
            guard self.generation == captured, !self.paused, !self.attaching else { return }
            self.attaching = true
            store.jobs.start(.teamSync, title: backlog ? "Upload and merge team footage" : "Team sync",
                             project: nil, profileGeneration: store.profileGeneration,
                             subjectID: store.activeProfile.profileName,
                             cleanup: { [weak self] in self?.attaching = false }) { [weak self] log in
                guard let self, self.generation == captured else { throw CancellationError() }
                do { try await self.performCycle(log: log) }
                catch {
                    if self.generation == captured {
                        self.message = error.localizedDescription
                        if error is CancellationError || Task.isCancelled { self.setPaused(true) }
                    }
                    throw error
                }
                return nil
            }
        }
    }

    private func performCycle(log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard let store, let db = store.database, let team = store.activeProfile.teamID,
              let profile = store.activeProfile.profileID, !paused, !replacingProfile else { throw CancellationError() }
        let captured = generation
        let snapshot = store.activeProfile
        let auth = try session()
        let scope = SyncScope(teamID: team, profileID: profile)
        syncing = true
        status = "Syncing…"
        defer {
            if captured == generation {
                syncing = false
                // Queue the latest UI edits after adoption, including edits made
                // while the asset/report work was awaiting another actor.
                store.saveActiveProfile()
            }
        }
        do {
            let client = try await auth.client()
            let engine = SyncEngine(database: db, client: client, scope: scope)
            let admitted = try await coordinator.run {
                try await db.saveSyncProfile(snapshot)
                try await engine.sync(log: log)
                try Task.checkCancellation()
                try await self.adoptSyncedProfile(database: db, generation: captured)
                try await engine.resolveAssets()
            }
            guard admitted else { throw SyncError.alreadySyncing }
            try Task.checkCancellation()
            let count = try await db.syncPendingCount()
            guard captured == generation else { throw CancellationError() }
            status = count == 0 ? "Synced" : "\(count) changes waiting"
            signedIn = true
            let changed = await engine.changedTables
            guard captured == generation else { throw CancellationError() }
            if changed.contains("wizard_lessons") {
                await store.refreshLessons(from: db, generation: store.profileGeneration)
            }
            if changed.contains("people") {
                let people = try await db.fetchPeople()
                guard captured == generation else { throw CancellationError() }
                store.people = people
            }
            if changed.contains("library_asset_metadata") { assetMetadataRevision += 1 }
            if changed.contains(where: { name in SyncTable.footage.contains { $0.name == name } }) {
                await store.refreshAllNow()
                let defaults = try await db.consumeSyncedRunDefaults()
                guard captured == generation else { throw CancellationError() }
                if !defaults.isEmpty {
                    if store.sceneRunSelection.isEmpty {
                        store.sceneRunSelection = Set(store.analysisRuns.filter { defaults[$0.videoID] == nil }.map(\.id))
                    }
                    store.sceneRunSelection.formUnion(defaults.values.filter { id in store.analysisRuns.contains { $0.id == id } })
                    store.projectStateVersion += 1
                    store.scheduleProjectStateSave()
                }
            }
            if changed.contains(where: { $0.hasPrefix("ig_") || $0 == "reel_traits" || $0 == "reel_outcomes" }) {
                await store.refreshSyncedInstagram(database: db)
            }
        } catch {
            guard captured == generation else { throw error }
            if case SyncError.needsUpdate = error { status = "Sync needs update" }
            else if error is CancellationError || Task.isCancelled { status = paused ? "Sync paused" : "Sync stopped" }
            else if error is URLError { online = false; await showOffline() }
            else { status = "Sync needs attention" }
            throw error
        }
    }

    private func adoptSyncedProfile(database: Database, generation captured: Int) async throws {
        guard let adoption = try await database.syncProfileAdoption() else { return }
        try Task.checkCancellation()
        guard captured == generation, let store else { throw CancellationError() }
        let merged = try TeamProfileDocument.merging(adoption.document, into: store.activeProfile,
                                                      baseline: adoption.baseline)
        // No suspension between merging the current UI, saving, and adopting it.
        // A failed save leaves the durable upload gate closed.
        try ProfileStore.save(merged)
        store.activeProfile = merged
        if let index = store.profiles.firstIndex(where: { $0.profileName == merged.profileName }) {
            store.profiles[index] = merged
        }
        try await database.completeSyncProfileAdoption(merged)
    }

    func signOut() async {
        await action {
            self.setPaused(true)
            for job in self.store?.jobs.running ?? [] where job.kind == .teamSync {
                self.store?.jobs.cancel(job.id)
            }
            await self.coordinator.cancelAndWait()
            try await self.session().signOut()
            self.signedIn = false
            self.teams = []
            self.members = []
            self.setPaused(true)
            self.status = "Team signed out"
        }
    }

    private func action(_ body: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do { try await body() }
        catch { message = error.localizedDescription }
    }
}
