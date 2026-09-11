import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Wizard sheet model")
struct WizardSheetModelTests {
    private func makeStore(_ temp: TempDatabase) async throws -> AppStore {
        let profile = Fixtures.brand(name: "WizardSheetModelTests")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Project")
        let json = String(decoding: try JSONEncoder().encode(Fixtures.timelineDocument(clips: [Fixtures.timelineClip()])), as: UTF8.self)
        let id = try await temp.database.createTimeline(projectID: project, name: "Timeline", documentJSON: json)
        store.activeProjectID = project
        store.builder.load(profileName: profile.profileName)
        store.openTimelineRecord(try #require(try await temp.database.fetchTimeline(id: id)))
        store.builder.updateScenes([Fixtures.scene()])
        return store
    }

    private func sheet(_ store: AppStore, defaults: UserDefaults) -> WizardSheetModel {
        var library = ScriptFixtures.library()
        library.projectID = store.activeProjectID
        library.tags = ["fixture"]
        library.people = [PersonRecord(id: 1, key: "alex", name: "Alex", descriptor: "")]
        library.scenes[0].tags += ["person:alex"]
        let snapshot = library
        return WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults), loadLibrary: { snapshot })
    }

    @Test func runDiffApplyAndRevert() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let undo = UndoManager(); undo.groupsByEvent = false
        store.builder.undoManager = undo
        let id = try #require(store.builder.timelineID)
        let clip = try #require(store.builder.document.videoTrack.first)
        store.builder.selection = .clip(clip.uid)
        let before = store.builder.document
        let model = sheet(store, defaults: defaults)
        model.request = "mute this clip"
        await model.run()
        #expect(model.phase == .preview && model.canApply)
        #expect(model.diff?.isEmpty == false)
        #expect(store.builder.document == before)
        #expect(model.log.contains { $0.contains("Applied") && $0.contains("ms") })
        model.request = "changed field after Run"
        await model.apply()
        #expect(model.phase == .applied && model.session == nil)
        #expect(store.builder.document.videoTrack.first?.muted == true)
        let run = try #require(try await temp.database.fetchBuilderRuns(timelineID: id).first)
        #expect(run.request == "mute this clip" && run.provider == "local" && run.status == .applied)
        #expect(model.beforeVersion?.request == "mute this clip")
        #expect(undo.canUndo)
        await model.revert()
        #expect(store.builder.document == before && model.beforeVersion == nil)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id).first?.status == .reverted)
    }

    @Test func discardRecordsOnceAndDoesNotEdit() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = try #require(store.builder.timelineID)
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        let before = store.builder.document
        let model = sheet(store, defaults: defaults)
        model.request = "trim this clip to 2 s"
        await model.run()
        #expect(model.canApply)
        await model.discard()
        await model.discard()
        #expect(model.phase == .discarded && model.session == nil)
        #expect(store.builder.document == before)
        let runs = try await temp.database.fetchBuilderRuns(timelineID: id)
        #expect(runs.count == 1 && runs.first?.status == .discarded)
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == nil)
    }

    @Test func unrecognisedAndRefused() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = sheet(store, defaults: defaults)
        model.request = "remove clips tagged fixture except the last one"
        await model.run()
        #expect(model.phase == .unrecognised && !model.reasons.isEmpty && !model.canApply)
        #expect(model.session == nil)
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        model.request = "split this clip at 99s"
        await model.run()
        #expect(model.phase == .refused && !model.canApply)
        #expect(model.reasons.contains { $0.contains("out_of_bounds") })
        await model.discard()
    }

    @Test func staleApply() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let undo = UndoManager(); undo.groupsByEvent = false; store.builder.undoManager = undo
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        let model = sheet(store, defaults: defaults)
        model.request = "mute this clip"
        await model.run()
        store.builder.addText(at: 0)
        let manual = store.builder.document
        await model.apply()
        #expect(model.failure == .staleRevision && !model.canApply)
        #expect(store.builder.document == manual)
        // Adding text selects the new item; "this clip" needs the clip again.
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        await model.run()
        #expect(model.canApply && model.failure == nil)
        await model.discard()
    }

    @Test func findThenPreviewAddition() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = sheet(store, defaults: defaults)
        let before = store.builder.document
        model.request = "find scenes of Alex fixture"
        await model.run()
        #expect(model.phase == .found && model.results.map(\.id) == [1])
        #expect(model.session == nil && !model.canApply && model.diff == nil)
        #expect(model.pickerRequest()?.time == store.builder.playhead)
        #expect(store.builder.document == before)
        model.addAllAsBRoll()
        #expect(model.phase == .preview && model.canApply)
        #expect(model.session?.candidate?.videoTrack.contains(where: \.isCutaway) == true)
        #expect(store.builder.document == before)
        await model.discard()
    }
    @Test func dismissalDuringSnapshotCannotReviveRun() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<ScriptLibrarySnapshot, Never>?
        var library = ScriptFixtures.library(); library.projectID = store.activeProjectID
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults), loadLibrary: {
            await withCheckedContinuation { continuation = $0 }
        })
        model.request = "find fixture"
        let running = Task { await model.run() }
        while continuation == nil { await Task.yield() }
        model.dismiss()
        continuation?.resume(returning: library)
        await running.value
        #expect(model.session == nil && model.results.isEmpty && !model.canApply)
    }

    @Test func discardAfterTimelineSwitchKeepsOriginalAuditOwner() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalID = try #require(store.builder.timelineID)
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        let model = sheet(store, defaults: defaults)
        model.request = "mute this clip"
        await model.run()
        let json = String(decoding: try JSONEncoder().encode(Fixtures.timelineDocument(clips: [Fixtures.timelineClip()])), as: UTF8.self)
        let otherID = try await temp.database.createTimeline(projectID: try #require(store.activeProjectID),
                                                             name: "Other", documentJSON: json)
        store.openTimelineRecord(try #require(try await temp.database.fetchTimeline(id: otherID)))
        await model.discard()
        #expect(try await temp.database.fetchBuilderRuns(timelineID: originalID).first?.status == .discarded)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: otherID).isEmpty)
    }

    @Test func revertRefusesDifferentRunThanConfirmation() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let id = try #require(store.builder.timelineID)
        let before = store.builder.document
        let row = WizardBeforeRecord(timelineID: id, runUUID: "new-run", request: "A newer request",
                                     documentJSON: "{}", appliedRevision: 1)
        try await temp.database.saveWizardBefore(row)
        #expect(await store.revertLastWizardRun(timelineID: id, expectedRunUUID: "confirmed-old-run") == .failure(.staleRevision))
        #expect(store.builder.document == before)
    }

}
