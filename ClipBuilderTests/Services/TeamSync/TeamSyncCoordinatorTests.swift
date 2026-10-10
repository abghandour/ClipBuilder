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
    @Test("Profile save seeds only after initial sync and only without a team editing document",
          arguments: [false, true], [false, true])
    @MainActor
    func editingDefaultsSeeding(initialComplete: Bool, remoteHasEditing: Bool) async throws {
        let folder = try SyncTestFolder()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        var profile = BrandProfile(name: "Editing seed \(UUID().uuidString)")
        profile.profileID = scope.profileID
        profile.teamID = scope.teamID
        profile.sourceFolder = folder.url.appendingPathComponent("Input").path
        profile.outputFolder = folder.url.appendingPathComponent("Output").path
        defer { try? ProfileStore.delete(name: profile.profileName) }
        try await folder.database.bindSync(to: scope)
        var remote = profile
        if remoteHasEditing {
            remote.editing = ProfileEditingDefaults()
            remote.editing?.podcast.deadAirSeconds = 4.5
        }
        try await folder.database.saveSyncProfile(remote)
        if initialComplete { try await folder.database.completeInitialSync() }
        var settings = AppSettings()
        settings.podcast.deadAirSeconds = 2.75
        settings.transcribeLanguage = "pt-BR"
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: folder.database)
        // Neither construction nor a fallback read may materialize editing.
        #expect(store.editingDefaults.podcast.deadAirSeconds == 2.75)
        #expect(store.activeProfile.editing == nil)
        await store.saveActiveProfile()?.value
        let expected = initialComplete && !remoteHasEditing
            ? ProfileEditingDefaults(seedingFrom: settings) : nil
        #expect(store.activeProfile.editing == expected)
        #expect(store.profiles.first?.editing == expected)
        #expect(ProfileStore.load(name: profile.profileName)?.editing == expected)
        if remoteHasEditing {
            let json = try #require(try await folder.database.syncedProfileDocument())
            #expect(try TeamProfileDocument.applying(json, to: profile).editing == remote.editing)
        }
    }

    @Test("Team save waits for a database and first reconciliation")
    @MainActor
    func editingDefaultsWithoutSyncState() throws {
        let scope = try DataFolderOverride()
        _ = scope
        var profile = BrandProfile(name: "Waiting for team")
        profile.teamID = UUID()
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile,
                             ai: AIService(config: AIConfig()))
        #expect(store.saveActiveProfile() == nil)
        #expect(store.activeProfile.editing == nil)
        #expect(ProfileStore.load(name: profile.profileName)?.editing == nil)
    }

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
