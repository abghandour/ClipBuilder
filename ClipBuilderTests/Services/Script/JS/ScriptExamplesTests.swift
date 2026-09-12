import Foundation
import Testing
@testable import Clip_Builder

@MainActor @Suite("Bundled script examples", .serialized)
struct ScriptExamplesTests {
    private func capture() -> ScriptCapture {
        let live = ScriptFixtures.model()
        live.selection = .clip(live.document.videoTrack[0].uid)
        live.playhead = 1
        return ScriptCapture(model: live, library: ScriptFixtures.gapLibrary())
    }

    @Test func everyExampleParsesAndValidates() async throws {
        let capture = capture()
        let before = capture.document
        #expect(ScriptExamples.all.count == 4)
        #expect(Set(ScriptExamples.all.map { $0.id }).count == 4)
        for example in ScriptExamples.all {
            let header = try ScriptHeader.parse(example.source)
            var samples: [String: ScriptValue] = [:]
            if header.params.contains(where: { $0.name == "person" }) { samples["person"] = .string("aLeX sMiTh") }
            if header.params.contains(where: { $0.name == "tag" }) { samples["tag"] = .string("fixture") }
            let data = try JSONEncoder().encode(samples)
            let result = await ScriptValidation.validate(source: example.source, sampleParams: data, capture: capture)
            #expect(result.diagnostic == nil, "\(header.name): \(result.message)")
            #expect(!result.partial)
            #expect(capture.document == before)
        }
    }

    @Test func installsAndRestoresByStableIDOnly() async throws {
        let temp = try TempDatabase()
        try await temp.database.installBuilderScriptExamples()
        try await temp.database.installBuilderScriptExamples()
        let installed = try await temp.database.fetchBuilderScripts()
        #expect(installed.count == 4)
        #expect(installed.allSatisfy { $0.origin == .app })
        let example = try #require(installed.first)
        let editedSource = example.source + "\n// User edit"
        let edited = try await temp.database.saveBuilderScript(source: editedSource, id: example.id)
        try await temp.database.installBuilderScriptExamples()
        let reinstalled = try await temp.database.fetchBuilderScripts()
        #expect(reinstalled.first { $0.id == example.id } == edited)

        let human = try await temp.database.duplicateBuilderScript(id: example.id)
        let ai = try await temp.database.saveBuilderScript(source: editedSource, origin: .ai)
        let missing = try #require(installed.first { $0.id != example.id })
        try await temp.database.deleteBuilderScript(id: missing.id)
        // A non-app record occupying a bundled ID must also survive Restore.
        let protected = try #require(installed.first { $0.id != example.id && $0.id != missing.id })
        try await temp.database.deleteBuilderScript(id: protected.id)
        let replacement = try await temp.database.saveBuilderScript(source: editedSource, id: protected.id, origin: .human)
        try await temp.database.installBuilderScriptExamples(restoring: true)
        let restored = try await temp.database.fetchBuilderScripts()
        let bundled = try #require(ScriptExamples.all.first { $0.id == example.id })
        #expect(restored.count == 6)
        #expect(restored.first { $0.id == example.id }?.source == bundled.source)
        #expect(restored.first { $0.id == missing.id }?.origin == .app)
        #expect(restored.contains(human) && restored.contains(ai) && restored.contains(replacement))
    }

    @Test func firstLoadIsPerProfileAndDeletionSurvivesReload() async throws {
        let suite = "ScriptExamplesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScriptPreferences(defaults: defaults)
        let firstDB = try TempDatabase()
        let secondDB = try TempDatabase()
        let first = ScriptLibraryModel(database: firstDB.database, profile: "First", preferences: preferences)
        await first.load()
        let removed = try #require(first.scripts.first)
        await first.delete(removed)
        let reopened = ScriptLibraryModel(database: firstDB.database, profile: "First", preferences: preferences)
        await reopened.load()
        #expect(reopened.scripts.count == 3)
        let second = ScriptLibraryModel(database: secondDB.database, profile: "Second", preferences: preferences)
        await second.load()
        #expect(second.scripts.count == 4)
        await reopened.installExamples(restoring: true)
        #expect(reopened.scripts.count == 4)
    }

    @Test func splitAppliesAsOneSnapshot() async throws {
        let live = BuilderTimelineModel()
        live.loadTimeline(id: 1, document: Fixtures.timelineDocument())
        live.onTimelineAutosave = { _, _ in }
        live.selection = .clip(live.document.videoTrack[0].uid)
        let undo = UndoManager()
        undo.groupsByEvent = false
        live.undoManager = undo
        let before = live.document
        let library = ScriptFixtures.library()
        let header = try ScriptHeader.parse(ScriptExamples.splitSelection)
        let capture = ScriptCapture(model: live, library: library)
        let params = try header.resolve(capture: capture).0
        let session = BuilderScriptSession(live: live, library: library, ownsHydration: false)
        defer { session.discard() }
        let run = ScriptRunModel(session: session, header: header, params: params)
        await run.run(source: ScriptExamples.splitSelection)
        #expect(run.diagnostic == nil)
        #expect(live.document == before)
        let candidate = try #require(session.frozenCandidate)
        _ = try live.applyScriptSnapshot(candidate: candidate, baseline: session.baseline,
            baselineRevision: session.baselineRevision, actionName: header.name).get()
        #expect(live.document.videoTrack.count == 6)
        #expect(live.document.videoTrack.allSatisfy { $0.precision == .speech })
        #expect(undo.canUndo)
        undo.undo()
        #expect(live.document == before && !undo.canUndo)
    }

