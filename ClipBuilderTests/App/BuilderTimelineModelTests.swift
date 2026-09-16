import AppKit
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder timeline model", .serialized)
struct BuilderTimelineModelTests {
    /// An undo manager that groups per explicit `event` call instead of per
    /// run-loop turn: registrations made inside one `event` land on the
    /// stack as one step when it ends, exactly as a user gesture would.
    private func makeUndoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func event(_ undo: UndoManager, _ edit: () -> Void) {
        undo.beginUndoGrouping()
        edit()
        undo.endUndoGrouping()
    }

    @Test("regression: trims and scrubbing respect playback speed")
    func speedAwareTrimAndScrub() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Speed")
        let scene = Fixtures.scene(start: 2, end: 10)
        model.updateScenes([scene])
        model.addScene(scene)
        let uid = try #require(model.document.videoTrack.first?.uid)
        model.updateClip(uid) { $0.speed = 2 }

        model.trimClip(uid, duration: 10)
        let clip = try #require(model.clip(uid))
        #expect(clip.duration == 4)
        #expect(model.sourceTime(for: clip, atTimeline: clip.startTime + 2) == 6)
    }

    @Test("regression: negative source track never crashes or returns a negative index")
    func negativeTrackIndex() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        let document = TimelineDocument()
        model.loadDocument(document)
        model.document.trackCount = 3
        #expect(model.trackIndex(fromTrack: -10, verticalDelta: -10_000) == 0)
        #expect(model.trackIndex(fromTrack: 99, verticalDelta: 10_000) == 2)
    }

    @Test("a drop anywhere in the lane stack lands on the lane under it, else the nearest track")
    func dropTrackFromLaneOffset() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(TimelineDocument())
        #expect(model.trackIndex(atLaneOffset: 500) == 0)
        model.document.trackCount = 3
        let layout = model.timelineLayout()
        let first = layout.videoTracks[0].laneHeight
        let second = layout.videoTracks[1].laneHeight
        #expect(model.trackIndex(atLaneOffset: -20) == 0)
        #expect(model.trackIndex(atLaneOffset: first / 2) == 0)
        #expect(model.trackIndex(atLaneOffset: first + BuilderTimelineModel.laneSpacing / 2) == 0)
        #expect(model.trackIndex(atLaneOffset: first + BuilderTimelineModel.laneSpacing + second / 2) == 1)
        // Below the last lane (Overlays, Sound, empty space): the last track.
        #expect(model.trackIndex(atLaneOffset: 10_000) == 2)
    }

    @Test("a clip in a crop area frames as a window, the tracking camera or keyframes at the area's aspect; splits keep each piece's path")
    func areaFraming() throws {
        var clip = Fixtures.timelineClip(sceneID: 1, sourceStart: 0, duration: 8, startTime: 0)
        clip.wide = true
        var document = Fixtures.timelineDocument(clips: [clip])
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 20)]
        document.normalizeCropBlocks()
        let model = BuilderTimelineModel(mode: .transient)
        model.seed(document: document, scenes: [Fixtures.scene(id: 1, start: 0, end: 8)])
        let uid = clip.uid
        #expect(model.clip(uid)?.areaFraming == .tracking)
        // The top half of a 9:16 canvas is 1.125 wide per unit height.
        #expect(abs(model.cropRatio(for: model.clip(uid)!) - 1.125 / (16.0 / 9.0)) < 1e-9)
        model.setFraming(uid, .fixed)
        let window = try #require(model.clip(uid)?.areaWindow)
        #expect(model.clip(uid)?.areaFraming == .fixed && window.hFrac == 1 && abs(window.wFrac - 1.125 / (16.0 / 9.0)) < 1e-6)
        model.setFraming(uid, .custom)
        let custom = try #require(model.clip(uid))
        #expect(custom.areaFraming == .custom && custom.areaWindow == nil && custom.cameraPath?.count == 2
                && custom.cameraPath?.first?.x == window.xFrac && custom.cameraPath?.last?.t == 8 && !custom.centerStage)
        #expect(model.cameraRect(for: custom, atTimeline: 4)?.x == window.xFrac)
        model.setCameraKeyframe(uid, atTimeline: 4, rect: CameraPathKeyframe(t: 0, x: 0.3, y: 0, w: window.wFrac, h: 1))
        model.setCameraCut(uid, at: 1, cut: true)
        #expect(model.clip(uid)?.cameraPath?.map(\.t) == [0, 3.99, 4, 8])
        // A split hands each piece the part of the path it plays, on its own clock.
        guard case .success(let split) = model.splitClip(uid, at: 4) else { Issue.record("split refused"); return }
        let head = try #require(model.clip(split.head)), tail = try #require(model.clip(split.tail))
        #expect(head.cameraPath?.last?.t == 4 && CameraKeyframes.rect(head.cameraPath ?? [], at: 3.5)?.x == window.xFrac)
        #expect(tail.cameraPath?.first?.t == 0 && tail.cameraPath?.first?.x == 0.3 && tail.cameraPath?.last?.t == 4)
        model.setFraming(split.tail, .tracking)
        #expect(model.clip(split.tail)?.areaFraming == .tracking && model.clip(split.tail)?.cameraPath == nil)
        // A cell tracking inside a feed: Static crops that feed at the area's aspect.
        model.updateClip(split.tail) { $0.areaRegion = FreeCropRect(xFrac: 0.5, yFrac: 0, wFrac: 0.5, hFrac: 0.5) }
        model.setFraming(split.tail, .fixed)
        let fromFeed = try #require(model.clip(split.tail)?.areaWindow)
        #expect(fromFeed.hFrac == 0.5 && fromFeed.xFrac >= 0.5 && fromFeed.xFrac + fromFeed.wFrac <= 1 + 1e-9)
        let encoded = try JSONEncoder().encode(model.clip(split.tail)!)
        #expect(try JSONDecoder().decode(TimelineClip.self, from: encoded).areaRegion?.xFrac == 0.5)
    }

    @Test("framing switches between static, tracking and custom; custom edits at the playhead; the canvas rescales paths")
    func customFraming() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Framing")
        var scene = Fixtures.scene(id: 1, start: 0, end: 8)
        scene.centerStagePathJSON = String(decoding: try JSONEncoder().encode(SceneCameraPath(camera: "balanced",
            keyframes: [CameraPathKeyframe(t: 0, x: 0.1, y: 0, w: 0.3164, h: 1), CameraPathKeyframe(t: 8, x: 0.5, y: 0, w: 0.3164, h: 1)])), as: UTF8.self)
        model.updateScenes([scene])
        model.addScene(scene)
        let uid = try #require(model.document.videoTrack.first?.uid)
        #expect(model.clip(uid)?.framing == .fixed)
        #expect(abs(model.cropRatio(for: model.clip(uid)!) - 0.5625 / (16.0 / 9.0)) < 1e-9)
        model.setFraming(uid, .tracking)
        #expect(model.clip(uid)?.framing == .tracking && model.clip(uid)?.centerStage == true)
        #expect(model.cameraRect(for: model.clip(uid)!, atTimeline: 4).map { abs($0.x - 0.3) < 1e-9 } == true)
        // Editable: the tracked path becomes the clip's own.
        model.makeCameraPathEditable(uid)
        let custom = try #require(model.clip(uid))
        #expect(custom.framing == .custom && custom.cameraPath?.count == 2 && custom.cameraPathSource == nil)
        // A drag at 4 s (no keyframe within a quarter second) adds one; at 7.9 s it moves the last.
        model.setCameraKeyframe(uid, atTimeline: 4, rect: CameraPathKeyframe(t: 0, x: 0.6, y: 0, w: 0.3164, h: 1))
        #expect(model.clip(uid)?.cameraPath?.map(\.t) == [0, 4, 8])
        model.setCameraKeyframe(uid, atTimeline: 7.9, rect: CameraPathKeyframe(t: 0, x: 0.2, y: 0, w: 0.3164, h: 1))
        #expect(model.clip(uid)?.cameraPath?.map(\.t) == [0, 4, 8] && model.clip(uid)?.cameraPath?[2].x == 0.2)
        model.setCameraCut(uid, at: 1, cut: true)
        #expect(model.clip(uid)?.cameraPath?.map(\.t) == [0, 3.99, 4, 8])
        #expect(abs((model.cameraRect(for: model.clip(uid)!, atTimeline: 3.5)?.x ?? 0) - 0.1) < 1e-9)
        model.removeCameraKeyframe(uid, at: 2)
        #expect(model.clip(uid)?.cameraPath?.map(\.t) == [0, 8])
        // Square canvas: heights stay, widths follow, centers hold.
        var settings = model.document.renderSettings
        settings.preset = .square1080
        model.setRenderSettings(settings)
        let rescaled = try #require(model.clip(uid)?.cameraPath)
        #expect(abs(rescaled[0].w - 1 / (16.0 / 9.0)) < 1e-9 && rescaled[0].h == 1)
        model.setFraming(uid, .fixed)
        #expect(model.clip(uid)?.framing == .fixed && model.clip(uid)?.cameraPath == nil && model.clip(uid)?.cropXFrac == 0.5)
        #expect(model.cameraRect(for: model.clip(uid)!, atTimeline: 4) == nil)
        model.undoManager?.undo()
    }

    @Test("a whole file becomes one main clip from its start to its end, packed after the track's clips")
    func addWholeFile() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Files")
        let scene = Fixtures.scene(id: 1, start: 0, end: 4)
        model.updateScenes([scene])
        model.addScene(scene)
        let video = Fixtures.video()
        model.addVideo(video)
        let clips = model.document.videoTrack.sorted { $0.startTime < $1.startTime }
        #expect(clips.count == 2)
        let file = try #require(clips.last)
        #expect(file.sceneID == nil && file.videoFile == video.path && file.wide == video.wide)
        #expect(file.sourceStart == 0 && file.sourceEnd == 10 && file.duration == 10 && file.startTime == 4)
        #expect(file.role == .main && !file.isCutaway)
        #expect(model.selection == .clip(file.uid))
        #expect(model.sourceURL(for: file) == video.url)
        // Dropped at the pointer on a sequential track: inserted before the scene.
        model.addVideo(video, at: model.dropInsertionTime(track: 0, at: 1), track: 0, snapped: false)
        let order = model.document.videoTrack.sorted { $0.startTime < $1.startTime }
        #expect(order.map(\.sceneID) == [nil, 1, nil] && order.map(\.startTime) == [0, 10, 14])
        var empty = video; empty.duration = 0
        model.addVideo(empty)
        #expect(model.document.videoTrack.count == 3)
    }

    @Test("a drop on a sequential track inserts at the pointer: before the clip whose middle is to the right")
    func dropInsertsAtPointer() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Drop")
        let a = Fixtures.scene(id: 1, start: 0, end: 4)
        let b = Fixtures.scene(id: 2, start: 10, end: 16)
        let c = Fixtures.scene(id: 3, start: 20, end: 22)
        model.updateScenes([a, b, c])
        model.addScene(a)   // 0-4
        model.addScene(b)   // 4-10
        func order() -> [Int64] { model.clips(inTrack: 0).sorted { $0.startTime < $1.startTime }.compactMap(\.sceneID) }
        #expect(order() == [1, 2])
        // Past every middle: appended.
        #expect(model.dropInsertionTime(track: 0, at: 9) == 10)
        // Left of b's middle (7): before b, just under its start, unsnapped.
        #expect(abs(model.dropInsertionTime(track: 0, at: 5) - 3.999) < 1e-9)
        // Left of a's middle (2): before a.
        #expect(abs(model.dropInsertionTime(track: 0, at: 0.5) - (-0.001)) < 1e-9)
        model.addScene(c, at: model.dropInsertionTime(track: 0, at: 5), track: 0, snapped: false)
        #expect(order() == [1, 3, 2])
        #expect(model.clips(inTrack: 0).sorted { $0.startTime < $1.startTime }.map(\.startTime) == [0, 4, 6])
        model.addScene(c, at: model.dropInsertionTime(track: 0, at: 0.5), track: 0, snapped: false)
        #expect(order() == [3, 1, 3, 2])
        #expect(model.clips(inTrack: 0).map(\.startTime).min() == 0)
        // A free-placement track keeps the snapped pointer time.
        model.setTrackSequential(false, track: 0)
        #expect(model.dropInsertionTime(track: 0, at: 5.3) == 5.5)
    }

    @Test("every clip operation is undoable and redoable")
    func clipOperationsAndUndo() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Undo")
        let undo = makeUndoManager()
        model.undoManager = undo
        let scene = Fixtures.scene()
        model.updateScenes([scene])

        /// Run one edit as one user event, then check undo restores the
        /// document exactly and redo reproduces the edit's result.
        func checkUndoable(_ label: String, _ edit: () -> Void) {
            let before = model.document
            event(undo, edit)
            let after = model.document
            #expect(after != before, "\(label) changed nothing")
            #expect(undo.canUndo, "\(label) registered no undo step")
            undo.undo()
            #expect(model.document == before, "undo of \(label) did not restore the document")
            undo.redo()
            #expect(model.document == after, "redo of \(label) did not reapply the edit")
        }

        checkUndoable("addScene") { model.addScene(scene) }
        let uid = try #require(model.document.videoTrack.first?.uid)
        checkUndoable("setTrackSequential") { model.setTrackSequential(false, track: 0) }
        #expect(model.document.trackSequential[0] == false)
        checkUndoable("placeClip") { model.placeClip(uid, startTime: 2.24, track: 0) }
        #expect(model.clip(uid)?.startTime == 2)
        checkUndoable("duplicateClip") { model.duplicateClip(uid) }
        #expect(model.document.videoTrack.count == 2)
        checkUndoable("removeClip") { model.removeClip(uid) }
        #expect(model.document.videoTrack.count == 1)
    }

    @Test("source range edits clamp to the video and resolve sequential layout")
    func sourceRangeAndLayout() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Range")
        let scene = Fixtures.scene(start: 2, end: 6)   // videoDuration 10
        model.updateScenes([scene])
        model.addScene(scene)
        model.addScene(scene)
        let clips = model.document.videoTrack
        #expect(clips.count == 2)
        let first = clips[0].uid, second = clips[1].uid

        // Past the end of the video: end clamps to the duration, start to
        // end - 0.5 at most.
        model.setClipSourceRange(first, start: 9.8, end: 30)
        let edited = try #require(model.clip(first))
        #expect(edited.sourceStart == 9.5)
        #expect(edited.sourceEnd == 10)
        #expect(edited.duration == 0.5)

        // Sequential track: the second clip follows the shortened first one.
        #expect(model.document.trackSequential[0])
        #expect(model.clip(second)?.startTime == 0.5)

        // Free-form track keeps positions where they are.
        model.setTrackSequential(false, track: 0)
        model.placeClip(second, startTime: 4, track: 0)
        model.setClipSourceRange(first, start: 0, end: 3)
        #expect(model.clip(second)?.startTime == 4)
        model.setTrackSequential(true, track: 0)
        #expect(model.clip(second)?.startTime == 3)
    }

    @Test("crop blocks update layout and duration")
    func cropBlocks() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Crop")
        let uid = model.addCropBlock(CropLayoutRef(name: "50-50 Horizontal"), at: 1, duration: 3)
        #expect(model.cropBlock(uid)?.layout.areaCount == 2)
        model.setCropLayout(CropLayoutRef(name: "33-33-33 Horizontal"), for: uid)
        #expect(model.cropBlock(uid)?.layout.areaCount == 3)
        model.resizeCropBlock(uid, duration: 4.2)
        #expect(model.cropBlock(uid)?.duration == 4)
    }

    @Test("regression: clear cancels a pending autosave")
    func clearCancelsPendingAutosave() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Clear")
        model.addScene(Fixtures.scene())
        model.clear()
        // Force any pending save without yielding while the global override is held.
        model.flushPendingAutosave()
        #expect(BuilderStateStore.load(profileName: "Clear") == nil)
        #expect(model.document.videoTrack.isEmpty)
    }

    @Test("switching timelines flushes the pending database autosave")
    func timelineSwitchFlushesAutosave() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Projects")
        var savedTimelineID: Int64?
        var savedDocument: TimelineDocument?
        model.onTimelineAutosave = { id, document in
            savedTimelineID = id
            savedDocument = document
        }
        model.loadTimeline(id: 41, document: TimelineDocument())
        model.addScene(Fixtures.scene())

        model.loadTimeline(id: 42, document: TimelineDocument())

        #expect(savedTimelineID == 41)
        #expect(savedDocument?.videoTrack.count == 1)
    }

    @Test("switching profiles resets undo; replacing the timeline stays undoable")
    func loadResetsUndoAndReplaceIsUndoable() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        let undo = makeUndoManager()
        model.undoManager = undo
        model.load(profileName: "First")
        event(undo) { model.addScene(Fixtures.scene()) }
        #expect(undo.canUndo)

        // A different profile's timeline has nothing to do with the old
        // steps.
        model.load(profileName: "Second")
        #expect(!undo.canUndo)

        // "Open in Builder" replaces a timeline the user may have wanted;
        // one undo brings it back.
        event(undo) { model.addScene(Fixtures.scene()) }
        let before = model.document
        event(undo) { model.loadDocument(Fixtures.timelineDocument(clips: [])) }
        #expect(model.document.videoTrack.isEmpty)
        #expect(undo.canUndo)
        undo.undo()
        #expect(model.document == before)
    }

    @Test("changed scenes rehydrate the clips that referenced them")
    func rehydrateChangedScenes() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Rehydrate")
        let previous = Fixtures.scene()
        model.updateScenes([previous])
        model.loadDocument(Fixtures.timelineDocument())

        var changed = Fixtures.scene(start: 4, end: 9)
        changed.videoPath = "/tmp/changed.mp4"
        model.updateChangedScenes([changed])
        let clip = try #require(model.document.videoTrack.first)
        #expect(clip.sourceStart == 4)
        #expect(clip.duration == 5)
        #expect(clip.videoFile == "/tmp/changed.mp4")
        #expect(clip.sceneFullDuration == 5)

        // A user trim inside the scene survives a later scene edit.
        let uid = clip.uid
        model.setClipSourceRange(uid, start: 5, end: 7)
        var again = changed
        again.startTime = 3
        model.updateChangedScenes([again])
        #expect(model.clip(uid)?.sourceStart == 5)
        #expect(model.clip(uid)?.duration == 2)
    }
}
