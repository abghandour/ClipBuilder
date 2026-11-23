import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration options")
struct TelestrationOptionsTests {
    private func options() -> WizardOptions {
        var value = WizardOptions()
        value.useBRoll = false
        value.includeOutro = false
        value.includeIntroBumper = false
        value.includeOutroBumper = false
        value.includeMiddleBumper = false
        value.useMusic = false
        value.framing = Framing(subject: .original)
        value.allowedTransitions = ["fade"]
        return value
    }

    private func drawing(_ time: Double) -> Telestration {
        Telestration(time: time, figures: [.init(kind: .arrow,
            points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)])])
    }

    @Test("Old options omit both new keys on round trip")
    func legacyOptionsJSON() throws {
        let old = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(old.drawnPauses == nil && old.strikeHighlightStyle == nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(json["drawnPauses"] == nil && json["strikeHighlightStyle"] == nil)
        var selected = old
        selected.drawnPauses = false
        selected.strikeHighlightStyle = "solid"
        let restored = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(selected))
        #expect(restored.drawnPauses == false && restored.strikeHighlightStyle == "solid")
        let merged = WizardOptions.merge(step1: selected.step1, step2: selected.step2, base: old)
        #expect(merged.drawnPauses == false && merged.strikeHighlightStyle == "solid")
    }

    @Test("Express copies and stores both choices in overlay settings")
    func expressOptionCopies() throws {
        var settings = try JSONDecoder().decode(MiniWizardSettings.self, from: Data("{}".utf8))
        #expect(settings.drawnPauses == nil && settings.strikeHighlightStyle == nil)
        settings.drawnPauses = false
        settings.strikeHighlightStyle = "solid"
        let restored = try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(settings))
        var step = WizardStep2Options()
        restored.applyOverlayOptions(to: &step)
        #expect(step.drawnPauses == false && step.strikeHighlightStyle == "solid")
    }

    @Test("Per-profile drawing preferences and preset copies retain both choices")
    func drawingPreferencesAndPresets() throws {
        let suite = "drawing-options-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = MiniWizardSettings()
        settings.drawnPauses = false
        settings.strikeHighlightStyle = "solid"
        settings.remember(profileName: "Drawn", defaults: defaults)
        let remembered = MiniWizardSettings.remembered(profile: Fixtures.brand(name: "Drawn"), defaults: defaults)
        #expect(remembered.drawnPauses == false && remembered.strikeHighlightStyle == "solid")
        let untouched = MiniWizardSettings.remembered(profile: Fixtures.brand(name: "Other"), defaults: defaults)
        #expect(untouched.drawnPauses == nil && untouched.strikeHighlightStyle == nil)
        let adopted = MiniWizardSettings().adoptingOverlays(from: settings, strikeActions: false)
        #expect(adopted.drawnPauses == false && adopted.strikeHighlightStyle == nil)
        let bridged = WizardPresetBridge.miniSettings(from: WizardPresetBridge.wizardFields(from: settings))
        #expect(bridged.drawnPauses == false && bridged.strikeHighlightStyle == "solid")
        let kept = WizardPresetStore.presetFields(WizardPresetBridge.wizardFields(from: settings))
        #expect(kept["drawnPauses"] == .bool(false) && kept["strikeHighlightStyle"] == .string("solid"))
    }

    @Test("Embedded drawing revisions invalidate Builder previews without changing plain windows")
    func builderDrawingRevisionKey() throws {
        var clip = Fixtures.timelineClip()
        clip.hold = true
        clip.sourceEnd = clip.sourceStart
        clip.telestration = drawing(clip.sourceStart ?? 2)
        let document = Fixtures.timelineDocument(clips: [clip])
        let profile = Fixtures.brand()
        let first = try #require(AppStore.builderPreviewKey(document: document, scenes: [Fixtures.scene()],
            profile: profile, camera: "balanced", window: 0...3, drawingRevision: 1))
        let changed = AppStore.builderPreviewKey(document: document, scenes: [Fixtures.scene()],
            profile: profile, camera: "balanced", window: 0...3, drawingRevision: 2)
        #expect(first != changed)
        clip.telestration = nil
        let plain = Fixtures.timelineDocument(clips: [clip])
        #expect(AppStore.builderPreviewKey(document: plain, scenes: [], profile: profile, camera: "balanced",
            window: 0...3, drawingRevision: 1) == AppStore.builderPreviewKey(document: plain, scenes: [],
            profile: profile, camera: "balanced", window: 0...3, drawingRevision: 2))
    }

    @Test("Off matches absent drawings for cuts, clocks, messages and joins", arguments: [false, true])
    func disabledDrawingPreparation(contactsOn: Bool) {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let plan = Fixtures.plan(clips: [clip, clip], transitions: ["fade"])
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        var enabled = options()
        enabled.strikeImpactFreeze = contactsOn ? 0.8 : nil
        var disabled = enabled
        disabled.drawnPauses = false
        for dub in [false, true] {
            enabled.dubLanguage = dub ? "pt" : nil
            disabled.dubLanguage = enabled.dubLanguage
            let baseline = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut, 1: cut], sceneMap: map,
                sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [4]],
                options: enabled, xfadeDuration: 0.5)
            let off = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut, 1: cut], sceneMap: map,
                sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [4]],
                drawings: [scene.videoPath: [drawing(0.25), drawing(4.1), drawing(9.75)]],
                options: disabled, xfadeDuration: 0.5)
            // Split pieces get fresh ids on every call; everything else must match.
            func plain(_ cuts: [Int: TimelineDocument]) -> [Int: TimelineDocument] {
                cuts.mapValues { cut in
                    var cut = cut
                    for index in cut.videoTrack.indices { cut.videoTrack[index].uid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
                    return cut
                }
            }
            #expect(plain(off.cuts) == plain(baseline.cuts))
            #expect(off.cuts.mapValues { $0.videoTrack.count } == baseline.cuts.mapValues { $0.videoTrack.count })
            #expect(off.timings == baseline.timings)
            #expect(off.messages == baseline.messages)
            #expect(off.joins == baseline.joins)
        }
        let drawingOnly = WizardStrikePauses.timing(for: clip, contacts: [], seconds: nil,
            drawings: [drawing(0.25), drawing(9.75)])
        let offJoins = WizardStrikePauses.resolveJoins(plan: plan, options: disabled,
            timings: [0: drawingOnly, 1: drawingOnly], xfadeDuration: 0.5)
        let emptyJoins = WizardStrikePauses.resolveJoins(plan: plan, options: disabled, timings: [:], xfadeDuration: 0.5)
        #expect(offJoins == emptyJoins)
    }

    @Test("Both status services treat off as absent drawings", arguments: [false, true])
    func disabledDrawingStatuses(fight: Bool) {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let plan = Fixtures.plan(clips: [clip])
        var enabled = options()
        enabled.strikeImpactFreeze = fight ? 0.8 : nil
        var disabled = enabled
        disabled.drawnPauses = false
        let empty = StrikeClipStatusRules.Saved(contacts: [4])
        var drawn = empty
        drawn.drawings = [drawing(0.1), drawing(4.1), drawing(7)]
        let baseline = StrikeClipStatusRules.status(index: 0, plan: plan, scene: scene,
            sourceType: fight ? .fight : .podcast, saved: empty, options: enabled, xfadeDuration: 0.5)
        let off = StrikeClipStatusRules.status(index: 0, plan: plan, scene: scene,
            sourceType: fight ? .fight : .podcast, saved: drawn, options: disabled, xfadeDuration: 0.5)
        #expect(off == baseline)
        let preview = WizardPreviewClip(id: "clip", title: "Clip", scene: scene, start: 0, end: 10)
        let request = MiniStrikeStatusRequest(dataKey: "source", videoID: scene.videoID, isFight: fight,
            clips: [.init(preview: preview, plan: clip, planAvailable: true)], options: enabled, xfadeDuration: 0.5)
        var offRequest = request
        offRequest.options = disabled
        let miniBaseline = request.evaluate(saved: empty), miniOff = offRequest.evaluate(saved: drawn)
        #expect(miniOff.statuses == miniBaseline.statuses && miniOff.summary == miniBaseline.summary)
        #expect(offRequest != request)
        var changedRevision = request
        changedRevision.dataKey += ":drawing-revision"
        #expect(changedRevision != request)
    }

    @Test("The live status snapshot fetches only its video's drawings")
    func statusSnapshotDrawings() async throws {
        let temp = try await TempDatabase()
        let first = try await temp.seedVideo(), second = try await temp.seedVideo()
        let annotation = drawing(3)
        _ = try await temp.database.saveTelestration(.init(videoID: first, drawing: annotation))
        _ = try await temp.database.saveTelestration(.init(videoID: second, drawing: drawing(7)))
        let snapshot = try await temp.database.strikeClipStatusSnapshot(videoID: first)
        #expect(snapshot.drawings == [annotation])
    }

    @Test("Editor setTime, stepping and existing drawings stay within the row")
    @MainActor func boundedEditorTime() {
        let editor = TelestratorEditor(initialTime: 0, duration: 20, aspect: 16.0 / 9,
            existing: nil, range: 4...8)
        #expect(editor.drawing.time == 4)
        editor.setTime(100)
        #expect(editor.drawing.time == 8)
        editor.step(1)
        #expect(editor.drawing.time == 8)
        editor.setTime(-1)
        editor.step(-1)
        #expect(editor.drawing.time == 4)
        editor.step(1)
        #expect(abs(editor.drawing.time - (4 + 1.0 / 30)) < 1e-9)
        editor.undo()
        #expect(editor.drawing.time == 4)
        let existing = TelestratorEditor(initialTime: 5, duration: 20, aspect: 1,
            existing: drawing(12), range: 4...8)
        #expect(existing.drawing.time == 8)
        let whole = TelestratorEditor(initialTime: 2, duration: 20, aspect: 1, existing: nil)
        whole.setTime(0)
        #expect(whole.drawing.time == 0)
        whole.setTime(100)
        #expect(whole.drawing.time == TelestrationRules.sourceTime(100, duration: 20))
    }

    @Test("Drawing failure keeps the caption fallback, with every omission retained")
    func composedEncodeFallbackOrder() {
        #expect(SegmentEncodeFallback.attempts(drawings: true, captions: true) == [
            .init(drawings: true, captions: true), .init(drawings: false, captions: true),
            .init(drawings: false, captions: false)])
        #expect(SegmentEncodeFallback.attempts(drawings: false, captions: true) == [
            .init(drawings: false, captions: true), .init(drawings: false, captions: false)])
        #expect(SegmentEncodeFallback.attempts(drawings: true, captions: false) == [
            .init(drawings: true, captions: false), .init(drawings: false, captions: false)])
        #expect(SegmentEncodeFallback.attempts(drawings: false, captions: false) == [
            .init(drawings: false, captions: false)])
    }
}
