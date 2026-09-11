import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder scripts", .serialized)
struct BuilderScriptTests {
    @Test("Every command round trips its complete typed payload")
    func commandRoundTrips() throws {
        let id = UUID().uuidString
        let commands: [BuilderCommand] = [
            .removeClip(clip: id), .removeClips(filter: ClipFilter()),
            .splitClip(clip: id, at: 1.123, precision: .speech),
            .trimClip(clip: id, duration: 2.345, precision: .speech),
            .setSourceRange(clip: id, start: 1, end: 3, precision: .ordinary),
            .placeClip(clip: id, start: 2, track: 0), .addScene(scene: 1, at: 2, track: 0),
            .addCutaway(scene: 1, at: 2, track: 0, duration: 1, sourceStart: 3, coverAll: true),
            .addCutaway(video: 1, track: 0, coverAll: false),
            .setClipRole(clip: id, role: .cutaway), .setCutawayAudio(clip: id, audio: .mixed),
            .duplicateClip(clip: id), .setTrackSequential(track: 0, sequential: false),
            .addCropBlock(layout: "Full Screen", at: 2, duration: 4),
            .setCropLayout(block: id, layout: "50-50 Horizontal"), .removeCropBlock(block: id),
            .addBumper(bumper: "intro", at: 2, mode: .pause), .addSound(sound: "music", at: 2, duration: 3),
            .addText(at: 2, text: "A quote: \"hello\""), .addImage(image: "photo", at: 2, length: 4),
            .removeOverlay(overlay: id), .setPlayhead(at: 2.123), .query(query: BuilderQuery(.clips))
        ]
        for command in commands {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(BuilderCommand.self, from: data) == command)
        }
        for kind in BuilderQuery.Kind.allCases {
            let query = BuilderQuery(kind)
            #expect(try JSONDecoder().decode(BuilderQuery.self, from: JSONEncoder().encode(query)) == query)
        }
        let step = BuilderScriptStep(.addText(text: "Bound"), bind: "title")
        #expect(try ScriptRunner.decode(JSONEncoder().encode([step])) == [step])
    }

    @Test("Malformed, unknown, oversized and nonfinite inputs refuse atomically")
    func invalidJSON() {
        let inputs = ["{", "[{\"command\":{\"op\":\"apply\"}}]",
                      "[{\"command\":{\"op\":\"set_playhead\",\"at\":1,\"extra\":true}}]",
                      "[{\"command\":{\"op\":\"trim_clip\",\"clip\":\"x\",\"duration\":1,\"precision\":\"word\"}}]",
                      "[{\"command\":{\"op\":\"remove_clips\",\"filter\":{\"typo\":true}}}]",
                      "[{\"command\":{\"op\":\"query\",\"query\":{\"kind\":\"scenes\",\"filter\":{}}}}]"]
        for input in inputs {
            let session = ScriptFixtures.session()
            #expect(!session.run(json: Data(input.utf8)).completed)
            #expect(session.candidate == nil)
        }
        #expect(!ScriptFixtures.session().run(json: Data(repeating: 32, count: ScriptRunner.maximumBytes + 1)).completed)
        #expect(!ScriptFixtures.session().run([.init(.setPlayhead(at: .infinity))]).completed)
        #expect(!ScriptFixtures.session().run(Array(repeating: .init(.setPlayhead(at: 0)), count: 201)).completed)
    }

    @Test("Clip operations map to store changes and bind the split tail")
    func clipCommands() throws {
        let source = Fixtures.timelineClip()
        let id = source.uid.uuidString
        let session = ScriptFixtures.session(clips: [source])
        let result = session.run([
            .init(.setTrackSequential(track: 0, sequential: false)),
            .init(.trimClip(clip: id, duration: 3)),
            .init(.setSourceRange(clip: id, start: 2.123, end: 5.789, precision: .speech)),
            .init(.placeClip(clip: id, start: 1.3, track: 0)),
            .init(.splitClip(clip: id, at: 2.5, precision: .speech), bind: "cut"),
            .init(.setClipRole(clip: "$cut.tail", role: .cutaway)),
            .init(.setCutawayAudio(clip: "$cut", audio: .mixed)),
            .init(.duplicateClip(clip: "$cut.tail"), bind: "copy"),
            .init(.removeClip(clip: "$copy"))
        ])
        #expect(result.completed)
        let document = try #require(session.candidate)
        #expect(document.videoTrack.count == 2)
        let head = try #require(document.videoTrack.first { $0.uid == source.uid })
        let tail = try #require(document.videoTrack.first { $0.uid != source.uid })
        #expect(head.startTime == 1.5 && head.duration == 1)
        #expect(abs((tail.sourceStart ?? 0) - 3.123) < 1e-9)
        #expect(tail.role == .cutaway && tail.cutawayAudio == .mixed && !tail.muted)
        #expect(tail.originKey == source.originKey)
        #expect(!document.trackSequential[0])
    }

    @Test("All additions use their documented defaults and return actual values")
    func additions() throws {
        let session = ScriptFixtures.session()
        let result = session.run([
            .init(.setPlayhead(at: 1.2)),
            .init(.addScene(scene: 1, track: 0), bind: "scene"),
            .init(.addCutaway(video: 1, track: 0, duration: 20, sourceStart: 8, coverAll: true), bind: "broll"),
            .init(.addSound(sound: "music", duration: 4), bind: "sound"),
            .init(.addText(text: "Hello"), bind: "text"),
            .init(.addImage(image: "photo", length: 2), bind: "image"),
            .init(.addBumper(bumper: "intro", at: 9, mode: .overlap), bind: "bumper")
        ])
        #expect(result.completed)
        let document = try #require(session.candidate)
        #expect(document.mainClips(inTrack: 0).map(\.startTime) == [0, 4])
        let cutaway = try #require(document.cutaways(inTrack: 0).first)
        #expect(cutaway.startTime == 1 && cutaway.duration == 2)
        #expect(document.soundTrack.first?.startTime == 1)
        #expect(document.textOverlays.first?.text == "Hello")
        #expect(document.imageOverlays.first?.endTime == 3)
        #expect(document.videoTrack.first(where: \.bumper)?.startTime == 9)
        if case .applied(let actual, _, let warnings) = result.outcomes[2] {
            #expect(!warnings.isEmpty)
            if case .object(let values) = actual { #expect(values["duration"] == .number(2)) }
            else { Issue.record("Expected actual cutaway fields") }
        } else { Issue.record("Expected applied cutaway") }
    }

    @Test("Crop commands, crop merging and all overlay removal variants")
    func cropsAndOverlays() throws {
        let model = ScriptFixtures.model()
        var block = OverlayBlockItem()
        block.duration = 2
        model.document.overlayBlocks = [block]
        let session = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        let result = session.run([
            .init(.addCropBlock(layout: "50-50 Horizontal", at: 0, duration: 4), bind: "crop"),
            .init(.setCropLayout(block: "$crop", layout: "33-33-33 Horizontal")),
            .init(.removeCropBlock(block: "$crop")),
            .init(.addCropBlock(layout: "Full Screen", at: 0, duration: 2)),
            .init(.addText(text: "Gone"), bind: "text"),
            .init(.addImage(image: "photo", length: 2), bind: "photo"),
            .init(.removeOverlay(overlay: "$text")), .init(.removeOverlay(overlay: "$photo")),
            .init(.removeOverlay(overlay: block.uid.uuidString))
        ])
        #expect(result.completed)
        let document = try #require(session.candidate)
        #expect(document.cropBlocks.count == 1 && document.cropBlocks[0].layout.isFullScreen)
        #expect(document.textOverlays.isEmpty && document.imageOverlays.isEmpty && document.overlayBlocks.isEmpty)
    }

    @Test("Refused commands have reasons, abort after earlier edits and close admission")
    func atomicRefusal() throws {
        let source = Fixtures.timelineClip()
        let session = ScriptFixtures.session(clips: [source])
        let result = session.run([
            .init(.removeClip(clip: source.uid.uuidString)),
            .init(.removeClip(clip: source.uid.uuidString)),
            .init(.addText(text: "Must not execute"))
        ])
        #expect(!result.completed && !result.hasDocumentChanges)
        #expect(result.outcomes.count == 2 && session.candidate == nil)
        if case .refused(let code, let reason) = result.outcomes[1] { #expect(!code.isEmpty && !reason.isEmpty) }
        else { Issue.record("Missing typed refusal") }
        #expect(!session.diff().isEmpty)
        #expect(!session.run([.init(.addText(text: "Late"))]).completed)
        #expect(!session.diff().changes.contains { $0.path.contains("textOverlays.") && $0.kind == .added })
    }

    @Test("Invalid targets, tracks, source bounds and assets refuse with reasons")
    func refusedCommands() {
        let source = Fixtures.timelineClip()
        let id = source.uid.uuidString
        let commands: [BuilderCommand] = [
            .removeClip(clip: UUID().uuidString), .placeClip(clip: id, start: 0, track: -1),
            .setTrackSequential(track: 6, sequential: false), .addScene(scene: 999, track: 0),
            .addScene(scene: 1, track: 1), .addImage(image: "/tmp/arbitrary.png", length: 2),
            .addSound(sound: "unknown", duration: 3), .addBumper(bumper: "unknown", mode: .pause),
            .setCutawayAudio(clip: id, audio: .mixed), .setSourceRange(clip: id, start: 8, end: 11),
            .splitClip(clip: id, at: 0), .trimClip(clip: id, duration: 0.01, precision: .speech),
            .addCutaway(scene: 1, video: 1, track: 0, coverAll: true),
            .addCutaway(video: 1, track: 0, sourceStart: 10, coverAll: true),
            .setCropLayout(block: UUID().uuidString, layout: "missing"),
            .removeOverlay(overlay: UUID().uuidString)
        ]
        for command in commands {
            let result = ScriptFixtures.session(clips: [source]).run([.init(command)])
            #expect(!result.completed, "\(command)")
            if case .refused(_, let reason) = result.outcomes.first { #expect(!reason.isEmpty) }
            else { Issue.record("Expected refusal for \(command)") }
        }
    }

    @Test("Runner rolls back a refused list and query steps see preceding completed mutations")
    func runnerAndOrdering() throws {
        let model = ScriptFixtures.model()
        let before = model.document
        let runner = ScriptRunner()
        let outcomes = runner.run([.init(.addText(text: "Before query")),
                                   .init(.query(query: BuilderQuery(.timeline))),
                                   .init(.removeOverlay(overlay: "missing"))],
                                  model: model, library: ScriptFixtures.library())
        #expect(outcomes.count == 3 && outcomes.last?.isRefused == true)
        #expect(TimelineDiff(before: before, after: model.document).isEmpty)
        #expect(runner.diagnosticDocument?.textOverlays.first?.text == "Before query")
        if case .applied(let actual, _, _) = outcomes[1] {
            let encoded = try JSONEncoder().encode(actual)
            let result = try JSONDecoder().decode(BuilderQueryResult.self, from: encoded)
            if case .object(let timeline) = result.timeline,
               case .object(let lanes) = timeline["lanes"], case .array(let text) = lanes["textOverlays"] {
                #expect(text.count == 1)
            } else { Issue.record("Query did not see completed text insertion") }
        } else { Issue.record("Expected query result") }
    }

    @Test("Bumper binding identifies the bumper rather than its indirect split tail")
    func bumperBinding() throws {
        let session = ScriptFixtures.session()
        let result = session.run([.init(.addBumper(bumper: "intro", at: 2, mode: .pause), bind: "pause"),
                                  .init(.removeClip(clip: "$pause"))])
        #expect(result.completed)
        #expect(session.candidate?.videoTrack.contains(where: \.bumper) == false)
        #expect(abs((session.candidate?.contentEnd ?? 0) - 4) < 1e-9)
    }

    @Test("Duplicate bindings and binding an idempotent query refuse")
    func bindingValidation() {
        let session = ScriptFixtures.session()
        #expect(!session.run([.init(.addText(text: "One"), bind: "x"),
                              .init(.addText(text: "Two"), bind: "x")]).completed)
        #expect(session.candidate == nil)
        #expect(!ScriptFixtures.session().run([.init(.query(query: BuilderQuery(.clips)), bind: "x")]).completed)
    }

    @Test("Cancellation and affected-item limits abort and drop the candidate")
    func cancellationAndLimits() async {
        let session = ScriptFixtures.session()
        let task = Task { @MainActor in session.run([.init(.addText(text: "Cancelled"))]) }
        task.cancel()
        let result = await task.value
        #expect(!result.completed && session.candidate == nil)
        let many = (0...ScriptRunner.maximumAffectedItems).map { index in
            Fixtures.timelineClip(startTime: Double(index) * 4)
        }
        let large = ScriptFixtures.session(clips: many)
        #expect(!large.run([.init(.removeClips(filter: ClipFilter()))]).completed)
        #expect(large.candidate == nil)
    }

    @Test("Idempotent setters and empty/query-only lists have no document edits")
    func unchangedAndQueries() {
        let source = Fixtures.timelineClip()
        let session = ScriptFixtures.session(clips: [source])
        let result = session.run([.init(.setClipRole(clip: source.uid.uuidString, role: .main)),
                                  .init(.setPlayhead(at: 0)), .init(.query(query: BuilderQuery(.timeline)))])
        #expect(result.completed && !result.hasDocumentChanges)
        if case .unchanged = result.outcomes[0] {} else { Issue.record("Expected unchanged") }
        #expect(session.diff().isEmpty)
        #expect(!ScriptFixtures.session().run([]).hasDocumentChanges)
    }

    @Test("Bulk removal freezes matches before sequential repacking changes overlap")
    func bulkFreeze() throws {
        let clips = [Fixtures.timelineClip(startTime: 0), Fixtures.timelineClip(startTime: 4), Fixtures.timelineClip(startTime: 8)]
        var filter = ClipFilter()
        filter.between = ScriptTimeRange(start: 0, end: 8)
        let session = ScriptFixtures.session(clips: clips)
        #expect(session.run([.init(.removeClips(filter: filter))]).completed)
        #expect(session.candidate?.videoTrack.map(\.uid) == [clips[2].uid])
        #expect(session.candidate?.videoTrack.first?.startTime == 0)
    }
    @Test("Runner exposes precise store refusal codes for speech edits")
    func speechRefusalCodes() {
        let source = Fixtures.timelineClip()
        var bumper = Fixtures.timelineClip(sceneID: nil)
        bumper.bumper = true
        let id = source.uid.uuidString
        let cases: [(BuilderCommand, String)] = [
            (.trimClip(clip: id, duration: 0.049, precision: .speech), "too_short"),
            (.trimClip(clip: id, duration: 9, precision: .speech), "out_of_bounds"),
            (.setSourceRange(clip: id, start: 2, end: 2.049, precision: .speech), "too_short"),
            (.setSourceRange(clip: id, start: 9, end: 10.001, precision: .speech), "out_of_bounds"),
            (.splitClip(clip: id, at: 0.049, precision: .speech), "too_short"),
            (.splitClip(clip: id, at: 4, precision: .speech), "out_of_bounds"),
            (.splitClip(clip: UUID().uuidString, at: 1, precision: .speech), "not_found"),
            (.trimClip(clip: bumper.uid.uuidString, duration: 1, precision: .speech), "bumper"),
            (.setSourceRange(clip: bumper.uid.uuidString, start: 2, end: 3, precision: .speech), "bumper"),
            (.splitClip(clip: bumper.uid.uuidString, at: 1, precision: .speech), "bumper")
        ]
        for (command, expected) in cases {
            let session = ScriptFixtures.session(clips: [source, bumper])
            let result = session.run([.init(command)])
            if case .refused(let code, let reason) = result.outcomes.first {
                #expect(code == expected, "\(command): expected \(expected), got \(code)")
                #expect(!reason.isEmpty)
            } else { Issue.record("Expected refusal for \(command)") }
            #expect(session.state == .failed && session.candidate == nil && session.diff().isEmpty)
        }
    }

}

extension BuilderScriptTests {
    @Test func removeAljoFromRosterOnlyEvidence() throws {
        let aljo = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 2)
        let other = Fixtures.timelineClip(sceneID: nil, sourceStart: 6, duration: 2, startTime: 2)
        let model = ScriptFixtures.model(clips: [aljo, other])
        var library = ScriptFixtures.library()
        library.scenes = []
        library.people = [.init(id: 1, key: "aljo_key", name: "Aljo", descriptor: "")]
        library.videoPeople = [1: [.init(key: "aljo_key", name: "Aljo", ranges: [.init(start: 2, end: 4)])]]
        let context = ParserContext(library: library, model: model)
        guard case .script(let steps) = BuilderRequestParser().parse("remove clips with Aljo", context: context) else {
            Issue.record("Expected a remove-clips script")
            return
        }
        var filter = ClipFilter(); filter.people = ["aljo_key"]
        #expect(steps == [.init(.removeClips(filter: filter))])
        let session = BuilderScriptSession(live: model, library: library)
        defer { session.discard() }
        #expect(session.run(steps).completed)
        #expect(session.workingDocument.videoTrack.map(\.uid) == [other.uid])
        #expect(model.document.videoTrack.map(\.uid) == [aljo.uid, other.uid])
    }
}
