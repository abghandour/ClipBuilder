import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Scriptable Builder surface expansion")
struct BuilderExpansionTests {
    private func model() -> BuilderTimelineModel {
        let model = ScriptFixtures.model()
        model.document.soundTrack = [SoundItem(name: "fixture.mp3")]
        model.document.textOverlays = [TextOverlayItem(text: "Before")]
        model.document.imageOverlays = [ImageOverlayItem(path: "/tmp/photo.png")]
        model.document.overlayBlocks = [OverlayBlockItem()]
        return model
    }

    private func commands(_ model: BuilderTimelineModel) -> [BuilderCommand] {
        let clip = model.document.videoTrack[0].uid.uuidString
        let sound = model.document.soundTrack[0].uid.uuidString
        let text = model.document.textOverlays[0].uid.uuidString
        return [
            .setSoundVolume(sound: sound, volume: 2),
            .setSoundRange(sound: sound, start: 1, duration: 4),
            .moveSound(sound: sound, at: 2),
            .setText(overlay: text, text: "After"),
            .setTextPosition(overlay: text, position: "top"),
            .setOverlayRange(overlay: text, at: 2, duration: 4),
            .setOverlayTransitions(overlay: text, transIn: "pop", transOut: "cut"),
            .setClipSpeed(clip: clip, speed: 0.5),
            .setClipFades(clip: clip, fadeIn: 0.2, fadeOut: 0.3),
            .setClipCaptions(clip: clip, captions: "bottom"),
            .setClipTransitions(clip: clip, transIn: "fade", transOut: "cut"),
            .setClipCenterStage(clip: clip, enabled: true),
            .setClipAreaWindow(clip: clip, x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            .setTrackCaptions(track: 0, captions: "bottom"),
            .setTrackMuted(track: 0, muted: true),
            .setTrackPosition(track: 0, position: "bottom"),
            .setTrackCrop(track: 0, fraction: 0.3),
            .setRenderSettings(settings: .init(preset: .custom, customWidth: 1280, customHeight: 720,
                                                quality: .custom, customCRF: 24)),
            .setPacing(pacing: .init(cadence: .twoSeconds, curve: .accelerate))
        ]
    }

    @Test func everyOperationRoundTripsAndRejectsUnknownOrMissingFields() throws {
        for command in commands(model()) {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(BuilderCommand.self, from: data) == command)
            let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var extra = original; extra["file_path"] = "/tmp/invented"
            let extraData = try JSONSerialization.data(withJSONObject: extra)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BuilderCommand.self, from: extraData) }
            for key in original.keys where key != "op" {
                var missing = original; missing.removeValue(forKey: key)
                // set_track_crop requires the key, but permits explicit null.
                let missingData = try JSONSerialization.data(withJSONObject: missing)
                #expect(throws: (any Error).self) { try JSONDecoder().decode(BuilderCommand.self, from: missingData) }
            }
        }
    }

    @Test func clearCropAndPartialRenderPatch() throws {
        let model = model()
        model.document.trackSettings[0].defaultCropXFrac = 0.3
        let clear = BuilderCommand.setTrackCrop(track: 0, fraction: nil)
        #expect(try JSONDecoder().decode(BuilderCommand.self, from: JSONEncoder().encode(clear)) == clear)
        #expect(!ScriptRunner().run([.init(clear)], model: model, library: ScriptFixtures.library()).contains { $0.isRefused })
        #expect(model.document.trackSettings[0].defaultCropXFrac == nil)
        let previous = model.document.renderSettings
        let patch = BuilderCommand.setRenderSettings(settings: .init(quality: .compact))
        #expect(!ScriptRunner().run([.init(patch)], model: model, library: ScriptFixtures.library()).contains { $0.isRefused })
        #expect(model.document.renderSettings.quality == .compact)
        #expect(model.document.renderSettings.preset == previous.preset)
        #expect(model.document.renderSettings.customWidth == previous.customWidth)
        #expect(model.document.renderSettings.customCRF == previous.customCRF)
    }

    @Test func textPositionClearsFractionalOverrides() {
        let model = model()
        model.document.textOverlays[0].xFrac = 0.5
        model.document.textOverlays[0].yFrac = 0.8
        let uid = model.document.textOverlays[0].uid.uuidString
        let command = BuilderCommand.setTextPosition(overlay: uid, position: "top")
        #expect(!ScriptRunner().run([.init(command)], model: model, library: ScriptFixtures.library()).contains { $0.isRefused })
        #expect(model.document.textOverlays[0].position == "top")
        #expect(model.document.textOverlays[0].xFrac == nil && model.document.textOverlays[0].yFrac == nil)
    }

    @Test func malformedValuesAreRejected() throws {
        let invalid = [
            #"{"op":"set_sound_volume","sound":"x","volume":6}"#,
            #"{"op":"set_sound_range","sound":"x","start":-1,"duration":2}"#,
            #"{"op":"move_sound","sound":"x","at":86401}"#,
            #"{"op":"set_text","overlay":"x","text":3}"#,
            #"{"op":"set_text_position","overlay":"x","position":"middle"}"#,
            #"{"op":"set_overlay_range","overlay":"x","at":0,"duration":0.1}"#,
            #"{"op":"set_overlay_transitions","overlay":"x","trans_in":"invented","trans_out":"cut"}"#,
            #"{"op":"set_clip_speed","clip":"x","speed":0.1}"#,
            #"{"op":"set_clip_fades","clip":"x","fade_in":0,"fade_out":-1}"#,
            #"{"op":"set_clip_captions","clip":"x","captions":"center"}"#,
            #"{"op":"set_clip_transitions","clip":"x","trans_in":"slide_up","trans_out":"cut"}"#,
            #"{"op":"set_clip_center_stage","clip":"x","enabled":1}"#,
            #"{"op":"set_clip_area_window","clip":"x","x":0.8,"y":0,"width":0.5,"height":1}"#,
            #"{"op":"set_track_captions","track":0,"captions":"inherit"}"#,
            #"{"op":"set_track_muted","track":0,"muted":"yes"}"#,
            #"{"op":"set_track_position","track":0,"position":"left"}"#,
            #"{"op":"set_track_crop","track":0,"fraction":1.1}"#,
            #"{"op":"set_render_settings","settings":{"custom_width":241}}"#,
            #"{"op":"set_render_settings","settings":{"custom_crf":40}}"#,
            #"{"op":"set_render_settings","settings":{"preset":null}}"#,
            #"{"op":"set_render_settings","settings":{"path":"/tmp/a"}}"#,
            #"{"op":"set_pacing","pacing":{"cadence":"fast","curve":"steady"}}"#,
            #"{"op":"set_pacing","pacing":{"cadence":"automatic","curve":"steady","extra":1}}"#
        ]
        for json in invalid {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BuilderCommand.self, from: Data(json.utf8)) }
        }
    }

    @Test func targetResolutionAndTypedRefusals() throws {
        let model = model()
        for command in commands(model) {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
            guard let target = ["clip", "sound", "overlay"].first(where: { object[$0] != nil }) else { continue }
            for reference in [UUID().uuidString, "$missing", "/tmp/not-an-id"] {
                object[target] = reference
                let unknown = try JSONDecoder().decode(BuilderCommand.self, from: JSONSerialization.data(withJSONObject: object))
                let result = ScriptRunner().run([.init(unknown)], model: model, library: ScriptFixtures.library())
                guard case .refused(let code, _) = result.first else { Issue.record("Expected refusal"); continue }
                #expect(code == "unknown_id")
            }
        }
        for command in [BuilderCommand.setClipSpeed(clip: "x", speed: .nan),
                        .setSoundRange(sound: "x", start: .infinity, duration: 3),
                        .setTrackCaptions(track: 100, captions: "none")] {
            let result = ScriptRunner().run([.init(command)], model: model, library: ScriptFixtures.library())
            guard case .refused(let code, _) = result.first else { Issue.record("Expected bounds refusal"); continue }
            #expect(code == "out_of_bounds")
        }
    }

    @Test func supportedSettersAreIdempotentAndDiffEveryChangedField() throws {
        let model = model()
        let unsupported: Set<String> = ["set_clip_fades", "set_clip_area_window", "set_clip_center_stage"]
        for command in commands(model) {
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
            if let op = object["op"] as? String, unsupported.contains(op) { continue }
            let before = model.document
            let result = ScriptRunner().run([.init(command)], model: model, library: ScriptFixtures.library())
            #expect(!result.contains { $0.isRefused })
            #expect(!TimelineDiff(before: before, after: model.document).isEmpty)
            let second = ScriptRunner().run([.init(command)], model: model, library: ScriptFixtures.library())
            guard case .unchanged = second.first else { Issue.record("Setter must be unchanged: \(command)"); continue }
        }
    }

    @Test func removedOperationsAreUnknown() throws {
        // Assemble absent names so literal vocabulary searches only find the model-limit docs.
        let operations = [
            ["set", "sound", "fades"],
            ["set", "track", "volume"],
            ["set", "clip", "screen", "crop"]
        ].map { $0.joined(separator: "_") }
        let fields: [[String: Any]] = [
            ["sound": "x", "fade_in": 0, "fade_out": 0],
            ["track": 0, "volume": 3],
            ["clip": "x", "layout": "Full Screen"]
        ]
        for (op, fields) in zip(operations, fields) {
            for payload in [["op": op] as [String: Any], fields.merging(["op": op]) { _, new in new }] {
                let data = try JSONSerialization.data(withJSONObject: payload)
                #expect(throws: ScriptError.invalid("Unknown operation: \(op)")) {
                    try JSONDecoder().decode(BuilderCommand.self, from: data)
                }
            }
        }
    }

    @Test func unavailableSettingsRefuseWithoutMutation() {
        let model = model()
        let clip = model.document.videoTrack[0].uid.uuidString
        let block = model.document.overlayBlocks[0].uid.uuidString
        let before = ScriptValue.stored(model.document)
        for command in [BuilderCommand.setOverlayTransitions(overlay: block, transIn: "fade", transOut: "cut"),
                        .setClipFades(clip: clip, fadeIn: 0.2, fadeOut: 0.2)] {
            let result = ScriptRunner().run([.init(command)], model: model, library: ScriptFixtures.library())
            guard case .refused(let code, _) = result.first else { Issue.record("Expected refusal"); continue }
            #expect(code == "invalid_value")
            #expect(ScriptValue.stored(model.document) == before)
        }
    }

    @Test func overlayLanesAndBindings() {
        let model = model()
        let ids = [model.document.textOverlays[0].uid, model.document.imageOverlays[0].uid, model.document.overlayBlocks[0].uid]
        for uid in ids {
            let result = ScriptRunner().run([.init(.setOverlayRange(overlay: uid.uuidString, at: 3, duration: 6))],
                                            model: model, library: ScriptFixtures.library())
            #expect(!result.contains { $0.isRefused })
        }
        let image = model.document.imageOverlays[0].uid.uuidString
        #expect(!ScriptRunner().run([.init(.setOverlayTransitions(overlay: image, transIn: "pop", transOut: "cut"))],
                                   model: model, library: ScriptFixtures.library()).contains { $0.isRefused })
        let result = ScriptRunner().run([
            .init(.addSound(sound: "music", duration: 3), bind: "music"),
            .init(.setSoundVolume(sound: "$music", volume: 1)),
            .init(.addText(text: "First"), bind: "title"),
            .init(.setText(overlay: "$title", text: "Bound"))
        ], model: model, library: ScriptFixtures.library())
        #expect(!result.contains { $0.isRefused })
        #expect(model.document.soundTrack.last?.volume == 1)
        #expect(model.document.textOverlays.last?.text == "Bound")
    }
}

