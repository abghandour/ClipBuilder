import Foundation
import MCP
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Expansion MCP vocabulary")
struct BuilderExpansionSchemaTests {
    @Test func queryVariantsAllowOnlyFieldsForTheirKind() throws {
        let session = ScriptFixtures.session()
        defer { session.discard() }
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()))
        let tool = try #require(tools.definitions.first { $0.name == "query" })
        let query = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue?["query"])
        let variants = try #require(query.objectValue?["oneOf"]?.arrayValue)
        #expect(variants.count == BuilderQuery.Kind.allCases.count)
        let extra: [String: Set<String>] = [
            "clips": ["filter"], "scenes": ["sceneFilter"], "people": ["includeHidden"],
            "transcript": ["video", "range"], "silences": ["video", "range", "clip", "threshold"]
        ]
        var seen = Set<String>()
        for variant in variants {
            let fields = try #require(variant.objectValue?["properties"]?.objectValue)
            let kind = try #require(fields["kind"]?.objectValue?["const"]?.stringValue)
            seen.insert(kind)
            #expect(Set(fields.keys) == (extra[kind] ?? []).union(["kind", "offset", "limit"]))
            #expect(variant.objectValue?["additionalProperties"] == .bool(false))
            #expect(variant.objectValue?["required"] == .array([.string("kind")]))
            let description = try #require(variant.objectValue?["description"]?.stringValue)
            #expect(!description.isEmpty)
            if kind == "scenes" {
                let filter = try #require(fields["sceneFilter"]?.objectValue)
                #expect(filter["additionalProperties"] == .bool(false))
                #expect(filter["properties"]?.objectValue?["people"] != nil)
            }
        }
        #expect(seen == Set(BuilderQuery.Kind.allCases.map(\.rawValue)))
    }

    @Test func queryDecodeExplainsKindSpecificFields() throws {
        do {
            _ = try JSONDecoder().decode(BuilderQuery.self, from: Data(#"{"kind":"scenes","filter":{"people":["aljo"]}}"#.utf8))
            Issue.record("Expected an invalid field refusal")
        } catch {
            #expect(error.localizedDescription == "Unknown fields for kind scenes: filter. Valid fields: kind, limit, offset, sceneFilter. filter is only valid for kind clips; use sceneFilter for scenes.")
        }
        let corrected = try JSONDecoder().decode(BuilderQuery.self, from: Data(#"{"kind":"scenes","sceneFilter":{"people":["aljo"]}}"#.utf8))
        #expect(corrected.sceneFilter?.people == ["aljo"])
        do {
            _ = try JSONDecoder().decode(BuilderQuery.self, from: Data(#"{"kind":"people","video":1}"#.utf8))
            Issue.record("Expected an invalid field refusal")
        } catch {
            #expect(error.localizedDescription.contains("Valid fields: includeHidden, kind, limit, offset."))
        }
    }

    @Test func schemasHaveClosedRequiredFields() throws {
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()))
        let tool = try #require(tools.definitions.first { $0.name == "run_script" })
        let decoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema))
        let json = try #require(decoded as? [String: Any])
        let properties = try #require(json["properties"] as? [String: Any])
        let steps = try #require(properties["steps"] as? [String: Any])
        let items = try #require(steps["items"] as? [String: Any])
        let stepProperties = try #require(items["properties"] as? [String: Any])
        let command = try #require(stepProperties["command"] as? [String: Any])
        let variants = try #require(command["oneOf"] as? [[String: Any]])
        // tools/list returns these definitions; command is the embedded private commandSchema.
        let listedTools = String(decoding: try JSONEncoder().encode(ListTools.Result(tools: tools.definitions)), as: UTF8.self)
        let commandSchema = String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self)
        for components in [["set", "sound", "fades"], ["set", "track", "volume"], ["set", "clip", "screen", "crop"]] {
            let op = components.joined(separator: "_")
            #expect(!listedTools.contains(op))
            #expect(!commandSchema.contains(op))
        }
        let expected: [String: Set<String>] = [
            "set_sound_volume": ["sound", "volume"], "set_sound_range": ["sound", "start", "duration"],
            "move_sound": ["sound", "at"],
            "set_text": ["overlay", "text"], "set_text_position": ["overlay", "position"],
            "set_overlay_range": ["overlay", "at", "duration"],
            "set_overlay_transitions": ["overlay", "trans_in", "trans_out"],
            "set_clip_speed": ["clip", "speed"], "set_clip_fades": ["clip", "fade_in", "fade_out"],
            "set_clip_captions": ["clip", "captions"], "set_clip_transitions": ["clip", "trans_in", "trans_out"],
            "set_clip_center_stage": ["clip", "enabled"],
            "set_clip_area_window": ["clip", "x", "y", "width", "height"],
            "set_track_captions": ["track", "captions"],
            "set_track_muted": ["track", "muted"], "set_track_position": ["track", "position"],
            "set_track_crop": ["track", "fraction"], "set_render_settings": ["settings"], "set_pacing": ["pacing"]
        ]
        var seen = Set<String>()
        for variant in variants {
            let properties = try #require(variant["properties"] as? [String: Any])
            let op = try #require((properties["op"] as? [String: Any])?["const"] as? String)
            guard let fields = expected[op] else { continue }
            seen.insert(op)
            #expect(Set(properties.keys) == fields.union(["op"]))
            let required = try #require(variant["required"] as? [String])
            #expect(Set(required) == fields.union(["op"]))
            #expect(variant["additionalProperties"] as? Bool == false)
        }
        #expect(seen == Set(expected.keys))
        session.discard()
    }
}

