import AppKit
import Testing
@testable import Clip_Builder

@MainActor @Suite("Builder impact flashes")
struct BuilderStrikeImpactTests {
    @Test func oneUndoAndOtherLanesStayPut() throws {
        let first = Fixtures.timelineClip(sourceStart: 0, duration: 4)
        let later = Fixtures.timelineClip(sourceStart: 0, duration: 2, startTime: 4)
        let other = Fixtures.timelineClip(sourceStart: 0, duration: 6, track: 1)
        var document = Fixtures.timelineDocument(clips: [first, later, other])
        document.trackCount = 2
        document.soundTrack = [SoundItem(name: "music")]
        document.textOverlays = [TextOverlayItem(text: "Unmoved")]
        document.imageOverlays = [ImageOverlayItem(path: "/tmp/image.png")]
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 6)]
        document.overlayBlocks = [OverlayBlockItem()]
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        model.loadTimeline(id: 53, document: document)
        model.onTimelineAutosave = { _, _ in }
        let before = model.document
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        #expect(try model.flashOnImpacts(first.uid, contacts: [1, 3]).get() == 2)
        #expect(model.clip(later.uid) == later && model.clip(other.uid) == other)
        #expect(model.document.soundTrack == before.soundTrack)
        #expect(model.document.textOverlays == before.textOverlays)
        #expect(model.document.imageOverlays == before.imageOverlays)
        #expect(model.document.overlayBlocks == before.overlayBlocks)
        #expect(model.document.cropBlocks == before.cropBlocks)
        #expect(undo.undoActionName == "Flash on Impacts")
        let flashed = model.document
        undo.undo()
        #expect(model.document == before && !undo.canUndo)
        undo.redo()
        #expect(model.document == flashed)
        let piece = try #require(model.document.videoTrack.first { $0.flashIn != nil })
        model.removeImpactFlash(piece.uid)
        #expect(model.clip(piece.uid)?.flashIn == nil)
        undo.undo()
        #expect(model.clip(piece.uid)?.flashIn == 0.12)
    }
    @Test func slowUndoRedoAndRemoval() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        let companion = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6, track: 1)
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        model.loadTimeline(id: 53, document: Fixtures.timelineDocument(clips: [clip, companion]))
        model.onTimelineAutosave = { _, _ in }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let before = model.document
        let result = try model.slowIntoImpacts(clip.uid, contacts: [2, 4]).get()
        #expect(result.count == 2 && result.skipped == 0)
        #expect(undo.undoActionName == "Slow into Impacts")
        let slowed = model.document
        // Slow motion alone must select the exact frame/sample assembly.
        #expect(MultitrackRenderer.usesTimedAssembly(slowed, transitions: []))
        #expect(!MultitrackRenderer.usesTimedAssembly(before, transitions: []))
        undo.undo()
        #expect(model.document == before && !undo.canUndo)
        undo.redo()
        #expect(model.document == slowed)
        let piece = try #require(model.document.videoTrack.first { $0.slowGroup != nil })
        try model.removeImpactSlowMotion(piece.uid).get()
        #expect(undo.undoActionName == "Remove Slow Motion")
        undo.undo()
        #expect(model.document == slowed)
    }

    @Test func slowAtEndOfFrozenHead() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4)
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        model.loadTimeline(id: 53, document: Fixtures.timelineDocument(clips: [clip]))
        model.onTimelineAutosave = { _, _ in }
        #expect(try model.freezeOnImpacts(clip.uid, contacts: [2], hold: 0.8).get() == 1)
        let head = try #require(model.document.videoTrack.first)
        let result = try model.slowIntoImpacts(head.uid, contacts: [2]).get()
        #expect(result.count == 1)
        let hold = try #require(model.document.videoTrack.first { $0.hold == true })
        #expect(abs(hold.startTime - 2.75) < 1e-9)
    }

    @Test(arguments: [false, true])
    func freezeAtSlowBoundaryKeepsEitherEditWhenOtherRemoved(removePause: Bool) throws {
        let original = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4)
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        model.loadTimeline(id: 53, document: Fixtures.timelineDocument(clips: [original]))
        model.onTimelineAutosave = { _, _ in }
        #expect(try model.slowIntoImpacts(original.uid, contacts: [2]).get().count == 1)
        let slowed = try #require(model.document.videoTrack.first { $0.slowGroup != nil })
        #expect(try model.freezeOnImpacts(slowed.uid, contacts: [2], hold: 0.8).get() == 1)
        let hold = try #require(model.document.videoTrack.first { $0.hold == true })
        #expect(abs(hold.startTime - 2.75) < 1e-9)
        #expect(abs((hold.sourceStart ?? -1) - 2) < 1e-9)
        if removePause {
            let pauseGroup = try #require(hold.pauseGroup)
            let removed = try #require(TimelinePauseRules.removed(group: pauseGroup, in: model.document))
            #expect(removed.videoTrack.contains { $0.slowGroup == slowed.slowGroup && abs($0.effectiveSpeed - 0.4) < 1e-9 })
        } else {
            let slowGroup = try #require(slowed.slowGroup)
            let removed = try #require(TimelineSlowRules.removed(group: slowGroup, in: model.document))
            let kept = try #require(removed.videoTrack.first { $0.uid == hold.uid })
            #expect(abs(kept.startTime - 2) < 1e-9 && abs(kept.duration - 0.8) < 1e-9)
        }
    }

}
