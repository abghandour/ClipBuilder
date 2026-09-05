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
        let scope = try DataFolderOverride()
        _ = scope
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
        let scope = try DataFolderOverride()
        _ = scope
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
        let scope = try DataFolderOverride()
        _ = scope
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
        let scope = try DataFolderOverride()
        _ = scope
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
        let scope = try DataFolderOverride()
        _ = scope
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
}
