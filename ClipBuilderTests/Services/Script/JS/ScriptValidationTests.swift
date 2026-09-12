import Foundation
import MCP
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

    @Test func threeAuthorSubmissionsNeverWriteProductionState() async throws {
        let temp = try TempDatabase()
        let live = ScriptFixtures.model()
        let before = live.document
        let library = ScriptFixtures.library()
        let video = try #require(library.videos.first)
        let inventoryBefore = try await temp.database.prerequisiteInventory(videoID: video.id)
        var autosaves = 0
        var serviceCalls = 0
        live.onTimelineAutosave = { _, _ in autosaves += 1 }
        let session = BuilderScriptSession(live: live, library: library, ownsHydration: false)
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()), mode: .author,
            confirmedPrerequisites: [.ensureTranscript(video: video.id)], ensure: { _ in
                serviceCalls += 1
                return .init(outcomes: [], completed: true, hasDocumentChanges: false)
            })
        let coordinator = BuilderRunCoordinator(tools: tools)
        let scripts = [
            ScriptHeaderTests.source("const broken = ;"),
            ScriptHeaderTests.source("builder.ops.add_text({text:'isolated'}); throw Error('retry');"),
            ScriptHeaderTests.source("builder.ops.ensure_transcript({video:\(video.id)});",
                requires: "[{\"kind\":\"transcript\",\"video\":\(video.id)}]")
        ]
        for (index, source) in scripts.enumerated() {
            let response = await coordinator.call(name: "submit_script", arguments: [
                "source": .string(source), "sampleParams": .object([:])
            ])
            #expect(response.isError == (index < 2))
            var hydrated = false
            live.scriptLibraryHydration.refresh { hydrated = true }
            #expect(hydrated && live.document == before && autosaves == 0 && serviceCalls == 0)
            #expect(session.prerequisiteEffects.isEmpty && session.prerequisiteReports.isEmpty)
            let records = try await temp.database.fetchBuilderRuns(timelineID: 1)
            let inventory = try await temp.database.prerequisiteInventory(videoID: video.id)
            #expect(records.isEmpty && inventory.rows == inventoryBefore.rows)
            #expect(inventory.rows["Completion receipts"]?.isEmpty == true)
        }
        let result = try #require(tools.lastSubmission)
        #expect(result.status == "accepted" && result.partial)
        #expect(result.message == "partial validation: requires user-run validation")
        #expect(result.diagnostics.first?.code == "requires_user_run_validation")
        #expect(session.authoredScript?.source == scripts.last)
        await coordinator.finish(success: true, message: nil, duration: 0)
        #expect(session.state == .completed && session.frozenCandidate == nil && session.candidate == nil)
        session.discard()
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
