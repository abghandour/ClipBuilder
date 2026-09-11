import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Wizard commit coordinator")
struct WizardCommitTests {
    private func makeStore(_ temp: TempDatabase) async throws -> AppStore {
        let profile = Fixtures.brand(name: "WizardCommitTests")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        let projectID = try await temp.database.createProject(profileName: profile.profileName, name: "Project")
        let json = String(decoding: try JSONEncoder().encode(Fixtures.timelineDocument()), as: UTF8.self)
        let id = try await temp.database.createTimeline(projectID: projectID, name: "Timeline", documentJSON: json)
        store.activeProjectID = projectID
        store.builder.load(profileName: profile.profileName)
        store.openTimelineRecord(try #require(try await temp.database.fetchTimeline(id: id)))
        return store
    }

    private func session(_ store: AppStore) -> BuilderScriptSession {
        var library = ScriptFixtures.library()
        library.projectID = store.activeProjectID
        let session = BuilderScriptSession(live: store.builder, library: library)
        session.run([.init(.addText(text: "First")), .init(.addText(text: "Second"))])
        session.freeze()
        return session
    }

    private func json(_ document: TimelineDocument) throws -> ScriptValue {
        try JSONDecoder().decode(ScriptValue.self, from: JSONEncoder().encode(document))
    }

    @Test("Apply writes timeline/run/before together and Revert restores one undoable snapshot")
    func applyAndRevert() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let id = try #require(store.builder.timelineID)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.builder.undoManager = undo
        let before = store.builder.document
        let session = session(store)
        let revision = try await store.applyWizardRun(session: session, request: "Add titles",
                                                      provenance: .local(technique: "parser")).get()
        let applied = store.builder.document
        let row = try #require(try await temp.database.fetchTimeline(id: id))
        let run = try #require(try await temp.database.fetchBuilderRuns(timelineID: id).first)
        let savedBefore = try #require(try await temp.database.fetchWizardBefore(timelineID: id))
        #expect(row.documentRevision == revision && run.appliedRevision == revision)
        #expect(run.status == .applied && run.runUUID == session.runUUID)
        #expect(savedBefore.runUUID == run.runUUID && savedBefore.appliedRevision == revision)
        #expect(try JSONDecoder().decode(ScriptValue.self, from: Data(row.documentJSON.utf8)) == json(applied))
        #expect(try JSONDecoder().decode(ScriptValue.self, from: Data(savedBefore.documentJSON.utf8)) == json(before))
        #expect(undo.canUndo)
        undo.removeAllActions()
        _ = try await store.revertLastWizardRun(timelineID: id).get()
        #expect(store.builder.document == before)
        #expect(ScriptValue.stored(store.builder.document) == ScriptValue.stored(before))
        #expect(undo.canUndo && undo.undoActionName == "Revert Wizard run")
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == nil)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id).first?.status == .reverted)
        #expect(await store.revertLastWizardRun(timelineID: id) == .failure(.missingBeforeVersion))
        undo.undo()
        #expect(!undo.canUndo && store.builder.document == applied)
        undo.redo()
        #expect(store.builder.document == before)
    }

    @Test("Failure on the final SQL write leaves live state, revision and existing undo untouched")
    func failedCommit() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let id = try #require(store.builder.timelineID)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.builder.undoManager = undo
        undo.beginUndoGrouping()
        store.builder.addText()
        undo.endUndoGrouping()
        let previousName = undo.undoActionName
        let session = session(store)
        let before = store.builder.document
        let revision = store.builder.revision
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.executeScript("""
            CREATE TRIGGER fail_wizard_before BEFORE INSERT ON timeline_wizard_before
            BEGIN SELECT RAISE(ABORT, 'injected failure after timeline and run writes'); END;
            """)
        let result = await store.applyWizardRun(session: session, request: "Fail", provenance: .local(technique: "parser"))
        if case .failure(.persistence) = result {} else { Issue.record("Expected a persistence failure") }
        #expect(ScriptValue.stored(store.builder.document) == ScriptValue.stored(before))
        #expect(store.builder.revision == revision && undo.undoActionName == previousName)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id).isEmpty)
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == nil)
        let persisted = try #require(try await temp.database.fetchTimeline(id: id))
        #expect(try JSONDecoder().decode(ScriptValue.self, from: Data(persisted.documentJSON.utf8)) == json(before))
        undo.undo()
        #expect(!undo.canUndo, "Only the pre-existing manual edit is registered")
    }

    @Test("Failed and discarded outcomes preserve the previous before-version")
    func terminalOutcomes() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let id = try #require(store.builder.timelineID)
        let old = WizardBeforeRecord(timelineID: id, runUUID: "old", request: "Old", documentJSON: "{}", appliedRevision: 1)
        try await temp.database.saveWizardBefore(old)
        let discarded = session(store)
        discarded.discard()
        #expect(await store.applyWizardRun(session: discarded, request: "Discarded", provenance: .local(technique: "parser")) == .failure(.notApplicable))
        var library = ScriptFixtures.library()
        library.projectID = store.activeProjectID
        let failed = BuilderScriptSession(live: store.builder, library: library)
        failed.run([.init(.removeClip(clip: "not-a-uuid"))])
        #expect(await store.applyWizardRun(session: failed, request: "Failed", provenance: .local(technique: "parser")) == .failure(.notApplicable))
        let rows = try await temp.database.fetchBuilderRuns(timelineID: id)
        #expect(Set(rows.map(\.status)) == Set([BuilderRunStatus.failed, .discarded]))
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == old)
    }

    @Test("Speech precision survives durable apply and Revert after reopening with no undo manager")
    func speechReopenRevert() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let id = try #require(store.builder.timelineID)
        var clip = Fixtures.timelineClip()
        clip.sceneID = nil
        clip.videoFile = "/tmp/speech.mp4"
        clip.sourceStart = 2.123
        clip.sourceEnd = 2.246
        clip.duration = 0.123
        clip.precision = .speech
        store.builder.document.videoTrack = [clip]
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.builder.undoManager = undo
        let session = session(store)
        _ = try await store.applyWizardRun(session: session, request: "Speech titles", provenance: .local(technique: "parser")).get()
        #expect(store.builder.document.videoTrack[0].precision == .speech)
        let reopenedDB = try Database(path: temp.path)
        let profile = Fixtures.brand(name: "WizardCommitTests")
        let settings = AppSettings()
        let reopened = AppStore(settings: settings, profiles: [profile], active: profile,
                                ai: AIService(config: settings.ai), database: reopenedDB)
        reopened.activeProjectID = store.activeProjectID
        reopened.openTimelineRecord(try #require(try await reopenedDB.fetchTimeline(id: id)))
        #expect(reopened.builder.undoManager == nil)
        _ = try await reopened.revertLastWizardRun(timelineID: id).get()
        let restored = try #require(reopened.builder.document.videoTrack.first)
        #expect(restored.precision == .speech && abs(restored.duration - 0.123) < 1e-9)
        #expect(abs((restored.sourceStart ?? 0) - 2.123) < 1e-9)
        #expect(try await reopenedDB.fetchWizardBefore(timelineID: id) == nil)
    }

    @Test("Database revision conflict and no manager refuse without live mutation")
    func conflicts() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let id = try #require(store.builder.timelineID)
        let session = session(store)
        #expect(await store.applyWizardRun(session: session, request: "No manager", provenance: .local(technique: "parser")) == .failure(.missingUndoManager))
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.builder.undoManager = undo
        try await temp.database.saveTimeline(id: id, documentJSON: "{}")
        #expect(await store.applyWizardRun(session: session, request: "Conflict", provenance: .local(technique: "parser")) == .failure(.staleRevision))
        #expect(store.builder.document == session.baseline && !undo.canUndo)
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == nil)
    }
}
