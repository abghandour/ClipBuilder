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

extension BuilderExpansionDiffTests {
    @Test func gapFieldsHaveIndividualDiffPaths() {
        let before = ScriptFixtures.gapModel().document
        let clip = "document.videoTrack.\(before.videoTrack[0].uid)."
        let bumper = "document.videoTrack.\(before.videoTrack[1].uid)."
        let text = "document.textOverlays.\(before.textOverlays[0].uid)."
        let image = "document.imageOverlays.\(before.imageOverlays[0].uid)."
        let edits: [(String, (inout TimelineDocument) -> Void)] = [
            (bumper + "bumperMode", { $0.videoTrack[1].bumperMode = .pause }),
            (clip + "volume", { $0.videoTrack[0].volume = 1 }),
            (clip + "position", { $0.videoTrack[0].position = "top" }),
            (clip + "cropXFrac", { $0.videoTrack[0].cropXFrac = 0.1 }),
            (clip + "muted", { $0.videoTrack[0].muted = true }),
            (image + "xFrac", { $0.imageOverlays[0].xFrac = 0.1 }),
            (image + "yFrac", { $0.imageOverlays[0].yFrac = 0.2 }),
            (image + "wFrac", { $0.imageOverlays[0].wFrac = 0.4 }),
            (image + "opacity", { $0.imageOverlays[0].opacity = 0.5 }),
            (text + "fontsize", { $0.textOverlays[0].fontsize = 60 }),
            (text + "fontcolor", { $0.textOverlays[0].fontcolor = "red" }),
            (text + "fontfamily", { $0.textOverlays[0].fontfamily = "Arial" }),
            (text + "bold", { $0.textOverlays[0].bold = true }),
            (text + "italic", { $0.textOverlays[0].italic = true }),
            (text + "bgcolor", { $0.textOverlays[0].bgcolor = "black" }),
            (text + "boxOpacity", { $0.textOverlays[0].boxOpacity = 0.2 }),
            (text + "boxRadius", { $0.textOverlays[0].boxRadius = 12 }),
            (text + "opacity", { $0.textOverlays[0].opacity = 0.5 }),
            (text + "strokeColor", { $0.textOverlays[0].strokeColor = "red" }),
            (text + "strokeWidthEm", { $0.textOverlays[0].strokeWidthEm = 0.2 }),
            (text + "shadowOpacity", { $0.textOverlays[0].shadowOpacity = 0.3 }),
            (text + "highlightColor", { $0.textOverlays[0].highlightColor = "yellow" }),
            (text + "design", { $0.textOverlays[0].design = "hero" }),
            (text + "kicker", { $0.textOverlays[0].kicker = "Label" }),
            (text + "accentColor", { $0.textOverlays[0].accentColor = "red" })
        ]
        for (path, edit) in edits {
            var after = before
            edit(&after)
            let diff = TimelineDiff(before: before, after: after)
            #expect(diff.changes.contains { $0.path == path })
        }
    }

    @Test func queryAndSummaryExposeCompactLaneState() throws {
        let model = ScriptFixtures.gapModel()
        model.document.videoTrack[0].volume = 2
        model.document.videoTrack[0].position = "top"
        model.document.videoTrack[0].cropXFrac = 0.2
        model.document.videoTrack[0].muted = true
        model.document.textOverlays[0].xFrac = 0.3
        model.document.textOverlays[0].yFrac = 0.4
        model.document.textOverlays[0].bold = true
        model.document.textOverlays[0].italic = true
        model.document.textOverlays[0].design = "hero"
        model.document.imageOverlays[0].opacity = 0.6
        let library = ScriptFixtures.gapLibrary()
        for kind in [BuilderQuery.Kind.timeline, .clips] {
            let result = try BuilderQuery(kind).execute(model: model, library: library, resolve: { _ in throw ScriptError.invalid("unused") })
            let clip = try #require(result.clips.first { !$0.bumper })
            #expect(clip.volume == 2 && clip.position == "top" && clip.cropFraction == 0.2 && clip.muted)
            // The clips query hides bumpers unless include_bumpers is set.
            if kind == .timeline {
                #expect(result.clips.first { $0.bumper }?.bumperMode == .overlap)
            } else {
                #expect(!result.clips.contains { $0.bumper })
            }
            // Lane rows ride on the first timeline page only.
            guard kind == .timeline else {
                #expect(result.sounds.isEmpty && result.overlays.isEmpty)
                continue
            }
            #expect(result.sounds.first?.name == "fixture.mp3" && result.sounds.first?.volume == 3)
            #expect(result.overlays.count == 3)
            let text = try #require(result.overlays.first { $0.lane == "text" })
            #expect(text.text == "Before" && text.x == 0.3 && text.y == 0.4)
            #expect(text.fontsize == 42 && text.bold == true && text.italic == true && text.design == "hero")
            let image = try #require(result.overlays.first { $0.lane == "image" })
            #expect(image.name == "photo" && image.width == 0.3 && image.opacity == 0.6)
        }
        let summary = try BuilderDocumentSummary(document: model.document, offset: 0, limit: 200)
        #expect(summary.rows.count == 7)
        let sound = try #require(summary.rows.first { $0.lane == "sound" })
        #expect(sound.name == "fixture.mp3" && sound.duration == 10)
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(!json.contains("/tmp/") && !json.contains("path"))
        #expect(json.contains("bumperMode") && json.contains("fontsize") && json.contains("cropFraction"))
        // A busy timeline caps lane rows at the page limit and says so.
        model.document.textOverlays = (0..<5).map { TextOverlayItem(text: "T\($0)") }
        let capped = try BuilderQuery(.timeline, limit: 2).execute(model: model, library: library, resolve: { _ in throw ScriptError.invalid("unused") })
        #expect(capped.overlays.count == 2)
        if case .object(let timeline)? = capped.timeline {
            #expect(timeline["laneRowsTruncated"] == .bool(true))
        } else {
            Issue.record("timeline object missing")
        }
    }

    @Test func templatesQueryListsSnapshotAndBuiltinWithPagination() throws {
        let model = ScriptFixtures.gapModel()
        let library = ScriptFixtures.gapLibrary()
        let query = try JSONDecoder().decode(BuilderQuery.self, from: Data(#"{"kind":"templates","limit":1}"#.utf8))
        let result = try query.execute(model: model, library: library, resolve: { _ in throw ScriptError.invalid("unused") })
        #expect(result.total == 2 && result.nextOffset == 1)
        #expect(result.templates == [TemplateQueryRow(name: "Lower Third", kind: "lower_third", duration: 4)])
        let next = try BuilderQuery(.templates, offset: 1, limit: 1).execute(model: model, library: library,
            resolve: { _ in throw ScriptError.invalid("unused") })
        #expect(next.templates == [TemplateQueryRow(name: "Title Card", kind: "template", duration: 5)])
        #expect(next.nextOffset == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BuilderQuery.self, from: Data(#"{"kind":"templates","filter":{}}"#.utf8))
        }
    }
}