extension BuilderExpansionTests {
    @Test func everyBuilderGapCommandChangesStateAndReportsDiff() throws {
        let expectedPaths = ["bumperMode", "duration", "cropBlocks", "soundTrack", "overlayBlocks",
                             "wFrac", "xFrac", "fontsize", "volume", "position", "cropXFrac", "videoTrack", "videoTrack"]
        for index in 0..<13 {
            let model = ScriptFixtures.gapModel()
            if index == 1 || index == 2 {
                model.document.cropBlocks[0].layout = CropLayoutRef(name: "50-50 Horizontal")
            }
            let command = ScriptFixtures.gapCommands(model)[index]
            let before = model.document
            let outcomes = ScriptRunner().run([.init(command)], model: model, library: ScriptFixtures.gapLibrary())
            guard case .applied = outcomes.first else { Issue.record("Expected apply for \(command): \(outcomes)"); continue }
            let diff = TimelineDiff(before: before, after: model.document)
            #expect(diff.changes.contains { $0.path.contains(expectedPaths[index]) })
            switch index {
            case 0: #expect(model.document.videoTrack.first { $0.bumper }?.bumperMode == .pause)
            case 1: #expect(model.document.cropBlocks.first { $0.uid == before.cropBlocks[0].uid }?.duration == 8)
            case 2: #expect(model.document.cropBlocks.contains { $0.startTime == 2 && $0.duration == 8 })
            case 3: #expect(model.document.soundTrack.isEmpty)
            case 4:
                #expect(model.document.overlayBlocks.last?.name == "Title Card")
                #expect(model.document.overlayBlocks.last?.duration == 4)
            case 5: #expect(model.document.imageOverlays[0].wFrac == 0.4 && model.document.imageOverlays[0].opacity == 0.6)
            case 6: #expect(model.document.textOverlays[0].xFrac == 0.2 && model.document.textOverlays[0].yFrac == 0.3)
            case 7: #expect(model.document.textOverlays[0].fontsize == 60 && model.document.textOverlays[0].bold)
            case 8: #expect(model.document.videoTrack.first { $0.bumper }?.volume == 2)
            case 9: #expect(model.document.videoTrack[0].position == "top")
            case 10: #expect(model.document.videoTrack[0].cropXFrac == 0.3)
            case 11:
                let feed = try #require(model.document.videoTrack.first { $0.track == 1 })
                #expect(feed.muted && feed.areaWindow != nil)
                #expect(model.document.trackSettings[0].label == "Left" && model.document.trackSettings[1].label == "Right")
            default:
                #expect(model.document.videoTrack.isEmpty && model.document.soundTrack.isEmpty)
                #expect(model.document.textOverlays.isEmpty && model.document.imageOverlays.isEmpty && model.document.overlayBlocks.isEmpty)
            }
        }
    }