extension BuilderExpansionSchemaTests {
    @Test func builderGapCommandsRoundTripAndRefuseUnknownFields() throws {
        for command in ScriptFixtures.gapCommands(ScriptFixtures.gapModel()) {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(BuilderCommand.self, from: data) == command)
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["unexpected"] = true
            let extra = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BuilderCommand.self, from: extra) }
        }
        for command in [BuilderCommand.setClipPosition(clip: "x", position: nil), .setClipCrop(clip: "x", fraction: nil)] {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(BuilderCommand.self, from: data) == command)
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: "position"); object.removeValue(forKey: "fraction")
            let missing = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BuilderCommand.self, from: missing) }
        }
    }

    @Test func builderGapSchemasAdvertiseAllCommands() throws {
        let session = ScriptFixtures.session()
        defer { session.discard() }
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()))
        let tool = try #require(tools.definitions.first { $0.name == "run_script" })
        let variants = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue?["steps"]?
            .objectValue?["items"]?.objectValue?["properties"]?.objectValue?["command"]?.objectValue?["oneOf"]?.arrayValue)
        for command in ScriptFixtures.gapCommands(ScriptFixtures.gapModel()) {
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
            let op = try #require(object["op"] as? String)
            let variant = try #require(variants.first { $0.objectValue?["properties"]?.objectValue?["op"]?.objectValue?["const"]?.stringValue == op })
            #expect(variant.objectValue?["additionalProperties"] == .bool(false))
            let properties = try #require(variant.objectValue?["properties"]?.objectValue)
            #expect(Set(object.keys).isSubset(of: Set(properties.keys)))
        }
    }

    @Test func builderGapInvalidValuesRefuse() {
        let payloads = [
            #"{"op":"set_bumper_mode","clip":"x","mode":"invalid"}"#,
            #"{"op":"set_crop_block_duration","block":"x","duration":0.49}"#,
            #"{"op":"set_crop_block_duration","block":"x","duration":86401}"#,
            #"{"op":"split_crop_block","at":-1}"#,
            #"{"op":"remove_sound"}"#,
            #"{"op":"add_overlay","template":"Lower Third","duration":0}"#,
            #"{"op":"add_overlay","template":"Lower Third","at":86400,"duration":1}"#,
            #"{"op":"set_image_geometry","overlay":"x"}"#,
            #"{"op":"set_image_geometry","overlay":"x","width":0.049}"#,
            #"{"op":"set_image_geometry","overlay":"x","opacity":1.1}"#,
            #"{"op":"set_overlay_position","overlay":"x","x":-1,"y":0}"#,
            #"{"op":"set_text_style","overlay":"x","style":{}}"#,
            #"{"op":"set_text_style","overlay":"x","style":{"unknown":1}}"#,
            #"{"op":"set_text_style","overlay":"x","style":{"fontsize":7}}"#,
            #"{"op":"set_text_style","overlay":"x","style":{"fontsize":400.5}}"#,
            #"{"op":"set_text_style","overlay":"x","style":{"fontcolor":"blue"}}"#,
            ##"{"op":"set_text_style","overlay":"x","style":{"bgcolor":"#xyz"}}"##,
            #"{"op":"set_text_style","overlay":"x","style":{"fontcolor":null}}"#,
            #"{"op":"set_text_style","overlay":"x","style":{"bold":1}}"#,
            #"{"op":"set_text_style","overlay":"x","style":{"box_radius":-1}}"#,
            #"{"op":"set_text_style","overlay":"x","style":{"stroke_width_em":1.1}}"#,
            #"{"op":"set_clip_volume","clip":"x","volume":0}"#,
            #"{"op":"set_clip_volume","clip":"x","volume":6}"#,
            #"{"op":"set_clip_position","clip":"x","position":"left"}"#,
            #"{"op":"set_clip_crop","clip":"x","fraction":1.01}"#,
            #"{"op":"split_zoom_feeds","clip":"x","left":"Left"}"#,
            #"{"op":"clear_timeline","at":0}"#
        ]
        for json in payloads {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BuilderCommand.self, from: Data(json.utf8)) }
        }
        for command in [BuilderCommand.splitCropBlock(at: .nan),
                        .setImageGeometry(overlay: "x", x: .infinity),
                        .setTextStyle(overlay: "x", style: .init(["box_radius": .number(.infinity)]))] {
            #expect(throws: (any Error).self) { try command.validateExpansion() }
        }
    }
}
