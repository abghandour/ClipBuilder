import Foundation

/// Multi-track builder timeline document — the Swift port of the Python
/// builder's timeline JSON (clip_builder.py buildTimeline()). CodingKeys and
/// null-handling match the JavaScript serializer exactly so timelines round-
/// trip between this app and the Python app's generated_videos.timeline_json.

nonisolated struct TimelineDocument: Codable, Sendable, Equatable {
    var videoTrack: [TimelineClip] = []
    var soundTrack: [SoundItem] = []
    var textOverlays: [TextOverlayItem] = []
    var trackSettings: [TrackSettings] = TimelineDocument.defaultTrackSettings
    var trackCount: Int = 1                       // 1...3 visible video tracks
    var trackSequential: [Bool] = [true, true, true]
    var includeIntro: Bool = true
    var includeOutro: Bool = true

    static let defaultTrackSettings: [TrackSettings] = [
        TrackSettings(defaultPosition: "top"),
        TrackSettings(defaultPosition: "center"),
        TrackSettings(defaultPosition: "bottom"),
    ]

    var isEmpty: Bool {
        videoTrack.isEmpty && soundTrack.isEmpty && textOverlays.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case videoTrack = "video_track"
        case soundTrack = "sound_track"
        case textOverlays = "text_overlays"
        case trackSettings = "track_settings"
        case trackCount = "track_count"
        case trackSequential = "track_sequential"
        case includeIntro = "include_intro"
        case includeOutro = "include_outro"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoTrack = try container.decodeIfPresent([TimelineClip].self, forKey: .videoTrack) ?? []
        soundTrack = try container.decodeIfPresent([SoundItem].self, forKey: .soundTrack) ?? []
        textOverlays = try container.decodeIfPresent([TextOverlayItem].self, forKey: .textOverlays) ?? []
        var settings = try container.decodeIfPresent([TrackSettings].self, forKey: .trackSettings) ?? []
        // Always keep exactly 3 entries with the UI's positional defaults.
        let defaults = Self.defaultTrackSettings
        for index in 0..<3 where index >= settings.count {
            settings.append(defaults[index])
        }
        for index in 0..<3 where settings[index].defaultPosition.isEmpty {
            settings[index].defaultPosition = defaults[index].defaultPosition
        }
        trackSettings = Array(settings.prefix(3))
        trackCount = min(3, max(1, try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 1))
        var sequential = try container.decodeIfPresent([Bool].self, forKey: .trackSequential) ?? [true, true, true]
        while sequential.count < 3 { sequential.append(true) }
        trackSequential = Array(sequential.prefix(3))
        includeIntro = try container.decodeIfPresent(Bool.self, forKey: .includeIntro) ?? true
        includeOutro = try container.decodeIfPresent(Bool.self, forKey: .includeOutro) ?? true
    }
}

