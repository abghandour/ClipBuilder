import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Atomic script snapshot apply", .serialized)
struct BuilderScriptApplyTests {
    private func live() -> BuilderTimelineModel {
        let model = BuilderTimelineModel()
        model.loadTimeline(id: 1, document: Fixtures.timelineDocument())
        model.onTimelineAutosave = { _, _ in }
        return model
    }

    private func frozen(_ model: BuilderTimelineModel, count: Int = 3) -> BuilderScriptSession {
        let session = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        session.run((0..<count).map { .init(.addText(text: "Text \($0)")) })
        session.freeze()
        return session
    }

    @Test("N commands register one undo; exact values survive changed scene metadata", arguments: [1, 5, 20])
    func singleUndo(count: Int) throws {
        let model = live()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let session = frozen(model, count: count)
        let candidate = try #require(session.frozenCandidate)
        let before = model.document
        let revision = model.revision
        #expect(!undo.canUndo)
        #expect(try model.applyScriptSnapshot(candidate: candidate, baseline: session.baseline,
                                              baselineRevision: session.baselineRevision, actionName: "Add text").get() == revision + 1)
        #expect(undo.canUndo && undo.undoActionName == "Wizard: Add text")
        let applied = model.document
        var scene = Fixtures.scene()
        scene.wide.toggle()
        scene.endTime = 200
        model.updateScenes([scene])
        undo.undo()
        #expect(!undo.canUndo, "A single undo must exhaust all registrations from the run")
        #expect(undo.canRedo)
        #expect(model.document == before)
        #expect(ScriptValue.stored(model.document) == ScriptValue.stored(before))
        undo.redo()
        #expect(!undo.canRedo && undo.canUndo)
        #expect(model.document == applied)
        #expect(ScriptValue.stored(model.document) == ScriptValue.stored(applied))
        #expect(model.revision > revision + 1)
    }

    @Test("Manual edit makes Apply stale without adding an undo")
    func staleEdit() throws {
        let model = live()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let session = frozen(model)
        model.document.textOverlays.append(TextOverlayItem(text: "Manual"))
        let edited = model.document
        #expect(model.applyScriptSnapshot(candidate: try #require(session.frozenCandidate), baseline: session.baseline,
                                          baselineRevision: session.baselineRevision, actionName: "Stale") == .failure(.staleRevision))
        #expect(model.document == edited && !undo.canUndo)
    }

    @Test("Timeline switch and missing manager refuse Apply")
    func ownershipAndManager() throws {
        let model = live()
        let session = frozen(model)
        let candidate = try #require(session.frozenCandidate)
        #expect(model.applyScriptSnapshot(candidate: candidate, baseline: session.baseline,
                                          baselineRevision: session.baselineRevision, actionName: "No manager") == .failure(.missingUndoManager))
        model.loadTimeline(id: 2, document: session.baseline)
        #expect(model.applyScriptSnapshot(candidate: candidate, baseline: session.baseline,
                                          baselineRevision: session.baselineRevision, actionName: "Wrong owner") == .failure(.identityChanged))
    }

    @Test("Apply rejects changes to fields omitted by the disk codec")
    func tamperedFrozenCandidate() throws {
        let model = live()
        let undo = UndoManager()
        model.undoManager = undo
        let session = frozen(model)
        var candidate = try #require(session.frozenCandidate)
        candidate.document.videoTrack[0].sceneFullDuration = 987
        #expect(model.applyScriptSnapshot(candidate: candidate, baseline: session.baseline,
                                          baselineRevision: session.baselineRevision, actionName: "Tampered") == .failure(.candidateChanged))
        #expect(!undo.canUndo && model.document == session.baseline)
    }

    @Test("Hydration and load move the revision; frozen candidate is unavailable before freeze")
    func revisions() {
        let model = live()
        let session = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        #expect(session.baselineRevision == model.revision && session.frozenCandidate == nil)
        let initial = model.revision
        model.updateScenes([Fixtures.scene()])
        #expect(model.revision > initial)
        let hydrated = model.revision
        model.loadTimeline(id: 1, document: model.document, revision: 1000)
        #expect(model.revision > hydrated && model.revision > 1000)
        #expect(model.persistedRevision == 1000)
    }

    @Test("Selection survives when valid, invalid selection clears, playhead clamps")
    func viewState() throws {
        let model = live()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let clip = try #require(model.document.videoTrack.first)
        model.selection = .clip(clip.uid)
        model.playhead = 100
        let session = frozen(model)
        _ = try model.applyScriptSnapshot(candidate: #require(session.frozenCandidate), baseline: session.baseline,
                                           baselineRevision: session.baselineRevision, actionName: "Text").get()
        #expect(model.selection == .clip(clip.uid))
        // Text defaults to the captured playhead, extending the candidate to
        // 103. The still-valid live playhead must stay at 100, not jump to 103.
        #expect(model.totalDuration == 103 && model.playhead == 100)
        model.playhead = 200
        let second = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        second.run([.init(.removeClip(clip: clip.uid.uuidString))])
        second.freeze()
        _ = try model.applyScriptSnapshot(candidate: #require(second.frozenCandidate), baseline: second.baseline,
                                           baselineRevision: second.baselineRevision, actionName: "Remove").get()
        #expect(model.selection == nil)
        #expect(model.playhead == model.totalDuration)
    }
}
