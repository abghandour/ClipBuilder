import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Isolated JavaScript validation", .serialized)
struct ScriptValidationTests {
    @Test func threeValidationsHaveNoProductionCapability() async throws {
        let temp = try TempDatabase()
        let live = ScriptFixtures.model()
        let before = live.document
        var autosaves = 0
        live.onTimelineAutosave = { _, _ in autosaves += 1 }
        let library = ScriptFixtures.library()
        let capture = ScriptCapture(model: live, library: library)
        let video = try #require(library.videos.first)
        let scripts = [
            ScriptHeaderTests.source("builder.ops.add_text({text:'validation only'});"),
            ScriptHeaderTests.source("builder.query({kind:'clips'}); return {summary:'read'};"),
            ScriptHeaderTests.source("builder.ops.ensure_transcript({video:\(video.id)});",
                requires: "[{\"kind\":\"transcript\",\"video\":\(video.id)}]")
        ]
        for (index, source) in scripts.enumerated() {
            let result = await ScriptValidation.validate(source: source, capture: capture)
            #expect(result.partial == (index == 2))
            if index < 2 { #expect(result.diagnostic == nil) }
            else { #expect(result.message == "requires user-run validation") }
            var hydrated = false
            live.scriptLibraryHydration.refresh { hydrated = true }
            #expect(hydrated, "Validation must never acquire a live hydration hold")
            #expect(live.document == before)
            #expect(autosaves == 0)
            let records = try await temp.database.fetchBuilderRuns(timelineID: 1)
            #expect(records.isEmpty)
        }
    }

    @Test func splitEvenlyUsesSnapshotAndRecordsScriptProvider() async throws {
        let temp = try TempDatabase()
        let model = BuilderTimelineModel()
        let document = Fixtures.timelineDocument()
        let project = try await temp.database.createProject(profileName: "S1", name: "S1")
        let timeline = try await temp.database.createTimeline(projectID: project, name: "S1",
            documentJSON: String(decoding: try JSONEncoder().encode(document), as: UTF8.self))
        model.loadTimeline(id: timeline, document: document)
        model.onTimelineAutosave = { _, _ in }
        let selected = try #require(model.document.videoTrack.first)
        model.selection = .clip(selected.uid)
        let before = model.document
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let library = ScriptFixtures.library()
        let source = ScriptHeaderTests.source("""
        builder.ops.ensure_transcript({video:params.video});
        const sel=builder.selection;
        if(!sel || sel.kind!=="clip") throw Error("Select a clip");
        const r=builder.run([
          {op:"split_clip_evenly",clip:sel.id,parts:params.parts,precision:"speech",bind:"pieces"},
          {command:{op:"set_clip_captions",clip:"$pieces.piece1",captions:"none"}}
        ]);
        console.log("done",r.outcomes.length);
        return {summary:"Split into "+params.parts+" parts"};
        """, params: #"[{"name":"parts","type":"number","min":2,"max":12,"step":1,"default":3},{"name":"video","type":"number","min":0,"step":1,"default":1}]"#,
            requires: #"[{"kind":"transcript","video":"$video"}]"#)
        let header = try ScriptHeader.parse(source)
        let (params, requirements) = try header.resolve(capture: ScriptCapture(model: model, library: library))
        let session = BuilderScriptSession(live: model, library: library)
        let run = ScriptRunModel(session: session, header: header, params: params, confirmed: requirements,
            ensure: { _ in .init(outcomes: [.unchanged(reason: "Captured transcript fixture")],
                                completed: true, hasDocumentChanges: false) })
        await run.run(source: source) { record in try await temp.database.recordBuilderRun(record) }
        #expect(run.diagnostic == nil)
        let candidate = try #require(session.frozenCandidate)
        #expect(!undo.canUndo)
        _ = try model.applyScriptSnapshot(candidate: candidate, baseline: session.baseline,
            baselineRevision: session.baselineRevision, actionName: "Split evenly").get()
        #expect(model.document.videoTrack.count == 3)
        #expect(undo.canUndo)
        undo.undo()
        #expect(!undo.canUndo)
        #expect(model.document == before)
        let records = try await temp.database.fetchBuilderRuns(timelineID: timeline)
        #expect(records.count == 1)
        #expect(records.first?.provider == "script")
        #expect(records.first?.summary == "Split into 3 parts")
        session.discard()
    }
}
