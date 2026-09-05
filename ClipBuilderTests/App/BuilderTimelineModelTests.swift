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
    func clearCancelsPendingAutosave() async throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Clear")
        model.addScene(Fixtures.scene())
        model.clear()
        try await Task.sleep(for: .milliseconds(650))
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
