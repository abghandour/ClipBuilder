import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Timeline termination persistence")
struct TimelineTerminationTests {
    private func makeStore(_ temp: TempDatabase) async throws -> AppStore {
        let profile = Fixtures.brand(name: "TimelineTerminationTests")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Project")
        let id = try await temp.database.createTimeline(projectID: project, name: "Timeline")
        store.activeProjectID = project
        store.openTimelineRecord(try #require(try await temp.database.fetchTimeline(id: id)))
        return store
    }

    @Test("Quitting after autosave does not reject the already persisted revision")
    func repeatedFlush() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        store.builder.addText()
        await store.flushForTermination()
        let id = try #require(store.builder.timelineID)
        let saved = try #require(try await temp.database.fetchTimeline(id: id))
        #expect(store.errorQueue.isEmpty)
        await store.flushForTermination()
        #expect(store.errorQueue.isEmpty)
        #expect(try await temp.database.fetchTimeline(id: id)?.documentRevision == saved.documentRevision)
        #expect(try await temp.database.fetchTimeline(id: id)?.documentJSON == saved.documentJSON)
    }

    @Test("Overlapping flushes drain the same revision once and preserve subsequent edits")
    func overlappingFlushes() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        store.builder.addText()
        async let first: Void = store.flushForTermination()
        async let second: Void = store.flushForTermination()
        _ = await (first, second)
        #expect(store.errorQueue.isEmpty)
        store.builder.addText()
        await store.flushForTermination()
        let id = try #require(store.builder.timelineID)
        let row = try #require(try await temp.database.fetchTimeline(id: id))
        #expect(row.documentRevision == store.builder.revision)
        let persisted = try JSONDecoder().decode(TimelineDocument.self, from: Data(row.documentJSON.utf8))
        #expect(persisted.textOverlays.count == 2)
        #expect(store.errorQueue.isEmpty)
    }
}
