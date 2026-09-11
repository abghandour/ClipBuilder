import Foundation

/// A closed command vocabulary keeps file paths and invented source metadata
/// out of scripts. References are session UUIDs or "$name" bindings.
nonisolated enum BuilderCommand: Codable, Sendable, Equatable {
    case ensureTranscript(video: Int64)
    case ensurePeople(video: Int64)
    case ensureAnalysis(video: Int64)
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

    case setBumperMode(clip: String, mode: BumperMode)
    case setCropBlockDuration(block: String, duration: Double)
    case splitCropBlock(at: Double)
    case removeSound(sound: String)
    case addOverlay(template: String, at: Double? = nil, duration: Double? = nil, person: String? = nil)
    case setImageGeometry(overlay: String, x: Double? = nil, y: Double? = nil, width: Double? = nil, opacity: Double? = nil)
    case setOverlayPosition(overlay: String, x: Double, y: Double)
    case setTextStyle(overlay: String, style: BuilderTextStylePatch)
    case setClipVolume(clip: String, volume: Int)
    case setClipPosition(clip: String, position: String?)
    case setClipCrop(clip: String, fraction: Double?)
    case splitZoomFeeds(clip: String, left: String, right: String)
    case clearTimeline

    case setSoundVolume(sound: String, volume: Int)
    case setSoundRange(sound: String, start: Double, duration: Double)
    case moveSound(sound: String, at: Double)
    case setText(overlay: String, text: String)
    case setTextPosition(overlay: String, position: String)
    case setOverlayRange(overlay: String, at: Double, duration: Double)
    case setOverlayTransitions(overlay: String, transIn: String, transOut: String)
    case setClipSpeed(clip: String, speed: Double)
    case setClipFades(clip: String, fadeIn: Double, fadeOut: Double)
    case setClipCaptions(clip: String, captions: String)
    case setClipTransitions(clip: String, transIn: String, transOut: String)
    case setClipCenterStage(clip: String, enabled: Bool)
    case setClipAreaWindow(clip: String, x: Double, y: Double, width: Double, height: Double)
    case setTrackCaptions(track: Int, captions: String)
    case setTrackMuted(track: Int, muted: Bool)
    case setTrackPosition(track: Int, position: String)
    case setTrackCrop(track: Int, fraction: Double?)
    case setRenderSettings(settings: BuilderRenderSettingsPatch)
    case setPacing(pacing: BuilderPacing)

    var prerequisite: (kind: BuilderPrerequisiteKind, video: Int64)? {
        switch self {
        case .ensureTranscript(let video): (.transcript, video)
        case .ensurePeople(let video): (.people, video)
        case .ensureAnalysis(let video): (.analysis, video)
        default: nil
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ScriptKey.self)
        let op = try c.decode(String.self, forKey: ScriptKey("op"))
        switch op {
        case "ensure_transcript", "ensure_people", "ensure_analysis":
            try c.only(["op", "video"])
            let video = try c.decode(Int64.self, forKey: ScriptKey("video"))
            guard video > 0 else { throw ScriptError.invalid("Video ID must be positive.") }
            switch op {
            case "ensure_transcript": self = .ensureTranscript(video: video)
            case "ensure_people": self = .ensurePeople(video: video)
            default: self = .ensureAnalysis(video: video)
            }
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
        case "set_bumper_mode":
            try c.only(["op", "clip", "mode"])
            self = .setBumperMode(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                mode: try c.decode(BumperMode.self, forKey: ScriptKey("mode")))
        case "set_crop_block_duration":
            try c.only(["op", "block", "duration"])
            self = .setCropBlockDuration(block: try c.decode(String.self, forKey: ScriptKey("block")),
                duration: try c.decode(Double.self, forKey: ScriptKey("duration")))
        case "split_crop_block":
            try c.only(["op", "at"])
            self = .splitCropBlock(at: try c.decode(Double.self, forKey: ScriptKey("at")))
        case "remove_sound":
            try c.only(["op", "sound"])
            self = .removeSound(sound: try c.decode(String.self, forKey: ScriptKey("sound")))
        case "add_overlay":
            try c.only(["op", "template", "at", "duration", "person"])
            self = .addOverlay(template: try c.decode(String.self, forKey: ScriptKey("template")),
                at: try c.decodeIfPresent(Double.self, forKey: ScriptKey("at")),
                duration: try c.decodeIfPresent(Double.self, forKey: ScriptKey("duration")),
                person: try c.decodeIfPresent(String.self, forKey: ScriptKey("person")))
        case "set_image_geometry":
            try c.only(["op", "overlay", "x", "y", "width", "opacity"])
            self = .setImageGeometry(overlay: try c.decode(String.self, forKey: ScriptKey("overlay")),
                x: try c.decodeIfPresent(Double.self, forKey: ScriptKey("x")),
                y: try c.decodeIfPresent(Double.self, forKey: ScriptKey("y")),
                width: try c.decodeIfPresent(Double.self, forKey: ScriptKey("width")),
                opacity: try c.decodeIfPresent(Double.self, forKey: ScriptKey("opacity")))
        case "set_overlay_position":
            try c.only(["op", "overlay", "x", "y"])
            self = .setOverlayPosition(overlay: try c.decode(String.self, forKey: ScriptKey("overlay")),
                x: try c.decode(Double.self, forKey: ScriptKey("x")),
                y: try c.decode(Double.self, forKey: ScriptKey("y")))
        case "set_text_style":
            try c.only(["op", "overlay", "style"])
            self = .setTextStyle(overlay: try c.decode(String.self, forKey: ScriptKey("overlay")),
                style: try c.decode(BuilderTextStylePatch.self, forKey: ScriptKey("style")))
        case "set_clip_volume":
            try c.only(["op", "clip", "volume"])
            self = .setClipVolume(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                volume: try c.decode(Int.self, forKey: ScriptKey("volume")))
        case "set_clip_position":
            try c.only(["op", "clip", "position"])
            guard c.contains(ScriptKey("position")) else { throw BuilderCommandFailure.invalid("Missing position; use null to clear.") }
            self = .setClipPosition(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                position: try c.decodeIfPresent(String.self, forKey: ScriptKey("position")))
        case "set_clip_crop":
            try c.only(["op", "clip", "fraction"])
            guard c.contains(ScriptKey("fraction")) else { throw BuilderCommandFailure.invalid("Missing fraction; use null to clear.") }
            self = .setClipCrop(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                fraction: try c.decodeIfPresent(Double.self, forKey: ScriptKey("fraction")))
        case "split_zoom_feeds":
            try c.only(["op", "clip", "left", "right"])
            self = .splitZoomFeeds(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                left: try c.decode(String.self, forKey: ScriptKey("left")),
                right: try c.decode(String.self, forKey: ScriptKey("right")))
        case "clear_timeline":
            try c.only(["op"])
            self = .clearTimeline
        case "set_sound_volume":
            try c.only(["op", "sound", "volume"])
            self = .setSoundVolume(sound: try c.decode(String.self, forKey: ScriptKey("sound")),
                volume: try c.decode(Int.self, forKey: ScriptKey("volume")))
        case "set_sound_range":
            try c.only(["op", "sound", "start", "duration"])
            self = .setSoundRange(sound: try c.decode(String.self, forKey: ScriptKey("sound")),
                start: try c.decode(Double.self, forKey: ScriptKey("start")),
                duration: try c.decode(Double.self, forKey: ScriptKey("duration")))
        case "move_sound":
            try c.only(["op", "sound", "at"])
            self = .moveSound(sound: try c.decode(String.self, forKey: ScriptKey("sound")),
                at: try c.decode(Double.self, forKey: ScriptKey("at")))
        case "set_text":
            try c.only(["op", "overlay", "text"])
            self = .setText(overlay: try c.decode(String.self, forKey: ScriptKey("overlay")),
                text: try c.decode(String.self, forKey: ScriptKey("text")))
        case "set_text_position":
            try c.only(["op", "overlay", "position"])
            self = .setTextPosition(overlay: try c.decode(String.self, forKey: ScriptKey("overlay")),
                position: try c.decode(String.self, forKey: ScriptKey("position")))
        case "set_overlay_range":
            try c.only(["op", "overlay", "at", "duration"])
            self = .setOverlayRange(overlay: try c.decode(String.self, forKey: ScriptKey("overlay")),
                at: try c.decode(Double.self, forKey: ScriptKey("at")),
                duration: try c.decode(Double.self, forKey: ScriptKey("duration")))
        case "set_overlay_transitions":
            try c.only(["op", "overlay", "trans_in", "trans_out"])
            self = .setOverlayTransitions(overlay: try c.decode(String.self, forKey: ScriptKey("overlay")),
                transIn: try c.decode(String.self, forKey: ScriptKey("trans_in")),
                transOut: try c.decode(String.self, forKey: ScriptKey("trans_out")))
        case "set_clip_speed":
            try c.only(["op", "clip", "speed"])
            self = .setClipSpeed(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                speed: try c.decode(Double.self, forKey: ScriptKey("speed")))
        case "set_clip_fades":
            try c.only(["op", "clip", "fade_in", "fade_out"])
            self = .setClipFades(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                fadeIn: try c.decode(Double.self, forKey: ScriptKey("fade_in")),
                fadeOut: try c.decode(Double.self, forKey: ScriptKey("fade_out")))
        case "set_clip_captions":
            try c.only(["op", "clip", "captions"])
            self = .setClipCaptions(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                captions: try c.decode(String.self, forKey: ScriptKey("captions")))
        case "set_clip_transitions":
            try c.only(["op", "clip", "trans_in", "trans_out"])
            self = .setClipTransitions(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                transIn: try c.decode(String.self, forKey: ScriptKey("trans_in")),
                transOut: try c.decode(String.self, forKey: ScriptKey("trans_out")))
        case "set_clip_center_stage":
            try c.only(["op", "clip", "enabled"])
            self = .setClipCenterStage(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                enabled: try c.decode(Bool.self, forKey: ScriptKey("enabled")))
        case "set_clip_area_window":
            try c.only(["op", "clip", "x", "y", "width", "height"])
            self = .setClipAreaWindow(clip: try c.decode(String.self, forKey: ScriptKey("clip")),
                x: try c.decode(Double.self, forKey: ScriptKey("x")),
                y: try c.decode(Double.self, forKey: ScriptKey("y")),
                width: try c.decode(Double.self, forKey: ScriptKey("width")),
                height: try c.decode(Double.self, forKey: ScriptKey("height")))
        case "set_track_captions":
            try c.only(["op", "track", "captions"])
            self = .setTrackCaptions(track: try c.decode(Int.self, forKey: ScriptKey("track")),
                captions: try c.decode(String.self, forKey: ScriptKey("captions")))
        case "set_track_muted":
            try c.only(["op", "track", "muted"])
            self = .setTrackMuted(track: try c.decode(Int.self, forKey: ScriptKey("track")),
                muted: try c.decode(Bool.self, forKey: ScriptKey("muted")))
        case "set_track_position":
            try c.only(["op", "track", "position"])
            self = .setTrackPosition(track: try c.decode(Int.self, forKey: ScriptKey("track")),
                position: try c.decode(String.self, forKey: ScriptKey("position")))
        case "set_track_crop":
            try c.only(["op", "track", "fraction"])
            guard c.contains(ScriptKey("fraction")) else { throw BuilderCommandFailure.invalid("Missing fraction; use null to clear crop.") }
            self = .setTrackCrop(track: try c.decode(Int.self, forKey: ScriptKey("track")),
                fraction: try c.decodeIfPresent(Double.self, forKey: ScriptKey("fraction")))
        case "set_render_settings":
            try c.only(["op", "settings"])
            self = .setRenderSettings(settings: try c.decode(BuilderRenderSettingsPatch.self, forKey: ScriptKey("settings")))
        case "set_pacing":
            try c.only(["op", "pacing"])
            self = .setPacing(pacing: try c.decode(BuilderPacing.self, forKey: ScriptKey("pacing")))
        default: throw ScriptError.invalid("Unknown operation: \(op)")
        }
        try validateExpansion()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ScriptKey.self)
        switch self {
        case let .setBumperMode(clip, mode):
            try c.encode("set_bumper_mode", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(mode, forKey: ScriptKey("mode"))
        case let .setCropBlockDuration(block, duration):
            try c.encode("set_crop_block_duration", forKey: ScriptKey("op"))
            try c.encode(block, forKey: ScriptKey("block"))
            try c.encode(duration, forKey: ScriptKey("duration"))
        case let .splitCropBlock(at):
            try c.encode("split_crop_block", forKey: ScriptKey("op"))
            try c.encode(at, forKey: ScriptKey("at"))
        case let .removeSound(sound):
            try c.encode("remove_sound", forKey: ScriptKey("op"))
            try c.encode(sound, forKey: ScriptKey("sound"))
        case let .addOverlay(template, at, duration, person):
            try c.encode("add_overlay", forKey: ScriptKey("op"))
            try c.encode(template, forKey: ScriptKey("template"))
            try c.encodeIfPresent(at, forKey: ScriptKey("at"))
            try c.encodeIfPresent(duration, forKey: ScriptKey("duration"))
            try c.encodeIfPresent(person, forKey: ScriptKey("person"))
        case let .setImageGeometry(overlay, x, y, width, opacity):
            try c.encode("set_image_geometry", forKey: ScriptKey("op"))
            try c.encode(overlay, forKey: ScriptKey("overlay"))
            try c.encodeIfPresent(x, forKey: ScriptKey("x"))
            try c.encodeIfPresent(y, forKey: ScriptKey("y"))
            try c.encodeIfPresent(width, forKey: ScriptKey("width"))
            try c.encodeIfPresent(opacity, forKey: ScriptKey("opacity"))
        case let .setOverlayPosition(overlay, x, y):
            try c.encode("set_overlay_position", forKey: ScriptKey("op"))
            try c.encode(overlay, forKey: ScriptKey("overlay"))
            try c.encode(x, forKey: ScriptKey("x"))
            try c.encode(y, forKey: ScriptKey("y"))
        case let .setTextStyle(overlay, style):
            try c.encode("set_text_style", forKey: ScriptKey("op"))
            try c.encode(overlay, forKey: ScriptKey("overlay"))
            try c.encode(style, forKey: ScriptKey("style"))
        case let .setClipVolume(clip, volume):
            try c.encode("set_clip_volume", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(volume, forKey: ScriptKey("volume"))
        case let .setClipPosition(clip, position):
            try c.encode("set_clip_position", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(position, forKey: ScriptKey("position"))
        case let .setClipCrop(clip, fraction):
            try c.encode("set_clip_crop", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(fraction, forKey: ScriptKey("fraction"))
        case let .splitZoomFeeds(clip, left, right):
            try c.encode("split_zoom_feeds", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(left, forKey: ScriptKey("left"))
            try c.encode(right, forKey: ScriptKey("right"))
        case .clearTimeline:
            try c.encode("clear_timeline", forKey: ScriptKey("op"))
        case let .setSoundVolume(sound, volume):
            try c.encode("set_sound_volume", forKey: ScriptKey("op"))
            try c.encode(sound, forKey: ScriptKey("sound"))
            try c.encode(volume, forKey: ScriptKey("volume"))
        case let .setSoundRange(sound, start, duration):
            try c.encode("set_sound_range", forKey: ScriptKey("op"))
            try c.encode(sound, forKey: ScriptKey("sound"))
            try c.encode(start, forKey: ScriptKey("start"))
            try c.encode(duration, forKey: ScriptKey("duration"))
        case let .moveSound(sound, at):
            try c.encode("move_sound", forKey: ScriptKey("op"))
            try c.encode(sound, forKey: ScriptKey("sound"))
            try c.encode(at, forKey: ScriptKey("at"))
        case let .setText(overlay, text):
            try c.encode("set_text", forKey: ScriptKey("op"))
            try c.encode(overlay, forKey: ScriptKey("overlay"))
            try c.encode(text, forKey: ScriptKey("text"))
        case let .setTextPosition(overlay, position):
            try c.encode("set_text_position", forKey: ScriptKey("op"))
            try c.encode(overlay, forKey: ScriptKey("overlay"))
            try c.encode(position, forKey: ScriptKey("position"))
        case let .setOverlayRange(overlay, at, duration):
            try c.encode("set_overlay_range", forKey: ScriptKey("op"))
            try c.encode(overlay, forKey: ScriptKey("overlay"))
            try c.encode(at, forKey: ScriptKey("at"))
            try c.encode(duration, forKey: ScriptKey("duration"))
        case let .setOverlayTransitions(overlay, transIn, transOut):
            try c.encode("set_overlay_transitions", forKey: ScriptKey("op"))
            try c.encode(overlay, forKey: ScriptKey("overlay"))
            try c.encode(transIn, forKey: ScriptKey("trans_in"))
            try c.encode(transOut, forKey: ScriptKey("trans_out"))
        case let .setClipSpeed(clip, speed):
            try c.encode("set_clip_speed", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(speed, forKey: ScriptKey("speed"))
        case let .setClipFades(clip, fadeIn, fadeOut):
            try c.encode("set_clip_fades", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(fadeIn, forKey: ScriptKey("fade_in"))
            try c.encode(fadeOut, forKey: ScriptKey("fade_out"))
        case let .setClipCaptions(clip, captions):
            try c.encode("set_clip_captions", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(captions, forKey: ScriptKey("captions"))
        case let .setClipTransitions(clip, transIn, transOut):
            try c.encode("set_clip_transitions", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(transIn, forKey: ScriptKey("trans_in"))
            try c.encode(transOut, forKey: ScriptKey("trans_out"))
        case let .setClipCenterStage(clip, enabled):
            try c.encode("set_clip_center_stage", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(enabled, forKey: ScriptKey("enabled"))
        case let .setClipAreaWindow(clip, x, y, width, height):
            try c.encode("set_clip_area_window", forKey: ScriptKey("op"))
            try c.encode(clip, forKey: ScriptKey("clip"))
            try c.encode(x, forKey: ScriptKey("x"))
            try c.encode(y, forKey: ScriptKey("y"))
            try c.encode(width, forKey: ScriptKey("width"))
            try c.encode(height, forKey: ScriptKey("height"))
        case let .setTrackCaptions(track, captions):
            try c.encode("set_track_captions", forKey: ScriptKey("op"))
            try c.encode(track, forKey: ScriptKey("track"))
            try c.encode(captions, forKey: ScriptKey("captions"))
        case let .setTrackMuted(track, muted):
            try c.encode("set_track_muted", forKey: ScriptKey("op"))
            try c.encode(track, forKey: ScriptKey("track"))
            try c.encode(muted, forKey: ScriptKey("muted"))
        case let .setTrackPosition(track, position):
            try c.encode("set_track_position", forKey: ScriptKey("op"))
            try c.encode(track, forKey: ScriptKey("track"))
            try c.encode(position, forKey: ScriptKey("position"))
        case let .setTrackCrop(track, fraction):
            try c.encode("set_track_crop", forKey: ScriptKey("op"))
            try c.encode(track, forKey: ScriptKey("track"))
            try c.encode(fraction, forKey: ScriptKey("fraction"))
        case let .setRenderSettings(settings):
            try c.encode("set_render_settings", forKey: ScriptKey("op"))
            try c.encode(settings, forKey: ScriptKey("settings"))
        case let .setPacing(pacing):
            try c.encode("set_pacing", forKey: ScriptKey("op"))
            try c.encode(pacing, forKey: ScriptKey("pacing"))
        case let .ensureTranscript(video):
            try c.encode("ensure_transcript", forKey: ScriptKey("op"))
            try c.encode(video, forKey: ScriptKey("video"))
        case let .ensurePeople(video):
            try c.encode("ensure_people", forKey: ScriptKey("op"))
            try c.encode(video, forKey: ScriptKey("video"))
        case let .ensureAnalysis(video):
            try c.encode("ensure_analysis", forKey: ScriptKey("op"))
            try c.encode(video, forKey: ScriptKey("video"))
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
