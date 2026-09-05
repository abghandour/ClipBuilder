import Foundation

/// Multi-track builder timeline document — the Swift port of the Python
/// builder's timeline JSON (clip_builder.py buildTimeline()). CodingKeys and
/// null-handling match the JavaScript serializer exactly so timelines round-
/// trip between this app and the Python app's generated_videos.timeline_json.

nonisolated struct TimelineDocument: Codable, Sendable, Equatable {
    var renderSettings = RenderSettings()
    var pacing = EditPacing()
    var videoTrack: [TimelineClip] = []
    var soundTrack: [SoundItem] = []
    var textOverlays: [TextOverlayItem] = []
    var imageOverlays: [ImageOverlayItem] = []
    var overlayBlocks: [OverlayBlockItem] = []
    /// The cropping row: which Screen Crop layout is on screen when. Blocks
    /// tile the timeline gap-free (see `normalizingCropBlocks`); an empty
    /// list means a document that predates the row and renders the legacy
    /// per-clip `screenCrop` way.
    var cropBlocks: [CropBlockItem] = []
    var trackSettings: [TrackSettings] = TimelineDocument.defaultTrackSettings
    /// Visible video tracks. Derived from the cropping row (one track per
    /// area of the largest layout) whenever the row exists; kept in the
    /// JSON for older readers.
    var trackCount: Int = 1                       // 1...maxTracks visible video tracks
    var trackSequential: [Bool] = Array(repeating: true, count: TimelineDocument.maxTracks)

    /// Video tracks the timeline can show — enough for a screen-crop
    /// layout with one clip per area (the Python app only knows three).
    static let maxTracks = 6

    static let defaultTrackSettings: [TrackSettings] = [
        TrackSettings(defaultPosition: "top"),
        TrackSettings(defaultPosition: "center"),
        TrackSettings(defaultPosition: "bottom"),
        TrackSettings(defaultPosition: "top"),
        TrackSettings(defaultPosition: "center"),
        TrackSettings(defaultPosition: "bottom"),
    ]

    var isEmpty: Bool {
        videoTrack.isEmpty && soundTrack.isEmpty && textOverlays.isEmpty
            && imageOverlays.isEmpty && overlayBlocks.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case renderSettings = "render_settings"
        case pacing
        case videoTrack = "video_track"
        case soundTrack = "sound_track"
        case textOverlays = "text_overlays"
        case imageOverlays = "image_overlays"
        case overlayBlocks = "overlay_blocks"
        case cropBlocks = "crop_blocks"
        case trackSettings = "track_settings"
        case trackCount = "track_count"
        case trackSequential = "track_sequential"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        renderSettings = try container.decodeIfPresent(RenderSettings.self, forKey: .renderSettings)
            ?? RenderSettings()
        pacing = try container.decodeIfPresent(EditPacing.self, forKey: .pacing) ?? EditPacing()
        videoTrack = try container.decodeIfPresent([TimelineClip].self, forKey: .videoTrack) ?? []
        soundTrack = try container.decodeIfPresent([SoundItem].self, forKey: .soundTrack) ?? []
        textOverlays = try container.decodeIfPresent([TextOverlayItem].self, forKey: .textOverlays) ?? []
        imageOverlays = try container.decodeIfPresent([ImageOverlayItem].self, forKey: .imageOverlays) ?? []
        overlayBlocks = try container.decodeIfPresent([OverlayBlockItem].self, forKey: .overlayBlocks) ?? []
        cropBlocks = try container.decodeIfPresent([CropBlockItem].self, forKey: .cropBlocks) ?? []
        var settings = try container.decodeIfPresent([TrackSettings].self, forKey: .trackSettings) ?? []
        // Always keep exactly maxTracks entries with the UI's positional defaults.
        let defaults = Self.defaultTrackSettings
        for index in 0..<Self.maxTracks where index >= settings.count {
            settings.append(defaults[index])
        }
        for index in 0..<Self.maxTracks where settings[index].defaultPosition.isEmpty {
            settings[index].defaultPosition = defaults[index].defaultPosition
        }
        trackSettings = Array(settings.prefix(Self.maxTracks))
        trackCount = min(Self.maxTracks, max(1, try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 1))
        var sequential = try container.decodeIfPresent([Bool].self, forKey: .trackSequential)
            ?? Array(repeating: true, count: Self.maxTracks)
        while sequential.count < Self.maxTracks { sequential.append(true) }
        trackSequential = Array(sequential.prefix(Self.maxTracks))
    }

    /// Flatten overlay blocks into concrete text/image items (for rendering
    /// and any consumer that predates blocks). Each block's items shift to
    /// the block's start and clamp to its window; unbounded items span it.
    func expandingOverlayBlocks() -> TimelineDocument {
        guard !overlayBlocks.isEmpty else { return self }
        var document = self
        for block in overlayBlocks {
            for template in block.composition.texts {
                var item = template
                item.uid = UUID()
                let relStart = min(template.startTime, block.duration)
                let relEnd = template.unbounded ? block.duration : min(template.endTime, block.duration)
                guard relEnd > relStart else { continue }
                item.startTime = block.startTime + relStart
                item.endTime = block.startTime + relEnd
                item.unbounded = false
                document.textOverlays.append(item)
            }
            for template in block.composition.images {
                var item = template
                item.uid = UUID()
                let relStart = min(template.startTime, block.duration)
                let relEnd = template.unbounded ? block.duration : min(template.endTime, block.duration)
                guard relEnd > relStart else { continue }
                item.startTime = block.startTime + relStart
                item.endTime = block.startTime + relEnd
                item.unbounded = false
                document.imageOverlays.append(item)
            }
        }
        document.overlayBlocks = []
        return document
    }

    // MARK: - Cropping row

    /// Where the video content ends — the cropping row always covers at
    /// least this far.
    var contentEnd: Double {
        let clipEnd = videoTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let soundEnd = soundTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let textEnd = textOverlays.map(\.endTime).max() ?? 0
        let imageEnd = imageOverlays.map(\.endTime).max() ?? 0
        let blockEnd = overlayBlocks.map(\.endTime).max() ?? 0
        return max(clipEnd, soundEnd, textEnd, imageEnd, blockEnd)
    }

    /// The cropping row's block at a time (nil only for legacy documents
    /// without a row).
    func cropBlock(at time: Double) -> CropBlockItem? {
        cropBlocks.first { $0.startTime <= time + 0.001 && time < $0.endTime - 0.001 }
            ?? cropBlocks.last.flatMap { time >= $0.endTime - 0.001 ? $0 : nil }
    }

    /// One track per area of the largest layout on the row — plus any
    /// higher track that still holds clips, so stranded clips stay visible
    /// (flagged) instead of vanishing until they are moved or deleted.
    var derivedTrackCount: Int {
        let widest = cropBlocks.map { $0.layout.areaCount }.max() ?? 1
        let occupied = (videoTrack.map(\.track).max() ?? -1) + 1
        return min(Self.maxTracks, max(1, widest, occupied))
    }

    /// Whether `track` has an area to show at `time`. Track 0 always has
    /// one (a single-area layout is the full frame).
    func hasArea(track: Int, at time: Double) -> Bool {
        guard let block = cropBlock(at: time) else { return true }
        return track < block.layout.areaCount
    }

    /// Whether some part of the clip falls where its track has no area —
    /// that stretch is not rendered.
    func isOrphaned(_ clip: TimelineClip) -> Bool {
        guard !cropBlocks.isEmpty, clip.track > 0 else { return false }
        return cropBlocks.contains { block in
            block.startTime < clip.startTime + clip.duration - 0.001
                && clip.startTime < block.endTime - 0.001
                && clip.track >= block.layout.areaCount
        }
    }

    /// Re-tile the cropping row: blocks sorted, overlaps resolved in favor
    /// of `winner` (else the later-starting block), gaps filled with Full
    /// Screen, adjacent Full Screen blocks merged, and the tail stretched
    /// (or a Full Screen filler appended) so the row always reaches the end
    /// of the content. Also refreshes the derived track count.
    mutating func normalizeCropBlocks(winner: UUID? = nil, minimumEnd: Double = 0) {
        let minimumBlock = 0.5
        var ordered = cropBlocks
            .filter { $0.duration >= minimumBlock - 0.001 }
            .map { block -> CropBlockItem in
                var block = block
                block.startTime = max(0, block.startTime)
                return block
            }
            .sorted { $0.startTime < $1.startTime }
        // Resolve overlaps: the winner keeps its full extent, everything it
        // covers is cut back (or dropped); otherwise later blocks win over
        // earlier ones, which matches "the block you just placed is on top".
        if let winner, let winning = ordered.first(where: { $0.uid == winner }) {
            var resolved: [CropBlockItem] = []
            for block in ordered where block.uid != winner {
                var piece = block
                if piece.endTime <= winning.startTime + 0.001 || piece.startTime >= winning.endTime - 0.001 {
                    resolved.append(piece)
                    continue
                }
                // Left remainder.
                if piece.startTime < winning.startTime - 0.001 {
                    var left = piece
                    left.duration = winning.startTime - piece.startTime
                    resolved.append(left)
                }
                // Right remainder.
                if piece.endTime > winning.endTime + 0.001 {
                    piece.uid = piece.startTime < winning.startTime - 0.001 ? UUID() : piece.uid
                    piece.duration = piece.endTime - winning.endTime
                    piece.startTime = winning.endTime
                    resolved.append(piece)
                }
            }
            resolved.append(winning)
            ordered = resolved.sorted { $0.startTime < $1.startTime }
        }
        var tiled: [CropBlockItem] = []
        var cursor = 0.0
        for var block in ordered {
            if block.startTime < cursor - 0.001 {
                // Later block wins: cut the earlier one back to this start.
                if var previous = tiled.popLast() {
                    previous.duration = block.startTime - previous.startTime
                    if previous.duration >= minimumBlock - 0.001 { tiled.append(previous) }
                }
            } else if block.startTime > cursor + 0.001 {
                tiled.append(CropBlockItem(layout: .fullScreen, startTime: cursor,
                                           duration: block.startTime - cursor))
            }
            block.duration = max(minimumBlock, block.duration)
            tiled.append(block)
            cursor = block.endTime
        }
        let end = max(minimumEnd, contentEnd, CropBlockItem.defaultDuration)
        if let last = tiled.last {
            if last.endTime < end - 0.001 {
                if last.layout == .fullScreen {
                    tiled[tiled.count - 1].duration = end - last.startTime
                } else {
                    tiled.append(CropBlockItem(layout: .fullScreen, startTime: last.endTime,
                                               duration: end - last.endTime))
                }
            }
        } else {
            tiled = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: end)]
        }
        // Merge runs of Full Screen so the row reads as one stretch.
        var merged: [CropBlockItem] = []
        for block in tiled {
            if let previous = merged.last, previous.layout == .fullScreen, block.layout == .fullScreen {
                merged[merged.count - 1].duration = block.endTime - previous.startTime
            } else {
                merged.append(block)
            }
        }
        for index in merged.indices {
            merged[index].startTime = (merged[index].startTime * 1000).rounded() / 1000
            merged[index].duration = (merged[index].duration * 1000).rounded() / 1000
        }
        cropBlocks = merged
        trackCount = derivedTrackCount
    }

    /// Give a document that predates the cropping row one: clips carrying a
    /// "Layout/Area" reference (the AI Wizard's layout blocks, the old
    /// Apply Layout command) become crop blocks spanning their time, and
    /// each such clip moves to the track its area occupies. Full Screen
    /// fills the rest. Documents that already have a row are untouched.
    mutating func migrateLegacyScreenCrops() {
        guard cropBlocks.isEmpty else { return }
        var blocks: [CropBlockItem] = []
        for index in videoTrack.indices {
            guard let reference = videoTrack[index].screenCrop,
                  let match = CropLayoutRef.resolve(reference: reference) else { continue }
            let (layout, areaIndex) = match
            let clip = videoTrack[index]
            videoTrack[index].track = min(Self.maxTracks - 1, areaIndex)
            videoTrack[index].screenCrop = nil
            if let existing = blocks.firstIndex(where: {
                $0.layout == layout && $0.startTime < clip.startTime + clip.duration + 0.001
                    && clip.startTime < $0.endTime + 0.001
            }) {
                let start = min(blocks[existing].startTime, clip.startTime)
                let end = max(blocks[existing].endTime, clip.startTime + clip.duration)
                blocks[existing].startTime = start
                blocks[existing].duration = end - start
            } else {
                blocks.append(CropBlockItem(layout: layout, startTime: clip.startTime, duration: clip.duration))
            }
        }
        cropBlocks = blocks
        normalizeCropBlocks()
    }
}

