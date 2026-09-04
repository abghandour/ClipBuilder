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
}
