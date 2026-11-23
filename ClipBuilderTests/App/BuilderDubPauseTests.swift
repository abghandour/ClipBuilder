import AppKit
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder dub pause undo", .serialized)
struct BuilderDubPauseTests {
    @Test("Draw, resize and delete derive dub silence in the same undo step")
    func undo() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 8)
        var document = Fixtures.timelineDocument(clips: [clip])
        document.dubLines = [DubLine(clipUID: clip.uid, speakerKey: "host", voice: "fixture", text: "Hello",
            sourceStart: 1, sourceEnd: 6, start: 1, duration: 5)]
        let model = BuilderTimelineModel()
        model.loadTimeline(id: 54, document: document)
        model.onTimelineAutosave = { _, _ in }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let drawing = Telestration(figures: [.init(kind: .line,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)])], stay: 2)
        var before = model.document
        let group = try model.drawOnPause(clip.uid, at: 3, drawing: drawing).get()
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
        try model.setDrawing(group, drawing: nil).get()
        undo.removeAllActions()
        before = model.document
        try model.trimClip(group, duration: 1.5).get()
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
        before = model.document
        model.removeClip(group)
        #expect(DubFreezes.intervals(in: model.document).isEmpty)
        try checkUndo(model, undo, before: before)
    }

    @Test("Freeze on impacts inserts both audio gaps in one undo step")
    func impacts() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 8)
        var document = Fixtures.timelineDocument(clips: [clip])
        document.dubLines = [DubLine(clipUID: clip.uid, speakerKey: "host", voice: "fixture", text: "Hello",
            sourceStart: 1, sourceEnd: 7, start: 1, duration: 6)]
        let model = BuilderTimelineModel()
        model.loadTimeline(id: 54, document: document)
        model.onTimelineAutosave = { _, _ in }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let before = model.document
        #expect(try model.freezeOnImpacts(clip.uid, contacts: [2, 5], hold: 0.8).get() == 2)
        let pauses = DubFreezes.intervals(in: model.document)
        #expect(pauses.count == 2)
        #expect(abs(pauses[0].lowerBound - 2) < 1e-8 && abs(pauses[1].lowerBound - 5.8) < 1e-8)
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
    }

    @Test("Trim, speed, cleanup, bumper insertion/removal and hold deletion follow current holds, including undo")
    func editsThenLayout() throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 10)
        clip.videoFile = "/dub-edit-source.mp4"
        var document = Fixtures.timelineDocument(clips: [clip])
        document.dubLines = [DubLine(clipUID: clip.uid, speakerKey: "host", voice: "fixture", text: "Hello",
            sourceStart: 0.25, sourceEnd: 9.25, start: 0.25, duration: 9)]
        let inserted = try #require(TimelinePauseRules.insert([.init(time: 4, duration: 1, owner: clip.uid)],
            into: document, resolve: { $0 }))
        let model = BuilderTimelineModel()
        model.loadTimeline(id: 54, document: inserted.document)
        model.onTimelineAutosave = { _, _ in }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let head = try #require(model.document.videoTrack.first { $0.hold != true && $0.startTime == 0 })
        try checkLayout(model.document)
        var before = model.document
        try model.trimClip(head.uid, duration: 3).get()
        #expect(abs(try #require(DubFreezes.intervals(in: model.document).first).lowerBound - 3) < 1e-9)
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
        before = model.document
        model.updateClip(head.uid, repack: true) { $0.speed = 2; $0.duration /= 2 }
        #expect(abs(try #require(DubFreezes.intervals(in: model.document).first).lowerBound - 1.5) < 1e-9)
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
        before = model.document
        #expect(model.applyAcceptedCleanupCuts([7: [0.5...1.0]], videoIDsByPath: ["/dub-edit-source.mp4": 7]) > 0)
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
        before = model.document
        model.addBumper(BumperAsset(path: "/dub-edit-bumper.mp4", displayName: "Bumper", duration: 1),
            at: 0.5, mode: .pause)
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
        let foundBumper = model.document.videoTrack.first { $0.bumper }
        let bumper = try #require(foundBumper)
        before = model.document
        model.removeClip(bumper.uid)
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
        before = model.document
        model.removeClip(inserted.holds[0])
        #expect(DubFreezes.intervals(in: model.document).isEmpty)
        try checkLayout(model.document)
        try checkUndo(model, undo, before: before)
    }

    /// This fixture's speech spans every hold. Compare each derived gap to
    /// the current hold interval, never to a saved audio-relative position.
    private func checkLayout(_ document: TimelineDocument) throws {
        let speech = try #require(document.dubLines?.first)
        let freezes = DubFreezes.intervals(in: document)
        let layout = DubPauseRules.layout(speech, freezes: freezes)
        let gaps = zip(layout.segments, layout.segments.dropFirst()).map {
            ($0.start + $0.duration)..<$1.start
        }
        #expect(gaps.count == freezes.count)
        for (gap, freeze) in zip(gaps, freezes) {
            #expect(abs(gap.lowerBound - freeze.lowerBound) < 1e-8)
            #expect(abs(gap.upperBound - freeze.upperBound) < 1e-8)
        }
    }

    private func checkUndo(_ model: BuilderTimelineModel, _ undo: UndoManager, before: TimelineDocument) throws {
        let after = model.document
        undo.undo()
        try checkLayout(model.document)
        #expect(model.document == before && !undo.canUndo)
        #expect(DubFreezes.intervals(in: model.document) == DubFreezes.intervals(in: before))
        undo.redo()
        try checkLayout(model.document)
        #expect(model.document == after && !undo.canRedo)
        #expect(DubFreezes.intervals(in: model.document) == DubFreezes.intervals(in: after))
        undo.removeAllActions()
    }
}
