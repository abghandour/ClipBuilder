import Foundation

/// What one cell of a crop recipe shows.
nonisolated enum CropRecipeSubject: Sendable, Hashable, Codable {
    /// Whoever is talking.
    case talker
    /// The n-th most recent other speaker (1 = the previous one).
    case recent(Int)
    /// The n-th person who is not talking, in tile order (1 = the first).
    case others(Int)
    /// A fixed feed of the recording.
    case tile(Int)
    /// A named person from the roster.
    case person(String)
    /// The people who are not talking, one after another, each for this
    /// many seconds.
    case rotate(Double)

    /// "talker", "previous", "recent:2", "others:1", "tile:0", "person:<key>", "rotate:5".
    init?(token raw: String) {
        let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if token == "talker" || token == "speaker" { self = .talker; return }
        if token == "previous" { self = .recent(1); return }
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "recent": guard let n = Int(parts[1]), n >= 1 else { return nil }; self = .recent(n)
        case "others": guard let n = Int(parts[1]), n >= 1 else { return nil }; self = .others(n)
        case "tile": guard let n = Int(parts[1]), n >= 0 else { return nil }; self = .tile(n)
        case "rotate":
            guard let seconds = Double(parts[1]), CropRecipe.rotationRange.contains(seconds) else { return nil }
            self = .rotate(seconds)
        case "person":
            let key = raw.trimmingCharacters(in: .whitespaces).dropFirst("person:".count)
            guard !key.isEmpty else { return nil }
            self = .person(String(key))
        default: return nil
        }
    }

    var token: String {
        switch self {
        case .talker: "talker"
        case .recent(let n): "recent:\(n)"
        case .others(let n): "others:\(n)"
        case .tile(let n): "tile:\(n)"
        case .person(let key): "person:\(key)"
        case .rotate(let seconds): "rotate:\(seconds.formatted(.number.precision(.fractionLength(0...2))))"
        }
    }

    var label: String {
        switch self {
        case .talker: "Talker"
        case .recent(1): "Previous speaker"
        case .recent(let n): "Speaker \(n) back"
        case .others(let n): "Other \(n)"
        case .tile(let n): "Feed \(n + 1)"
        case .person(let key): key
        case .rotate: "Rotating others"
        }
    }
}

/// A way to lay a whole recording out on the canvas: a Screen Crop layout
/// plus what each area shows, built from the recording's speaker turns and
/// feeds. The layout picks itself by the number of people unless named.
nonisolated struct CropRecipe: Sendable, Hashable, Identifiable {
    enum Kind: String, CaseIterable, Sendable, Codable {
        /// Full screen, following whoever is talking.
        case talker
        /// Everyone at once: 50/50, thirds, 2×2 or 2×3 by head count.
        case grid
        /// The talker in the top half, everyone else across the bottom.
        case talkerAndRest = "talker_and_rest"
        /// The talker on top, the previous speaker below.
        case talkerAndPrevious = "talker_and_previous"
        /// The talker on top; the bottom cell takes turns showing the others.
        case talkerAndRotation = "talker_and_rotation"

        var name: String {
            switch self {
            case .talker: "Talker full screen"
            case .grid: "Everyone in a grid"
            case .talkerAndRest: "Talker and the rest"
            case .talkerAndPrevious: "Talker and previous"
            case .talkerAndRotation: "Talker and rotating others"
            }
        }

        var summary: String {
            switch self {
            case .talker: "One person at a time, cutting to whoever is talking."
            case .grid: "Every feed in its own cell; 50/50 for two, thirds for three, 2×2 for four, 2×3 for five or six."
            case .talkerAndRest: "The talker in the top half; the others share the bottom."
            case .talkerAndPrevious: "The talker on top, the previous speaker below."
            case .talkerAndRotation: "The talker on top; the bottom cell takes turns showing the others every few seconds."
            }
        }
    }

    var kind: Kind
    /// A Screen Crop layout to use instead of the automatic one.
    var layout: String? = nil
    /// What each area shows, instead of the recipe's own assignment.
    var slots: [CropRecipeSubject]? = nil
    /// Outline the talker's cell (layouts with two or more areas).
    var highlightTalker = false
    /// Seconds a cell keeps its subject before the next speaker takes it.
    var minimumHold = 1.5
    /// Seconds a rotating cell shows each person.
    var rotationSeconds = 5.0
    /// Still cells (a fixed feed or person) get the tracking camera inside
    /// their feed instead of a fixed crop of it.
    var tracking = true

    var id: String { kind.rawValue }
    var name: String { kind.name }

    static let holdRange = 0.4...30.0
    static let rotationRange = 1.0...60.0
    static let builtIn: [CropRecipe] = Kind.allCases.map { CropRecipe(kind: $0) }
}

