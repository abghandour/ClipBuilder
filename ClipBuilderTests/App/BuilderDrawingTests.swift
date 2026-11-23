import AppKit
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder drawing edits", .serialized)
struct BuilderDrawingTests {
    private func drawing(stay: Double = 2.7) -> Telestration {
        Telestration(time: 99, figures: [.init(kind: .line,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)])], stay: stay)
    }

    @Test("Draw on Pause packs its track, selects the hold, and undoes and redoes in one step", arguments: [0, 1])
    func insertionUndo(track: Int) throws {
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 4, track: track, speed: 2)
        let later = Fixtures.timelineClip(sceneID: nil, duration: 2, startTime: 4, track: track)
        let other = Fixtures.timelineClip(sceneID: nil, duration: 6, track: 1 - track)
        var cutaway = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 3, track: track)
        cutaway.role = .cutaway
        var document = Fixtures.timelineDocument(clips: [clip, later, other, cutaway])
        document.trackCount = 2
        document.cropBlocks = [.init(layout: .init(name: "50-50 Horizontal"), startTime: 0, duration: 20)]
        document.soundTrack = [.init(name: "fixture.mp3")]
        document.textOverlays = [.init(text: "Unmoved")]
        document.imageOverlays = [.init(path: "/tmp/fixture.png")]
        document.overlayBlocks = [.init()]
        model.loadTimeline(id: 53, document: document)
        model.onTimelineAutosave = { _, _ in }
        model.selection = .clip(clip.uid)
        let before = model.document
        let undo = UndoManager(); undo.groupsByEvent = false
        model.undoManager = undo
        let note = drawing()
        let uid = try model.drawOnPause(clip.uid, at: 3, drawing: note).get()
        let hold = try #require(model.clip(uid))
        #expect(model.selection == .clip(uid))
        #expect(hold.hold == true && hold.telestration != nil)
        #expect(abs(hold.startTime - 3) < 1e-9 && abs(hold.duration - note.duration) < 1e-9)
        #expect(abs(try #require(hold.sourceStart) - 8) < 1e-9)
        #expect(abs(try #require(model.clip(later.uid)).startTime - (4 + note.duration)) < 1e-9)
        #expect(model.document.videoTrack.filter { $0.originKey == other.originKey && $0.hold == true }.count == 1)
        #expect(abs(try #require(model.clip(cutaway.uid)).startTime - (cutaway.startTime + note.duration)) < 1e-9)
        #expect(abs(try #require(model.document.soundTrack.first).duration - (try #require(before.soundTrack.first).duration + note.duration)) < 1e-9)
        #expect(model.document.textOverlays == before.textOverlays)
        #expect(model.document.imageOverlays == before.imageOverlays)
        #expect(model.document.overlayBlocks == before.overlayBlocks)
        #expect(abs(try #require(model.document.cropBlocks.first).duration - (try #require(before.cropBlocks.first).duration + note.duration)) < 1e-9)
        let after = model.document
        #expect(undo.undoActionName == "Draw on Pause")
        undo.undo()
        #expect(model.document == before && !undo.canUndo)
        undo.redo()
        #expect(model.document == after && !undo.canRedo)
    }

    @Test("Add, edit and remove each pack later clips and each undo and redo once")
    func editUndo() throws {
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 3, duration: 0.8)
        hold.hold = true; hold.sourceEnd = 3
        let later = Fixtures.timelineClip(sceneID: nil, duration: 2, startTime: 0.8)
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        model.loadTimeline(id: 54, document: Fixtures.timelineDocument(clips: [hold, later]))
        model.onTimelineAutosave = { _, _ in }
        model.selection = .clip(hold.uid)
        let undo = UndoManager(); undo.groupsByEvent = false
        model.undoManager = undo
        for note in [drawing(), drawing(stay: 9), nil] as [Telestration?] {
            undo.removeAllActions()
            let before = model.document
            try model.setDrawing(hold.uid, drawing: note).get()
            let edited = try #require(model.clip(hold.uid))
            let length = note?.duration ?? 5
            #expect(abs(edited.duration - length) < 1e-9)
            #expect(abs(try #require(model.clip(later.uid)).startTime - length) < 1e-9)
            #expect((edited.telestration == nil) == (note == nil))
            #expect(abs(try #require(edited.sourceStart) - (try #require(hold.sourceStart))) < 1e-9)
            #expect(abs(try #require(edited.sourceEnd) - (try #require(hold.sourceEnd))) < 1e-9)
            #expect(model.selection == .clip(hold.uid))
            let after = model.document
            #expect(undo.undoActionName == (note == nil ? "Remove Drawing" : before.videoTrack.first { $0.uid == hold.uid }?.telestration == nil ? "Add Drawing" : "Edit Drawing"))
            undo.undo()
            #expect(model.document == before && !undo.canUndo)
            undo.redo()
            #expect(model.document == after && !undo.canRedo)
        }
    }

    @Test("Refused edits and manual drawn-hold trims do not change the document or undo stack")
    func refusals() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4)
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        model.loadTimeline(id: 55, document: Fixtures.timelineDocument(clips: [clip]))
        model.onTimelineAutosave = { _, _ in }
        let undo = UndoManager(); undo.groupsByEvent = false
        model.undoManager = undo
        let before = model.document
        #expect(throws: ClipEditFailure.outOfBounds) { try model.drawOnPause(clip.uid, at: 0.1, drawing: drawing()).get() }
        #expect(throws: ClipEditFailure.outOfBounds) { try model.setDrawing(clip.uid, drawing: drawing()).get() }
        #expect(throws: ClipEditFailure.notFound) { try model.setDrawing(UUID(), drawing: nil).get() }
        #expect(model.document == before && !undo.canUndo)
        let uid = try model.drawOnPause(clip.uid, at: 2, drawing: drawing()).get()
        undo.removeAllActions()
        let drawn = model.document
        for precision in [TimelinePrecision.ordinary, .speech] {
            #expect(throws: ClipEditFailure.outOfBounds) { try model.trimClip(uid, duration: 1, precision: precision).get() }
            #expect(throws: ClipEditFailure.outOfBounds) {
                try model.setClipSourceRange(uid, start: 2, end: 3, precision: precision).get()
            }
        }
        var invalid = drawing(); invalid.fade = 100
        #expect(throws: ClipEditFailure.outOfBounds) { try model.setDrawing(uid, drawing: invalid).get() }
        #expect(throws: ClipEditFailure.outOfBounds) { try model.drawOnPause(uid, at: 2.5, drawing: drawing()).get() }
        #expect(model.document == drawn && !undo.canUndo)
        try model.setDrawing(uid, drawing: nil).get()
        try model.trimClip(uid, duration: 1).get()
        #expect(abs(try #require(model.clip(uid)).duration - 1) < 1e-9)
    }

    @Test("On a free track what follows the freeze moves with it; legacy scene-backed clips resolve their source bounds")
    func freeTrackAndSceneBounds() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 4, startTime: 2)
        let later = Fixtures.timelineClip(sceneID: nil, startTime: 9)
        var document = Fixtures.timelineDocument(clips: [clip, later])
        document.trackSequential[0] = false
        let model = BuilderTimelineModel(mode: .transient)
        model.seed(document: document, scenes: [])
        let uid = try model.drawOnPause(clip.uid, at: 3, drawing: drawing()).get()
        // A free track is not packed, so the store moves the later clip itself:
        // left in place it would play over the freeze and the clip's own tail.
        let first = drawing().duration
        #expect(abs(try #require(model.clip(later.uid)).startTime - (9 + first)) < 1e-9)
        #expect(abs(try #require(model.clip(uid)).startTime - 3) < 1e-9)
        let tail = try #require(model.document.videoTrack.first { $0.track == 0 && $0.hold != true && $0.startTime > 3 && $0.uid != later.uid })
        #expect(abs(tail.startTime - (3 + first)) < 1e-9)
        try model.setDrawing(uid, drawing: drawing(stay: 9)).get()
        let second = drawing(stay: 9).duration
        #expect(abs(try #require(model.clip(later.uid)).startTime - (9 + second)) < 1e-9)
        #expect(abs(try #require(model.clip(tail.uid)).startTime - (3 + second)) < 1e-9)
        try model.setDrawing(uid, drawing: nil).get()
        let plain = try #require(model.clip(uid)).duration
        #expect(abs(try #require(model.clip(tail.uid)).startTime - (3 + plain)) < 1e-9)

        // A clip layered over the one drawn on, starting after the freeze, moves
        // too; B-roll on the track stays where it is bound.
        let base = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 4, startTime: 0)
        let over = Fixtures.timelineClip(sceneID: nil, duration: 3, startTime: 3)
        var broll = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 5)
        broll.role = .cutaway
        var layered = Fixtures.timelineDocument(clips: [base, over, broll])
        layered.trackSequential[0] = false
        model.seed(document: layered, scenes: [])
        _ = try model.drawOnPause(base.uid, at: 1, drawing: drawing()).get()
        #expect(abs(try #require(model.clip(over.uid)).startTime - (3 + first)) < 1e-9)
        #expect(abs(try #require(model.clip(broll.uid)).startTime - (5 + first)) < 1e-9)

        var legacy = Fixtures.timelineClip(duration: 4)
        legacy.sourceStart = nil; legacy.sourceEnd = nil
        model.seed(document: Fixtures.timelineDocument(clips: [legacy]), scenes: [Fixtures.scene(start: 10, end: 14)])
        let held = try model.drawOnPause(legacy.uid, at: 1, drawing: drawing()).get()
        #expect(abs(try #require(model.clip(held)?.sourceStart) - 11) < 1e-9)
    }

    @Test("The later part of a split drawing refuses an animation that ends before the split")
    func splitPieceRefusesTooShortDrawing() throws {
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 7, duration: 2.5, startTime: 0)
        hold.hold = true
        hold.sourceEnd = 7
        var carried = drawing(stay: 3.2)
        carried.offset = 1.5
        hold.telestration = carried
        let model = BuilderTimelineModel(mode: .transient)
        model.seed(document: Fixtures.timelineDocument(clips: [hold]), scenes: [])
        let before = model.document
        let short = Telestration(time: 7, figures: carried.figures.prefix(1).map { $0 }, stay: 0.5, drawSpeed: 0.5, fade: 0.3)
        #expect(short.duration < 1.5 + StrikeFreezeRules.minimumPiece)
        if case .success = model.setDrawing(hold.uid, drawing: short) { Issue.record("accepted") }
        #expect(model.document == before)
    }
}
