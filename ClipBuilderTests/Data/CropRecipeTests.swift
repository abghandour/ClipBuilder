import Foundation
import Testing
@testable import Clip_Builder

@Suite("Crop recipes")
struct CropRecipeTests {
    private static let tiles = [
        PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 0.5, personKey: "ann"),
        PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 0.5, personKey: "bob"),
        PodcastTile(index: 2, x: 0, y: 0.5, w: 0.5, h: 0.5),
        PodcastTile(index: 3, x: 0.5, y: 0.5, w: 0.5, h: 0.5),
    ]

    private static func turn(_ start: Double, _ end: Double, tile: Int) -> SpeakerTurn {
        var turn = SpeakerTurn(videoID: 1, start: start, end: end, cluster: tile, confidence: 0.9)
        turn.tile = tile
        return turn
    }

    static let turns = [turn(0, 3, tile: 0), turn(3, 6, tile: 1), turn(6, 8, tile: 2), turn(8, 10, tile: 0)]

    static func video(tiles: [PodcastTile] = tiles) throws -> VideoRecord {
        var video = Fixtures.video()
        video.podcastLayout = "grid"
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        return video
    }

    @Test("subject tokens round trip and refuse nonsense")
    func tokens() {
        for token in ["talker", "recent:2", "others:1", "tile:0", "person:Ann Lee"] {
            #expect(CropRecipeSubject(token: token)?.token == token, "\(token)")
        }
        #expect(CropRecipeSubject(token: "previous") == .recent(1))
        #expect(CropRecipeSubject(token: "speaker") == .talker)
        for bad in ["", "recent:0", "others:x", "tile:-1", "person:", "faces"] {
            #expect(CropRecipeSubject(token: bad) == nil, "\(bad)")
        }
    }

    @Test("layouts follow the head count and the built-ins exist")
    func layouts() {
        #expect(CropRecipePlanner.layoutName(kind: .grid, people: 2) == "50-50 Horizontal")
        #expect(CropRecipePlanner.layoutName(kind: .grid, people: 3) == "33-33-33 Horizontal")
        #expect(CropRecipePlanner.layoutName(kind: .grid, people: 4) == "2x2 Grid")
        #expect(CropRecipePlanner.layoutName(kind: .grid, people: 6) == "2x3 Grid")
        #expect(CropRecipePlanner.layoutName(kind: .grid, people: 7) == nil)
        #expect(CropRecipePlanner.layoutName(kind: .talkerAndRest, people: 4) == "Talker + 3")
        #expect(CropRecipePlanner.layoutName(kind: .talker, people: 4) == "Full Screen")
        for name in ["2x2 Grid", "2x3 Grid", "Talker + 2", "Talker + 3"] {
            let layout = ScreenCropStore.builtIn.first { $0.name == name }
            #expect(layout != nil, "\(name)")
            #expect(abs((layout?.areas.reduce(0) { $0 + $1.coverage } ?? 0) - 1) < 1e-9, "\(name)")
        }
    }

    @Test("segments hold the talker for the minimum time, keep the last talker through silence, and rank recent speakers")
    func segments() {
        let segments = CropRecipePlanner.segments(turns: Self.turns, tiles: Self.tiles, range: 0...10, hold: 1.5)
        #expect(segments.map(\.talker) == [0, 1, 2, 0])
        #expect(segments.map(\.start) == [0, 3, 6, 8] && segments.last?.end == 10)
        #expect(segments[0].recent == [1, 2, 3])
        #expect(segments[1].recent == [0, 2, 3])
        #expect(segments[2].recent == [1, 0, 3])
        #expect(segments[3].recent == [2, 1, 3])
        // A quick exchange inside the hold does not switch.
        let quick = [Self.turn(0, 3, tile: 0), Self.turn(3, 3.5, tile: 1), Self.turn(3.5, 6, tile: 0)]
        let held = CropRecipePlanner.segments(turns: quick, tiles: Self.tiles, range: 0...6, hold: 1.5)
        #expect(held.map(\.talker) == [0])
        // Side-by-side turns map by their resolved side.
        var left = SpeakerTurn(videoID: 1, start: 0, end: 2, cluster: 0, confidence: 1); left.resolvedSide = .left
        var right = SpeakerTurn(videoID: 1, start: 2, end: 4, cluster: 1, confidence: 1); right.resolvedSide = .right
        let halves = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1), PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        #expect(CropRecipePlanner.segments(turns: [left, right], tiles: halves, range: 0...4, hold: 1).map(\.talker) == [0, 1])
        // A range starts on whoever is talking at its start, with times clipped to it.
        let part = CropRecipePlanner.segments(turns: Self.turns, tiles: Self.tiles, range: 4...9, hold: 1.5)
        #expect(part.map(\.talker) == [1, 2, 0] && part.map(\.start) == [4, 6, 8] && part.last?.end == 9)
    }

    @Test("a cell crop keeps the area's aspect inside the tile and centers on the face when known")
    func cellCrop() {
        let tile = Self.tiles[0]
        // A square-ish 2×2 cell on a 9:16 canvas: 0.5625 wide per unit height.
        let crop = CropRecipePlanner.crop(tile: tile, aspect: 0.5625, sourceAspect: 16.0 / 9.0)
        #expect(crop.hFrac == 0.5 && abs(crop.wFrac - 0.5 * 0.5625 / (16.0 / 9.0)) < 1e-3)
        #expect(abs(crop.xFrac + crop.wFrac / 2 - 0.25) < 1e-3 && crop.yFrac == 0)
        let faced = CropRecipePlanner.crop(tile: tile, aspect: 0.5625, sourceAspect: 16.0 / 9.0, center: (0.45, 0.2))
        #expect(abs(faced.xFrac + faced.wFrac - 0.5) < 1e-3, "clamped to the tile's right edge")
        // A wide cell: the crop spans the tile's width and trims its height.
        let wide = CropRecipePlanner.crop(tile: tile, aspect: 2, sourceAspect: 16.0 / 9.0)
        #expect(wide.wFrac == 0.5 && abs(wide.hFrac - 0.5 * (16.0 / 9.0) / 2) < 1e-3)
    }

    @Test("a grid plan fixes every cell on its feed and knows when each cell's person talks")
    func gridPlan() throws {
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .grid), video: Self.video(), turns: Self.turns, roster: [],
                                              layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        #expect(plan.layout.name == "2x2 Grid" && plan.slots.count == 4)
        #expect(plan.slots.map(\.subject) == [.tile(0), .tile(1), .tile(2), .tile(3)])
        // Still cells track inside their feed; without tracking they are fixed crops.
        #expect(plan.slots.allSatisfy { $0.region != nil && $0.window == nil && $0.path == nil })
        #expect(plan.slots[0].talking == [0...3, 8...10] && plan.slots[3].talking.isEmpty)
        #expect(plan.slots[1].region == FreeCropRect(xFrac: 0.5, yFrac: 0, wFrac: 0.5, hFrac: 0.5))
        var fixed = CropRecipe(kind: .grid); fixed.tracking = false
        let still = try CropRecipePlanner.plan(fixed, video: Self.video(), turns: Self.turns, roster: [],
                                               layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        #expect(still.slots.allSatisfy { $0.window != nil && $0.region == nil })
        #expect(still.slots[1].window?.xFrac ?? 0 > 0.5)
        // A tile that knows where its face sits centers the crop there.
        var faced = Self.tiles; faced[1].faceX = 0.6; faced[1].faceY = 0.2
        let centered = try CropRecipePlanner.plan(fixed, video: Self.video(tiles: faced), turns: Self.turns, roster: [],
                                                  layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        let window = try #require(centered.slots[1].window)
        #expect(abs(window.xFrac + window.wFrac / 2 - 0.6) < 1e-3 && window.yFrac == 0)
        // Six people in a 2×3 grid; seven need a named layout.
        var six = Self.tiles
        six += [PodcastTile(index: 4, x: 0, y: 0.5, w: 0.5, h: 0.5), PodcastTile(index: 5, x: 0.5, y: 0.5, w: 0.5, h: 0.5)]
        #expect(try CropRecipePlanner.plan(CropRecipe(kind: .grid), video: Self.video(tiles: six), turns: Self.turns, roster: [],
                                           layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0).layout.name == "2x3 Grid")
        #expect(throws: CropRecipePlanner.Failure.self) {
            try CropRecipePlanner.plan(CropRecipe(kind: .grid), video: Self.video(tiles: six + [PodcastTile(index: 6, x: 0, y: 0, w: 0.1, h: 0.1)]),
                                       turns: Self.turns, roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        }
    }

    @Test("talker recipes cut between feeds with held keyframes and fill the other cells")
    func talkerPlans() throws {
        let rest = try CropRecipePlanner.plan(CropRecipe(kind: .talkerAndRest), video: Self.video(), turns: Self.turns, roster: [],
                                              layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        #expect(rest.layout.name == "Talker + 3" && rest.slots.map(\.subject) == [.talker, .others(1), .others(2), .others(3)])
        let talker = try #require(rest.slots[0].path)
        #expect(talker.map(\.t) == [0, 2.99, 3, 5.99, 6, 7.99, 8, 10])
        #expect(talker[0].x == talker[6].x && talker[2].x > 0.5 && talker[4].y == 0.5)
        #expect(rest.slots[0].talking == [0...10], "the talker's cell always shows the talker")
        // "Other 1" shows feed 1 while feed 0 talks and feed 0 otherwise: two cuts, not three.
        let other = try #require(rest.slots[1].path)
        #expect(other.map(\.t) == [0, 2.99, 3, 7.99, 8, 10])
        // Feed 3 never talks: "Other 3" always shows it, so the cell tracks inside that feed.
        #expect(rest.slots[3].region != nil && rest.slots[3].path == nil && rest.slots[3].window == nil)

        let previous = try CropRecipePlanner.plan(CropRecipe(kind: .talkerAndPrevious), video: Self.video(), turns: Self.turns,
                                                  roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        #expect(previous.layout.name == "50-50 Horizontal" && previous.slots.count == 2)
        // Before anyone else has spoken the lower cell shows the next feed in order.
        #expect(previous.slots[1].path?.first?.x ?? 0 > 0.5)

        let full = try CropRecipePlanner.plan(CropRecipe(kind: .talker, highlightTalker: true), video: Self.video(), turns: Self.turns,
                                              roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        #expect(full.layout.isFullScreen && full.slots.count == 1 && full.slots[0].window == nil)
        let path = try #require(full.slots[0].path)
        #expect(abs(path[0].w - 0.5 * 0.5625 / (16.0 / 9.0)) < 1e-3 && path[0].h == 0.5)
        #expect(full.notes.contains { $0.contains("not outlined") })

        // A scene of the file: keyframes count from the scene's start, spans stay in source seconds.
        let scene = try CropRecipePlanner.plan(CropRecipe(kind: .talkerAndPrevious), video: Self.video(), range: 4...9,
                                               turns: Self.turns, roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        #expect(scene.slots[0].path?.map(\.t) == [0, 1.99, 2, 3.99, 4, 5] && scene.slots[0].talking == [4...9])

        // A named layout with hand-picked subjects, including a person by key.
        var custom = CropRecipe(kind: .grid)
        custom.layout = "50-50 Horizontal"
        custom.slots = [.person("bob"), .recent(1)]
        let picked = try CropRecipePlanner.plan(custom, video: Self.video(), turns: Self.turns, roster: [],
                                                layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        #expect(picked.slots[0].region?.xFrac == 0.5 && picked.slots[0].talking == [3...6])
        #expect(picked.slots[1].path != nil)
    }

    @Test("the rotating cell takes turns through everyone but the talker on a steady beat")
    func rotation() throws {
        var recipe = CropRecipe(kind: .talkerAndRotation)
        recipe.rotationSeconds = 2
        let plan = try CropRecipePlanner.plan(recipe, video: Self.video(), turns: Self.turns, roster: [],
                                              layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        #expect(plan.layout.name == "50-50 Horizontal" && plan.slots.map(\.subject) == [.talker, .rotate(2)])
        let path = try #require(plan.slots[1].path)
        // Which feed a keyframe shows, from its rectangle.
        func tile(_ keyframe: CameraPathKeyframe) -> Int? {
            Self.tiles.first { $0.contains(x: keyframe.x + keyframe.w / 2, y: keyframe.y + keyframe.h / 2) }?.index
        }
        let talkers = CropRecipePlanner.segments(turns: Self.turns, tiles: Self.tiles, range: 0...10, hold: 1.5)
        for keyframe in path {
            let talker = talkers.last { $0.start <= keyframe.t + 1e-6 }?.talker
            #expect(tile(keyframe) != talker, "at \(keyframe.t) the cell shows the talker")
        }
        // Beats at 2, 4, 6, 8 plus the talker changes at 3 and 8: cuts land on those.
        let cuts = path.filter { keyframe in path.contains { abs($0.t - (keyframe.t - 0.01)) < 1e-6 } }.map(\.t)
        #expect(cuts.contains(2) && cuts.contains(4) && cuts.contains(6))
        #expect(Set(path.compactMap(tile)).count >= 3, "rotates through several people")
        #expect(plan.slots[1].talking.isEmpty)
        #expect(CropRecipeSubject(token: "rotate:2.5") == .rotate(2.5) && CropRecipeSubject(token: "rotate:0") == nil)
        #expect(CropRecipeSubject(token: "rotate:2.5")?.token == "rotate:2.5")
    }

    @Test("feeds fall back to halves or roster columns, and missing turns or feeds are refused")
    func fallbacksAndFailures() throws {
        var split = Fixtures.video()
        split.podcastLayout = "split_horizontal"
        #expect(CropRecipePlanner.tiles(video: split, roster: []).map(\.x) == [0, 0.5])
        let roster = [
            VideoPersonRecord(videoID: 1, personID: 1, key: "b", name: "B", descriptor: "", portraitAt: 0,
                              portraitBox: .init(x: 0.6, y: 0.1, w: 0.2, h: 0.4)),
            VideoPersonRecord(videoID: 1, personID: 2, key: "a", name: "A", descriptor: "", portraitAt: 0,
                              portraitBox: .init(x: 0.1, y: 0.1, w: 0.2, h: 0.4)),
        ]
        let columns = CropRecipePlanner.tiles(video: Fixtures.video(), roster: roster)
        #expect(columns.map(\.personKey) == ["a", "b"] && columns[0].x == 0 && abs(columns[1].x - 0.45) < 1e-9)
        // A grid without turns is a still grid; a talker recipe needs turns.
        #expect(try CropRecipePlanner.plan(CropRecipe(kind: .grid), video: Self.video(), turns: [], roster: [],
                                           layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0).slots.allSatisfy { $0.region != nil })
        #expect(throws: CropRecipePlanner.Failure.self) {
            try CropRecipePlanner.plan(CropRecipe(kind: .talkerAndRest), video: Self.video(), turns: [], roster: [],
                                       layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        }
        #expect(throws: CropRecipePlanner.Failure.self) {
            try CropRecipePlanner.plan(CropRecipe(kind: .grid), video: Fixtures.video(), turns: Self.turns, roster: [],
                                       layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        }
        var missing = CropRecipe(kind: .grid)
        missing.slots = [.tile(9)]
        #expect(throws: CropRecipePlanner.Failure.self) {
            try CropRecipePlanner.plan(missing, video: Self.video(), turns: Self.turns, roster: [],
                                       layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16.0)
        }
    }
}
