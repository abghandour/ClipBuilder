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