/// One stretch of the cropping row: the Screen Crop layout on screen for
/// that time. Areas map to video tracks in reading order (left-to-right,
/// then top-to-bottom), so Track I shows the first area, Track II the
/// second, and so on.
nonisolated struct CropBlockItem: Codable, Sendable, Equatable, Identifiable {
    /// SwiftUI identity only — never encoded.
    var uid = UUID()

    var layout: CropLayoutRef = .fullScreen
    var startTime: Double = 0
    var duration: Double = CropBlockItem.defaultDuration

    static let defaultDuration = 5.0

    var endTime: Double { startTime + duration }
    var id: UUID { uid }

    enum CodingKeys: String, CodingKey {
        case layout, duration
        case startTime = "start_time"
    }

    init(layout: CropLayoutRef, startTime: Double, duration: Double) {
        self.layout = layout
        self.startTime = startTime
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = CropLayoutRef(name: try container.decodeIfPresent(String.self, forKey: .layout) ?? "")
        startTime = max(0, try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0)
        duration = max(0.5, try container.decodeIfPresent(Double.self, forKey: .duration) ?? Self.defaultDuration)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layout.name, forKey: .layout)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(duration, forKey: .duration)
    }

    static func == (lhs: CropBlockItem, rhs: CropBlockItem) -> Bool {
        lhs.uid == rhs.uid && lhs.layout == rhs.layout
            && lhs.startTime == rhs.startTime && lhs.duration == rhs.duration
    }
}

