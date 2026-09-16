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
            .addVideo(video: 1, at: 2, track: 0), .addVideo(video: 1, track: 0),
            .setClipCameraPath(clip: id, keyframes: [CameraPathKeyframe(t: 0, x: 0.1, y: 0, w: 0.3, h: 1),
                                                     CameraPathKeyframe(t: 2.5, x: 0.6, y: 0, w: 0.3, h: 1)]),
            .setClipCameraPath(clip: id, keyframes: []),
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

    @Test("add_video adds the whole file as a main clip, binds it, and the videos query describes files")
    func addVideoAndVideosQuery() throws {
        let session = ScriptFixtures.session()
        let result = session.run([.init(.addVideo(video: 1, track: 0), bind: "file")])
        #expect(result.completed)
        let document = try #require(session.candidate)
        let file = try #require(document.videoTrack.first { $0.sceneID == nil && !$0.isCutaway })
        #expect(file.videoFile == "/tmp/fixture.mp4" && file.sourceStart == 0 && file.sourceEnd == 10
                && file.duration == 10 && file.startTime == 4 && file.wide)
        #expect(result.outcomes.first?.createdIDs["clip"] == file.uid.uuidString)
        // The binding resolves in a later command of the same session.
        let follow = session.run([.init(.setClipCenterStage(clip: "$file", enabled: true))])
        #expect(follow.completed && session.candidate?.videoTrack.first { $0.uid == file.uid }?.centerStage == true)
        let decoded = try JSONDecoder().decode([BuilderScriptStep].self,
            from: Data(#"[{"command":{"op":"add_video","video":1,"track":0,"at":2}}]"#.utf8))
        #expect(decoded == [.init(.addVideo(video: 1, at: 2, track: 0))])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([BuilderScriptStep].self,
                from: Data(#"[{"command":{"op":"add_video","video":1,"track":0,"duration":3}}]"#.utf8))
        }
        var library = ScriptFixtures.library()
        // A podcast pass stamps analyzedAt and the speech date, never the visual one.
        library.videos[0].analyzedAt = "2026-09-15"
        library.videos[0].speechAnalyzedAt = "2026-09-15"
        library.videos[0].videoType = "podcast"
        library.videoPeople = [1: [VideoPersonRanges(key: "b", name: "Bob", ranges: []),
                                   VideoPersonRanges(key: "a", name: "Alice", ranges: [])]]
        let resolve: (String) throws -> UUID = { _ in throw ScriptError.invalid("unused") }
        let videos = try BuilderQuery(.videos).execute(model: ScriptFixtures.model(), library: library, resolve: resolve)
        #expect(videos.videos == [VideoQueryRow(id: 1, filename: "fixture.mp4", duration: 10, width: 1920, height: 1080,
                                                wide: true, type: "podcast", analyzed: true, scenes: 1, people: ["a", "b"])])
        #expect(videos.total == 1 && videos.nextOffset == nil)
        var filtered = BuilderQuery(.videos); filtered.filter = ClipFilter()
        #expect(throws: (any Error).self) { try filtered.execute(model: ScriptFixtures.model(), library: library, resolve: resolve) }
    }

    @Test("compose_video lays a file out by a recipe: layout block, one muted track per cell, windows or paths, outlined talker")
    func composeVideo() throws {
        var library = ScriptFixtures.library()
        library.videos = [try CropRecipeTests.video()]
        library.speakerTurns = [1: CropRecipeTests.turns]
        let session = BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: library)
        let grid = session.run([.init(.composeVideo(video: 1, recipe: "grid", at: 0), bind: "grid")])
        #expect(grid.completed, "\(grid.outcomes)")
        var document = try #require(session.candidate)
        #expect(document.cropBlocks.first?.layout.name == "2x2 Grid" && document.cropBlocks.first?.duration == 10)
        #expect(document.videoTrack.count == 4 && document.trackCount == 4)
        #expect(document.videoTrack.map(\.track) == [0, 1, 2, 3] && document.videoTrack.map(\.muted) == [false, true, true, true])
        #expect(document.videoTrack.allSatisfy { $0.areaRegion != nil && $0.areaWindow == nil && $0.cameraPath == nil && $0.videoFile == "/tmp/fixture.mp4" })
        #expect(document.videoTrack.allSatisfy { $0.areaFraming == .tracking })
        // Cells beyond the first are freed from sequential packing so they line up.
        #expect(document.trackSequential[0] && !document.trackSequential[1] && !document.trackSequential[3])
        #expect(grid.outcomes.first?.createdIDs["clip"] == document.videoTrack[0].uid.uuidString)
        #expect(grid.outcomes.first?.createdIDs["block"] == document.cropBlocks.first?.uid.uuidString)
        // The binding names the first cell.
        #expect(session.run([.init(.setClipMuted(clip: "$grid", muted: true))]).completed)

        // The talker on top with keyframes in the area; the others below; the talker's cell outlined.
        let rest = BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: library)
        let outcome = rest.run([.init(.composeVideo(video: 1, recipe: "talker_and_rest", at: 0, highlightTalker: true))])
        #expect(outcome.completed, "\(outcome.outcomes)")
        document = try #require(rest.candidate)
        #expect(document.cropBlocks.first?.layout.name == "Talker + 3")
        let top = document.videoTrack.filter { $0.track == 0 }.sorted { $0.startTime < $1.startTime }
        #expect(top.count == 1 && top[0].cameraPath?.count == 8 && top[0].areaFraming == .custom
                && top[0].cameraPathSource == "recipe" && top[0].effect?.preset == "outline" && !top[0].centerStage)
        // "Other 1" never holds the talker, so it stays one piece without an outline.
        let second = document.videoTrack.filter { $0.track == 1 }
        #expect(second.count == 1 && second[0].effect == nil && second[0].cameraPath?.count == 6)

        // A grid with the talker marked: cells split where their person talks.
        let marked = BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: library)
        #expect(marked.run([.init(.composeVideo(video: 1, recipe: "grid", at: 0, highlightTalker: true))]).completed)
        document = try #require(marked.candidate)
        let first = document.videoTrack.filter { $0.track == 0 }.sorted { $0.startTime < $1.startTime }
        #expect(first.map(\.startTime) == [0, 3, 8] && first.map { $0.effect?.preset } == ["outline", nil, "outline"])
        #expect(first.map(\.sourceStart) == [0, 3, 8] && first.allSatisfy { $0.areaRegion == first[0].areaRegion && $0.areaRegion != nil })
        #expect(document.videoTrack.filter { $0.track == 3 }.count == 1)

        // Named layout and subjects, a hold, JSON round trip, and refusals.
        let decoded = try JSONDecoder().decode([BuilderScriptStep].self, from: Data(
            #"[{"command":{"op":"compose_video","video":1,"recipe":"grid","layout":"50-50 Horizontal","slots":["person:bob","previous"],"hold":2,"highlight_talker":true,"rotate":3}}]"#.utf8))
        #expect(decoded == [.init(.composeVideo(video: 1, recipe: "grid", layout: "50-50 Horizontal",
                                                slots: ["person:bob", "previous"], highlightTalker: true, hold: 2, rotate: 3))])
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(encoded.contains("\"highlight_talker\":true") && encoded.contains("\"hold\":2") && encoded.contains("\"rotate\":3"))
        let custom = BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: library)
        #expect(custom.run(decoded).completed)
        #expect(custom.candidate?.videoTrack.count == 4 && custom.candidate?.cropBlocks.first?.layout.name == "50-50 Horizontal", "bob's cell splits around 3…6 s; the previous-speaker cell stays whole")
        for bad in [BuilderCommand.composeVideo(video: 1, recipe: "mosaic"),
                    .composeVideo(video: 1, recipe: "grid", slots: ["faces"]),
                    .composeVideo(video: 1, recipe: "grid", hold: 0.1),
                    .composeVideo(video: 1, recipe: "grid", layout: "Nope"),
                    .composeVideo(video: 2, recipe: "grid")] {
            #expect(!BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: library).run([.init(bad)]).completed, "\(bad)")
        }
        // The rotation recipe cuts the lower cell on a beat.
        let rotating = BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: library)
        #expect(rotating.run([.init(.composeVideo(video: 1, recipe: "talker_and_rotation", at: 0, rotate: 2))]).completed)
        #expect((rotating.candidate?.videoTrack.first { $0.track == 1 }?.cameraPath?.count ?? 0) > 6)
        #expect(!BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: library)
            .run([.init(.composeVideo(video: 1, recipe: "talker_and_rotation", rotate: 0.5))]).completed)

        // On a sequential first track the composition starts where that track ends, with a warning.
        let packedModel = ScriptFixtures.model()
        let packed = BuilderScriptSession(live: packedModel, library: library)
        let end = packedModel.clips(inTrack: 0).map { $0.startTime + $0.duration }.max() ?? 0
        let late = packed.run([.init(.composeVideo(video: 1, recipe: "grid", at: 20))])
        #expect(late.completed)
        if case .applied(_, _, let warnings) = late.outcomes[0] { #expect(warnings.contains { $0.contains("sequential") }) }
        #expect(packed.candidate?.cropBlocks.first { !$0.layout.isFullScreen }?.startTime == end)
        #expect(packed.candidate?.videoTrack.filter { $0.videoFile == "/tmp/fixture.mp4" && $0.sceneID == nil }.allSatisfy { $0.startTime == end } == true)

        // A scene of the file: the block spans the scene, the cells are scene clips.
        let free = ScriptFixtures.model(clips: [])
        free.setTrackSequential(false, track: 0)
        let sceneRun = BuilderScriptSession(live: free, library: library)
        let composed = sceneRun.run([.init(.composeVideo(scene: 1, recipe: "talker_and_previous", at: 1))])
        #expect(composed.completed, "\(composed.outcomes)")
        document = try #require(sceneRun.candidate)
        let sceneBlock = document.cropBlocks.first { !$0.layout.isFullScreen }
        #expect(sceneBlock?.startTime == 1 && sceneBlock?.duration == 4 && sceneBlock?.layout.name == "50-50 Horizontal")
        #expect(document.videoTrack.count == 2 && document.videoTrack.allSatisfy { $0.sceneID == 1 && $0.sourceStart == 2 && $0.duration == 4 })
        #expect(document.videoTrack[0].cameraPath?.first?.t == 0 && document.videoTrack[0].cameraPath?.last?.t == 4)
        for bad in [BuilderCommand.composeVideo(recipe: "grid"), .composeVideo(video: 1, scene: 1, recipe: "grid"),
                    .composeVideo(scene: 9, recipe: "grid")] {
            #expect(!BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: library).run([.init(bad)]).completed, "\(bad)")
        }
        // No turns: the talker recipe is refused with a reason.
        var silent = library; silent.speakerTurns = [:]
        let refused = BuilderScriptSession(live: ScriptFixtures.model(clips: []), library: silent)
            .run([.init(.composeVideo(video: 1, recipe: "talker"))])
        #expect(!refused.completed)
    }

    @Test("a camera path on a clip in a crop area is accepted at the area's aspect and replaces its window")
    func cameraPathInArea() throws {
        var source = Fixtures.timelineClip()
        source.wide = true
        source.areaWindow = FreeCropRect(xFrac: 0.2, yFrac: 0, wFrac: 0.5, hFrac: 0.5)
        let model = ScriptFixtures.model(clips: [source])
        var document = model.document
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 20)]
        document.normalizeCropBlocks()
        model.seed(document: document, scenes: model.scenes)
        let session = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        let frames = [CameraPathKeyframe(t: 0, x: 0.1, y: 0, w: 0.3, h: 0.5), CameraPathKeyframe(t: 3, x: 0.6, y: 0, w: 0.3, h: 0.5)]
        let set = session.run([.init(.setClipCameraPath(clip: source.uid.uuidString, keyframes: frames))])
        #expect(set.completed, "\(set.outcomes)")
        let clip = try #require(session.candidate?.videoTrack.first { $0.uid == source.uid })
        #expect(clip.cameraPath == frames && clip.areaWindow == nil && !clip.centerStage && clip.areaFraming == .custom)
    }

    @Test("a scripted camera path sets, reads back through the camera query, clears, and refuses bad paths")
    func cameraPathScripting() throws {
        var source = Fixtures.timelineClip()
        source.wide = true
        let id = source.uid.uuidString
        let session = ScriptFixtures.session(clips: [source])
        let frames = [CameraPathKeyframe(t: 0, x: 0.1, y: 0, w: 0.3, h: 1),
                      CameraPathKeyframe(t: 3, x: 0.6, y: 0, w: 0.3, h: 1)]
        let set = session.run([.init(.setClipCameraPath(clip: id, keyframes: frames))])
        #expect(set.completed)
        let clip = try #require(session.candidate?.videoTrack.first { $0.uid == source.uid })
        #expect(clip.cameraPath == frames && clip.centerStage && clip.framing == .custom && clip.cameraPathSource == "wizard")
        // The document keeps it across a save/load round trip.
        let encoded = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: encoded)
        #expect(decoded.cameraPath == frames && decoded.cameraPathSource == "wizard")
        // The camera query reports the clip's own path on its own clock.
        var query = BuilderQuery(.camera); query.clip = id
        let model = ScriptFixtures.model(clips: [clip])
        let camera = try query.execute(model: model, library: ScriptFixtures.library(), resolve: { UUID(uuidString: $0)! })
        // Sliced to the clip's 4 s span: the path holds its last rectangle past 3 s.
        #expect(camera.cameraSource == "clip" && camera.camera.first?.x == 0.1 && camera.camera.last?.t == 4)
        #expect(camera.camera.last?.x == 0.6 && camera.camera.contains { $0.t == 3 })
        let cleared = session.run([.init(.setClipCameraPath(clip: id, keyframes: []))])
        #expect(cleared.completed)
        #expect(session.candidate?.videoTrack.first { $0.uid == source.uid }?.cameraPath == nil)
        for bad in [[CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.3, h: 1)],
                    [CameraPathKeyframe(t: 1, x: 0, y: 0, w: 0.3, h: 1), CameraPathKeyframe(t: 1, x: 0, y: 0, w: 0.3, h: 1)],
                    [CameraPathKeyframe(t: 0, x: 0.9, y: 0, w: 0.3, h: 1), CameraPathKeyframe(t: 1, x: 0, y: 0, w: 0.3, h: 1)],
                    [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.3, h: 1), CameraPathKeyframe(t: 30, x: 0, y: 0, w: 0.3, h: 1)]] {
            let refused = ScriptFixtures.session(clips: [source]).run([.init(.setClipCameraPath(clip: id, keyframes: bad))])
            #expect(!refused.completed, "\(bad)")
        }
        // Not wide: refused.
        let narrow = ScriptFixtures.session().run([.init(.setClipCameraPath(clip: Fixtures.timelineClip().uid.uuidString, keyframes: frames))])
        #expect(!narrow.completed)
    }

    @Test("the speakers query reports podcast turns with their tiles and the layout")
    func speakersQuery() throws {
        var library = ScriptFixtures.library()
        library.videos[0].podcastLayout = "grid"
        library.videos[0].podcastTilesJSON = #"[{"index":0,"x":0,"y":0,"w":0.5,"h":1,"personKey":"host"},{"index":1,"x":0.5,"y":0,"w":0.5,"h":1}]"#
        library.speakerTurns = [1: [SpeakerTurn(videoID: 1, start: 0, end: 2, cluster: 0, confidence: 0.9, resolvedSide: .left, personKey: "host", tile: 0),
                                    SpeakerTurn(videoID: 1, start: 2, end: 5, cluster: 1, confidence: 0.8, resolvedSide: .right, tile: 1)]]
        var query = BuilderQuery(.speakers); query.video = 1
        let resolve: (String) throws -> UUID = { _ in throw ScriptError.invalid("unused") }
        let result = try query.execute(model: ScriptFixtures.model(), library: library, resolve: resolve)
        #expect(result.speakers == [SpeakerQueryRow(start: 0, end: 2, person: "host", side: "left", tile: 0, confidence: 0.9),
                                    SpeakerQueryRow(start: 2, end: 5, person: nil, side: "right", tile: 1, confidence: 0.8)])
        #expect(result.podcast?.layout == "grid" && result.podcast?.tiles.count == 2 && result.podcast?.tiles[0].personKey == "host")
        #expect(result.total == 2)
        #expect(throws: (any Error).self) { try BuilderQuery(.speakers).execute(model: ScriptFixtures.model(), library: library, resolve: resolve) }
        let decoded = try JSONDecoder().decode(BuilderQuery.self, from: Data(#"{"kind":"speakers","video":1}"#.utf8))
        #expect(decoded == query)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BuilderQuery.self, from: Data(#"{"kind":"speakers","clip":"x"}"#.utf8)) }
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
            .addVideo(video: 999, track: 0), .addVideo(video: 1, track: 1),
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
        // Rebinding a name replaces it: $x now names the second text.
        let session = ScriptFixtures.session()
        let result = session.run([.init(.addText(text: "One"), bind: "x"),
                                  .init(.addText(text: "Two"), bind: "x"),
                                  .init(.setText(overlay: "$x", text: "Second"))])
        #expect(result.completed)
        #expect(session.candidate?.textOverlays.map(\.text) == ["One", "Second"])
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