    @Test func selectedReferenceResolvesTheTimelineSelection() throws {
        let model = ScriptFixtures.gapModel()
        let clip = model.document.videoTrack[0]
        model.selection = .clip(clip.uid)
        let library = ScriptFixtures.gapLibrary()
        let outcomes = ScriptRunner().run([.init(.splitClipEvenly(clip: "selected", parts: 2))], model: model, library: library)
        guard case .applied(_, let created, _) = outcomes.first else {
            Issue.record("Expected apply, got \(outcomes)"); return
        }
        #expect(created["piece1"] == clip.uid.uuidString)
        #expect(model.document.videoTrack.filter { !$0.bumper }.count == 2)
        // A sound selection resolves for sound commands too.
        model.selection = .sound(model.document.soundTrack[0].uid)
        #expect(!ScriptRunner().run([.init(.setSoundVolume(sound: "selected", volume: 2))], model: model, library: library).contains { $0.isRefused })
        #expect(model.document.soundTrack[0].volume == 2)
        // Nothing selected: refused with guidance, document untouched.
        model.selection = nil
        let before = ScriptValue.stored(model.document)
        let refused = ScriptRunner().run([.init(.removeClip(clip: "selected"))], model: model, library: library)
        #expect(refused.contains { $0.isRefused })
        #expect(ScriptValue.stored(model.document) == before)
    }

