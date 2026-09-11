import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Expansion field diff coverage")
struct BuilderExpansionDiffTests {
    @Test func everyStoredExpansionFieldHasAnIndividualPath() {
        var before = Fixtures.timelineDocument()
        before.soundTrack = [SoundItem(name: "music")]
        before.textOverlays = [TextOverlayItem(text: "before")]
        before.imageOverlays = [ImageOverlayItem()]
        before.overlayBlocks = [OverlayBlockItem()]
        // Keep optionals present so the expected diff descends to leaf fields.
        before.videoTrack[0].areaWindow = FreeCropRect()
        let clip = "document.videoTrack.\(before.videoTrack[0].uid)."
        let sound = "document.soundTrack.\(before.soundTrack[0].uid)."
        let text = "document.textOverlays.\(before.textOverlays[0].uid)."
        let image = "document.imageOverlays.\(before.imageOverlays[0].uid)."
        let block = "document.overlayBlocks.\(before.overlayBlocks[0].uid)."
        let edits: [(String, (inout TimelineDocument) -> Void)] = [
            (sound + "volume", { $0.soundTrack[0].volume = 1 }),
            (sound + "startTime", { $0.soundTrack[0].startTime = 2 }),
            (sound + "duration", { $0.soundTrack[0].duration = 4 }),
            (text + "text", { $0.textOverlays[0].text = "after" }),
            (text + "position", { $0.textOverlays[0].position = "top" }),
            (text + "xFrac", { $0.textOverlays[0].xFrac = 0.2 }),
            (text + "yFrac", { $0.textOverlays[0].yFrac = 0.3 }),
            (text + "startTime", { $0.textOverlays[0].startTime = 1 }),
            (text + "endTime", { $0.textOverlays[0].endTime = 6 }),
            (text + "transIn", { $0.textOverlays[0].transIn = "cut" }),
            (text + "transOut", { $0.textOverlays[0].transOut = "cut" }),
            (image + "startTime", { $0.imageOverlays[0].startTime = 1 }),
            (image + "endTime", { $0.imageOverlays[0].endTime = 6 }),
            (image + "transIn", { $0.imageOverlays[0].transIn = "cut" }),
            (image + "transOut", { $0.imageOverlays[0].transOut = "cut" }),
            (block + "startTime", { $0.overlayBlocks[0].startTime = 1 }),
            (block + "duration", { $0.overlayBlocks[0].duration = 6 }),
            (clip + "speed", { $0.videoTrack[0].speed = 0.5 }),
            (clip + "duration", { $0.videoTrack[0].duration += 1 }),
            (clip + "fadeIn", { $0.videoTrack[0].fadeIn = 0.2 }),
            (clip + "fadeOut", { $0.videoTrack[0].fadeOut = 0.2 }),
            (clip + "captions", { $0.videoTrack[0].captions = "bottom" }),
            (clip + "transIn", { $0.videoTrack[0].transIn = "fade" }),
            (clip + "transOut", { $0.videoTrack[0].transOut = "fade" }),
            (clip + "centerStage", { $0.videoTrack[0].centerStage = true }),
            (clip + "screenCrop", { $0.videoTrack[0].screenCrop = "legacy" }),
            (clip + "areaWindow.xFrac", { $0.videoTrack[0].areaWindow?.xFrac = 0.1 }),
            (clip + "areaWindow.yFrac", { $0.videoTrack[0].areaWindow?.yFrac = 0.1 }),
            (clip + "areaWindow.wFrac", { $0.videoTrack[0].areaWindow?.wFrac = 0.5 }),
            (clip + "areaWindow.hFrac", { $0.videoTrack[0].areaWindow?.hFrac = 0.5 }),
            ("document.trackSettings.0.captions", { $0.trackSettings[0].captions = "bottom" }),
            ("document.trackSettings.0.muted", { $0.trackSettings[0].muted = true }),
            ("document.trackSettings.0.defaultPosition", { $0.trackSettings[0].defaultPosition = "bottom" }),
            ("document.trackSettings.0.defaultCropXFrac", { $0.trackSettings[0].defaultCropXFrac = 0.3 }),
            ("document.trackSettings.0.label", { $0.trackSettings[0].label = "Legacy label" }),
            ("document.renderSettings.preset", { $0.renderSettings.preset = .custom }),
            ("document.renderSettings.customWidth", { $0.renderSettings.customWidth = 1280 }),
            ("document.renderSettings.customHeight", { $0.renderSettings.customHeight = 720 }),
            ("document.renderSettings.quality", { $0.renderSettings.quality = .custom }),
            ("document.renderSettings.customCRF", { $0.renderSettings.customCRF = 24 }),
            ("document.pacing.cadence", { $0.pacing.cadence = .twoSeconds }),
            ("document.pacing.curve", { $0.pacing.curve = .accelerate })
        ]
        for (path, edit) in edits {
            var after = before
            edit(&after)
            let diff = TimelineDiff(before: before, after: after)
            #expect(diff.changes.contains { $0.path == path }, "Missing \(path)")
            #expect(!diff.isEmpty)
        }
    }

    @Test func readableWizardLinesIncludeSettingsAndEdits() {
        let model = ScriptFixtures.model()
        let session = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        let steps: [BuilderScriptStep] = [
            .init(.setClipSpeed(clip: model.document.videoTrack[0].uid.uuidString, speed: 0.5)),
            .init(.setTrackCaptions(track: 0, captions: "bottom")),
            .init(.setRenderSettings(settings: .init(preset: .landscape1080))),
            .init(.setPacing(pacing: .init(cadence: .twoSeconds)))
        ]
        #expect(session.run(steps).completed)
        session.freeze()
        let lines = BuilderWizardDiff.lines(session: session, steps: steps).joined(separator: "\n")
        #expect(lines.contains("speed") && lines.contains("Track 1") && lines.contains("captions"))
        #expect(lines.contains("Output") && lines.contains("Pacing"))
    }
}
