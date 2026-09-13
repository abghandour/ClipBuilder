import Foundation
import MCP

/// Single schema vocabulary for MCP, JavaScript wrappers and reference text.
@MainActor
enum BuilderCommandCatalog {
    static let integer: Value = .object(["type": .string("integer"), "minimum": .int(0)])
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(Value.string)), "additionalProperties": .bool(false)])
    }

    static var querySchema: Value {
        let string: Value = .object(["type": .string("string")])
        let number: Value = .object(["type": .string("number")])
        let terms: Value = .object(["type": .string("array"), "maxItems": .int(100), "items": string])
        let range = object(["start": number, "end": number], required: ["start", "end"])
        return .object(["oneOf": .array(BuilderQuery.Kind.allCases.map { kind in
            var fields: [String: Value] = [
                "kind": .object(["const": .string(kind.rawValue)]),
                "offset": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1_000_000)]),
                "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(200)])
            ]
            let description: String
            switch kind {
            case .clips:
                fields["filter"] = clipFilterSchema
                description = "Working timeline clips. Filter people with filter.people."
            case .scenes:
                fields["sceneFilter"] = object([
                    "people": terms, "tags": terms, "video": integer, "text": string,
                    "min_score": number, "include_excluded": .object(["type": .string("boolean")])
                ])
                description = "Library scenes. Filter people with sceneFilter.people; filter is not valid here."
            case .people:
                fields["includeHidden"] = .object(["type": .string("boolean")])
                description = "Known people; optionally include hidden people."
            case .transcript:
                fields["video"] = integer; fields["range"] = range
                description = "Transcript for a project video, optionally restricted to a source-time range."
            case .silences:
                fields["video"] = integer; fields["range"] = range; fields["clip"] = string
                fields["threshold"] = .object(["type": .string("number"), "minimum": .double(0.05), "maximum": .int(60)])
                description = "Observed silence for a video or clip UUID, with optional source-time range and gap threshold in seconds."
            case .timeline: description = "Working timeline overview; pagination only."
            case .tags: description = "Known Library tags; pagination only."
            case .templates: description = "Snapshotted overlay templates and built-in Lower Third; pagination only."
            case .effects: description = "Effect presets, parameter ranges and local ffmpeg availability; pagination only."
            case .layouts: description = "Available crop layouts; pagination only."
            case .capabilities: description = "Captured prerequisite availability by video; pagination only."
            }
            guard case .object(var schema) = object(fields, required: ["kind"]) else { preconditionFailure() }
            schema["description"] = .string(description)
            return .object(schema)
        })])
    }

    static var commandSchema: Value {
        let string: Value = .object(["type": .string("string")])
        let number: Value = .object(["type": .string("number"), "minimum": .int(0)])
        let bool: Value = .object(["type": .string("boolean")])
        var fields: [String: Value] = [:]
        for key in ["clip", "block", "layout", "bumper", "sound", "text", "image", "overlay", "template", "person", "left", "right"] { fields[key] = string }
        for key in ["at", "start", "end", "duration", "source_start", "length"] { fields[key] = number }
        for key in ["track", "scene", "video"] { fields[key] = integer }
        for key in ["cover_all", "muted", "sequential"] { fields[key] = bool }
        for key in ["speed", "fade_in", "fade_out", "x", "y", "width", "height", "opacity"] { fields[key] = number }
        for key in ["position", "captions", "trans_in", "trans_out"] { fields[key] = string }
        fields["effect"] = .object(["anyOf": .array([
            .object(["type": .string("null")]),
            object([
                "preset": .object(["enum": .array(EffectCatalog.ids.map(Value.string))]),
                "params": .object(["type": .string("object"),
                                   "additionalProperties": .object(["type": .string("number")])]),
                "intensity": .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
            ], required: ["preset"])
        ])])
        var styleFields: [String: Value] = [:]
        for key in ["fontcolor", "fontfamily", "bgcolor", "stroke_color", "highlight_color", "design", "kicker", "accent_color"] {
            styleFields[key] = .object(["type": BuilderTextStylePatch.nullableFields.contains(key)
                ? .array([.string("string"), .string("null")]) : .string("string")])
        }
        for key in ["box_opacity", "opacity", "stroke_width_em", "shadow_opacity"] {
            styleFields[key] = .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
        }
        styleFields["fontsize"] = .object(["type": .string("integer"), "minimum": .int(8), "maximum": .int(400)])
        styleFields["box_radius"] = .object(["type": .array([.string("number"), .string("null")]), "minimum": .int(0)])
        styleFields["bold"] = bool; styleFields["italic"] = bool
        if case .object(var patch) = object(styleFields) {
            patch["minProperties"] = .int(1)
            fields["style"] = .object(patch)
        }
        fields["enabled"] = bool
        fields["volume"] = .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(5)])
        fields["fraction"] = .object(["type": .array([.string("number"), .string("null")]), "minimum": .int(0), "maximum": .int(1)])
        fields["settings"] = object([
            "preset": .object(["enum": .array(RenderPreset.allCases.map { .string($0.rawValue) })]),
            "quality": .object(["enum": .array(EncodeQuality.allCases.map { .string($0.rawValue) })]),
            "custom_width": .object(["type": .string("integer"), "minimum": .int(240), "maximum": .int(7680), "multipleOf": .int(2)]),
            "custom_height": .object(["type": .string("integer"), "minimum": .int(240), "maximum": .int(7680), "multipleOf": .int(2)]),
            "custom_crf": .object(["type": .string("integer"), "minimum": .int(10), "maximum": .int(35)])
        ])
        fields["pacing"] = object([
            "cadence": .object(["enum": .array(CutCadence.allCases.map { .string($0.rawValue) })]),
            "curve": .object(["enum": .array(PaceCurve.allCases.map { .string($0.rawValue) })])
        ], required: ["cadence", "curve"])
        fields["parts"] = .object(["type": .string("integer"), "minimum": .int(2), "maximum": .int(12)])
        fields["precision"] = .object(["enum": .array([.string("ordinary"), .string("speech")])])
        fields["role"] = .object(["enum": .array(ClipRole.allCases.map { .string($0.rawValue) })])
        fields["audio"] = .object(["enum": .array(CutawayAudio.allCases.map { .string($0.rawValue) })])
        fields["mode"] = .object(["enum": .array(BumperMode.allCases.map { .string($0.rawValue) })])
        fields["filter"] = clipFilterSchema; fields["query"] = querySchema
        // Each operation has exactly the fields accepted by BuilderCommand.
        let variants: [(String, [String], [String])] = [
            ("set_bumper_mode", ["clip", "mode"], ["clip", "mode"]),
            ("set_crop_block_duration", ["block", "duration"], ["block", "duration"]),
            ("split_crop_block", ["at"], ["at"]),
            ("remove_sound", ["sound"], ["sound"]),
            ("add_overlay", ["template", "at", "duration", "person"], ["template"]),
            ("set_image_geometry", ["overlay", "x", "y", "width", "opacity"], ["overlay"]),
            ("set_overlay_position", ["overlay", "x", "y"], ["overlay", "x", "y"]),
            ("set_text_style", ["overlay", "style"], ["overlay", "style"]),
            ("set_clip_volume", ["clip", "volume"], ["clip", "volume"]),
            ("set_clip_position", ["clip", "position"], ["clip", "position"]),
            ("set_clip_crop", ["clip", "fraction"], ["clip", "fraction"]),
            ("split_zoom_feeds", ["clip", "left", "right"], ["clip", "left", "right"]),
            ("clear_timeline", [], []),
            ("set_sound_volume", ["sound", "volume"], ["sound", "volume"]),
            ("set_sound_range", ["sound", "start", "duration"], ["sound", "start", "duration"]),
            ("move_sound", ["sound", "at"], ["sound", "at"]),
            ("set_text", ["overlay", "text"], ["overlay", "text"]),
            ("set_text_position", ["overlay", "position"], ["overlay", "position"]),
            ("set_overlay_range", ["overlay", "at", "duration"], ["overlay", "at", "duration"]),
            ("set_overlay_transitions", ["overlay", "trans_in", "trans_out"], ["overlay", "trans_in", "trans_out"]),
            ("set_clip_speed", ["clip", "speed"], ["clip", "speed"]),
            ("set_clip_fades", ["clip", "fade_in", "fade_out"], ["clip", "fade_in", "fade_out"]),
            ("set_clip_captions", ["clip", "captions"], ["clip", "captions"]),
            ("set_clip_transitions", ["clip", "trans_in", "trans_out"], ["clip", "trans_in", "trans_out"]),
            ("set_clip_center_stage", ["clip", "enabled"], ["clip", "enabled"]),
            ("set_clip_area_window", ["clip", "x", "y", "width", "height"], ["clip", "x", "y", "width", "height"]),
            ("set_track_effect", ["track", "effect"], ["track", "effect"]),
            ("set_clip_effect", ["clip", "effect"], ["clip", "effect"]),
            ("set_track_captions", ["track", "captions"], ["track", "captions"]),
            ("set_track_muted", ["track", "muted"], ["track", "muted"]),
            ("set_track_position", ["track", "position"], ["track", "position"]),
            ("set_track_crop", ["track", "fraction"], ["track", "fraction"]),
            ("set_render_settings", ["settings"], ["settings"]),
            ("set_pacing", ["pacing"], ["pacing"]),
            ("remove_clip", ["clip"], ["clip"]),
            ("remove_clips", ["filter"], ["filter"]),
            ("split_clip_evenly", ["clip", "parts", "precision"], ["clip", "parts"]),
            ("split_clip", ["clip", "at", "precision"], ["clip", "at"]),
            ("trim_clip", ["clip", "duration", "precision"], ["clip", "duration"]),
            ("set_source_range", ["clip", "start", "end", "precision"], ["clip", "start", "end"]),
            ("place_clip", ["clip", "start", "track"], ["clip", "start", "track"]),
            ("add_scene", ["scene", "at", "track"], ["scene", "track"]),
            ("add_cutaway", ["scene", "video", "at", "track", "duration", "source_start", "cover_all"], ["track", "cover_all"]),
            ("set_clip_role", ["clip", "role"], ["clip", "role"]),
            ("set_cutaway_audio", ["clip", "audio"], ["clip", "audio"]),
            ("set_clip_muted", ["clip", "muted"], ["clip", "muted"]),
            ("set_cutaway_cover_all", ["clip", "cover_all"], ["clip", "cover_all"]),
            ("duplicate_clip", ["clip"], ["clip"]),
            ("set_track_sequential", ["track", "sequential"], ["track", "sequential"]),
            ("add_crop_block", ["layout", "at", "duration"], ["layout"]),
            ("set_crop_layout", ["block", "layout"], ["block", "layout"]),
            ("remove_crop_block", ["block"], ["block"]),
            ("add_bumper", ["bumper", "at", "mode"], ["bumper", "mode"]),
            ("add_sound", ["sound", "at", "duration"], ["sound", "duration"]),
            ("add_text", ["at", "text"], ["text"]),
            ("add_image", ["image", "at", "length"], ["image", "length"]),
            ("remove_overlay", ["overlay"], ["overlay"]),
            ("set_playhead", ["at"], ["at"]),
            ("query", ["query"], ["query"]),
        ]
        return .object(["oneOf": .array(variants.map { op, allowed, required in
            var properties = fields.filter { allowed.contains($0.key) }
            func choices(_ values: [String]) -> Value { .object(["enum": .array(values.map(Value.string))]) }
            func bounded(_ low: Double, _ high: Double) -> Value {
                .object(["type": .string("number"), "minimum": .double(low), "maximum": .double(high)])
            }
            if op == "set_clip_position" {
                properties["position"] = .object(["enum": .array([.string("top"), .string("center"), .string("bottom"), .null])])
            }
            if ["set_image_geometry", "set_overlay_position"].contains(op) {
                for key in ["x", "y", "opacity"] where allowed.contains(key) { properties[key] = bounded(0, 1) }
                if allowed.contains("width") { properties["width"] = bounded(0.05, 1) }
            }
            if ["set_crop_block_duration", "add_overlay"].contains(op) { properties["duration"] = bounded(0.5, 86400) }
            if ["split_crop_block", "add_overlay"].contains(op) { properties["at"] = bounded(0, 86400) }
            if op == "set_clip_speed" { properties["speed"] = bounded(0.5, 2) }
            if op == "set_clip_captions" { properties["captions"] = choices(TimelineClip.captionChoices) }
            if op == "set_track_captions" { properties["captions"] = choices(TrackSettings.captionChoices) }
            if op == "set_text_position" || op == "set_track_position" {
                properties["position"] = choices(["top", "center", "bottom"])
            }
            if op == "set_clip_transitions" || op == "set_overlay_transitions" {
                let names = op == "set_clip_transitions" ? ["cut"] + RenderEngine.allTransitions : TextOverlayItem.transitionChoices
                properties["trans_in"] = choices(names); properties["trans_out"] = choices(names)
            }
            if op == "set_clip_area_window" {
                for key in ["x", "y", "width", "height"] { properties[key] = bounded(0, 1) }
            }
            if op == "set_sound_range" || op == "set_overlay_range" {
                properties["duration"] = bounded(0.5, 86400)
            }
            properties["op"] = .object(["const": .string(op)])
            var schema = object(properties, required: ["op"] + required)
            if op == "set_image_geometry", case .object(var object) = schema {
                object["anyOf"] = .array(["x", "y", "width", "opacity"].map {
                    .object(["required": .array([.string($0)])])
                })
                schema = .object(object)
            }
            let limitations = [
                "add_overlay": "Use a name from query kind templates. Lower Third accepts an optional roster person key/display name; otherwise creates NAME / ROLE / TITLE. Saved templates use their captured composition.",
                "set_text_style": "Nonempty patch. design is hero, tag or null. Null clears bgcolor, box_radius, stroke_color, highlight_color, design, kicker, accent_color. Colors accept white, black, red, yellow or renderer-compatible #/0x hex.",
                "set_clip_position": "Wide Full Screen clips only; null restores the track default.",
                "set_clip_crop": "Wide Full Screen clips only; null clears the clip crop.",
                "split_zoom_feeds": "Requires a wide Full Screen clip on track 0, captured source dimensions and the 50-50 Horizontal layout; refuses an existing split partner.",
                "set_clip_volume": "Bumpers and B-roll only: the exporter ignores main-clip volume. Mute main clips with set_clip_muted or set_track_muted.",
                "clear_timeline": "Clear every timeline lane and reset settings; all existing lane items count toward the edit budget.",
                "set_overlay_transitions": "Text/image transitions only; overlay blocks retain their composition transitions.",
                "set_clip_area_window": "Requires a crop area and captured source dimensions; preserve the current window aspect ratio (or the default area aspect). Width must be at least 0.1.",
                "set_clip_fades": "B-roll only; each fade is at most half the clip duration.",
                "set_clip_speed": "Preserves source start and rounds screen duration to 0.1 seconds like the inspector. Refuses source overflow."
            ]
            if let description = limitations[op], case .object(var fields) = schema {
                fields["description"] = .string(description)
                return .object(fields)
            }
            return schema
        })])
    }

    static var clipFilterSchema: Value {
        let terms: Value = .object(["type": .string("array"), "maxItems": .int(100),
                                    "items": .object(["type": .string("string")])])
        return object(["track": integer, "role": .object(["enum": .array(ClipRole.allCases.map { .string($0.rawValue) })]),
            "include_bumpers": .object(["type": .string("boolean")]), "people": terms, "tags": terms, "any_tags": terms,
            "scene_score_below": .object(["type": .string("number")]),
            "between": object(["start": .object(["type": .string("number")]), "end": .object(["type": .string("number")])], required: ["start", "end"])])
    }
    static var operations: [String: Value] {
        guard case .object(let root) = commandSchema, case .array(let variants) = root["oneOf"] else { return [:] }
        return Dictionary(uniqueKeysWithValues: variants.compactMap { schema in
            guard let fields = schema.objectValue?["properties"]?.objectValue,
                  let name = fields["op"]?.objectValue?["const"]?.stringValue else { return nil }
            return (name, schema)
        })
    }

    static var referenceText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json(_ value: Value) -> String {
            String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
        }
        // Intern repeated field schemas (especially transition enums). Every
        // constraint survives, without repeating the same schema per operation.
        var rules: [String: Value] = [:]
        var ruleIDs: [String: String] = [:]
        func compact(_ schema: Value, discriminator: String) -> Value {
            guard case .object(var root) = schema,
                  case .object(let properties) = root.removeValue(forKey: "properties") else { return schema }
            root.removeValue(forKey: "type")
            root.removeValue(forKey: "additionalProperties")
            var fields: [String: Value] = [:]
            for key in properties.keys.sorted() where key != discriminator {
                if key == "query" { fields[key] = .string("queryKinds"); continue }
                guard let value = properties[key] else { continue }
                let encoded = json(value)
                let id: String
                if let existing = ruleIDs[encoded] { id = existing }
                else {
                    id = "r" + String(rules.count + 1)
                    rules[id] = value; ruleIDs[encoded] = id
                }
                fields[key] = .string(id)
            }
            root["fields"] = .object(fields)
            return .object(root)
        }
        var ops: [String: Value] = [:]
        let catalog = operations
        for name in catalog.keys.sorted() {
            if let schema = catalog[name] { ops[name] = compact(schema, discriminator: "op") }
        }
        let queries: [Value]
        if case .array(let variants) = querySchema.objectValue?["oneOf"] { queries = variants }
        else { queries = [] }
        var queryKinds: [String: Value] = [:]
        for schema in queries {
            if let kind = schema.objectValue?["properties"]?.objectValue?["kind"]?.objectValue?["const"]?.stringValue {
                queryKinds[kind] = compact(schema, discriminator: "kind")
            }
        }
        return """
        Clip Builder JavaScript reference. Every entry is a strict object (no extra keys); its dictionary key supplies op or kind. fields reference fieldRules (query references queryKinds); required lists and all constraints are authoritative. Unknown keys refuse. All IDs must come from captured queries. Track I = 0.
        Header must be the first non-whitespace token: /** clipbuilder-script
        {"name":"Example","description":"Describe the preview.","mode":"edit","params":[{"name":"parts","type":"number","min":2,"max":12,"step":1,"default":3}],"requires":[]}
        */
        Strict JSON: no comments, duplicate or unknown keys. Nonempty name/description; mode edit|find. params and requires arrays mandatory.
        Parameter fields: name,type,label?,min?,max?,step?,choices?,default?. Unique ASCII identifiers. Types: string,number,boolean,choice,clip,scene,track,time. min/max/step only number/time/track; finite ordered bounds, positive step aligned from min or zero. choice requires distinct nonempty choices; other types cannot use choices. Defaults obey runtime rules. All params required unless defaulted; time defaults to captured playhead (0…86400 seconds). clip = captured clip UUID; scene = captured safe integer ID; track = visible zero-based index. Supply sampleParams for required IDs without defaults, never guess.
        requires: at most 12 distinct {kind:"transcript"|"people"|"analysis",video:ID|"$parameterName"}; resolve to concrete safe nonnegative captured video IDs. Find mode prohibits requires. Ensures must precede any mutation, including refused attempts, and match declared confirmed targets. Validation only stubs ensures: partial validation: requires user-run validation. No prerequisite success is certified.
        API: builder.query(q); builder.summary({offset:0,limit:50}) returns rows,total,nextOffset (limit max 200, offset max 1000000). Page explicitly. Read-only builder.selection = {kind,id}|null; builder.playhead; builder.focusedTrack = index|null; builder.tracks = [{index,label}].
        builder.run([{op,...,bind?:"name"}] or [{command:{op,...},bind?:"name"}],{tolerate:true}); never mix flat and wire fields. builder.ops.<op>(args,{bind?,tolerate?}) is a one-step run; args may also contain bind. builder.ops.query({query:q}) is a command, separate from builder.query(q).
        builder.ops.ensure_transcript({video}); builder.ops.ensure_people({video}); builder.ops.ensure_analysis({video}) are separate prefix calls, unavailable without declared requires; never put ensures in builder.run.
        Result envelope: {outcomes,completed,hasDocumentChanges}. Outcomes: {status:"applied",actualValues,createdIDs,warnings}, {status:"unchanged",reason}, {status:"refused",code,reason}. Refusals throw Error with code/reason unless tolerate:true. A refused list rolls back; earlier lists remain. Bindings persist: use "$name" or "$name.piece1"; rebinding replaces its namespace. Bind only ID-producing operations.
        Find scripts may query/summary and must call builder.report_scenes({scenes:[{id,reason}],summary}) once; at most 10 unique captured scenes, one-line reasons 1…500 characters, summary 1…2000. No mutations or ensures.
        Frozen params rejects undeclared reads. Read-only script = {name,mode}; console.log/warn/error bounded to 64 KiB. Optional return {summary:"…"}; no promises, timers, modules, network, filesystem or host objects. JSON only, finite safe numbers, depth <=32; no undefined fields, array holes, functions, cycles or BigInt. Source <=256 KiB, params <=64 KiB, bridge <=1 MiB, command lists <=200 steps/256 KiB. User explicitly Saves/Runs/Applies; scripts cannot Apply.
        """ + "\n" + json(.object(["operations": .object(ops), "queryKinds": .object(queryKinds), "fieldRules": .object(rules)]))
    }
}