    @Test func timelineQueryReportsSelectionAndFocusedTrack() throws {
        let model = ScriptFixtures.gapModel()
        let clip = model.document.videoTrack[0]
        model.selection = .clip(clip.uid)
        model.focusedTrack = 1
        let result = try BuilderQuery(.timeline).execute(model: model, library: ScriptFixtures.gapLibrary(),
                                                         resolve: { _ in throw ScriptError.invalid("unused") })
        guard case .object(let timeline)? = result.timeline else { Issue.record("timeline object missing"); return }
        #expect(timeline["selection"] == .object(["kind": .string("clip"), "id": .string(clip.uid.uuidString)]))
        #expect(timeline["focusedTrack"] == .number(1))
        model.selection = nil
        model.focusedTrack = nil
        let cleared = try BuilderQuery(.timeline).execute(model: model, library: ScriptFixtures.gapLibrary(),
                                                          resolve: { _ in throw ScriptError.invalid("unused") })
        if case .object(let timeline)? = cleared.timeline {
            #expect(timeline["selection"] == .null && timeline["focusedTrack"] == .null)
        }
    }

    @Test func gapRefusalsLeaveDocumentUntouched() {
        let model = ScriptFixtures.gapModel()
        model.document.videoTrack[0].wide = false
        let clip = model.document.videoTrack[0].uid.uuidString
        let bumper = model.document.videoTrack[1].uid.uuidString
        let commands: [BuilderCommand] = [
            .setBumperMode(clip: clip, mode: .pause), .setClipPosition(clip: clip, position: "top"),
            .setClipCrop(clip: clip, fraction: 0.5), .setClipVolume(clip: clip, volume: 2),
            .setTextStyle(overlay: model.document.textOverlays[0].uid.uuidString, style: .init(["design": .string("modern")])),
            .addOverlay(template: "Missing"), .splitCropBlock(at: 20), .splitCropBlock(at: 0.2),
            .removeSound(sound: UUID().uuidString), .addOverlay(template: "Lower Third", person: "Missing"),
            .addOverlay(template: "Title Card", person: "alex")
        ]
        let before = ScriptValue.stored(model.document)
        for command in commands {
            let result = ScriptRunner().run([.init(command)], model: model, library: ScriptFixtures.gapLibrary())
            #expect(result.contains { $0.isRefused })
            #expect(ScriptValue.stored(model.document) == before)
        }
        model.document.videoTrack[0].wide = true
        var library = ScriptFixtures.gapLibrary()
        library.layouts = []
        let split = BuilderCommand.splitZoomFeeds(clip: clip, left: "L", right: "R")
        #expect(ScriptRunner().run([.init(split)], model: model, library: library).contains { $0.isRefused })
        library = ScriptFixtures.gapLibrary()
        // Off track 0 the store would relocate the clip; refuse instead.
        model.document.videoTrack[0].track = 1
        #expect(ScriptRunner().run([.init(split)], model: model, library: library).contains { $0.isRefused })
        model.document.videoTrack[0].track = 0
        #expect(!ScriptRunner().run([.init(split)], model: model, library: library).contains { $0.isRefused })
        let splitState = ScriptValue.stored(model.document)
        #expect(ScriptRunner().run([.init(split)], model: model, library: library).contains { $0.isRefused })
        #expect(ScriptValue.stored(model.document) == splitState)
    }

