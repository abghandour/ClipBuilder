import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Expansion atomic Apply", .serialized)
struct BuilderExpansionApplyTests {
    @Test("Mixed expansion lists commit exactly once or apply nothing", arguments: [1, 5, 20])
    func atomic(count: Int) throws {
        let model = BuilderTimelineModel()
        var document = Fixtures.timelineDocument()
        document.soundTrack = [SoundItem(name: "fixture.mp3")]
        document.textOverlays = [TextOverlayItem(text: "Initial")]
        model.loadTimeline(id: 1, document: document)
        model.onTimelineAutosave = { _, _ in }
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let before = model.document
        let clip = before.videoTrack[0].uid.uuidString
        let sound = before.soundTrack[0].uid.uuidString
        let text = before.textOverlays[0].uid.uuidString
        let edits: [BuilderCommand] = [
            .setSoundVolume(sound: sound, volume: 2),
            .setSoundRange(sound: sound, start: 2, duration: 6),
            .moveSound(sound: sound, at: 4),
            .setText(overlay: text, text: "Edited"),
            .setTextPosition(overlay: text, position: "top"),
            .setOverlayRange(overlay: text, at: 2, duration: 5),
            .setOverlayTransitions(overlay: text, transIn: "cut", transOut: "pop"),
            .setClipSpeed(clip: clip, speed: 0.5),
            .setClipCaptions(clip: clip, captions: "bottom"),
            .setClipTransitions(clip: clip, transIn: "fade", transOut: "cut"),
            .setTrackCaptions(track: 0, captions: "bottom"),
            .setTrackMuted(track: 0, muted: true),
            .setRenderSettings(settings: .init(preset: .landscape1080)),
            .setPacing(pacing: .init(cadence: .threeSeconds))
        ]
        let steps = (0..<count).map { BuilderScriptStep(edits[$0 % edits.count]) }
        let failed = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        #expect(!failed.run(steps + [.init(.setText(overlay: UUID().uuidString, text: "Missing"))]).completed)
        failed.freeze()
        #expect(failed.frozenCandidate == nil)
        #expect(!undo.canUndo)
        #expect(ScriptValue.stored(model.document) == ScriptValue.stored(before))

        let valid = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        #expect(valid.run(steps).completed)
        valid.freeze()
        #expect(!undo.canUndo)
        let candidate = try #require(valid.frozenCandidate)
        _ = try model.applyScriptSnapshot(candidate: candidate, baseline: valid.baseline,
                                           baselineRevision: valid.baselineRevision, actionName: "Expansion").get()
        #expect(undo.canUndo)
        let applied = model.document
        #expect(ScriptValue.stored(applied) == ScriptValue.stored(candidate.document))
        undo.undo()
        #expect(!undo.canUndo && undo.canRedo)
        #expect(ScriptValue.stored(model.document) == ScriptValue.stored(before))
        undo.redo()
        #expect(!undo.canRedo && undo.canUndo)
        #expect(ScriptValue.stored(model.document) == ScriptValue.stored(applied))
    }
}