/// A Screen Crop layout by name, resolved against the resources on demand
/// so a document never snapshots geometry. Full Screen is the one layout
/// that is not a resource: a single area covering the whole frame, which
/// renders the legacy unmasked way.
nonisolated struct CropLayoutRef: Sendable, Hashable {
    var name: String

    static let fullScreenName = "Full Screen"
    static let fullScreen = CropLayoutRef(name: fullScreenName)

    var isFullScreen: Bool {
        name.isEmpty || name.caseInsensitiveCompare(Self.fullScreenName) == .orderedSame
    }

    static func == (lhs: CropLayoutRef, rhs: CropLayoutRef) -> Bool {
        if lhs.isFullScreen || rhs.isFullScreen { return lhs.isFullScreen == rhs.isFullScreen }
        return lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(isFullScreen ? Self.fullScreenName.lowercased() : name.lowercased())
    }

    /// The resource layout, or nil when it was deleted (a missing layout
    /// behaves like Full Screen so the timeline still renders).
    var resolved: ScreenCropLayout? {
        isFullScreen ? nil : ScreenCropStore.layout(named: name)
    }

    /// Areas in track order: left-to-right, then top-to-bottom.
    var orderedAreas: [ScreenCropArea] {
        resolved?.areasInTrackOrder ?? []
    }

    var areaCount: Int {
        isFullScreen ? 1 : max(1, orderedAreas.count)
    }

    var displayName: String {
        isFullScreen ? Self.fullScreenName : name
    }

    var isMissing: Bool { !isFullScreen && resolved == nil }

    /// The area a track shows under this layout; nil for a track without
    /// one, and nil for Full Screen (which is "no mask").
    func area(forTrack track: Int) -> ScreenCropArea? {
        orderedAreas[safe: track]
    }

    /// "Layout/Area" for a track, the reference the renderer masks with.
    func reference(forTrack track: Int) -> String? {
        guard let layout = resolved, let area = area(forTrack: track) else { return nil }
        return ScreenCropStore.reference(layout: layout.name, area: area.name)
    }

    /// Resolve a legacy "Layout/Area" clip reference to (layout, track index).
    static func resolve(reference: String) -> (CropLayoutRef, Int)? {
        let parts = reference.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let layoutName = parts.first, let layout = ScreenCropStore.layout(named: layoutName) else {
            return nil
        }
        let ordered = layout.areasInTrackOrder
        if parts.count == 2,
           let index = ordered.firstIndex(where: { $0.name.caseInsensitiveCompare(parts[1]) == .orderedSame }) {
            return (CropLayoutRef(name: layout.name), index)
        }
        return ordered.count == 1 ? (CropLayoutRef(name: layout.name), 0) : nil
    }
}

