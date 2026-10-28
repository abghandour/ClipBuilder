import Foundation

/// Assigns visual sources on the composition clock. Audio always remains the main recording.
nonisolated enum LayoutRoleFiller {
    static func plan(layout: ScreenCropLayout, context: FramingContext) -> [AreaSegment] {
        resolve(layout: layout, context: context).areas
    }

    struct Result: Sendable {
        var areas: [AreaSegment]
        var notes: [String]
    }

    /// The feeds a layout can show, named from the roster; a lone roster entry stands in for a missing feed.
    static func tiles(context: FramingContext) -> [PodcastTile] {
        let rawTiles = context.feeds.isEmpty && context.roster.count == 1
            ? context.roster.map { person in
                PodcastTile(index: 0, x: 0, y: 0, w: 1, h: 1, personKey: person.key,
                    faceX: person.portraitBox.map { $0.x + $0.w / 2 },
                    faceY: person.portraitBox.map { $0.y + $0.h / 2 })
            } : context.feeds
        return VIPRecipePlanning.namedTiles(rawTiles, roster: context.roster)
    }

    static func resolve(layout: ScreenCropLayout, context: FramingContext) -> Result {
        let tiles = tiles(context: context)
        let range = context.range
        let duration = range.upperBound - range.lowerBound
        guard duration > 0 else { return Result(areas: [], notes: []) }
        let speech = CropRecipePlanner.segments(turns: context.turns, tiles: tiles,
            range: range, hold: FramingHolds.recipeHold)
        let vip = tiles.filter { context.vipIDs.contains($0.personKey ?? "") }.map(\.index)
        let rotation = VIPRotation.shots(range: range, segments: speech, vipTiles: vip, recentFirst: nil)
        let first = speech.first?.talker ?? tiles.first?.index
        var notes: [String] = []
        let roles = layout.areas.compactMap(\.role)
        if roles.contains(.vip), vip.isEmpty { notes.append("No VIP tagged: VIP shows the current talker; Others shows the previous talker.") }
        let peopleAreas = layout.areas.contains { $0.role == nil || $0.role == .vip || $0.role == .others || $0.role == .broll }
        if peopleAreas, tiles.count == 1 { notes.append("Only one person: every people area shows that person.") }
        if peopleAreas, !context.turns.contains(where: { $0.start <= range.lowerBound && $0.end > range.lowerBound }) {
            notes.append("Silence at the start: areas begin with the first speaker of the run.")
        }
        if roles.contains(.broll), context.brollCuts.isEmpty { notes.append("No B-roll: the B-roll area shows Others, then VIP.") }
        if Set(roles).count < roles.count { notes.append("Repeated roles use the next candidate in area order.") }
        var occurrences: [ScreenCropArea.Role: Int] = [:]
        var output: [AreaSegment] = []
        for (position, area) in layout.areas.enumerated() {
            let role = area.role
            let ordinal = role.map { occurrences[$0, default: 0] } ?? position
            if let role { occurrences[role, default: 0] += 1 }
            if role == .screen || role == .presenter {
                let assigned = role.flatMap { context.sourceRoles[$0.rawValue] }.flatMap { $0.isEmpty ? nil : $0 }
                let path = assigned ?? context.sourcePath
                let source = context.sources.first { $0.url.path == path }
                if assigned == nil { notes.append("Missing \(role?.label ?? "") source: showing the main recording.") }
                output.append(AreaSegment(areaID: area.id, sourceID: source?.id ?? (path == context.sourcePath ? context.sourceID : nil),
                    sourcePath: path, start: range.lowerBound, duration: duration, role: role,
                    framing: .static(window: nil), audio: .program, timelineStart: 0))
                continue
            }
            var edges = Set([range.lowerBound, range.upperBound])
            edges.formUnion(speech.map(\.start))
            let firstSpeech = context.turns.filter { $0.end > range.lowerBound }.map(\.start).min()
            if let firstSpeech, firstSpeech > range.lowerBound { edges.insert(firstSpeech) }
            if role == .vip { edges.formUnion(rotation.map(\.time)) }
            if role == .broll {
                for cut in context.brollCuts {
                    edges.insert(range.lowerBound + cut.start)
                    edges.insert(range.lowerBound + cut.start + cut.duration)
                }
            }
            let ordered = edges.filter { range.contains($0) }.sorted()
            var pieces: [AreaSegment] = []
            for (start, end) in zip(ordered, ordered.dropFirst()) where end > start {
                let active = speech.last { $0.start <= start }
                let talker = active?.talker ?? first
                let recent = active?.recent ?? []
                let nonVIP = tiles.filter { !vip.contains($0.index) }.map(\.index)
                let previousNonVIP = speech.last { $0.start <= start && nonVIP.contains($0.talker) }?.talker
                var candidates: [Int]
                switch role {
                case .vip:
                    let current = rotation.last { $0.time <= start }?.tile
                    candidates = vip.isEmpty ? [talker].compactMap { $0 } + recent
                        : [current].compactMap { $0 } + vip
                case .others, .broll:
                    candidates = vip.isEmpty ? recent + [talker].compactMap { $0 }
                        : [previousNonVIP].compactMap { $0 } + nonVIP + vip
                case nil: candidates = tiles.map(\.index)
                case .screen, .presenter: candidates = []
                }
                if vip.isEmpty, let firstSpeech, start < firstSpeech { candidates = [first].compactMap { $0 } }
                if candidates.isEmpty { candidates = [first].compactMap { $0 } }
                var seen = Set<Int>()
                candidates = candidates.filter { seen.insert($0).inserted }
                let selected = candidates.isEmpty ? nil : candidates[ordinal % candidates.count]
                let tile = tiles.first { $0.index == selected }
                var recipe = CropRecipe(kind: .talker)
                recipe.slots = selected.map { [.tile($0)] }
                recipe.minimumHold = role == .vip ? FramingHolds.vipHold : FramingHolds.recipeHold
                recipe.rotationSeconds = FramingHolds.rotation
                let picture = tile?.picture
                var piece = AreaSegment(areaID: area.id, sourceID: context.sourceID, sourcePath: context.sourcePath,
                    start: start, duration: end - start, role: role,
                    framing: tile == nil ? .static(window: nil) : .recipe(recipe), audio: .program,
                    timelineStart: start - range.lowerBound,
                    region: picture.map { FreeCropRect(xFrac: $0.x, yFrac: $0.y, wFrac: $0.w, hFrac: $0.h) },
                    focus: tile?.faceCenter.map { AreaFocus(x: $0.x, y: $0.y) })
                if role == .broll, let cut = context.brollCuts.first(where: {
                    $0.start <= start - range.lowerBound && start - range.lowerBound < $0.start + $0.duration
                }) {
                    switch cut.source {
                    case .scene(let id):
                        if let scene = context.scenes.first(where: { $0.id == id }) {
                            piece.sourceID = scene.videoID
                            piece.sourcePath = scene.videoURL.path
                            piece.start = cut.sourceStart + start - range.lowerBound - cut.start
                            piece.framing = .static(window: nil)
                            piece.region = nil
                            piece.focus = nil
                        }
                    case .reaction(let index):
                        if let tile = tiles.first(where: { $0.index == index }) {
                            let box = tile.picture
                            piece.start = cut.sourceStart + start - range.lowerBound - cut.start
                            piece.region = FreeCropRect(xFrac: box.x, yFrac: box.y, wFrac: box.w, hFrac: box.h)
                            recipe.slots = [.tile(index)]
                            piece.framing = .recipe(recipe)
                        }
                    }
                }
                if let last = pieces.last, last.sourcePath == piece.sourcePath, last.framing == piece.framing,
                   last.region == piece.region, abs(last.start + last.duration - piece.start) < 0.001 {
                    pieces[pieces.count - 1].duration += piece.duration
                } else { pieces.append(piece) }
            }
            output += pieces
        }
        return Result(areas: output, notes: notes)
    }
}