/// One clip on a video track. Identity: a scene id when untrimmed, or a raw
/// video_file/start/end triple — the same dual form the web serializer emits
/// (a trimmed scene clip loses its id so the Python side renders the trim).
nonisolated struct TimelineClip: Codable, Sendable, Equatable, Identifiable {
    /// SwiftUI identity only — never encoded.
    var uid = UUID()

    var sceneID: Int64?
    var videoFile: String?
    var sourceStart: Double?      // trim start within the source file
    var sourceEnd: Double?        // trim end within the source file
    var startTime: Double = 0     // position on the timeline
    var duration: Double = 0      // trimmed length shown on the timeline
    var track: Int = 0
    var wide: Bool = false
    var stackOrder: Int = 0
    var volume: Int = 5           // 1-5
    var muted: Bool = false
    var position: String?         // "top" | "center" | "bottom" | nil (layer default)
    var transIn: String?
    var transOut: String?
    var cropXFrac: Double?
    var freeCrops: [FreeCrop]?
    var captions: String = "inherit"   // inherit | none | top | middle | bottom

    /// Full duration of the referenced scene — editor state used to decide
    /// whether the clip is trimmed. Never encoded; refilled on hydration.
    var sceneFullDuration: Double?

    var isTrimmedScene: Bool {
        guard sceneID != nil, let full = sceneFullDuration else { return false }
        return abs(duration - full) > 0.05
    }

    static let captionChoices = ["inherit", "none", "top", "middle", "bottom"]

    enum CodingKeys: String, CodingKey {
        case type
        case sceneID = "id"
        case videoFile = "video_file"
        case sourceStart = "start"
        case sourceEnd = "end"
        case startTime = "start_time"
        case track, wide, muted, position, volume, captions, duration
        case stackOrder = "stack_order"
        case transIn = "trans_in"
        case transOut = "trans_out"
        case cropXFrac = "crop_x_frac"
        case freeCrops = "free_crops"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sceneID = try container.decodeIfPresent(Int64.self, forKey: .sceneID)
        videoFile = try container.decodeIfPresent(String.self, forKey: .videoFile)
        sourceStart = try container.decodeIfPresent(Double.self, forKey: .sourceStart)
        sourceEnd = try container.decodeIfPresent(Double.self, forKey: .sourceEnd)
        startTime = try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
        track = try container.decodeIfPresent(Int.self, forKey: .track) ?? 0
        wide = try container.decodeIfPresent(Bool.self, forKey: .wide) ?? false
        stackOrder = try container.decodeIfPresent(Int.self, forKey: .stackOrder) ?? 0
        volume = try container.decodeIfPresent(Int.self, forKey: .volume) ?? 5
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        position = try container.decodeIfPresent(String.self, forKey: .position)
        transIn = try container.decodeIfPresent(String.self, forKey: .transIn)
        transOut = try container.decodeIfPresent(String.self, forKey: .transOut)
        cropXFrac = try container.decodeIfPresent(Double.self, forKey: .cropXFrac)
        freeCrops = try container.decodeIfPresent([FreeCrop].self, forKey: .freeCrops)
        captions = Self.decodeCaptions(container, key: .captions, fallback: "inherit",
                                       valid: Self.captionChoices)
        // The web serializer never writes duration for scene clips; hydration
        // fills it in from the scene. video_file clips carry it implicitly.
        if let explicit = try container.decodeIfPresent(Double.self, forKey: .duration) {
            duration = explicit
        } else if let start = sourceStart, let end = sourceEnd {
            duration = max(0, end - start)
        }
    }

    /// Old saves use booleans for captions (true→bottom, false→none) —
    /// migrate exactly like _generate_multitrack does.
    static func decodeCaptions(_ container: KeyedDecodingContainer<CodingKeys>,
                               key: CodingKeys, fallback: String, valid: [String]) -> String {
        if let flag = try? container.decode(Bool.self, forKey: key) {
            return flag ? "bottom" : "none"
        }
        if let value = try? container.decode(String.self, forKey: key), valid.contains(value) {
            return value
        }
        return fallback
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("clip", forKey: .type)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(track, forKey: .track)
        try container.encode(wide, forKey: .wide)
        try container.encode(stackOrder, forKey: .stackOrder)
        try container.encode(volume, forKey: .volume)
        try container.encode(muted, forKey: .muted)
        try encodeOrNull(position, in: &container, forKey: .position)
        try encodeOrNull(transIn, in: &container, forKey: .transIn)
        try encodeOrNull(transOut, in: &container, forKey: .transOut)
        try encodeOrNull(cropXFrac, in: &container, forKey: .cropXFrac)
        if let freeCrops, !freeCrops.isEmpty {
            try container.encode(freeCrops, forKey: .freeCrops)
        } else {
            try container.encodeNil(forKey: .freeCrops)
        }
        try container.encode(captions, forKey: .captions)
        if let sceneID, !isTrimmedScene {
            try container.encode(sceneID, forKey: .sceneID)
        } else if let videoFile, let sourceStart {
            // Trimmed / raw-file clips: identify by file + trimmed extent,
            // matching the web serializer's video_file fallback.
            try container.encode(videoFile, forKey: .videoFile)
            try container.encode(sourceStart, forKey: .sourceStart)
            try container.encode(sourceStart + duration, forKey: .sourceEnd)
        } else if let sceneID {
            try container.encode(sceneID, forKey: .sceneID)
        }
    }

    static func == (lhs: TimelineClip, rhs: TimelineClip) -> Bool {
        lhs.uid == rhs.uid && lhs.sceneID == rhs.sceneID && lhs.videoFile == rhs.videoFile
            && lhs.sourceStart == rhs.sourceStart && lhs.startTime == rhs.startTime
            && lhs.duration == rhs.duration && lhs.track == rhs.track && lhs.wide == rhs.wide
            && lhs.stackOrder == rhs.stackOrder && lhs.volume == rhs.volume && lhs.muted == rhs.muted
            && lhs.position == rhs.position && lhs.transIn == rhs.transIn && lhs.transOut == rhs.transOut
            && lhs.cropXFrac == rhs.cropXFrac && lhs.freeCrops == rhs.freeCrops && lhs.captions == rhs.captions
    }

    var id: UUID { uid }
}