    @Test func unknownPersonAndTagRefuseClearly() async {
        let capture = capture()
        let person = await ScriptValidation.validate(source: ScriptExamples.removePerson,
            sampleParams: Data(#"{"person":"not in roster"}"#.utf8), capture: capture)
        #expect(person.diagnostic?.reason.contains("Unknown person") == true)
        let tag = await ScriptValidation.validate(source: ScriptExamples.addBRoll,
            sampleParams: Data(#"{"tag":"not a tag"}"#.utf8), capture: capture)
        #expect(tag.diagnostic?.reason.contains("No available scene") == true)
    }

    @Test func personMatchesKeyAndNameAcrossRosterPages() async throws {
        for person in ["Z_ALEX", "aLeX sMiTh"] {
            var library = ScriptFixtures.library()
            library.people = (0..<204).map {
                PersonRecord(id: Int64($0 + 10), key: "a\($0)", name: "Person \($0)", descriptor: "Fixture")
            }
            library.people.append(PersonRecord(id: 1, key: "z_alex", name: "Alex Smith", descriptor: "Host"))
            library.scenes[0].tags = ["person:z_alex"]
            library.scenes.append(Fixtures.scene(id: 2))
            let live = ScriptFixtures.model(clips: [Fixtures.timelineClip(), Fixtures.timelineClip(sceneID: 2, startTime: 4)])
            let header = try ScriptHeader.parse(ScriptExamples.removePerson)
            let params = try JSONEncoder().encode(["person": person])
            let session = BuilderScriptSession(live: live, library: library, ownsHydration: false)
            let run = ScriptRunModel(session: session, header: header, params: params)
            await run.run(source: ScriptExamples.removePerson)
            #expect(run.diagnostic == nil)
            let candidate = try #require(session.frozenCandidate)
            #expect(candidate.document.videoTrack.count == 1)
            #expect(candidate.document.videoTrack.first?.sceneID == 2)
            session.discard()
        }
    }

    @Test func tagUsesCapturedPlayheadAndChosenTrack() async throws {
        let live = ScriptFixtures.model()
        live.playhead = 1.5
        let library = ScriptFixtures.library()
        let header = try ScriptHeader.parse(ScriptExamples.addBRoll)
        let capture = ScriptCapture(model: live, library: library)
        let params = try header.resolve(Data(#"{"tag":"fixture","track":0}"#.utf8), capture: capture).0
        let session = BuilderScriptSession(live: live, library: library, ownsHydration: false)
        defer { session.discard() }
        let run = ScriptRunModel(session: session, header: header, params: params)
        await run.run(source: ScriptExamples.addBRoll)
        #expect(run.diagnostic == nil)
        let candidate = try #require(session.frozenCandidate)
        let cutaway = try #require(candidate.document.videoTrack.first { $0.role == .cutaway })
        #expect(cutaway.sceneID == library.scenes[0].id)
        #expect(cutaway.startTime == 1.5 && cutaway.track == 0)
    }

    @Test func muteIncludesAlreadyMutedAndLaterPages() async throws {
        let clips = (0..<205).map { index in
            var clip = Fixtures.timelineClip(startTime: Double(index) * 4)
            clip.role = .cutaway
            clip.muted = index != 0 && index != 204
            return clip
        }
        let live = ScriptFixtures.model(clips: clips)
        let session = BuilderScriptSession(live: live, library: ScriptFixtures.library(), ownsHydration: false)
        defer { session.discard() }
        let header = try ScriptHeader.parse(ScriptExamples.muteBRoll)
        let run = ScriptRunModel(session: session, header: header, params: Data("{}".utf8))
        await run.run(source: ScriptExamples.muteBRoll)
        #expect(run.diagnostic == nil)
        let candidate = try #require(session.frozenCandidate)
        #expect(candidate.document.videoTrack.count == 205)
        #expect(candidate.document.videoTrack.allSatisfy { $0.muted })
    }

    @Test func referenceIncludesEveryOperationAndHeader() {
        let reference = BuilderCommandCatalog.referenceText
        for op in BuilderCommandCatalog.operations.keys { #expect(reference.contains("\"" + op + "\"")) }
        #expect(reference.contains("/** clipbuilder-script"))
        for field in ["name", "description", "mode", "params", "requires"] {
            #expect(reference.contains("\"" + field + "\""))
        }
    }
}
