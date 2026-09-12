import Foundation
import Testing
@testable import Clip_Builder

@MainActor @Suite("Script library model", .serialized)
struct ScriptLibraryModelTests {
    @Test func allPagesAndInvalidation() throws {
        let live = ScriptFixtures.model()
        var library = ScriptFixtures.library()
        library.scenes = (1...451).map { Fixtures.scene(id: Int64($0)) }
        let capture = ScriptCapture(model: live, library: library)
        let model = ScriptLibraryModel(database: nil)
        model.open(nil, capture: capture)
        model.source = ScriptHeaderTests.source("return;", params: #"[{"name":"scene","type":"scene"},{"name":"clip","type":"clip"},{"name":"track","type":"track"},{"name":"time","type":"time"}]"#)
        model.parse()
        let header = try #require(model.header)
        let scene = try #require(header.params.first { $0.name == "scene" })
        let clip = try #require(header.params.first { $0.name == "clip" })
        let track = try #require(header.params.first { $0.name == "track" })
        #expect(model.choices(for: scene).count == 451)
        #expect(model.choices(for: scene).last?.id == "451")
        #expect(model.choices(for: clip).count == live.document.videoTrack.count)
        #expect(model.choices(for: track).count == live.document.trackCount)
        model.values["scene"] = "451"
        model.values["clip"] = live.document.videoTrack.first?.uid.uuidString
        model.values["track"] = "0"
        #expect(throws: Never.self) { _ = try model.parameters() }
        live.loadTimeline(id: 99, document: live.document)
        model.invalidate(ifChanged: live)
        #expect(model.capture == nil)
        #expect(model.values.isEmpty)
        #expect(model.choices(for: scene).isEmpty)
        #expect(throws: (any Error).self) { _ = try model.parameters() }
    }

    @Test func parameterRulesAndMalformedHeader() async throws {
        let temp = try TempDatabase()
        let model = ScriptLibraryModel(database: temp.database)
        model.open(nil, capture: ScriptCapture(model: ScriptFixtures.model(), library: ScriptFixtures.library()))
        model.source = ScriptHeaderTests.source("return;", params: #"[{"name":"n","type":"number","min":2,"max":8,"step":2},{"name":"yes","type":"boolean"},{"name":"choice","type":"choice","choices":["a","b"]},{"name":"text","type":"string"}]"#)
        model.parse()
        model.values = ["n": "4", "yes": "false", "choice": "b", "text": "hello"]
        #expect(throws: Never.self) { _ = try model.parameters() }
        for invalid in ["3", "9", "nan", "infinity"] {
            model.values["n"] = invalid
            #expect(throws: (any Error).self) { _ = try model.parameters() }
        }
        model.source = "\n/** clipbuilder-script\n{broken}\n*/"
        model.parse()
        await model.validate()
        #expect(model.diagnostic != nil)
        #expect(model.diagnostic?.line == 3)
        #expect(model.diagnostic?.column == 2)
        do { _ = try await model.save(); Issue.record("Malformed headers must not save") } catch {}
        let rows = try await temp.database.fetchBuilderScripts()
        #expect(rows.isEmpty)
    }

    @Test func formRunProducesPreviewAndScriptAudit() async throws {
        let temp = try TempDatabase()
        let project = try await temp.database.createProject(profileName: "S2", name: "S2")
        let document = Fixtures.timelineDocument()
        let timeline = try await temp.database.createTimeline(projectID: project, name: "S2",
            documentJSON: String(decoding: try JSONEncoder().encode(document), as: UTF8.self))
        let live = BuilderTimelineModel()
        live.loadTimeline(id: timeline, document: document)
        live.onTimelineAutosave = { _, _ in }
        let library = ScriptFixtures.library()
        let model = ScriptLibraryModel(database: temp.database)
        model.open(nil, capture: ScriptCapture(model: live, library: library))
        model.source = ScriptHeaderTests.source("builder.ops.set_clip_muted({clip:params.clip,muted:true});",
            params: #"[{"name":"clip","type":"clip"}]"#)
        model.parse()
        model.values["clip"] = live.document.videoTrack.first?.uid.uuidString
        let record = try await model.save()
        let header = try ScriptHeader.parse(record.source)
        let params = try model.parameters()
        let session = BuilderScriptSession(live: live, library: library, ownsHydration: false)
        defer { session.discard() }
        let run = ScriptRunModel(session: session, header: header, params: params)
        await run.run(source: record.source) { try await temp.database.recordBuilderRun($0) }
        #expect(run.diagnostic == nil)
        #expect(session.state == .completed)
        #expect(!session.diff().isEmpty)
        let rows = try await temp.database.fetchBuilderRuns(timelineID: timeline)
        #expect(rows.count == 1)
        #expect(rows.first?.provider == "script")
        #expect(rows.first?.model == record.name)
    }
}