    @Test func lowerThirdAndSavedTemplateBindingsUseSnapshot() throws {
        let model = ScriptFixtures.gapModel()
        let library = ScriptFixtures.gapLibrary()
        let steps: [BuilderScriptStep] = [
            .init(.addOverlay(template: "Lower Third", at: 0), bind: "blank"),
            .init(.setOverlayRange(overlay: "$blank", at: 1, duration: 2)),
            .init(.addOverlay(template: "Lower Third", person: "alex")),
            .init(.addOverlay(template: "Lower Third", person: "Alex Smith")),
            .init(.addOverlay(template: "Title Card"), bind: "saved"),
            .init(.setOverlayRange(overlay: "$saved", at: 2, duration: 6))
        ]
        #expect(!ScriptRunner().run(steps, model: model, library: library).contains { $0.isRefused })
        let blocks = Array(model.document.overlayBlocks.dropFirst())
        #expect(blocks.count == 4)
        let blank = LowerThirdOverlay.composition(name: "NAME", role: "ROLE / TITLE", logoPath: library.logoPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let blankData = try encoder.encode(blank)
        #expect(try encoder.encode(blocks[0].composition) == blankData)
        #expect(blocks[0].composition.texts.map(\.text) == ["NAME", "ROLE / TITLE"])
        #expect(blocks[0].composition.images.first?.path == library.logoPath)
        // Composition item IDs are runtime identities, so compare semantic values below.
        #expect(blocks[1].name == "Lower Third — Alex Smith")
        #expect(blocks[1].composition.texts.map(\.text) == ["Alex Smith", "Host"])
        #expect(blocks[2].composition.texts.map(\.text) == blocks[1].composition.texts.map(\.text))
        #expect(blocks[3].composition == library.templates[0].composition)
        #expect(blocks[3].startTime == 2 && blocks[3].duration == 6)
    }

    @Test func nullableOverridesAndStylePatchPreserveOtherFields() throws {
        let model = ScriptFixtures.gapModel()
        model.document.videoTrack[0].position = "top"
        model.document.videoTrack[0].cropXFrac = 0.2
        let clip = model.document.videoTrack[0].uid.uuidString
        let text = model.document.textOverlays[0].uid.uuidString
        let image = model.document.imageOverlays[0].uid.uuidString
        let style: BuilderTextStylePatch = .init([
            "fontsize": .number(80), "fontcolor": .string("#abc"), "fontfamily": .string("Arial"),
            "bold": .bool(true), "italic": .bool(true), "bgcolor": .string("black"),
            "box_opacity": .number(0.2), "box_radius": .number(12), "opacity": .number(0.8),
            "stroke_color": .string("red"), "stroke_width_em": .number(0.1), "shadow_opacity": .number(0.3),
            "highlight_color": .string("yellow"), "design": .string("hero"), "kicker": .string("Hello"),
            "accent_color": .string("0x123456")
        ])
        #expect(try JSONDecoder().decode(BuilderTextStylePatch.self, from: JSONEncoder().encode(style)) == style)
        let steps: [BuilderScriptStep] = [
            .init(.setClipPosition(clip: clip, position: nil)), .init(.setClipCrop(clip: clip, fraction: nil)),
            .init(.setTextStyle(overlay: text, style: style)),
            .init(.setOverlayPosition(overlay: image, x: 0, y: 1))
        ]
        #expect(!ScriptRunner().run(steps, model: model, library: ScriptFixtures.gapLibrary()).contains { $0.isRefused })
        #expect(model.document.videoTrack[0].position == nil && model.document.videoTrack[0].cropXFrac == nil)
        #expect(model.document.imageOverlays[0].xFrac == 0 && model.document.imageOverlays[0].yFrac == 1)
        let styled = model.document.textOverlays[0]
        #expect(styled.fontsize == 80 && styled.fontcolor == "#abc" && styled.fontfamily == "Arial")
        #expect(styled.bold && styled.italic && styled.design == "hero" && styled.kicker == "Hello")
        #expect(styled.text == "Before" && styled.startTime == 0 && styled.endTime == 3)
        let clear = BuilderTextStylePatch(Dictionary(uniqueKeysWithValues: BuilderTextStylePatch.nullableFields.map { ($0, ScriptValue.null) }))
        #expect(!ScriptRunner().run([.init(.setTextStyle(overlay: text, style: clear))], model: model, library: ScriptFixtures.gapLibrary()).contains { $0.isRefused })
        let cleared = model.document.textOverlays[0]
        #expect(cleared.bgcolor == nil && cleared.boxRadius == nil && cleared.strokeColor == nil)
        #expect(cleared.highlightColor == nil && cleared.design == nil && cleared.kicker == nil && cleared.accentColor == nil)
        #expect(cleared.fontsize == 80 && cleared.bold && cleared.opacity == 0.8)
    }
}

extension BuilderExpansionTests {
    @Test(arguments: [1.0, 2.0])
    func evenlySplitsSixPiecesWithCompleteDiffAndSourceContinuity(speed: Double) throws {
        let original = Fixtures.timelineClip(sourceStart: 0, duration: 27.8, speed: speed)
        let model = ScriptFixtures.model(clips: [original])
        var library = ScriptFixtures.library()
        library.videos[0].duration = 100
        library.scenes[0].videoDuration = 100
        let session = BuilderScriptSession(live: model, library: library)
        defer { session.discard() }
        let command = BuilderCommand.splitClipEvenly(clip: original.uid.uuidString, parts: 6)
        let encoded = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(BuilderCommand.self, from: encoded) == command)
        let result = session.run([.init(command, bind: "pieces")])
        #expect(result.completed)
        let pieces = session.workingDocument.videoTrack.sorted { $0.startTime < $1.startTime }
        #expect(pieces.count == 6)
        let durations = pieces.map { $0.duration }
        let shortest = try #require(durations.min())
        let longest = try #require(durations.max())
        #expect(longest - shortest <= 0.05 + 1e-9)
        #expect(abs(durations.reduce(0, +) - 27.8) < 1e-9)
        #expect(pieces.first?.uid == original.uid)
        #expect(pieces.allSatisfy { $0.track == original.track && $0.originKey == original.originKey && $0.precision == .speech })
        for (head, tail) in zip(pieces, pieces.dropFirst()) {
            #expect(abs(head.startTime + head.duration - tail.startTime) < 1e-9)
            let end = try #require(head.sourceEnd)
            let start = try #require(tail.sourceStart)
            #expect(abs(end - start) < 1e-9)
        }
        let outcome = try #require(result.outcomes.first)
        #expect(Set(outcome.createdIDs.keys) == Set((1...6).map { "piece\($0)" }))
        guard case .applied(let actual, _, _) = outcome else { Issue.record("Expected applied"); return }
        #expect(actual == .object(["durations": .array(durations.map { .number($0) })]))
        let summary = BuilderWizardDiff.lines(session: session, steps: [.init(command)])
        #expect(summary.contains("Split 1 clips"))
        let changes = session.diff().changes
        #expect(changes.contains { $0.path.contains("duration") })
        for piece in pieces.dropFirst() {
            #expect(changes.contains { $0.kind == .added && $0.path.contains(piece.uid.uuidString) })
        }
    }

