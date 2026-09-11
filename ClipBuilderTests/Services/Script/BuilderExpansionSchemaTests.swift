import Foundation
import MCP
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Expansion MCP vocabulary")
struct BuilderExpansionSchemaTests {
    @Test func schemasHaveClosedRequiredFields() throws {
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()))
        let tool = try #require(tools.definitions.first { $0.name == "run_script" })
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema)) as? [String: Any])
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
            #expect(Set(try #require(variant["required"] as? [String])) == fields.union(["op"]))
            #expect(variant["additionalProperties"] as? Bool == false)
        }
        #expect(seen == Set(expected.keys))
        session.discard()
    }
}