private nonisolated func encodeOrNull<T: Encodable, K: CodingKey>(
    _ value: T?, in container: inout KeyedEncodingContainer<K>, forKey key: K) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}

/// Per-layer settings (three entries, one per video track).
nonisolated struct TrackSettings: Codable, Sendable, Equatable {
    var muted: Bool = false
    var defaultPosition: String = "top"     // wide-clip slot when the clip has no override
    var captions: String = "none"           // none | top | middle | bottom
    var defaultCropXFrac: Double?

    static let captionChoices = ["none", "top", "middle", "bottom"]

    enum CodingKeys: String, CodingKey {
        case muted, captions
        case defaultPosition = "default_position"
        case defaultCropXFrac = "default_crop_x_frac"
    }

    init(muted: Bool = false, defaultPosition: String = "top",
         captions: String = "none", defaultCropXFrac: Double? = nil) {
        self.muted = muted
        self.defaultPosition = defaultPosition
        self.captions = captions
        self.defaultCropXFrac = defaultCropXFrac
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        defaultPosition = try container.decodeIfPresent(String.self, forKey: .defaultPosition) ?? ""
        if let flag = try? container.decode(Bool.self, forKey: .captions) {
            captions = flag ? "bottom" : "none"
        } else if let value = try? container.decode(String.self, forKey: .captions),
                  Self.captionChoices.contains(value) {
            captions = value
        } else {
            captions = "none"
        }
        defaultCropXFrac = try container.decodeIfPresent(Double.self, forKey: .defaultCropXFrac)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(muted, forKey: .muted)
        try container.encode(defaultPosition, forKey: .defaultPosition)
        try container.encode(captions, forKey: .captions)
        try encodeOrNull(defaultCropXFrac, in: &container, forKey: .defaultCropXFrac)
    }
}

/// One music block on the sound track.
nonisolated struct SoundItem: Codable, Sendable, Equatable, Identifiable {
    var uid = UUID()
    var name: String = ""
    var volume: Int = 3            // 1-5
    var startTime: Double = 0
    var duration: Double = 10

    enum CodingKeys: String, CodingKey {
        case name, volume, duration
        case startTime = "start_time"
    }

    init(name: String = "", volume: Int = 3, startTime: Double = 0, duration: Double = 10) {
        self.name = name
        self.volume = volume
        self.startTime = startTime
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        volume = try container.decodeIfPresent(Int.self, forKey: .volume) ?? 3
        startTime = try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 10
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(volume, forKey: .volume)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(duration, forKey: .duration)
    }

    static func == (lhs: SoundItem, rhs: SoundItem) -> Bool {
        lhs.uid == rhs.uid && lhs.name == rhs.name && lhs.volume == rhs.volume
            && lhs.startTime == rhs.startTime && lhs.duration == rhs.duration
    }

    var id: UUID { uid }
}

