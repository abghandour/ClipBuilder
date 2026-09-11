import Foundation

/// A closed command vocabulary keeps file paths and invented source metadata
/// out of scripts. References are session UUIDs or "$name" bindings.
nonisolated enum BuilderCommand: Codable, Sendable, Equatable {
    case removeClip(clip: String)
    case removeClips(filter: ClipFilter)
    case splitClip(clip: String, at: Double, precision: TimelinePrecision? = nil)
    case trimClip(clip: String, duration: Double, precision: TimelinePrecision? = nil)
    case setSourceRange(clip: String, start: Double, end: Double, precision: TimelinePrecision? = nil)
    case placeClip(clip: String, start: Double, track: Int)
    case addScene(scene: Int64, at: Double? = nil, track: Int)
    case addCutaway(scene: Int64? = nil, video: Int64? = nil, at: Double? = nil,
                    track: Int, duration: Double? = nil, sourceStart: Double? = nil, coverAll: Bool)
    case setClipRole(clip: String, role: ClipRole)
    case setCutawayAudio(clip: String, audio: CutawayAudio)
    case setClipMuted(clip: String, muted: Bool)
    case setCutawayCoverAll(clip: String, coverAll: Bool)
    case duplicateClip(clip: String)
    case setTrackSequential(track: Int, sequential: Bool)
    case addCropBlock(layout: String, at: Double? = nil, duration: Double? = nil)
    case setCropLayout(block: String, layout: String)
    case removeCropBlock(block: String)
    case addBumper(bumper: String, at: Double? = nil, mode: BumperMode)
    case addSound(sound: String, at: Double? = nil, duration: Double)
    case addText(at: Double? = nil, text: String)
    case addImage(image: String, at: Double? = nil, length: Double)
    case removeOverlay(overlay: String)
    case setPlayhead(at: Double)
    case query(query: BuilderQuery)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ScriptKey.self)
        let op = try c.decode(String.self, forKey: ScriptKey("op"))
        switch op {
        case "remove_clip":
            try c.only(["op", "clip"])
            self = .removeClip(clip: try c.decode(String.self, forKey: ScriptKey("clip")))
        case "remove_clips":
            try c.only(["op", "filter"])
            self = .removeClips(filter: try c.decode(ClipFilter.self, forKey: ScriptKey("filter")))
        case "split_clip":
            try c.only(["op", "clip", "at", "precision"])
            self = .splitClip(
                clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                at: try c.decode(Double.self, forKey: ScriptKey("at")),
                precision: try c.decodeIfPresent(TimelinePrecision.self, forKey: ScriptKey("precision")))
        case "trim_clip":
            try c.only(["op", "clip", "duration", "precision"])
            self = .trimClip(
                clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                duration: try c.decode(Double.self, forKey: ScriptKey("duration")),
                precision: try c.decodeIfPresent(TimelinePrecision.self, forKey: ScriptKey("precision")))
        case "set_source_range":
            try c.only(["op", "clip", "start", "end", "precision"])
            self = .setSourceRange(
                clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                start: try c.decode(Double.self, forKey: ScriptKey("start")),
                end: try c.decode(Double.self, forKey: ScriptKey("end")),
                precision: try c.decodeIfPresent(TimelinePrecision.self, forKey: ScriptKey("precision")))
        case "place_clip":
            try c.only(["op", "clip", "start", "track"])
            self = .placeClip(
                clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                start: try c.decode(Double.self, forKey: ScriptKey("start")),
                track: try c.decode(Int.self, forKey: ScriptKey("track")))
        case "add_scene":
            try c.only(["op", "scene", "at", "track"])
            self = .addScene(
                scene: try c.decode(Int64.self, forKey: ScriptKey("scene")),
                at: try c.decodeIfPresent(Double.self, forKey: ScriptKey("at")),
                track: try c.decode(Int.self, forKey: ScriptKey("track")))
        case "add_cutaway":
            try c.only(["op", "scene", "video", "at", "track", "duration", "source_start", "cover_all"])
            self = .addCutaway(
                scene: try c.decodeIfPresent(Int64.self, forKey: ScriptKey("scene")),
                video: try c.decodeIfPresent(Int64.self, forKey: ScriptKey("video")),
                at: try c.decodeIfPresent(Double.self, forKey: ScriptKey("at")),
                track: try c.decode(Int.self, forKey: ScriptKey("track")),
                duration: try c.decodeIfPresent(Double.self, forKey: ScriptKey("duration")),
                sourceStart: try c.decodeIfPresent(Double.self, forKey: ScriptKey("source_start")),
                coverAll: try c.decode(Bool.self, forKey: ScriptKey("cover_all")))
        case "set_clip_role":
            try c.only(["op", "clip", "role"])
            self = .setClipRole(
                clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                role: try c.decode(ClipRole.self, forKey: ScriptKey("role")))
        case "set_cutaway_audio":
            try c.only(["op", "clip", "audio"])
            self = .setCutawayAudio(
                clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                audio: try c.decode(CutawayAudio.self, forKey: ScriptKey("audio")))
        case "set_clip_muted":
            try c.only(["op", "clip", "muted"])
            self = .setClipMuted(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                                 muted: try c.decode(Bool.self, forKey: ScriptKey("muted")))
        case "set_cutaway_cover_all":
            try c.only(["op", "clip", "cover_all"])
            self = .setCutawayCoverAll(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                                       coverAll: try c.decode(Bool.self, forKey: ScriptKey("cover_all")))
        case "duplicate_clip":
            try c.only(["op", "clip"])
            self = .duplicateClip(clip: try c.decode(String.self, forKey: ScriptKey("clip")))
        case "set_track_sequential":
            try c.only(["op", "track", "sequential"])
            self = .setTrackSequential(
                track: try c.decode(Int.self, forKey: ScriptKey("track")),
                sequential: try c.decode(Bool.self, forKey: ScriptKey("sequential")))
        case "add_crop_block":
            try c.only(["op", "layout", "at", "duration"])
            self = .addCropBlock(
                layout: try c.decode(String.self, forKey: ScriptKey("layout")),
                at: try c.decodeIfPresent(Double.self, forKey: ScriptKey("at")),
                duration: try c.decodeIfPresent(Double.self, forKey: ScriptKey("duration")))
        case "set_crop_layout":
            try c.only(["op", "block", "layout"])
            self = .setCropLayout(
                block: try c.decode(String.self, forKey: ScriptKey("block")),
                layout: try c.decode(String.self, forKey: ScriptKey("layout")))
        case "remove_crop_block":
            try c.only(["op", "block"])
            self = .removeCropBlock(block: try c.decode(String.self, forKey: ScriptKey("block")))
        case "add_bumper":
            try c.only(["op", "bumper", "at", "mode"])
            self = .addBumper(
                bumper: try c.decode(String.self, forKey: ScriptKey("bumper")),
                at: try c.decodeIfPresent(Double.self, forKey: ScriptKey("at")),
                mode: try c.decode(BumperMode.self, forKey: ScriptKey("mode")))
        case "add_sound":
            try c.only(["op", "sound", "at", "duration"])
            self = .addSound(
                sound: try c.decode(String.self, forKey: ScriptKey("sound")),
                at: try c.decodeIfPresent(Double.self, forKey: ScriptKey("at")),
                duration: try c.decode(Double.self, forKey: ScriptKey("duration")))
        case "add_text":
            try c.only(["op", "at", "text"])
            self = .addText(
                at: try c.decodeIfPresent(Double.self, forKey: ScriptKey("at")),
                text: try c.decode(String.self, forKey: ScriptKey("text")))
        case "add_image":
            try c.only(["op", "image", "at", "length"])
            self = .addImage(
                image: try c.decode(String.self, forKey: ScriptKey("image")),
                at: try c.decodeIfPresent(Double.self, forKey: ScriptKey("at")),
                length: try c.decode(Double.self, forKey: ScriptKey("length")))
        case "remove_overlay":
            try c.only(["op", "overlay"])
            self = .removeOverlay(overlay: try c.decode(String.self, forKey: ScriptKey("overlay")))
        case "set_playhead":
            try c.only(["op", "at"])
            self = .setPlayhead(at: try c.decode(Double.self, forKey: ScriptKey("at")))
        case "query":
            try c.only(["op", "query"])
            self = .query(query: try c.decode(BuilderQuery.self, forKey: ScriptKey("query")))
        default: throw ScriptError.invalid("Unknown operation: \(op)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ScriptKey.self)
        switch self {
        case let .removeClip(clip):
            try c.encode("remove_clip", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
        case let .removeClips(filter):
            try c.encode("remove_clips", forKey: ScriptKey("op"))
            try c.encode(filter, forKey: ScriptKey("filter"))
        case let .splitClip(clip, at, precision):
            try c.encode("split_clip", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(at, forKey: ScriptKey("at"))
            try c.encodeIfPresent(precision, forKey: ScriptKey("precision"))
        case let .trimClip(clip, duration, precision):
            try c.encode("trim_clip", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(duration, forKey: ScriptKey("duration"))
            try c.encodeIfPresent(precision, forKey: ScriptKey("precision"))
        case let .setSourceRange(clip, start, end, precision):
            try c.encode("set_source_range", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(start, forKey: ScriptKey("start"))
            try c.encode(end, forKey: ScriptKey("end"))
            try c.encodeIfPresent(precision, forKey: ScriptKey("precision"))
        case let .placeClip(clip, start, track):
            try c.encode("place_clip", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(start, forKey: ScriptKey("start"))
            try c.encode(track, forKey: ScriptKey("track"))
        case let .addScene(scene, at, track):
            try c.encode("add_scene", forKey: ScriptKey("op"))
            try c.encode(scene, forKey: ScriptKey("scene"))
            try c.encodeIfPresent(at, forKey: ScriptKey("at"))
            try c.encode(track, forKey: ScriptKey("track"))
        case let .addCutaway(scene, video, at, track, duration, sourceStart, coverAll):
            try c.encode("add_cutaway", forKey: ScriptKey("op"))
            try c.encodeIfPresent(scene, forKey: ScriptKey("scene"))
            try c.encodeIfPresent(video, forKey: ScriptKey("video"))
            try c.encodeIfPresent(at, forKey: ScriptKey("at"))
            try c.encode(track, forKey: ScriptKey("track"))
            try c.encodeIfPresent(duration, forKey: ScriptKey("duration"))
            try c.encodeIfPresent(sourceStart, forKey: ScriptKey("source_start"))
            try c.encode(coverAll, forKey: ScriptKey("cover_all"))
        case let .setClipRole(clip, role):
            try c.encode("set_clip_role", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(role, forKey: ScriptKey("role"))
        case let .setCutawayAudio(clip, audio):
            try c.encode("set_cutaway_audio", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(audio, forKey: ScriptKey("audio"))
        case let .setClipMuted(clip, muted):
            try c.encode("set_clip_muted", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(muted, forKey: ScriptKey("muted"))
        case let .setCutawayCoverAll(clip, coverAll):
            try c.encode("set_cutaway_cover_all", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(coverAll, forKey: ScriptKey("cover_all"))
        case let .duplicateClip(clip):
            try c.encode("duplicate_clip", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
        case let .setTrackSequential(track, sequential):
            try c.encode("set_track_sequential", forKey: ScriptKey("op"))
            try c.encode(track, forKey: ScriptKey("track"))
            try c.encode(sequential, forKey: ScriptKey("sequential"))
        case let .addCropBlock(layout, at, duration):
            try c.encode("add_crop_block", forKey: ScriptKey("op"))
            try c.encode(layout, forKey: ScriptKey("layout"))
            try c.encodeIfPresent(at, forKey: ScriptKey("at"))
            try c.encodeIfPresent(duration, forKey: ScriptKey("duration"))
        case let .setCropLayout(block, layout):
            try c.encode("set_crop_layout", forKey: ScriptKey("op"))
            try c.encode(block, forKey: ScriptKey("block"))
            try c.encode(layout, forKey: ScriptKey("layout"))
        case let .removeCropBlock(block):
            try c.encode("remove_crop_block", forKey: ScriptKey("op"))
            try c.encode(block, forKey: ScriptKey("block"))
        case let .addBumper(bumper, at, mode):
            try c.encode("add_bumper", forKey: ScriptKey("op"))
            try c.encode(bumper, forKey: ScriptKey("bumper"))
            try c.encodeIfPresent(at, forKey: ScriptKey("at"))
            try c.encode(mode, forKey: ScriptKey("mode"))
        case let .addSound(sound, at, duration):
            try c.encode("add_sound", forKey: ScriptKey("op"))
            try c.encode(sound, forKey: ScriptKey("sound"))
            try c.encodeIfPresent(at, forKey: ScriptKey("at"))
            try c.encode(duration, forKey: ScriptKey("duration"))
        case let .addText(at, text):
            try c.encode("add_text", forKey: ScriptKey("op"))
            try c.encodeIfPresent(at, forKey: ScriptKey("at"))
            try c.encode(text, forKey: ScriptKey("text"))
        case let .addImage(image, at, length):
            try c.encode("add_image", forKey: ScriptKey("op"))
            try c.encode(image, forKey: ScriptKey("image"))
            try c.encodeIfPresent(at, forKey: ScriptKey("at"))
            try c.encode(length, forKey: ScriptKey("length"))
        case let .removeOverlay(overlay):
            try c.encode("remove_overlay", forKey: ScriptKey("op"))
            try c.encode(overlay, forKey: ScriptKey("overlay"))
        case let .setPlayhead(at):
            try c.encode("set_playhead", forKey: ScriptKey("op"))
            try c.encode(at, forKey: ScriptKey("at"))
        case let .query(query):
            try c.encode("query", forKey: ScriptKey("op"))
            try c.encode(query, forKey: ScriptKey("query"))
        }
    }
}

/// Bind only returned IDs, never selection (normalization can remove it).
nonisolated struct BuilderScriptStep: Codable, Sendable, Equatable {
    var command: BuilderCommand
    var bind: String?

    init(_ command: BuilderCommand, bind: String? = nil) {
        self.command = command
        self.bind = bind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ScriptKey.self)
        try c.only(["command", "bind"])
        command = try c.decode(BuilderCommand.self, forKey: ScriptKey("command"))
        bind = try c.decodeIfPresent(String.self, forKey: ScriptKey("bind"))
    }
}

nonisolated enum ScriptError: Error, LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): reason }
    }
}

nonisolated struct ScriptKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

nonisolated extension KeyedDecodingContainer where Key == ScriptKey {
    func only(_ fields: Set<String>) throws {
        let unknown = Set(allKeys.map(\.stringValue)).subtracting(fields)
        guard unknown.isEmpty else {
            throw ScriptError.invalid("Unknown fields: " + unknown.sorted().joined(separator: ", "))
        }
    }
}