/// Turns a recipe and a recording's analysis into a layout and one window
/// or camera path per area. Pure: the store applies the plan.
nonisolated enum CropRecipePlanner {
    struct Slot: Sendable, Equatable {
        var subject: CropRecipeSubject
        /// A fixed part of the source, at the area's aspect.
        var window: FreeCropRect?
        /// Hard cuts between parts of the source, at the area's aspect.
        var path: [CameraPathKeyframe]?
        /// The feed the tracking camera stays inside (a still cell).
        var region: FreeCropRect?
        /// Source spans during which this cell shows the talker.
        var talking: [ClosedRange<Double>] = []
    }

    struct Plan: Sendable, Equatable {
        var layout: CropLayoutRef
        var slots: [Slot]
        var notes: [String] = []
    }

    /// One stretch of the recording with a stable talker.
    struct Segment: Sendable, Equatable {
        var start: Double
        var end: Double
        var talker: Int
        /// Other tiles by how recently they spoke, most recent first.
        var recent: [Int]
    }

    struct Failure: Error, CustomStringConvertible, Sendable {
        var description: String
    }

    /// The built-in layout for a head count, or nil above six.
    static func layoutName(kind: CropRecipe.Kind, people: Int) -> String? {
        switch kind {
        case .talker: return CropLayoutRef.fullScreenName
        case .talkerAndPrevious, .talkerAndRotation: return "50-50 Horizontal"
        case .grid:
            switch people {
            case ...1: return CropLayoutRef.fullScreenName
            case 2: return "50-50 Horizontal"
            case 3: return "33-33-33 Horizontal"
            case 4: return "2x2 Grid"
            case 5, 6: return "2x3 Grid"
            default: return nil
            }
        case .talkerAndRest:
            switch people {
            case ...1: return CropLayoutRef.fullScreenName
            case 2: return "50-50 Horizontal"
            case 3: return "Talker + 2"
            case 4: return "Talker + 3"
            default: return nil
            }
        }
    }

    /// The recipe's own assignment of subjects to areas.
    static func defaultSlots(_ recipe: CropRecipe, areas: Int, tiles: [PodcastTile]) -> [CropRecipeSubject] {
        switch recipe.kind {
        case .talker: return [.talker]
        case .grid: return tiles.sorted { $0.index < $1.index }.prefix(areas).map { .tile($0.index) }
        case .talkerAndRest: return [.talker] + (1..<max(1, areas)).map { .others($0) }
        case .talkerAndPrevious: return [.talker, .recent(1)]
        case .talkerAndRotation: return [.talker, .rotate(recipe.rotationSeconds)]
        }
    }

    /// Feeds to lay out: the analyzed tiles, or halves for a side-by-side
    /// recording, or a column per roster portrait for a single camera.
    static func tiles(video: VideoRecord, roster: [VideoPersonRecord]) -> [PodcastTile] {
        let stored = video.podcastTiles
        if stored.count >= 2 { return stored.sorted { $0.index < $1.index } }
        if video.podcastLayout == PodcastLayout.splitHorizontal.rawValue {
            return [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1), PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        }
        struct Portrait { var key: String; var center: Double }
        let portraits: [Portrait] = roster.compactMap { person in
            guard let box = person.portraitBox else { return nil }
            return Portrait(key: person.key, center: box.x + box.w / 2)
        }.sorted { $0.center < $1.center }
        guard portraits.count >= 2 else { return stored }
        // A column per person, split midway between neighboring portraits.
        var result: [PodcastTile] = []
        for (index, entry) in portraits.enumerated() {
            let left: Double = index == 0 ? 0 : (portraits[index - 1].center + entry.center) / 2
            let right: Double = index == portraits.count - 1 ? 1 : (entry.center + portraits[index + 1].center) / 2
            result.append(PodcastTile(index: index, x: left, y: 0, w: max(0.05, right - left), h: 1, personKey: entry.key))
        }
        return result
    }

    /// The tile a turn was seen or heard in.
    static func tile(for turn: SpeakerTurn, tiles: [PodcastTile]) -> Int? {
        if let index = turn.tile, tiles.contains(where: { $0.index == index }) { return index }
        if let key = turn.personKey, let match = tiles.first(where: { $0.personKey == key }) { return match.index }
        if tiles.count == 2, turn.resolvedSide == .left { return tiles[0].index }
        if tiles.count == 2, turn.resolvedSide == .right { return tiles[1].index }
        return nil
    }

    /// A turn shorter than this is an interjection and never takes a cell.
    static let minimumTurn = 1.0

    /// Stretches with a stable talker over `range` of the recording (source
    /// seconds): the tile only changes after `hold` seconds, silence keeps
    /// the last talker, and the range starts on whoever is speaking at its
    /// start (or the first speaker after it).
    static func segments(turns: [SpeakerTurn], tiles: [PodcastTile], range: ClosedRange<Double>,
                         hold: Double) -> [Segment] {
        let placed = turns.sorted { $0.start < $1.start }
            .filter { $0.end > range.lowerBound && $0.start < range.upperBound }
            .compactMap { turn -> (start: Double, end: Double, tile: Int)? in
                guard let tile = tile(for: turn, tiles: tiles) else { return nil }
                return (max(turn.start, range.lowerBound), min(turn.end, range.upperBound), tile)
            }
            .enumerated()
            .filter { $0.offset == 0 || $0.element.end - $0.element.start >= minimumTurn }
            .map(\.element)
        guard let first = placed.first else { return [] }
        let start = range.lowerBound, end = range.upperBound
        var order = tiles.map(\.index).filter { $0 != first.tile }
        var segments = [Segment(start: start, end: end, talker: first.tile, recent: order)]
        var heldSince = start
        for turn in placed.dropFirst() {
            let current = segments[segments.count - 1]
            guard turn.tile != current.talker else { continue }
            let time = max(turn.start, heldSince + hold)
            guard time < min(turn.end, end) else { continue }
            segments[segments.count - 1].end = time
            order.removeAll { $0 == turn.tile }
            order.insert(current.talker, at: 0)
            segments.append(Segment(start: time, end: end, talker: turn.tile, recent: order))
            heldSince = time
        }
        return segments
    }

    /// The largest crop of `aspect` (output width ÷ height) inside a tile,
    /// centered on the face when known, else on the tile.
    static func crop(tile: PodcastTile, aspect: Double, sourceAspect: Double,
                     center: (x: Double, y: Double)? = nil) -> FreeCropRect {
        var h = tile.h
        var w = h * aspect / sourceAspect
        if w > tile.w { w = tile.w; h = w * sourceAspect / aspect }
        let cx = center?.x ?? tile.centerX, cy = center?.y ?? tile.centerY
        let x = min(min(1 - w, tile.x + tile.w - w), max(max(0, tile.x), cx - w / 2))
        let y = min(min(1 - h, tile.y + tile.h - h), max(max(0, tile.y), cy - h / 2))
        return FreeCropRect(xFrac: round4(x), yFrac: round4(y), wFrac: round4(w), hFrac: round4(h))
    }

    private static func round4(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }

    /// Touching spans joined, so a cell that keeps the talker across
    /// several turns is one stretch.
    static func merged(_ spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, span.lowerBound <= last.upperBound + 1e-6 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Lay a recording out, or `range` of it (source seconds; a scene is
    /// one, the whole file the default). Keyframe times count from the
    /// range's start; talking spans stay in source seconds. `canvasAspect`
    /// is the output width ÷ height.
    static func plan(_ recipe: CropRecipe, video: VideoRecord, range: ClosedRange<Double>? = nil,
                     turns: [SpeakerTurn], roster: [VideoPersonRecord], layouts: [ScreenCropLayout],
                     canvasAspect: Double) throws -> Plan {
        guard video.duration.isFinite, video.duration > 0 else { throw Failure(description: "The file has no duration.") }
        let span = range ?? 0...video.duration
        guard span.lowerBound >= 0, span.upperBound <= video.duration + 0.05, span.upperBound - span.lowerBound > 0.05 else {
            throw Failure(description: "The range lies outside the file.")
        }
        let length = span.upperBound - span.lowerBound
        guard video.width > 0, video.height > 0 else {
            throw Failure(description: "The file's frame size is unknown; analyze it first.")
        }
        let sourceAspect = Double(video.width) / Double(video.height)
        let tiles = tiles(video: video, roster: roster)
        let people = max(1, tiles.count)
        guard recipe.kind == .talker || tiles.count >= 2 else {
            throw Failure(description: "This recipe needs a recording with two or more feeds or people; only the full-screen talker works here.")
        }
        guard let layoutName = recipe.layout ?? layoutName(kind: recipe.kind, people: people) else {
            throw Failure(description: "No built-in layout holds \(people) people; name a Screen Crop layout.")
        }
        let ref = CropLayoutRef(name: layoutName)
        let areas: [ScreenCropArea]
        if ref.isFullScreen {
            areas = [ScreenCropArea(name: CropLayoutRef.fullScreenName, points: [
                ScreenCropPoint(x: 0, y: 0), ScreenCropPoint(x: 1, y: 0), ScreenCropPoint(x: 1, y: 1), ScreenCropPoint(x: 0, y: 1)])]
        } else {
            guard let layout = layouts.first(where: { $0.name.caseInsensitiveCompare(layoutName) == .orderedSame }),
                  !layout.areas.isEmpty else {
                throw Failure(description: "Layout \"\(layoutName)\" is not available.")
            }
            areas = layout.areasInTrackOrder
        }
        let subjects = recipe.slots ?? defaultSlots(recipe, areas: areas.count, tiles: tiles)
        guard !subjects.isEmpty, subjects.count <= areas.count, subjects.count <= TimelineDocument.maxTracks else {
            throw Failure(description: "The layout has \(areas.count) areas for \(subjects.count) subjects (at most \(TimelineDocument.maxTracks)).")
        }
        let segments = segments(turns: turns, tiles: tiles, range: span, hold: recipe.minimumHold)
        let needsTurns = subjects.contains { if case .tile = $0 { false } else if case .person = $0 { false } else { true } }
        guard !needsTurns || !segments.isEmpty else {
            throw Failure(description: "No speaker turns for this file; run Analyze so the recording knows who talks when.")
        }
        var notes: [String] = []
        let faceCenters: [Int: (x: Double, y: Double)] = Dictionary(uniqueKeysWithValues: tiles.compactMap { tile in
            if let face = tile.faceCenter { return (tile.index, face) }
            guard let key = tile.personKey, let box = roster.first(where: { $0.key == key })?.portraitBox,
                  tile.contains(x: box.x + box.w / 2, y: box.y + box.h / 2) else { return nil }
            return (tile.index, (box.x + box.w / 2, box.y + box.h / 2))
        })
        func rect(_ index: Int, area: ScreenCropArea) -> FreeCropRect? {
            guard let tile = tiles.first(where: { $0.index == index }) else { return nil }
            let bounds = area.bounds
            let aspect = canvasAspect * bounds.w / max(0.001, bounds.h)
            return crop(tile: tile, aspect: aspect, sourceAspect: sourceAspect, center: faceCenters[index])
        }
        func fullFrame(area: ScreenCropArea) -> FreeCropRect {
            let bounds = area.bounds
            let aspect = canvasAspect * bounds.w / max(0.001, bounds.h)
            return crop(tile: PodcastTile(index: -1, x: 0, y: 0, w: 1, h: 1), aspect: aspect, sourceAspect: sourceAspect)
        }
        var slots: [Slot] = []
        let order = tiles.map(\.index)
        for (position, subject) in subjects.enumerated() {
            let area = areas[position]
            // What the cell shows over time: (source time, tile), nil where
            // the subject has nobody.
            var events: [(time: Double, tile: Int?)] = []
            var talking: [ClosedRange<Double>] = []
            switch subject {
            case .tile(let index):
                guard tiles.contains(where: { $0.index == index }) else {
                    throw Failure(description: "Feed \(index) does not exist; the recording has \(tiles.count).")
                }
                events = [(span.lowerBound, index)]
                talking = segments.filter { $0.talker == index }.map { $0.start...$0.end }
            case .person(let key):
                guard let tile = tiles.first(where: { $0.personKey?.caseInsensitiveCompare(key) == .orderedSame }) else {
                    throw Failure(description: "Nobody named \"\(key)\" sits in a feed of this recording.")
                }
                events = [(span.lowerBound, tile.index)]
                talking = segments.filter { $0.talker == tile.index }.map { $0.start...$0.end }
            case .talker:
                events = segments.map { ($0.start, $0.talker) }
                talking = segments.map { $0.start...$0.end }
            case .recent(let n):
                events = segments.map { ($0.start, $0.recent[safe: n - 1]) }
            case .others(let n):
                events = segments.map { segment in (segment.start, order.filter { $0 != segment.talker }[safe: n - 1]) }
            case .rotate(let every):
                // Round-robin through everyone but the talker, on a steady
                // beat from the range's start; a cell never shows the talker.
                var pointer = -1
                func next(excluding talker: Int) -> Int? {
                    for _ in order {
                        pointer = (pointer + 1) % max(1, order.count)
                        if order[safe: pointer] != talker { return order[safe: pointer] }
                    }
                    return nil
                }
                var shown: Int?
                for segment in segments {
                    if shown == nil || shown == segment.talker {
                        shown = next(excluding: segment.talker)
                        events.append((segment.start, shown))
                    }
                    // The next beat at or after the segment's start that is
                    // not the moment the cell just changed.
                    var tick = span.lowerBound + ceil((segment.start - span.lowerBound) / every - 1e-9) * every
                    if let lastTime = events.last?.time, tick <= lastTime + 1e-6 { tick += every }
                    while tick < segment.end - 0.5 {
                        shown = next(excluding: segment.talker)
                        events.append((tick, shown))
                        tick += every
                    }
                }
            }
            if events.contains(where: { $0.tile == nil }) {
                notes.append("\(subject.label): no one to show during part of the recording; the cell holds its last person.")
            }
            // Fill gaps with the nearest shown tile so every cell has someone.
            var filled: [(time: Double, tile: Int)] = []
            var last: Int? = events.compactMap(\.tile).first
            for event in events { if let tile = event.tile { last = tile }; if let last { filled.append((event.time, last)) } }
            guard !filled.isEmpty else { throw Failure(description: "\(subject.label): nobody to show.") }
            func rectFor(_ index: Int) throws -> FreeCropRect {
                if ref.isFullScreen && tiles.count < 2 { return fullFrame(area: area) }
                guard let rect = rect(index, area: area) else { throw Failure(description: "Feed \(index) is missing.") }
                return rect
            }
            var slot = Slot(subject: subject, talking: merged(talking))
            // Hard cuts between the rectangles the cell shows, dropping
            // repeats; one rectangle means a still cell.
            var path: [CameraPathKeyframe] = []
            for event in filled {
                let rect = try rectFor(event.tile)
                let at = max(0, event.time - span.lowerBound)
                if var previous = path.last {
                    if previous.x == rect.xFrac && previous.y == rect.yFrac && previous.w == rect.wFrac && previous.h == rect.hFrac {
                        continue
                    }
                    previous.t = at - CameraKeyframes.cutGap
                    if previous.t > path[path.count - 1].t { path.append(previous) }
                }
                path.append(CameraPathKeyframe(t: at, x: rect.xFrac, y: rect.yFrac, w: rect.wFrac, h: rect.hFrac))
            }
            if path.count == 1, let only = path.first {
                if ref.isFullScreen {
                    var end = only; end.t = length
                    slot.path = [only, end]
                } else if recipe.tracking, let tile = tiles.first(where: { $0.index == filled[0].tile }) {
                    // A still cell: the tracking camera inside the feed.
                    slot.region = FreeCropRect(xFrac: tile.x, yFrac: tile.y, wFrac: tile.w, hFrac: tile.h)
                } else {
                    slot.window = FreeCropRect(xFrac: only.x, yFrac: only.y, wFrac: only.w, hFrac: only.h)
                }
            } else {
                if let last = path.last, last.t < length {
                    var hold = last; hold.t = length; path.append(hold)
                }
                slot.path = path
            }
            slots.append(slot)
        }
        if recipe.highlightTalker, ref.isFullScreen {
            notes.append("The talker is not outlined in Full Screen.")
        }
        return Plan(layout: ref, slots: slots, notes: notes)
    }
}