extension ScreenCropLayout {
    /// Areas in reading order — rows by their top edge (a 6% tolerance so
    /// slightly uneven hand-drawn splits still share a row), then left to
    /// right within a row. This is the order tracks map to areas.
    var areasInTrackOrder: [ScreenCropArea] {
        areas.sorted { lhs, rhs in
            let a = lhs.bounds, b = rhs.bounds
            if abs(a.y - b.y) > 0.06 { return a.y < b.y }
            if abs(a.x - b.x) > 0.001 { return a.x < b.x }
            return a.y < b.y
        }
    }
}

/// An overlay template placed on the timeline as one unit: a snapshot of the
/// template's composition (later template edits don't affect placed blocks),
/// positioned and trimmed as a single block. Internal items keep their
/// timing relative to the block start.
nonisolated struct OverlayBlockItem: Codable, Sendable, Equatable, Identifiable {
    /// SwiftUI identity only — never encoded.
    var uid = UUID()

    var name: String = "Overlay"
    var startTime: Double = 0
    var duration: Double = 3
    var composition = OverlayComposition()

    var endTime: Double { startTime + duration }
    var id: UUID { uid }

    enum CodingKeys: String, CodingKey {
        case name, duration, composition
        case startTime = "start_time"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Overlay"
        startTime = try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
        duration = max(0.5, try container.decodeIfPresent(Double.self, forKey: .duration) ?? 3)
        composition = try container.decodeIfPresent(OverlayComposition.self, forKey: .composition)
            ?? OverlayComposition()
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
    /// Kept for the JSON format; the Builder no longer edits it. Overlapping
    /// clips on one track stack by start time instead.
    var stackOrder: Int = 0
    var volume: Int = 5           // 1-5
    var muted: Bool = false
    var position: String?         // "top" | "center" | "bottom" | nil (layer default)
    var transIn: String?
    var transOut: String?
    var cropXFrac: Double?
    var freeCrops: [FreeCrop]?
    /// A Screen Crop reference ("Layout/Area"): only that area of the 9:16
    /// frame stays visible for this clip (the rest is transparent, so lower
    /// layers show through). Nil = unmasked.
    var screenCrop: String?
    /// The exact part of the source (fractions of the frame) that fills
    /// this clip's crop area, chosen by hand in the inspector. Nil lets the
    /// tracking camera frame the area. Always the area's aspect ratio.
    var areaWindow: FreeCropRect?
    var captions: String = "inherit"   // inherit | none | top | middle | bottom
    /// Wide clips only: reframe with the Center Stage tracking camera
    /// instead of a static crop.
    var centerStage: Bool = false
    /// Playback speed (nil = 1×). 0.5 = slow motion; `duration` is screen
    /// time, so the source span consumed is duration × speed.
    var speed: Double?

    /// Full duration of the referenced scene — editor state used to decide
    /// whether the clip is trimmed. Never encoded; refilled on hydration.
    var sceneFullDuration: Double?

    var effectiveSpeed: Double { speed ?? 1 }

    /// Source seconds this clip consumes (screen duration × speed).
    var sourceSpan: Double { duration * effectiveSpeed }

    var isTrimmedScene: Bool {
        guard sceneID != nil, let full = sceneFullDuration else { return false }
        return abs(sourceSpan - full) > 0.05
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
        case screenCrop = "screen_crop"
        case areaWindow = "area_window"
        case centerStage = "center_stage"
        case speed
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sceneID = try container.decodeIfPresent(Int64.self, forKey: .sceneID)
        videoFile = try container.decodeIfPresent(String.self, forKey: .videoFile)
        sourceStart = try container.decodeIfPresent(Double.self, forKey: .sourceStart)
        sourceEnd = try container.decodeIfPresent(Double.self, forKey: .sourceEnd)
        startTime = try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
        track = max(0, try container.decodeIfPresent(Int.self, forKey: .track) ?? 0)
        wide = try container.decodeIfPresent(Bool.self, forKey: .wide) ?? false
        stackOrder = try container.decodeIfPresent(Int.self, forKey: .stackOrder) ?? 0
        volume = try container.decodeIfPresent(Int.self, forKey: .volume) ?? 5
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        position = try container.decodeIfPresent(String.self, forKey: .position)
        transIn = try container.decodeIfPresent(String.self, forKey: .transIn)
        transOut = try container.decodeIfPresent(String.self, forKey: .transOut)
        cropXFrac = try container.decodeIfPresent(Double.self, forKey: .cropXFrac)
        freeCrops = try container.decodeIfPresent([FreeCrop].self, forKey: .freeCrops)
        screenCrop = try container.decodeIfPresent(String.self, forKey: .screenCrop)
        areaWindow = try container.decodeIfPresent(FreeCropRect.self, forKey: .areaWindow)
        centerStage = try container.decodeIfPresent(Bool.self, forKey: .centerStage) ?? false
        speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        captions = Self.decodeCaptions(container, key: .captions, fallback: "inherit",
                                       valid: Self.captionChoices)
        // The web serializer never writes duration for scene clips; hydration
        // fills it in from the scene. video_file clips carry it implicitly.
        if let explicit = try container.decodeIfPresent(Double.self, forKey: .duration) {
            duration = explicit
        } else if let start = sourceStart, let end = sourceEnd {
            // source_end is in SOURCE seconds; screen time is the span
            // divided by the playback speed (a 0.5× clip shows 4 s of
            // screen for 2 s of source).
            duration = max(0, end - start) / max(0.01, speed ?? 1)
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
        try encodeOrNull(screenCrop, in: &container, forKey: .screenCrop)
        if let areaWindow { try container.encode(areaWindow, forKey: .areaWindow) }
        try container.encode(captions, forKey: .captions)
        try container.encode(centerStage, forKey: .centerStage)
        try encodeOrNull(speed, in: &container, forKey: .speed)
        if let sceneID, !isTrimmedScene {
            try container.encode(sceneID, forKey: .sceneID)
        } else if let videoFile, let sourceStart {
            // Trimmed / raw-file clips: identify by file + trimmed extent
            // (in SOURCE seconds — slow motion stretches only screen time),
            // matching the web serializer's video_file fallback.
            try container.encode(videoFile, forKey: .videoFile)
            try container.encode(sourceStart, forKey: .sourceStart)
            try container.encode(sourceStart + sourceSpan, forKey: .sourceEnd)
            // Screen duration explicitly, so a speed-changed clip survives
            // the save/load round trip exactly.
            try container.encode(duration, forKey: .duration)
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
            && lhs.centerStage == rhs.centerStage && lhs.speed == rhs.speed
            && lhs.cropXFrac == rhs.cropXFrac && lhs.freeCrops == rhs.freeCrops && lhs.captions == rhs.captions
            && lhs.screenCrop == rhs.screenCrop && lhs.areaWindow == rhs.areaWindow
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

/// One image overlay: a picture from the Images library composited over the
/// video for a time window, with the same enter/exit transitions as text
/// overlays. Position/size are fractions of the frame; width sets the scale
/// and height follows the image's aspect ratio.
nonisolated struct ImageOverlayItem: Codable, Sendable, Equatable, Identifiable {
    /// SwiftUI identity only — never encoded.
    var uid = UUID()

    var path: String = ""               // absolute path into the Images library
    var startTime: Double = 0
    var endTime: Double = 3
    var xFrac: Double = 0.5             // center, as fraction of frame width
    var yFrac: Double = 0.5             // center, as fraction of frame height
    var wFrac: Double = 0.3             // width as fraction of frame width
    var opacity: Double = 1
    var transIn: String = "fade"
    var transOut: String = "fade"
    /// Template-only: ignore endTime and last as long as the whole overlay
    /// is visible. Resolved to a concrete endTime when the template is
    /// applied (clip end in the Wizard, composition end in the Builder).
    var unbounded: Bool = false

    var id: UUID { uid }
    var duration: Double { max(0, endTime - startTime) }
    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    var displayName: String { url.deletingPathExtension().lastPathComponent }

    enum CodingKeys: String, CodingKey {
        case path, opacity, unbounded
        case startTime = "start_time"
        case endTime = "end_time"
        case xFrac = "x_frac"
        case yFrac = "y_frac"
        case wFrac = "w_frac"
        case transIn = "trans_in"
        case transOut = "trans_out"
    }

    init(path: String = "", startTime: Double = 0, endTime: Double = 3) {
        self.path = path
        self.startTime = startTime
        self.endTime = endTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        startTime = try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
        endTime = try container.decodeIfPresent(Double.self, forKey: .endTime) ?? 3
        xFrac = try container.decodeIfPresent(Double.self, forKey: .xFrac) ?? 0.5
        yFrac = try container.decodeIfPresent(Double.self, forKey: .yFrac) ?? 0.5
        wFrac = try container.decodeIfPresent(Double.self, forKey: .wFrac) ?? 0.3
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        transIn = try container.decodeIfPresent(String.self, forKey: .transIn) ?? "fade"
        transOut = try container.decodeIfPresent(String.self, forKey: .transOut) ?? "fade"
        unbounded = try container.decodeIfPresent(Bool.self, forKey: .unbounded) ?? false
    }

    static func == (lhs: ImageOverlayItem, rhs: ImageOverlayItem) -> Bool {
        lhs.uid == rhs.uid && lhs.path == rhs.path && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime && lhs.xFrac == rhs.xFrac && lhs.yFrac == rhs.yFrac
            && lhs.wFrac == rhs.wFrac && lhs.opacity == rhs.opacity
            && lhs.transIn == rhs.transIn && lhs.transOut == rhs.transOut
            && lhs.unbounded == rhs.unbounded
    }
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
    // Style flair (all default to the legacy flat look when absent).
    var strokeColor: String?            // outline color; nil = no outline
    var strokeWidthEm: Double = 0       // outline width as a fraction of font size
    var shadowOpacity: Double = 0       // drop shadow strength, 0 = none
    var highlightColor: String?         // color for *starred* words in `text`
    // Pro compositions ("hero" = kicker bar + gradient headline,
    // "tag" = skewed chip); nil = plain line rendering.
    var design: String?
    var kicker: String?                 // small label above a hero headline
    var accentColor: String?            // bar/stripe color for hero/tag
    /// Overlay-template flag: the AI Wizard may replace this text with its
    /// own copy. Meaningless on timeline overlays.
    var isDynamic: Bool = false
    /// Whole-element opacity (text, outline, shadow, and box together);
    /// boxOpacity stays the background box's own alpha.
    var opacity: Double = 1
    /// Background box corner radius in video pixels; nil = legacy 4px.
    var boxRadius: Double?
    /// Template-only: ignore endTime and last as long as the whole overlay
    /// is visible (resolved to a concrete endTime when applied).
    var unbounded: Bool = false

    var duration: Double { max(0, endTime - startTime) }

    static let transitionChoices = ["fade", "slide_left", "slide_right", "slide_up", "slide_down", "pop", "cut"]

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
        case strokeColor = "stroke_color"
        case strokeWidthEm = "stroke_width_em"
        case shadowOpacity = "shadow_opacity"
        case highlightColor = "highlight_color"
        case design, kicker
        case accentColor = "accent_color"
        case isDynamic = "dynamic"
        case opacity, unbounded
        case boxRadius = "box_radius"
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
        strokeColor = try container.decodeIfPresent(String.self, forKey: .strokeColor)
        strokeWidthEm = try container.decodeIfPresent(Double.self, forKey: .strokeWidthEm) ?? 0
        shadowOpacity = try container.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? 0
        highlightColor = try container.decodeIfPresent(String.self, forKey: .highlightColor)
        design = try container.decodeIfPresent(String.self, forKey: .design)
        kicker = try container.decodeIfPresent(String.self, forKey: .kicker)
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor)
        isDynamic = try container.decodeIfPresent(Bool.self, forKey: .isDynamic) ?? false
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        boxRadius = try container.decodeIfPresent(Double.self, forKey: .boxRadius)
        unbounded = try container.decodeIfPresent(Bool.self, forKey: .unbounded) ?? false
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
        if let strokeColor, strokeWidthEm > 0 {
            try container.encode(strokeColor, forKey: .strokeColor)
            try container.encode(strokeWidthEm, forKey: .strokeWidthEm)
        }
        if shadowOpacity > 0 { try container.encode(shadowOpacity, forKey: .shadowOpacity) }
        if let highlightColor { try container.encode(highlightColor, forKey: .highlightColor) }
        if let design { try container.encode(design, forKey: .design) }
        if let kicker { try container.encode(kicker, forKey: .kicker) }
        if let accentColor { try container.encode(accentColor, forKey: .accentColor) }
        if isDynamic { try container.encode(true, forKey: .isDynamic) }
        if opacity < 1 { try container.encode(opacity, forKey: .opacity) }
        if let boxRadius { try container.encode(boxRadius, forKey: .boxRadius) }
        if unbounded { try container.encode(true, forKey: .unbounded) }
    }

    static func == (lhs: TextOverlayItem, rhs: TextOverlayItem) -> Bool {
        lhs.uid == rhs.uid && lhs.text == rhs.text && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime && lhs.fontsize == rhs.fontsize
            && lhs.fontcolor == rhs.fontcolor && lhs.fontfamily == rhs.fontfamily
            && lhs.boxOpacity == rhs.boxOpacity && lhs.bold == rhs.bold && lhs.italic == rhs.italic
            && lhs.bgcolor == rhs.bgcolor && lhs.xFrac == rhs.xFrac && lhs.yFrac == rhs.yFrac
            && lhs.wFrac == rhs.wFrac && lhs.hFrac == rhs.hFrac && lhs.position == rhs.position
            && lhs.transIn == rhs.transIn && lhs.transOut == rhs.transOut
            && lhs.strokeColor == rhs.strokeColor && lhs.strokeWidthEm == rhs.strokeWidthEm
            && lhs.shadowOpacity == rhs.shadowOpacity && lhs.highlightColor == rhs.highlightColor
            && lhs.design == rhs.design && lhs.kicker == rhs.kicker
            && lhs.accentColor == rhs.accentColor && lhs.isDynamic == rhs.isDynamic
            && lhs.opacity == rhs.opacity && lhs.boxRadius == rhs.boxRadius
            && lhs.unbounded == rhs.unbounded
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