/// One text overlay. Optional keys are encoded only when meaningful, matching
/// the web serializer (bold/italic only when true, fractions only when set).
nonisolated struct TextOverlayItem: Codable, Sendable, Equatable, Identifiable {
    var uid = UUID()
    var text: String = ""
    var startTime: Double = 0
    var endTime: Double = 3
    var fontsize: Int = 42
    var fontcolor: String = "white"
    var fontfamily: String?
    var boxOpacity: Double = 0.5
    var bold: Bool = false
    var italic: Bool = false
    var bgcolor: String?
    var xFrac: Double?
    var yFrac: Double?
    var wFrac: Double?
    var hFrac: Double?
    var position: String = "bottom"     // used when fractions are absent
    var transIn: String = "fade"
    var transOut: String = "fade"

    var duration: Double { max(0, endTime - startTime) }

    static let transitionChoices = ["fade", "slide_left", "slide_right", "slide_up", "slide_down", "cut"]

    enum CodingKeys: String, CodingKey {
        case text, fontsize, fontcolor, fontfamily, bold, italic, bgcolor, position
        case startTime = "start_time"
        case endTime = "end_time"
        case boxOpacity = "box_opacity"
        case xFrac = "x_frac"
        case yFrac = "y_frac"
        case wFrac = "w_frac"
        case hFrac = "h_frac"
        case transIn = "trans_in"
        case transOut = "trans_out"
    }

    init(text: String = "", startTime: Double = 0, endTime: Double = 3) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        startTime = try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
        endTime = try container.decodeIfPresent(Double.self, forKey: .endTime) ?? 3
        fontsize = try container.decodeIfPresent(Int.self, forKey: .fontsize) ?? 42
        fontcolor = try container.decodeIfPresent(String.self, forKey: .fontcolor) ?? "white"
        fontfamily = try container.decodeIfPresent(String.self, forKey: .fontfamily)
        boxOpacity = try container.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? 0.5
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        bgcolor = try container.decodeIfPresent(String.self, forKey: .bgcolor)
        xFrac = try container.decodeIfPresent(Double.self, forKey: .xFrac)
        yFrac = try container.decodeIfPresent(Double.self, forKey: .yFrac)
        wFrac = try container.decodeIfPresent(Double.self, forKey: .wFrac)
        hFrac = try container.decodeIfPresent(Double.self, forKey: .hFrac)
        position = try container.decodeIfPresent(String.self, forKey: .position) ?? "bottom"
        transIn = try container.decodeIfPresent(String.self, forKey: .transIn) ?? "fade"
        transOut = try container.decodeIfPresent(String.self, forKey: .transOut) ?? "fade"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(fontsize, forKey: .fontsize)
        try container.encode(fontcolor, forKey: .fontcolor)
        try container.encode(boxOpacity, forKey: .boxOpacity)
        try container.encode(transIn, forKey: .transIn)
        try container.encode(transOut, forKey: .transOut)
        try container.encode(position, forKey: .position)
        if let fontfamily { try container.encode(fontfamily, forKey: .fontfamily) }
        if let xFrac, let yFrac {
            try container.encode(xFrac, forKey: .xFrac)
            try container.encode(yFrac, forKey: .yFrac)
        }
        if let wFrac, let hFrac, wFrac > 0, hFrac > 0 {
            try container.encode(wFrac, forKey: .wFrac)
            try container.encode(hFrac, forKey: .hFrac)
        }
        if bold { try container.encode(true, forKey: .bold) }
        if italic { try container.encode(true, forKey: .italic) }
        if let bgcolor { try container.encode(bgcolor, forKey: .bgcolor) }
    }

    static func == (lhs: TextOverlayItem, rhs: TextOverlayItem) -> Bool {
        lhs.uid == rhs.uid && lhs.text == rhs.text && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime && lhs.fontsize == rhs.fontsize
            && lhs.fontcolor == rhs.fontcolor && lhs.fontfamily == rhs.fontfamily
            && lhs.boxOpacity == rhs.boxOpacity && lhs.bold == rhs.bold && lhs.italic == rhs.italic
            && lhs.bgcolor == rhs.bgcolor && lhs.xFrac == rhs.xFrac && lhs.yFrac == rhs.yFrac
            && lhs.wFrac == rhs.wFrac && lhs.hFrac == rhs.hFrac && lhs.position == rhs.position
            && lhs.transIn == rhs.transIn && lhs.transOut == rhs.transOut
    }

    var id: UUID { uid }
}

/// Free-mode crop: one source rectangle mapped to one destination rectangle
/// on the 1080x1920 canvas, composited in z order.
nonisolated struct FreeCrop: Codable, Sendable, Equatable {
    var src: FreeCropRect
    var dst: FreeCropRect
    var z: Int = 0
}

nonisolated struct FreeCropRect: Codable, Sendable, Equatable {
    var xFrac: Double = 0
    var yFrac: Double = 0
    var wFrac: Double = 1
    var hFrac: Double = 1

    enum CodingKeys: String, CodingKey {
        case xFrac = "x_frac"
        case yFrac = "y_frac"
        case wFrac = "w_frac"
        case hFrac = "h_frac"
    }
}
