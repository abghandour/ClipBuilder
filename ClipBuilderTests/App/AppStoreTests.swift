import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("App store", .serialized)
struct AppStoreTests {
    private func makeStore(profiles: [BrandProfile]? = nil) -> AppStore {
        let profiles = profiles ?? [Fixtures.brand(name: "One")]
        let settings = AppSettings()
        return AppStore(settings: settings, profiles: profiles, active: profiles[0],
                        ai: AIService(config: settings.ai))
    }

    @Test("errors queue in order and cancellation is dropped")
    func errorQueue() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        store.presentError("first")
        store.presentError("second")
        store.presentError("cancelled", CancellationError())
        #expect(store.currentError?.message == "first")
        store.dismissCurrentError()
        #expect(store.currentError?.message == "second")
        store.dismissCurrentError()
        #expect(store.currentError == nil)
    }

    @Test("scene writes rebuild the index and bump the version")
    func scenesRebuildIndex() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        let version = store.scenesVersion
        store.scenes = [Fixtures.scene()]
        #expect(store.scenesVersion == version + 1)
        #expect(store.sceneIndex.countsByVideo[1] == 1)
        #expect(store.sceneIndex.allTags == ["fixture"])
    }

    @Test("regression: profile switch bumps generation and clears profile-owned rows")
    func switchProfileIsolation() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let profiles = [Fixtures.brand(name: "One"), Fixtures.brand(name: "Two")]
        let store = makeStore(profiles: profiles)
        store.videos = [Fixtures.video()]
        store.scenes = [Fixtures.scene()]
        store.people = [PersonRecord(id: 1, key: "person", name: "Person", descriptor: "")]
        let generation = store.profileGeneration

        store.switchProfile(named: "Two")

        #expect(store.activeProfile.profileName == "Two")
        #expect(store.profileGeneration == generation + 1)
        #expect(store.videos.isEmpty)
        #expect(store.scenes.isEmpty)
        #expect(store.people.isEmpty)
    }

    @Test("regression: a library fetch that started under the previous profile is ignored")
    func staleGenerationIgnored() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let profiles = [Fixtures.brand(name: "One"), Fixtures.brand(name: "Two")]
        let store = makeStore(profiles: profiles)
        let staleGeneration = store.profileGeneration
        let snapshot = Fixtures.snapshot(videos: [Fixtures.video()], scenes: [Fixtures.scene()])

        // The fetch completes after the profile moved on: its rows belong
        // to "One" and must not land in "Two".
        store.switchProfile(named: "Two")
        store.applyLibrarySnapshot(snapshot, generation: staleGeneration)
        #expect(store.videos.isEmpty)
        #expect(store.scenes.isEmpty)

        // The same snapshot with the current generation applies normally.
        store.applyLibrarySnapshot(snapshot, generation: store.profileGeneration)
        #expect(store.videos.count == 1)
        #expect(store.scenes.count == 1)
    }

    @Test("comparison batches queue oldest first and advance on resolve")
    func comparisonQueueIsFIFO() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        store.generatedVideos = [
            Fixtures.generatedVideo(id: 1),                    // older, no batch
            Fixtures.generatedVideo(id: 5, batchID: "later"),
            Fixtures.generatedVideo(id: 6, batchID: "later"),
            Fixtures.generatedVideo(id: 3, batchID: "earlier"),
            Fixtures.generatedVideo(id: 4, batchID: "earlier"),
            Fixtures.generatedVideo(id: 7, batchID: "single"),  // one video: nothing to compare
        ]
        store.queueComparisons(previousIDs: [1])

        #expect(store.pendingComparison?.id == "earlier")
        #expect(store.pendingComparison?.videos.map(\.id) == [3, 4])

        let first = try #require(store.pendingComparison)
        store.resolveComparison(first, winner: nil)
        #expect(store.pendingComparison?.id == "later")
        #expect(store.pendingComparison?.videos.map(\.id) == [5, 6])

        let second = try #require(store.pendingComparison)
        store.resolveComparison(second, winner: nil)
        #expect(store.pendingComparison == nil)
    }

    @Test("regression: switching projects does not invalidate the profile generation")
    func projectSwitchKeepsProfileGeneration() async throws {
        let temp = try TempDatabase()
        try await temp.database.ensureDefaultProject(profileName: "One", legacyTimelineJSON: nil)
        let other = try await temp.database.createProject(profileName: "One", name: "Other")
        let profile = Fixtures.brand(name: "One")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        await store.initializeProjectWorkspace()
        // The newest project is the "last opened" one, so launch lands on
        // it; switch to whichever project is not active.
        let homeID = try #require(try await temp.database.homeProjectID(profileName: "One"))
        let target = store.activeProjectID == other ? homeID : other
        let generation = store.profileGeneration
        let stateVersion = store.projectStateVersion
        await store.selectProject(target)?.value
        #expect(store.activeProjectID == target)
        #expect(store.profileGeneration == generation)
        #expect(store.projectStateVersion == stateVersion + 1)
        #expect(!store.isLoadingProject)
    }

    @Test("regression: a project with a job in flight cannot be deleted")
    func busyProjectCannotBeDeleted() async throws {
        let temp = try TempDatabase()
        try await temp.database.ensureDefaultProject(profileName: "One", legacyTimelineJSON: nil)
        let busy = try await temp.database.createProject(profileName: "One", name: "Busy")
        let profile = Fixtures.brand(name: "One")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        await store.initializeProjectWorkspace()
        store.isBuilderRendering = true
        store.builderRenderProjectID = busy
        #expect(store.busyProjectIDs == [busy])
        let record = try #require(store.projects.first { $0.id == busy })
        store.deleteProject(record, moveTimelinesToHome: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await temp.database.fetchProjects().contains { $0.id == busy })
        #expect(store.currentError != nil)
    }

    @Test("timelines switch and cycle within the project; wizard rows are skipped")
    func timelineSwitching() async throws {
        let temp = try TempDatabase()
        try await temp.database.ensureDefaultProject(profileName: "One", legacyTimelineJSON: nil)
        let homeID = try #require(try await temp.database.homeProjectID(profileName: "One"))
        // Real clips: the playhead clamps to the timeline's length on open.
        let documentJSON = try #require(String(data: JSONEncoder().encode(Fixtures.timelineDocument()),
                                              encoding: .utf8))
        let first = try await temp.database.createTimeline(projectID: homeID, name: "First",
                                                           documentJSON: documentJSON)
        let second = try await temp.database.createTimeline(projectID: homeID, name: "Second",
                                                            documentJSON: documentJSON)
        _ = try await temp.database.createTimeline(projectID: homeID, name: "Wizard · run", kind: "wizard",
                                                   documentJSON: "{}")
        let profile = Fixtures.brand(name: "One")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        await store.initializeProjectWorkspace()
        await store.selectProject(homeID)?.value
        #expect(store.switchableTimelines.map(\.id) == [first, second]
                    || store.switchableTimelines.map(\.id) == [second, first])

        // Scene clips get their length from the scene on open.
        store.builder.updateScenes([Fixtures.scene()])
        let firstRecord = try #require(store.timelines.first { $0.id == first })
        store.openTimelineRecord(firstRecord)
        #expect(store.openTimelineID == first)
        #expect(store.builder.totalDuration == 4)
        store.cycleTimeline(offset: 1)
        #expect(store.openTimelineID == second)
        store.cycleTimeline(offset: 1)
        #expect(store.openTimelineID == first, "cycling wraps and never lands on the wizard row")
        store.switchTimeline(to: try #require(store.timelines.first { $0.id == second }))
        #expect(store.openTimelineID == second)
        #expect(store.selectedSection == .timelines)

        // Viewport is per timeline: scrub and zoom the second, switch away
        // and back, and it is where it was left; the first is untouched.
        store.builder.playhead = 3
        store.builder.pointsPerSecond = 90
        store.timelineScrollX = 240
        store.switchTimeline(to: firstRecord)
        #expect(store.builder.playhead == 0)
        #expect(store.builder.pointsPerSecond == 60)
        store.switchTimeline(to: try #require(store.timelines.first { $0.id == second }))
        #expect(store.builder.playhead == 3)
        #expect(store.builder.pointsPerSecond == 90)
        #expect(store.timelineScrollX == 240)
        try await Task.sleep(for: .milliseconds(200))
        let stored = try #require(try await temp.database.fetchTimelines(projectID: homeID)
            .first { $0.id == second }?.viewState)
        #expect(stored.playhead == 3 && stored.zoom == 90 && stored.scrollX == 240)
    }

    @Test("launch restores the most recently opened project and its UI state")
    func restoresLastProject() async throws {
        let temp = try TempDatabase()
        try await temp.database.ensureDefaultProject(profileName: "One", legacyTimelineJSON: nil)
        let projectID = try await temp.database.createProject(profileName: "One", name: "Last Project")
        let state = ProjectUIState(
            section: "outputs",
            outputsSort: "Longest",
            outputsScrollID: 42,
            timelineScrollX: 180,
            timelineScrollY: 32
        )
        let stateJSON = String(data: try JSONEncoder().encode(state), encoding: .utf8) ?? "{}"
        try await temp.database.saveProjectUIState(id: projectID, json: stateJSON)
        try await temp.database.touchProject(id: projectID)

        let profile = Fixtures.brand(name: "One")
        let settings = AppSettings()
        let store = AppStore(
            settings: settings,
            profiles: [profile],
            active: profile,
            ai: AIService(config: settings.ai),
            database: temp.database
        )
        await store.initializeProjectWorkspace()

        #expect(store.activeProjectID == projectID)
        #expect(store.selectedSection == .outputs)
        #expect(store.outputsSort == "Longest")
        #expect(store.outputsScrollID == 42)
        #expect(store.timelineScrollX == 180)
        #expect(store.timelineScrollY == 32)
    }

    @Test("launch falls back to Home after the last project is deleted")
    func deletedLastProjectFallsBackHome() async throws {
        let temp = try TempDatabase()
        try await temp.database.ensureDefaultProject(profileName: "One", legacyTimelineJSON: nil)
        let homeID = try #require(try await temp.database.homeProjectID(profileName: "One"))
        let projectID = try await temp.database.createProject(profileName: "One", name: "Gone")
        try await temp.database.touchProject(id: projectID)
        try await temp.database.deleteProject(id: projectID)

        let profile = Fixtures.brand(name: "One")
        let settings = AppSettings()
        let store = AppStore(
            settings: settings,
            profiles: [profile],
            active: profile,
            ai: AIService(config: settings.ai),
            database: temp.database
        )
        await store.initializeProjectWorkspace()

        #expect(store.activeProjectID == homeID)
        #expect(store.activeProject?.isHome == true)
    }

    @Test("Connect confirms flavor and stores the appropriate token dates", arguments: ["IGtest-token", "EAAtest-token"])
    func instagramConnect(token: String) async throws {
        let transport = InstagramTestTransport([
            "graph.instagram.com/me": .json(#"{"user_id":"ig-123","id":"app-scoped","username":"peacegrappler","account_type":"BUSINESS"}"#),
            "graph.facebook.com/me/accounts": .json(#"{"data":[{"instagram_business_account":{"id":"ig-123","username":"peacegrappler"}}]}"#),
        ])
        let graph = transport.provider(accessToken: token)
        defer { transport.finish(graph) }
        let store = makeStore()
        // Connecting a Facebook token also clears any previous Instagram lifecycle dates.
        store.settings.instagram.tokenFlavor = "instagram"
        store.settings.instagram.tokenRefreshedAt = .distantPast
        store.settings.instagram.tokenExpiresAt = .distantFuture
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        var writes: [(String, String)] = []
        let task = try #require(store.connectInstagram(token: " \(token)\n", session: graph.session,
            saveToken: { value, account in writes.append((value, account)) }, now: instant))
        await task.value
        let isInstagram = token.hasPrefix("IG")
        #expect(store.currentError == nil)
        #expect(!store.isConnectingInstagram)
        #expect(store.settings.instagram.connectedUsername == "peacegrappler")
        #expect(store.settings.instagram.connectedIGUserID == "ig-123")
        #expect(store.settings.instagram.tokenFlavor == (isInstagram ? "instagram" : "facebook"))
        #expect(store.settings.instagram.tokenRefreshedAt == (isInstagram ? instant : nil))
        #expect(store.settings.instagram.tokenExpiresAt == (isInstagram ? instant.addingTimeInterval(60 * 86400) : nil))
        #expect(writes.count == 1)
        #expect(writes.first?.0 == token)
        #expect(writes.first?.1 == "instagram_graph_token")
        #expect(transport.requests.map { $0.url?.host } == [isInstagram ? "graph.instagram.com" : "graph.facebook.com"])
    }

    @Test("Connect recovers a misleading token prefix with one other-host probe", arguments: ["IGmis-prefixed", "EAAmis-prefixed"])
    func instagramConnectSecondProbe(token: String) async throws {
        let firstInstagram = token.hasPrefix("IG")
        let denied = InstagramTestTransport.Reply.json(#"{"error":{"code":190,"message":"Wrong host"}}"#)
        let transport = InstagramTestTransport([
            "graph.instagram.com/me": firstInstagram ? denied : .json(#"{"user_id":"ig-123","username":"peacegrappler","account_type":"MEDIA_CREATOR"}"#),
            "graph.facebook.com/me/accounts": firstInstagram ? .json(#"{"data":[{"instagram_business_account":{"id":"ig-123","username":"peacegrappler"}}]}"#) : denied,
        ])
        let graph = transport.provider(accessToken: token)
        defer { transport.finish(graph) }
        let store = makeStore()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        await store.connectInstagram(token: token, session: graph.session, saveToken: { _, _ in }, now: instant)?.value
        #expect(store.currentError == nil)
        #expect(store.settings.instagram.tokenFlavor == (firstInstagram ? "facebook" : "instagram"))
        #expect(store.settings.instagram.tokenRefreshedAt == (firstInstagram ? nil : instant))
        #expect(store.settings.instagram.tokenExpiresAt == (firstInstagram ? nil : instant.addingTimeInterval(60 * 86400)))
        #expect(transport.requests.map { $0.url?.host } == (firstInstagram
            ? ["graph.instagram.com", "graph.facebook.com"] : ["graph.facebook.com", "graph.instagram.com"]))
    }

    @Test("Two failed probes report the detected-flavor error and never persist")
    func instagramConnectBothFail() async throws {
        let transport = InstagramTestTransport([
            "graph.instagram.com/me": .json(#"{"user_id":"ig-123","username":"personal","account_type":"PERSONAL"}"#),
            "graph.facebook.com/me/accounts": .json(#"{"error":{"code":190,"message":"Wrong Facebook host"}}"#),
        ])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let store = makeStore()
        await store.connectInstagram(token: "IGpersonal", session: graph.session,
            saveToken: { _, _ in Issue.record("Failed probes must not persist") })?.value
        #expect(!store.settings.instagram.isGraphConnected)
        #expect(!store.isConnectingInstagram)
        #expect(store.currentError?.message.contains("switch it to Business or Creator") == true)
        #expect(store.currentError?.message.contains("Wrong Facebook host") == false)
        #expect(transport.requests.count == 2)
    }

    @Test("Refresh writes the same Keychain account and persists both live dates")
    func instagramRefreshPersistence() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        var original = InstagramSettings()
        original.connectedUsername = "peacegrappler"
        original.connectedIGUserID = "ig-123"
        original.tokenFlavor = "instagram"
        original.tokenRefreshedAt = Date(timeIntervalSince1970: 1_799_000_000)
        store.settings.instagram = original
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let refresh = InstagramTokenRefresh(token: "IGnew", refreshedAt: instant,
                                            expiresAt: instant.addingTimeInterval(123456))
        var keychain = "IGold"
        let saved = try store.applyInstagramTokenRefresh(refresh, settings: original, replacing: "IGold",
            readToken: { account in
                #expect(account == "instagram_graph_token")
                return keychain
            }, saveToken: { value, account in
                #expect(account == "instagram_graph_token")
                keychain = value
            })
        #expect(saved)
        #expect(keychain == "IGnew")
        #expect(store.settings.instagram.tokenRefreshedAt == instant)
        #expect(store.settings.instagram.tokenExpiresAt == refresh.expiresAt)
        let persisted = SettingsStore.loadSettings().instagram
        #expect(persisted.tokenRefreshedAt == instant)
        #expect(persisted.tokenExpiresAt == refresh.expiresAt)
    }

    @Test("A stale refresh cannot overwrite a disconnected or replaced connection", arguments: ["disconnect", "account", "reconnect", "token"])
    func instagramStaleRefresh(change: String) throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        var original = InstagramSettings()
        original.connectedUsername = "peacegrappler"
        original.connectedIGUserID = "ig-123"
        original.tokenFlavor = "instagram"
        original.tokenRefreshedAt = .distantPast
        store.settings.instagram = original
        switch change {
        case "disconnect": store.settings.instagram.connectedUsername = ""
        case "account": store.settings.instagram.connectedIGUserID = "other-id"
        case "reconnect": store.settings.instagram.tokenRefreshedAt = Date()
        default: break
        }
        let refresh = InstagramTokenRefresh(token: "IGnew", refreshedAt: Date(), expiresAt: .distantFuture)
        let saved = try store.applyInstagramTokenRefresh(refresh, settings: original, replacing: "IGold",
            readToken: { _ in change == "token" ? "IGanother" : "IGold" },
            saveToken: { _, _ in Issue.record("Stale refresh must not write the Keychain") })
        #expect(!saved)
        #expect(store.settings.instagram.tokenExpiresAt == nil)
    }

    @Test("Refresh Keychain errors leave both dates untouched")
    func instagramRefreshWriteFailure() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        var original = InstagramSettings()
        original.connectedUsername = "peacegrappler"
        original.connectedIGUserID = "ig-123"
        original.tokenFlavor = "instagram"
        original.tokenRefreshedAt = .distantPast
        store.settings.instagram = original
        let refresh = InstagramTokenRefresh(token: "IGnew", refreshedAt: Date(), expiresAt: .distantFuture)
        do {
            _ = try store.applyInstagramTokenRefresh(refresh, settings: original, replacing: "IGold",
                readToken: { _ in "IGold" }, saveToken: { _, _ in throw InstagramError.fetchFailed("Keychain denied") })
            Issue.record("Expected a Keychain error")
        } catch {}
        #expect(store.settings.instagram.tokenRefreshedAt == original.tokenRefreshedAt)
        #expect(store.settings.instagram.tokenExpiresAt == nil)
    }

}