    @Test func evenSplitRefusesInvalidCountsAndSliversAtomically() throws {
        for (parts, duration, precision) in [(13, 4.0, TimelinePrecision.speech), (6, 0.25, .speech), (6, 2.5, .ordinary)] {
            let session = ScriptFixtures.session(clips: [Fixtures.timelineClip(duration: duration)])
            let before = session.workingDocument
            let result = session.run([.init(.splitClipEvenly(clip: before.videoTrack[0].uid.uuidString,
                                                          parts: parts, precision: precision))], recoverRefusals: true)
            #expect(!result.completed && session.state == .ready)
            #expect(session.workingDocument == before && !result.hasDocumentChanges)
            session.discard()
        }
        let invalid = Data(#"{"op":"split_clip_evenly","clip":"id","parts":13}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BuilderCommand.self, from: invalid) }
    }
}

extension BuilderExpansionTests {
    @Test func effectsApplyClearAndRefuse() throws {
        let model = ScriptFixtures.gapModel()
        let library = ScriptFixtures.gapLibrary()
        let runner = ScriptRunner()
        let clip = model.document.videoTrack[0].uid.uuidString
        // None is always available, including machines without ffmpeg.
        let effect = EffectSpec(preset: "none", intensity: 0.5)
        let applied = runner.run([.init(.setTrackEffect(track: 0, effect: effect)),
                                  .init(.setClipEffect(clip: clip, effect: effect))], model: model, library: library)
        #expect(applied.allSatisfy { if case .applied = $0 { true } else { false } })
        #expect(model.document.trackSettings[0].effect == effect)
        #expect(model.document.videoTrack[0].effect == effect)
        let cleared = runner.run([.init(.setTrackEffect(track: 0, effect: nil)),
                                  .init(.setClipEffect(clip: clip, effect: nil))], model: model, library: library)
        #expect(cleared.allSatisfy { if case .applied = $0 { true } else { false } })
        #expect(model.document.trackSettings[0].effect == nil && model.document.videoTrack[0].effect == nil)
        let bumper = try #require(model.document.videoTrack.first { $0.bumper })
        var refusals: [BuilderCommand] = [
            .setClipEffect(clip: bumper.uid.uuidString, effect: effect),
            .setTrackEffect(track: 0, effect: .init(preset: "invented")),
            .setTrackEffect(track: 0, effect: .init(preset: "blur", params: ["sigma": 21])),
            .setTrackEffect(track: TimelineDocument.maxTracks, effect: nil)
        ]
        if let unavailable = EffectCatalog.presets.first(where: { !EffectCatalog.isAvailable($0.id) }) {
            refusals.append(.setTrackEffect(track: 0, effect: .init(preset: unavailable.id)))
        }
        for command in refusals {
            let before = model.document
            let outcomes = runner.run([.init(command)], model: model, library: library)
            #expect(outcomes.first?.isRefused == true)
            #expect(model.document == before)
        }
        let unknown = runner.run([.init(.setClipEffect(clip: "$missing", effect: nil))], model: model, library: library)
        if case .refused(let code, _) = unknown.first { #expect(code == "unknown_id") }
        else { Issue.record("Expected unknown_id") }
        let uuid = runner.run([.init(.setClipEffect(clip: UUID().uuidString, effect: nil))], model: model, library: library)
        if case .refused(let code, _) = uuid.first { #expect(code == "unknown_id") }
        else { Issue.record("Expected unknown_id") }
        if EffectCatalog.isAvailable("bw") {
            _ = runner.run([.init(.setTrackEffect(track: 0, effect: .init(preset: "bw")))], model: model, library: library)
            #expect(model.document.trackSettings[0].effect?.preset == "bw")
        }
    }

    @Test func unavailableEffectsRefuseBeforeMutation() {
        for command in [BuilderCommand.setTrackEffect(track: 0, effect: .init(preset: "warm")),
                        .setClipEffect(clip: "selected", effect: .init(preset: "edges"))] {
            do {
                try command.validateExpansion(effectFilters: [])
                Issue.record("Expected unavailable filter refusal")
            } catch let error as BuilderCommandFailure {
                #expect(error.code == "invalid_value" && error.reason.contains("unavailable"))
            } catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func effectsQueryAndRows() throws {
        let model = ScriptFixtures.gapModel()
        let library = ScriptFixtures.gapLibrary()
        model.document.trackSettings[0].effect = .init(preset: "bw")
        model.document.videoTrack[0].effect = .init(preset: "sepia")
        let resolve: (String) throws -> UUID = { _ in throw BuilderCommandFailure.unknownID }
        let catalog = try BuilderQuery(.effects).execute(model: model, library: library, resolve: resolve)
        #expect(catalog.effects.map(\.id) == EffectCatalog.ids)
        #expect(catalog.effects.first { $0.id == "blur" }?.params.first?.name == "sigma")
        #expect(catalog.effects.first { $0.id == "bw" }?.available == EffectCatalog.isAvailable("bw"))
        let page = try BuilderQuery(.effects, limit: 1).execute(model: model, library: library, resolve: resolve)
        #expect(page.effects.count == 1 && page.nextOffset == 1 && page.total == EffectCatalog.ids.count)
        // A second ordinary clip with no override reports null; the gap
        // fixture's other clip is a bumper, which the clips query hides.
        model.document.videoTrack.append(Fixtures.timelineClip(startTime: 20))
        for kind in [BuilderQuery.Kind.timeline, .clips] {
            let rows = try BuilderQuery(kind).execute(model: model, library: library, resolve: resolve)
            let row = try #require(rows.clips.first { $0.id == model.document.videoTrack[0].uid.uuidString })
            #expect(row.effect == ScriptValue.stored(EffectSpec(preset: "sepia")))
            #expect(rows.clips.contains { $0.effect == .null })
        }
        let layouts = try BuilderQuery(.layouts).execute(model: model, library: library, resolve: resolve)
        for layout in layouts.layouts where !layout.areas.isEmpty {
            guard case .object(let area) = layout.areas[0] else { Issue.record("Expected area object"); continue }
            #expect(area["effect"] == ScriptValue.stored(EffectSpec(preset: "bw")))
        }
    }
}
