import AppKit
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder linked pause edits", .serialized)
struct BuilderPauseTests {
    private func drawing(stay: Double = 2) -> Telestration {
        Telestration(figures: [.init(kind: .line,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)])], stay: stay)
    }

    private func model(free: Bool = false) -> BuilderTimelineModel {
        let main = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6)
        let other = Fixtures.timelineClip(sceneID: nil, sourceStart: 30, duration: 6, track: 1)
        let later = Fixtures.timelineClip(sceneID: nil, startTime: 6, track: 1)
        var document = Fixtures.timelineDocument(clips: [main, other, later])
        document.trackCount = 2
        document.trackSequential[0] = !free; document.trackSequential[1] = !free
        document.soundTrack = [.init(name: "music", startTime: 1, duration: 8)]
        document.cropBlocks = [.init(layout: .init(name: "50-50 Horizontal"), startTime: 0, duration: 10)]
        // Persistent: a transient model registers no undo steps.
        let model = BuilderTimelineModel()
        model.loadTimeline(id: 54, document: document)
        model.onTimelineAutosave = { _, _ in }
        return model
    }

    private func undoRedo(_ model: BuilderTimelineModel, undo: UndoManager,
                          before: TimelineDocument, name: String) {
        let after = model.document
        #expect(undo.undoActionName == name)
        undo.undo()
        #expect(model.document == before && !undo.canUndo)
        undo.redo()
        #expect(model.document == after && !undo.canRedo)
        undo.removeAllActions()
    }

    private func alreadyPacked(_ model: BuilderTimelineModel) {
        let before = model.document
        for track in 0..<TimelineDocument.maxTracks { model.resolveLayout(track: track) }
        #expect(model.document.videoTrack.count == before.videoTrack.count)
        for (after, original) in zip(model.document.videoTrack, before.videoTrack) {
            #expect(after.uid == original.uid)
            #expect(abs(after.startTime - original.startTime) < 1e-8)
            #expect(abs(after.duration - original.duration) < 1e-8)
            #expect(after.sourceStart == original.sourceStart && after.sourceEnd == original.sourceEnd)
        }
    }

    @Test("Draw, edit drawing, trim and delete a companion each undo and redo once", arguments: [false, true])
    func linkedEdits(free: Bool) throws {
        let model = model(free: free)
        let source = try #require(model.document.videoTrack.first)
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        var before = model.document
        let group = try model.drawOnPause(source.uid, at: 2, drawing: drawing()).get()
        #expect(model.selection == .clip(group))
        let companion = try #require(model.document.videoTrack.first { $0.track == 1 && $0.pauseGroup == group })
        alreadyPacked(model)
        undoRedo(model, undo: undo, before: before, name: "Draw on Pause")

        before = model.document
        let note = drawing(stay: 6)
        try model.setDrawing(group, drawing: note).get()
        for hold in model.document.videoTrack.filter({ $0.pauseGroup == group }) {
            #expect(abs(hold.duration - note.duration) < 1e-8)
        }
        #expect(model.clip(companion.uid)?.telestration == nil)
        alreadyPacked(model)
        undoRedo(model, undo: undo, before: before, name: "Edit Drawing")

        before = model.document
        try model.setDrawing(group, drawing: nil).get()
        undoRedo(model, undo: undo, before: before, name: "Remove Drawing")
        before = model.document
        try model.trimClip(companion.uid, duration: 1.5).get()
        #expect(abs(try #require(model.clip(group)).duration - 1.5) < 1e-8)
        alreadyPacked(model)
        undoRedo(model, undo: undo, before: before, name: "Trim Freeze Frame")

        before = model.document
        model.selection = .clip(companion.uid)
        model.removeClip(companion.uid)
        #expect(model.clip(group) == nil && model.clip(companion.uid) == nil && model.selection == nil)
        #expect(model.document.videoTrack.filter { $0.hold != true && $0.originKey == source.originKey }.count == 2)
        alreadyPacked(model)
        undoRedo(model, undo: undo, before: before, name: "Delete Clip")
    }

    @Test("Freeze on impacts shifts free and sequential tracks in one undo step", arguments: [false, true])
    func freeze(free: Bool) throws {
        let model = model(free: free)
        let source = try #require(model.document.videoTrack.first)
        let later = try #require(model.document.videoTrack.last)
        let before = model.document
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.selection = .clip(source.uid)
        #expect(try model.freezeOnImpacts(source.uid, contacts: [11, 14], hold: 0.8).get() == 2)
        let holds = model.document.videoTrack.filter { $0.hold == true }
        #expect(holds.count == 4 && Set(holds.compactMap(\.pauseGroup)).count == 2)
        #expect(abs(try #require(model.clip(later.uid)).startTime - (later.startTime + 1.6)) < 1e-8)
        #expect(model.document.videoTrack.filter { $0.originKey == source.originKey }.allSatisfy { $0.strikeImpactsFrozen == true })
        #expect(model.document.videoTrack.filter { $0.track == 1 }.allSatisfy { $0.strikeImpactsFrozen == nil })
        let head = try #require(model.document.videoTrack.first)
        #expect(model.selection == .clip(head.uid))
        alreadyPacked(model)
        undoRedo(model, undo: undo, before: before, name: "Freeze on Impacts")
    }

    @Test("Legacy and orphaned holds retain their single-track edit behavior", arguments: [false, true])
    func legacy(orphaned: Bool) throws {
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 3, duration: 1)
        hold.hold = true; hold.sourceEnd = 3
        if orphaned { hold.pauseGroup = UUID() }
        let later = Fixtures.timelineClip(sceneID: nil, duration: 3, startTime: 1)
        let other = Fixtures.timelineClip(sceneID: nil, duration: 4, track: 1)
        var document = Fixtures.timelineDocument(clips: [hold, later, other])
        document.trackSequential[0] = false
        document.soundTrack = [.init(startTime: 1, duration: 3)]
        let model = BuilderTimelineModel(mode: .transient)
        model.seed(document: document, scenes: [])
        let baseline = model.document
        try model.setDrawing(hold.uid, drawing: drawing()).get()
        #expect(abs(try #require(model.clip(later.uid)).startTime - drawing().duration) < 1e-8)
        #expect(model.clip(other.uid) == other && model.document.soundTrack == baseline.soundTrack)
        try model.setDrawing(hold.uid, drawing: nil).get()
        let laterBeforeTrim = model.clip(later.uid)
        try model.trimClip(hold.uid, duration: 0.5).get()
        #expect(model.clip(later.uid) == laterBeforeTrim)
        #expect(model.clip(other.uid) == other && model.document.soundTrack == baseline.soundTrack)
        model.removeClip(hold.uid)
        #expect(model.clip(later.uid) == laterBeforeTrim && model.clip(other.uid) == other)
        #expect(model.document.soundTrack == baseline.soundTrack)
    }

    @Test("Near-edge and already-held companions remain packed through linked edits")
    func edgePacking() throws {
        for duration in [1.9, 2.1, 4.0] {
            let main = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
            var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: duration, track: 1)
            if duration == 4 { first.hold = true; first.sourceEnd = 10 }
            let next = Fixtures.timelineClip(sceneID: nil, sourceStart: 20, duration: 6 - duration,
                                             startTime: duration, track: 1)
            let model = BuilderTimelineModel(mode: .transient)
            model.seed(document: Fixtures.timelineDocument(clips: [main, first, next]), scenes: [])
            #expect(try model.freezeOnImpacts(main.uid, contacts: [2], hold: 1).get() == 1)
            let group = try #require(model.document.videoTrack.first { $0.track == 0 && $0.hold == true })
            alreadyPacked(model)
            try model.trimClip(group.uid, duration: 2).get()
            alreadyPacked(model)
            model.removeClip(group.uid)
            alreadyPacked(model)
        }
    }

    @Test("A pause lasts as long as its longest drawing; a plain picture of it cannot cut it short; a copy is its own freeze")
    func drawingOwnsThePause() throws {
        let model = model()
        let source = try #require(model.document.videoTrack.first)
        let group = try model.drawOnPause(source.uid, at: 2, drawing: drawing(stay: 6)).get()
        let long = try #require(model.clip(group)).duration
        let companion = try #require(model.document.videoTrack.first { $0.track == 1 && $0.pauseGroup == group })
        let before = model.document
        if case .success = model.trimClip(companion.uid, duration: 1) { Issue.record("companion trim accepted") }
        #expect(model.document == before)
        // A shorter drawing on the other picture leaves the pause at the longer one.
        try model.setDrawing(companion.uid, drawing: drawing(stay: 1)).get()
        #expect(abs(try #require(model.clip(group)).duration - long) < 1e-9)
        #expect(abs(try #require(model.clip(companion.uid)).duration - long) < 1e-9)
        #expect(model.clip(companion.uid)?.telestration != nil)
        // Removing the long one shrinks the pause to the remaining drawing.
        try model.setDrawing(group, drawing: nil).get()
        let short = drawing(stay: 1).duration
        #expect(abs(try #require(model.clip(group)).duration - short) < 1e-9)
        #expect(abs(try #require(model.clip(companion.uid)).duration - short) < 1e-9)
        let count = model.document.videoTrack.count
        model.duplicateClip(companion.uid)
        #expect(model.document.videoTrack.count == count + 1)
        #expect(model.document.videoTrack.filter { $0.pauseGroup == group }.count == 2)
    }
}
