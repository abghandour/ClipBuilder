import Foundation
import Testing
@testable import Clip_Builder

@Suite("Builder run persistence")
struct BuilderRunPersistenceTests {
    private actor WriterStartGate {
        private var waiting: CheckedContinuation<Void, Never>?

        func wait() async {
            if let waiting {
                self.waiting = nil
                waiting.resume()
            } else {
                await withCheckedContinuation { waiting = $0 }
            }
        }
    }

    private func timeline(_ temp: TempDatabase) async throws -> Int64 {
        let project = try await temp.database.createProject(profileName: "Test", name: "Project")
        return try await temp.database.createTimeline(projectID: project, name: "Timeline")
    }

    @Test("Run CRUD retains immutable audit and distinguishes all statuses")
    func runCRUD() async throws {
        let temp = try TempDatabase()
        let id = try await timeline(temp)
        var run = BuilderRunRecord(runUUID: UUID().uuidString, timelineID: id, request: "Cut pauses",
                                   provider: "local", model: "parser", durationSeconds: 0.25, status: .completed,
                                   baselineRevision: 4, summary: "Two cuts", libraryEffectsJSON: "[]", eventsJSON: "[]")
        try await temp.database.recordBuilderRun(run)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id, limit: 1) == [run])
        run.status = .applied
        run.appliedRevision = 5
        try await temp.database.recordBuilderRun(run)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id) == [run])
        try await temp.database.updateBuilderRunStatus(runUUID: run.runUUID, status: .reverted)
        run.status = .reverted
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id) == [run])
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id, limit: 0).isEmpty)
    }

    @Test("Retention stays at 50 and protects the oldest referenced run")
    func retention() async throws {
        let temp = try TempDatabase()
        let id = try await timeline(temp)
        let protected = BuilderRunRecord(runUUID: "protected", timelineID: id, request: "Old",
                                         createdAt: "2000-01-01", status: .applied, baselineRevision: 0)
        try await temp.database.recordBuilderRun(protected)
        try await temp.database.saveWizardBefore(WizardBeforeRecord(timelineID: id, runUUID: protected.runUUID,
                                                                    request: "Old", documentJSON: "{}", appliedRevision: 1))
        for index in 0..<65 {
            try await temp.database.recordBuilderRun(BuilderRunRecord(runUUID: "run-\(index)", timelineID: id,
                                                                       request: "Failed", status: .failed, baselineRevision: 1))
        }
        let rows = try await temp.database.fetchBuilderRuns(timelineID: id, limit: 100)
        #expect(rows.count == 50)
        #expect(rows.contains { $0.runUUID == protected.runUUID })
        #expect(rows.contains { $0.runUUID == "run-64" })
        #expect(!rows.contains { $0.runUUID == "run-0" })
    }

    @Test("Before-version is ordinary JSON and both tables cascade on timeline deletion")
    func beforeRoundTripAndCascade() async throws {
        let temp = try TempDatabase()
        let id = try await timeline(temp)
        let document = Fixtures.timelineDocument()
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let before = WizardBeforeRecord(timelineID: id, runUUID: "run", request: "Request",
                                         documentJSON: json, appliedRevision: 7)
        try await temp.database.recordBuilderRun(BuilderRunRecord(runUUID: "run", timelineID: id,
                                                                   request: "Request", status: .applied, baselineRevision: 6))
        try await temp.database.saveWizardBefore(before)
        let read = try #require(try await temp.database.fetchWizardBefore(timelineID: id))
        #expect(read == before)
        let ordinary = try JSONDecoder().decode(TimelineDocument.self, from: Data(read.documentJSON.utf8))
        #expect(ordinary.videoTrack.count == document.videoTrack.count)
        #expect(ordinary.videoTrack[0].uid != document.videoTrack[0].uid)
        try await temp.database.deleteWizardBefore(timelineID: id)
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == nil)
        try await temp.database.saveWizardBefore(before)
        try await temp.database.deleteTimeline(id: id)
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == nil)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id).isEmpty)
    }

    @Test("Concurrent autosave and Wizard commit cannot claim the same revision", arguments: 0..<10)
    func concurrentAutosaveAndCommit(iteration: Int) async throws {
        let temp = try TempDatabase()
        let id = try await timeline(temp)
        let database = temp.database
        let gate = WriterStartGate()
        let run = BuilderRunRecord(runUUID: "race-\(iteration)", timelineID: id, request: "Request",
                                   status: .applied, baselineRevision: 0, appliedRevision: 1)
        let before = WizardBeforeRecord(timelineID: id, runUUID: run.runUUID, request: "Request",
                                         documentJSON: "{}", appliedRevision: 1)
        let autosave = Task.detached {
            await gate.wait()
            do {
                try await database.saveTimelineRevision(id: id, documentJSON: "{\"autosave\":true}",
                                                        revision: 1, thumbnailVideoID: nil,
                                                        runUUID: nil, status: nil)
                return true
            } catch ApplyFailure.staleRevision { return false }
        }
        let commit = Task.detached {
            await gate.wait()
            do {
                try database.commitWizardSnapshot(timelineID: id, documentJSON: "{\"wizard\":true}",
                                                   expectedRevision: 0, revision: 1, thumbnailVideoID: nil,
                                                   run: run, before: before)
                return true
            } catch ApplyFailure.staleRevision { return false }
        }
        // Join both writers even if one reports an unexpected SQLite error.
        let autosaveResult = await autosave.result
        let commitResult = await commit.result
        let autosaveWon = try autosaveResult.get()
        let commitWon = try commitResult.get()
        #expect(autosaveWon != commitWon)
        let row = try #require(try await database.fetchTimeline(id: id))
        #expect(row.documentRevision == 1)
        #expect(row.documentJSON == (commitWon ? "{\"wizard\":true}" : "{\"autosave\":true}"))
        #expect(try await database.fetchBuilderRuns(timelineID: id) == (commitWon ? [run] : []))
        #expect(try await database.fetchWizardBefore(timelineID: id) == (commitWon ? before : nil))
    }

    @Test("An autosave at the committed revision cannot overwrite the Wizard snapshot")
    func equalRevisionAutosaveIsStale() async throws {
        let temp = try TempDatabase()
        let id = try await timeline(temp)
        try temp.database.commitWizardSnapshot(timelineID: id, documentJSON: "{\"wizard\":true}",
                                                expectedRevision: 0, revision: 1, thumbnailVideoID: nil,
                                                run: nil, before: nil)
        do {
            try await temp.database.saveTimelineRevision(id: id, documentJSON: "{\"autosave\":true}",
                                                         revision: 1, thumbnailVideoID: nil,
                                                         runUUID: nil, status: nil)
            Issue.record("Expected equal-revision autosave refusal")
        } catch { #expect(error as? ApplyFailure == .staleRevision) }
        #expect(try await temp.database.fetchTimeline(id: id)?.documentJSON == "{\"wizard\":true}")
    }

    @Test("CAS and a failure after timeline write roll back the entire commit")
    func rollback() async throws {
        let temp = try TempDatabase()
        let id = try await timeline(temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        let run = BuilderRunRecord(runUUID: "run", timelineID: id, request: "Request", status: .applied,
                                   baselineRevision: 0, appliedRevision: 1)
        let before = WizardBeforeRecord(timelineID: id, runUUID: "run", request: "Request",
                                         documentJSON: "{}", appliedRevision: 1)
        do {
            try temp.database.commitWizardSnapshot(timelineID: id, documentJSON: "{\"changed\":true}",
                                                    expectedRevision: 10, revision: 11, thumbnailVideoID: nil,
                                                    run: run, before: before)
            Issue.record("Expected CAS refusal")
        } catch { #expect(error as? ApplyFailure == .staleRevision) }
        try raw.executeScript("""
            CREATE TRIGGER fail_before BEFORE INSERT ON timeline_wizard_before
            BEGIN SELECT RAISE(ABORT, 'injected before-version failure'); END;
            """)
        do {
            try temp.database.commitWizardSnapshot(timelineID: id, documentJSON: "{\"changed\":true}",
                                                    expectedRevision: 0, revision: 1, thumbnailVideoID: nil,
                                                    run: run, before: before)
            Issue.record("Expected injected failure")
        } catch { /* Verify all three rows through a separate connection below. */ }
        #expect(try await temp.database.fetchTimeline(id: id)?.documentJSON == "{}")
        #expect(try await temp.database.fetchTimeline(id: id)?.documentRevision == 0)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id).isEmpty)
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == nil)
    }
}
