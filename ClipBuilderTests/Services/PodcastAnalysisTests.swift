import AppKit
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Podcast analysis")
struct PodcastAnalysisTests {
    @Test("language selection prefers a confident primary locale")
    func languageSelection() {
        let chosen = TranscriptionService.choosePodcastLanguage(
            primary: [.init(identifier: "en-US", confidence: 0.62),
                      .init(identifier: "pt-BR", confidence: 0.41)],
            installed: [.init(identifier: "es-ES", confidence: 0.91)])
        #expect(chosen?.identifier == "en-US")

        let fallback = TranscriptionService.choosePodcastLanguage(
            primary: [.init(identifier: "en-US", confidence: 0.2),
                      .init(identifier: "pt-BR", confidence: 0.3)],
            installed: [.init(identifier: "es-ES", confidence: 0.8)])
        #expect(fallback?.identifier == "es-ES")
    }

    @Test("speaker turns retain transcript word-safe boundaries")
    func turnBoundaries() {
        let segments = [
            TranscriptSegment(start: 0, end: 1.2, text: "Question?",
                              words: [.init(word: "Question?", start: 0, end: 1.2)]),
            TranscriptSegment(start: 1.4, end: 2.8, text: "Answer.",
                              words: [.init(word: "Answer.", start: 1.4, end: 2.8)]),
            TranscriptSegment(start: 3, end: 4, text: "More.",
                              words: [.init(word: "More.", start: 3, end: 4)]),
        ]
        let turns = PodcastSpeakerSeparator.turns(
            segments: segments,
            embeddings: [[1, 0], [0, 1], [1, 0]], videoID: 9)
        let boundaries = Set(segments.flatMap { [$0.start, $0.end] })
        #expect(turns.allSatisfy { boundaries.contains($0.start) && boundaries.contains($0.end) })
    }

    @Test("exchange grouping keeps each question with its answer")
    func exchangeGrouping() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "Why did you start?", words: nil),
            TranscriptSegment(start: 2, end: 8, text: "I wanted to help people.", words: nil),
            TranscriptSegment(start: 8, end: 10, text: "What changed?", words: nil),
            TranscriptSegment(start: 10, end: 16, text: "Everything changed after that.", words: nil),
        ]
        let candidates = PodcastExchangeSegmenter.candidateExchanges(segments: segments, turns: [])
        #expect(candidates.count == 2)
        #expect(candidates[0].start == 0)
        #expect(candidates[0].end == 8)
        #expect(candidates[1].start == 8)
        #expect(candidates[1].end == 16)
    }

    @Test("exchange speaker tags are derived from the final time range")
    func exchangeSpeakerKeys() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Why?", words: nil),
            TranscriptSegment(start: 1, end: 2, text: "And specifically?", words: nil),
            TranscriptSegment(start: 2, end: 5, text: "Because it mattered.", words: nil),
        ]
        let turns = [
            SpeakerTurn(videoID: 1, start: 0, end: 2, cluster: 0,
                        confidence: 1, personKey: "host"),
            SpeakerTurn(videoID: 1, start: 2, end: 5, cluster: 1,
                        confidence: 1, personKey: "guest"),
        ]
        let candidates = PodcastExchangeSegmenter.candidateExchanges(
            segments: segments, turns: turns)
        #expect(candidates.count == 1)
        #expect(candidates.first?.end == 5)
        #expect(candidates.flatMap(\.speakerKeys).contains("host"))
        #expect(candidates.flatMap(\.speakerKeys).contains("guest"))
    }

    @Test("highlight threshold controls automatic favorites")
    func favorites() {
        #expect(PodcastAnalysisService.shouldFavorite(score: 7, threshold: 7))
        #expect(!PodcastAnalysisService.shouldFavorite(score: 6.99, threshold: 7))
    }

    @Test("picture talker wins when audio mapping disagrees")
    func pictureTieBreak() {
        let audio = [SpeakerTurn(videoID: 1, start: 0, end: 3, cluster: 0,
                                 confidence: 0.9, resolvedSide: .left)]
        let picture = [PictureTalkerSignal(start: 0, end: 3, side: .right, confidence: 0.9)]
        let resolved = PodcastSpeakerTimelineResolver.resolve(
            audioTurns: audio, picture: picture, layout: .splitHorizontal,
            roster: [], minimumHold: 1.5)
        #expect(resolved.first?.resolvedSide == .right)
        #expect(resolved.first?.pictureSide == .right)
    }

    @Test("camera hold never changes the attributed speaker")
    func cameraHold() {
        let turns = [
            SpeakerTurn(videoID: 1, start: 0, end: 0.5, cluster: 0, confidence: 1),
            SpeakerTurn(videoID: 1, start: 0.5, end: 3, cluster: 1, confidence: 1),
            SpeakerTurn(videoID: 1, start: 3, end: 5, cluster: 1, confidence: 1),
        ]
        let picture = turns.enumerated().map { index, turn in
            PictureTalkerSignal(start: turn.start, end: turn.end,
                                side: index == 0 ? .right : .left, confidence: 1)
        }
        let resolved = PodcastSpeakerTimelineResolver.resolve(
            audioTurns: turns, picture: picture, layout: .splitHorizontal,
            roster: [], minimumHold: 1.5)
        #expect(resolved[0].resolvedSide == .right)
        #expect(resolved[1].resolvedSide == .left)
        let path = PodcastSpeakerTimelineResolver.cameraPath(
            for: 0...5, turns: resolved, layout: .splitHorizontal,
            videoSize: CGSize(width: 1920, height: 1080), minimumHold: 1.5)
        #expect(path.keyframes.first!.x > 0.5)
        #expect(path.keyframes.filter { $0.t < 1.5 }.allSatisfy { $0.x > 0.5 })
        #expect(path.keyframes.last!.x < 0.5)
    }

    @Test("a video-call grid becomes tiles from recurring face positions; stacked feeds count as a grid, one face does not")
    func gridTiles() {
        func box(_ cx: Double, _ cy: Double) -> CGRect { CGRect(x: cx - 0.05, y: cy - 0.05, width: 0.1, height: 0.1) }
        let quad = [box(0.25, 0.25), box(0.75, 0.25), box(0.25, 0.75), box(0.75, 0.75)]
        // One frame misses a face; a stray extra face appears once.
        let tiles = PodcastVisualAnalyzer.inferTiles(faceSets: [quad, Array(quad.prefix(3)), quad + [box(0.5, 0.5)]])
        #expect(tiles.count == 4)
        #expect(tiles.map(\.index) == [0, 1, 2, 3])
        #expect(tiles[0].x == 0 && tiles[0].y == 0 && tiles[0].w == 0.5 && tiles[0].h == 0.5)
        #expect(tiles[3].x == 0.5 && tiles[3].y == 0.5)
        #expect(tiles[1].contains(x: 0.75, y: 0.25) && !tiles[1].contains(x: 0.25, y: 0.25))
        let stacked = PodcastVisualAnalyzer.inferTiles(faceSets: [[box(0.5, 0.25), box(0.5, 0.75)], [box(0.5, 0.25), box(0.5, 0.75)]])
        #expect(stacked.count == 2 && stacked[0].h == 0.5 && stacked[1].y == 0.5 && stacked[0].w == 1)
        #expect(PodcastVisualAnalyzer.inferTiles(faceSets: [[box(0.5, 0.5)], [box(0.5, 0.5)]]).isEmpty)
        #expect(PodcastVisualAnalyzer.tilePresence(faceSets: [quad, Array(quad.prefix(3))], tiles: tiles) == 0.5)
        let roster = [VideoPersonRecord(videoID: 1, personID: 1, key: "modestino", name: "Modestino", descriptor: "",
                                        portraitAt: 1, portraitBox: .init(x: 0.6, y: 0.55, w: 0.2, h: 0.3))]
        let named = PodcastVisualAnalyzer.named(tiles, roster: roster)
        #expect(named[3].personKey == "modestino" && named.prefix(3).allSatisfy { $0.personKey == nil })
    }

    @Test("grid turns resolve to the tile whose mouth moved, fall back to the voice's usual tile, and crop the tile at 9:16")
    func gridResolutionAndCrop() {
        var tiles = PodcastVisualAnalyzer.inferTiles(faceSets: [[
            CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), CGRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1),
            CGRect(x: 0.2, y: 0.7, width: 0.1, height: 0.1), CGRect(x: 0.7, y: 0.7, width: 0.1, height: 0.1)]])
        tiles[3].personKey = "quemuel"
        let audio = [
            SpeakerTurn(videoID: 1, start: 0, end: 2, cluster: 0, confidence: 0.6),
            SpeakerTurn(videoID: 1, start: 2, end: 4, cluster: 1, confidence: 0.6),
            SpeakerTurn(videoID: 1, start: 4, end: 6, cluster: 0, confidence: 0.6),
        ]
        let picture = [PictureTalkerSignal(start: 0, end: 2, side: .right, confidence: 0.9, tile: 3),
                       PictureTalkerSignal(start: 2, end: 4, side: .left, confidence: 0.8, tile: 0)]
        let roster = [VideoPersonRecord(videoID: 1, personID: 1, key: "modestino", name: "Modestino", descriptor: "",
                                        portraitAt: 1, portraitBox: .init(x: 0.1, y: 0.1, w: 0.2, h: 0.2))]
        let resolved = PodcastSpeakerTimelineResolver.resolve(audioTurns: audio, picture: picture, layout: .grid,
                                                              roster: roster, minimumHold: 1.5, tiles: tiles)
        let resolvedTiles: [Int?] = resolved.map { $0.tile }
        let resolvedPeople: [String?] = resolved.map { $0.personKey }
        #expect(resolvedTiles == [3, 0, 3])
        #expect(resolvedPeople == ["quemuel", "modestino", "quemuel"])
        #expect(resolved[0].resolvedSide == .right && resolved[1].resolvedSide == .left)
        let path = PodcastSpeakerTimelineResolver.cameraPath(for: 0...6, turns: resolved, layout: .grid,
                                                             videoSize: CGSize(width: 1920, height: 1080),
                                                             roster: roster, minimumHold: 1.5, tiles: tiles)
        let first = try! #require(path.keyframes.first)
        // The largest 9:16 crop inside the bottom-right cell, centered on it.
        let expectedWidth = 0.5 * (9.0 / 16.0) / (1920.0 / 1080.0)
        #expect(abs(first.h - 0.5) < 1e-9)
        #expect(abs(first.w - expectedWidth) < 1e-9)
        #expect(abs(first.x - (0.75 - first.w / 2)) < 1e-9)
        #expect(abs(first.y - 0.5) < 1e-9)
        #expect(path.keyframes.contains { $0.t >= 2 && $0.y == 0 && $0.x < 0.5 })
        #expect(path.keyframes.last?.y == 0.5)
    }

    @Test("the speaker map needs a transcript and stores nothing without one")
    func speakerMapWithoutTranscript() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 0)
        let video = try #require(try await temp.database.video(id: videoID))
        let turns = try await PodcastAnalysisService.mapSpeakers(video: video, database: temp.database,
                                                                 holdSeconds: 1.5, log: { _ in })
        #expect(turns.isEmpty)
        #expect(try await temp.database.fetchSpeakerTurns(videoID: videoID).isEmpty)
        #expect(try await temp.database.video(id: videoID)?.podcastLayout == nil)
    }

    @Test("a cell's picture bounds leave the black bars of a letterboxed feed out of the crop")
    func pictureBounds() throws {
        // A 320×180 frame: two cells side by side, each with picture only
        // between 20% and 80% of its height; the right cell fills its cell.
        let width = 320, height = 180
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let leftCell = x < width / 2
                let inPicture = !leftCell || (y >= 36 && y < 144)
                let offset = (y * width + x) * 4
                pixels[offset] = inPicture ? 120 : 6; pixels[offset + 1] = inPicture ? 110 : 6; pixels[offset + 2] = inPicture ? 100 : 6; pixels[offset + 3] = 255
            }
        }
        let context = try #require(pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        let image = try #require(context.makeImage())
        let jpeg = try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1), PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        let trimmed = PodcastVisualAnalyzer.withPictureBounds(tiles, frames: [jpeg, jpeg])
        let left = try #require(trimmed[0].pictureY)
        #expect(abs(left - 0.2) < 0.03 && abs((trimmed[0].pictureH ?? 0) - 0.6) < 0.04, "\(trimmed[0])")
        #expect(trimmed[0].pictureX == 0 && abs((trimmed[0].pictureW ?? 0) - 0.5) < 0.02)
        #expect(trimmed[1].pictureY == nil, "a full cell reports no trimming")
        // Crops come from the picture, so the bars stay out.
        let crop = CropRecipePlanner.crop(tile: trimmed[0], aspect: 0.5625, sourceAspect: 16.0 / 9.0)
        #expect(crop.yFrac >= 0.19 && crop.yFrac + crop.hFrac <= 0.81)
        let path = PodcastSpeakerTimelineResolver.tileCrop(trimmed[0], aspect: 16.0 / 9.0)
        #expect(path.y >= 0.19 && path.y + path.h <= 0.81)
        // The trimmed cell still names and locates the same feed.
        #expect(trimmed[0].picture.contains(x: 0.25, y: 0.5) && !trimmed[0].picture.contains(x: 0.25, y: 0.1) && trimmed[0].contains(x: 0.25, y: 0.1))
        let roundTrip = try JSONDecoder().decode([PodcastTile].self, from: JSONEncoder().encode(trimmed))
        #expect(roundTrip == trimmed)
        #expect(PodcastVisualAnalyzer.withPictureBounds(tiles, frames: []) == tiles)
    }

    @Test("tiles remember where their faces sit")
    func tileFaceCenters() {
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1), PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        let faces: [[CGRect]] = [[CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.2), CGRect(x: 0.7, y: 0.3, width: 0.1, height: 0.2)],
                                 [CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.2)]]
        let centered = PodcastVisualAnalyzer.withFaceCenters(tiles, faceSets: faces)
        #expect(centered[0].faceCenter.map { abs($0.x - 0.2) < 1e-9 && abs($0.y - 0.3) < 1e-9 } == true)
        #expect(centered[1].faceCenter.map { abs($0.x - 0.75) < 1e-9 } == true)
        #expect(PodcastVisualAnalyzer.withFaceCenters(tiles, faceSets: []).allSatisfy { $0.faceCenter == nil })
    }

    @Test("grid tiles and per-turn tiles persist")
    func gridPersistence() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 0)
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "host"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        try await temp.database.setPodcastLayout(videoID: videoID, layout: .grid, seamX: nil, confidence: 0.8, tiles: tiles)
        let video = try #require(try await temp.database.video(id: videoID))
        #expect(video.podcastLayout == "grid" && video.podcastTiles == tiles)
        let turn = SpeakerTurn(videoID: videoID, start: 1, end: 4, cluster: 1, confidence: 0.75,
                               resolvedSide: .right, personKey: "guest", tile: 1)
        try await temp.database.replaceSpeakerTurns(videoID: videoID, turns: [turn])
        #expect(try await temp.database.fetchSpeakerTurns(videoID: videoID).first?.tile == 1)
        try await temp.database.setPodcastLayout(videoID: videoID, layout: .singleCamera, seamX: nil, confidence: 1)
        #expect(try await temp.database.video(id: videoID)?.podcastTiles.isEmpty == true)
    }

    @Test("multi-sentence speech results split only at timestamped word ends")
    func sentenceBoundaries() {
        let words = [TranscriptWord(word: "Why?", start: 0, end: 1),
                     TranscriptWord(word: "Because.", start: 1.2, end: 3),
                     TranscriptWord(word: "When?", start: 3.2, end: 4),
                     TranscriptWord(word: "Tomorrow.", start: 4.2, end: 6)]
        let segments = [TranscriptSegment(start: 0, end: 6,
                                          text: "Why? Because. When? Tomorrow.", words: words)]
        let ranges = PodcastExchangeSegmenter.candidateExchanges(segments: segments, turns: [])
        #expect(ranges.count == 2)
        #expect(ranges[0].end == 3)
        #expect(ranges[1].start == 3.2)
    }

    @Test("identity sampling stays sparse for a thirty-minute recording")
    func sparseIdentitySampling() {
        let turns = (0..<600).map { index in
            SpeakerTurn(videoID: 1, start: Double(index * 3), end: Double(index * 3 + 3),
                        cluster: index % 2, confidence: 1)
        }
        #expect(PodcastAnalysisService.identitySampleTimes(turns: turns, duration: 1800).count <= 6)
    }

    @Test("voice windows can separate speakers within one speech result")
    func voiceWindows() {
        let words = (0..<6).map { TranscriptWord(word: "word", start: Double($0), end: Double($0 + 1)) }
        let windows = PodcastSpeakerSeparator.voiceWindows([
            TranscriptSegment(start: 0, end: 6, text: "words", words: words),
        ])
        #expect(windows.count == 6)
        #expect(windows.last?.end == 6)
    }

    @Test("profile portraits and merged speaker identities survive People review")
    func profilePortraitsAndMerge() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 0)
        try await temp.database.upsertPerson(key: "guest", descriptor: "Guest")
        try await temp.database.upsertPerson(key: "known", descriptor: "Known guest")
        let people = try await temp.database.fetchPeople()
        let guest = try #require(people.first { $0.key == "guest" })
        let known = try #require(people.first { $0.key == "known" })
        try await temp.database.replaceVideoPeople(videoID: videoID, entries: [
            (guest.id, 1, "{\"x\":0.1,\"y\":0.2,\"w\":0.3,\"h\":0.4}", nil),
        ])
        let references = try await temp.database.podcastPortraitReferences()
        #expect(references.first?.key == "guest")
        #expect(references.first?.time == 1)
        try await temp.database.replaceSpeakerTurns(videoID: videoID, turns: [
            SpeakerTurn(videoID: videoID, start: 0, end: 3, cluster: 0,
                        confidence: 1, personKey: guest.key),
        ])
        try await temp.database.mergePeople(source: guest, into: known)
        #expect(try await temp.database.fetchSpeakerTurns(videoID: videoID).first?.personKey == known.key)
        try await temp.database.deletePerson(known)
        #expect(try await temp.database.fetchSpeakerTurns(videoID: videoID).first?.personKey == nil)
    }

    @Test("speaker turns persist with resolved identity and picture evidence")
    func speakerTurnPersistence() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 0)
        let turn = SpeakerTurn(videoID: videoID, start: 1, end: 4, cluster: 1,
                               confidence: 0.75, pictureSide: .right,
                               pictureConfidence: 0.88, resolvedSide: .right,
                               personKey: "guest")
        try await temp.database.replaceSpeakerTurns(videoID: videoID, turns: [turn])
        let fetched = try await temp.database.fetchSpeakerTurns(videoID: videoID)
        #expect(fetched.count == 1)
        #expect(fetched[0].personKey == "guest")
        #expect(fetched[0].pictureConfidence == 0.88)
    }

    @Test("podcast Wizard keeps a short exchange whole and sentence-trims an overlong one")
    func wizardBoundaries() async throws {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        var short = Fixtures.scene(start: 2, end: 12)
        short.tags = ["podcast", "reel-highlight"]
        var options = WizardOptions()
        options.formatPreset = "podcast"
        options.targetDurationSeconds = 20
        let raw: [String: Any] = ["target_duration": 20,
                                  "clips": [["scene_id": 1, "start": 4, "end": 9]]]
        let whole = try #require(await engine.validatePlan(
            raw, scenes: [1: short], musicNames: [], options: options))
        #expect(whole.clips[0].start == 2)
        #expect(whole.clips[0].end == 12)

        var long = short
        long.endTime = 62
        let trimmed = try #require(await engine.validatePlan(
            raw, scenes: [1: long], musicNames: [], options: options,
            podcastSentenceEnds: [1: [7, 12, 18, 25]]))
        #expect(trimmed.clips[0].start == 2)
        #expect(trimmed.clips[0].end == 7)

        let untrimmedAI: [String: Any] = ["target_duration": 20,
                                          "clips": [["scene_id": 1, "start": 2, "end": 62]]]
        let capped = try #require(await engine.validatePlan(
            untrimmedAI, scenes: [1: long], musicNames: [], options: options,
            podcastSentenceEnds: [1: [7, 12, 18, 25]]))
        #expect(capped.clips[0].end == 18)
        #expect(capped.clips[0].end - capped.clips[0].start <= 20)
    }

    @Test("split Zoom timeline creates pinned synchronized tracks")
    func splitTimeline() {
        var scene = Fixtures.scene(start: 0, end: 10)
        scene.tags = ["podcast", "podcast:split", "reel-highlight"]
        let document = WizardEngine.timelineDocument(
            from: Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 10)], targetDuration: 10),
            sceneMap: [scene.id: scene], podcastFraming: .splitZoom)
        #expect(document.videoTrack.count == 2)
        #expect(document.videoTrack.map(\.track) == [0, 1])
        #expect(document.videoTrack[0].areaWindow?.xFrac == 0)
        #expect(document.videoTrack[1].areaWindow?.xFrac == 0.5)
        #expect(document.videoTrack[1].muted)
        #expect(document.cropBlocks.first?.layout.name == "50-50 Horizontal")
    }
    @Test("unpunctuated alternating turns produce complete question-answer exchanges")
    func unpunctuatedTurns() {
        let rows = [
            TranscriptSegment(start: 0, end: 3, text: "your next challenge", words: nil),
            TranscriptSegment(start: 3, end: 25, text: "I started working on a new project", words: nil),
            TranscriptSegment(start: 25, end: 29, text: "your biggest surprise", words: nil),
            TranscriptSegment(start: 29, end: 55, text: "The response changed everything", words: nil),
        ]
        let turns = rows.enumerated().map { index, row in
            SpeakerTurn(videoID: 1, start: row.start, end: row.end, cluster: index % 2,
                        confidence: 0.9, personKey: index % 2 == 0 ? "host" : "guest")
        }
        let ranges = PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: turns)
        #expect(ranges.count == 2)
        #expect(ranges.map(\.start) == [0, 25])
        #expect(ranges.map(\.end) == [25, 55])
        let words = rows.map { TranscriptWord(word: $0.text, start: $0.start, end: $0.end) }
        let combined = [TranscriptSegment(start: 0, end: 55, text: rows.map(\.text).joined(separator: " "), words: words)]
        #expect(PodcastExchangeSegmenter.candidateExchanges(segments: combined, turns: turns).count == 2)
    }

    @Test("interrogative openers work in English and Portuguese without question marks")
    func questionOpeners() {
        for opener in ["why", "how", "what", "when", "where", "who", "did", "do", "does", "is", "are",
                       "can", "could", "would", "should", "tell me", "por que", "como", "o que",
                       "quando", "onde", "quem", "você"] {
            let rows = [
                TranscriptSegment(start: 0, end: 20, text: "\(opener) this happened", words: nil),
                TranscriptSegment(start: 20, end: 40, text: "My answer", words: nil),
                TranscriptSegment(start: 40, end: 60, text: "\(opener) it changed", words: nil),
                TranscriptSegment(start: 60, end: 80, text: "My next answer", words: nil),
            ]
            let turns = rows.enumerated().map { index, row in
                SpeakerTurn(videoID: 1, start: row.start, end: row.end, cluster: index % 2, confidence: 1)
            }
            #expect(PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: turns).count == 2)
        }
    }

    @Test("long pauses split only with speaker changes and preserve the first answer")
    func pauseBoundaries() {
        let rows = [TranscriptSegment(start: 0, end: 20, text: "A story", words: nil),
                    TranscriptSegment(start: 21.5, end: 41.5, text: "Another story", words: nil)]
        var turns = [SpeakerTurn(videoID: 1, start: 0, end: 20, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: 1, start: 21.5, end: 41.5, cluster: 1, confidence: 1)]
        #expect(PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: turns).count == 2)
        turns[1].cluster = 0
        #expect(PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: turns).count == 1)
    }

    @Test("monologue fallback is bounded while AI-confirmed exchanges retain their full length")
    func monologueSafetyNet() throws {
        let words = (0..<1800).map { TranscriptWord(word: "word\($0)", start: Double($0), end: Double($0 + 1)) }
        let row = TranscriptSegment(start: 0, end: 1800, text: words.map(\.word).joined(separator: " "), words: words)
        for transcript in [[row], [TranscriptSegment(start: 0, end: 1800, text: row.text, words: nil)]] {
            let sentences = PodcastExchangeSegmenter.sentenceSegments(transcript)
            #expect(sentences.map(\.text).joined(separator: " ") == row.text)
            let ranges = PodcastExchangeSegmenter.candidateExchanges(segments: transcript, turns: [])
            #expect(ranges.count >= 10)
            #expect(ranges.allSatisfy { $0.end - $0.start <= 180 })
            #expect(ranges.first?.start == 0)
            #expect(ranges.last?.end == 1800)
            let merged = try PodcastExchangeSegmenter.validatedExchanges(
                [["first_sentence": 0, "last_sentence": sentences.count - 1]], segments: sentences, turns: [])
            #expect(merged.count == 1)
            #expect(merged.first?.start == 0)
            #expect(merged.first?.end == 1800)
        }
    }

    @Test("AI can split and merge sentence ranges but cannot omit or overlap speech")
    func aiSentencePartition() throws {
        let rows = (0..<4).map { TranscriptSegment(start: Double($0 * 10), end: Double(($0 + 1) * 10), text: "speech", words: nil) }
        #expect(PodcastExchangeSegmenter.candidateExchanges(segments: rows, turns: []).count == 1)
        let split = try PodcastExchangeSegmenter.validatedExchanges(
            [["first_sentence": 0, "last_sentence": 1], ["first_sentence": 2, "last_sentence": 3]], segments: rows, turns: [])
        #expect(split.map(\.start) == [0, 20])
        #expect(split.map(\.end) == [20, 40])
        let merged = try PodcastExchangeSegmenter.validatedExchanges(
            [["first_sentence": 0, "last_sentence": 3]], segments: rows, turns: [])
        #expect(merged.count == 1)
        let invalidResponses: [[[String: Any]]] = [
            [["first_sentence": 0, "last_sentence": 2]],
            [["first_sentence": 0, "last_sentence": 2], ["first_sentence": 2, "last_sentence": 3]],
            [["first_sentence": 0, "last_sentence": 4]],
            [["first_sentence": 0.5, "last_sentence": 3]],
            [],
        ]
        for invalid in invalidResponses {
            #expect(throws: (any Error).self) {
                try PodcastExchangeSegmenter.validatedExchanges(invalid, segments: rows, turns: [])
            }
        }
    }

    @Test("two exchanges persist exactly two scenes with whole-exchange role tags")
    func exchangeSceneRanges() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 0)
        let segments = [
            TranscriptSegment(start: 0, end: 3, text: "Why this", words: nil),
            TranscriptSegment(start: 3, end: 20, text: "My explanation", words: nil),
            TranscriptSegment(start: 20, end: 23, text: "What changed", words: nil),
            TranscriptSegment(start: 23, end: 40, text: "Everything changed", words: nil),
        ]
        let turns = segments.enumerated().map { index, segment in
            SpeakerTurn(videoID: videoID, start: segment.start, end: segment.end,
                        cluster: index % 2, confidence: 1,
                        personKey: index % 2 == 0 ? "host" : "guest")
        }
        let candidates = PodcastExchangeSegmenter.candidateExchanges(segments: segments, turns: turns)
        #expect(candidates.count == 2)
        let exchanges = candidates.enumerated().map { index, candidate in
            PodcastExchange(start: candidate.start, end: candidate.end, title: "Exchange", summary: "",
                            score: index == 0 ? 8 : 0, speakerKeys: candidate.speakerKeys)
        }
        let tags = PodcastAnalysisService.exchangeTagRanges(exchanges, layout: .splitHorizontal, highlightThreshold: 7)
        let runID = try await temp.database.saveAnalysis(
            videoID: videoID, runName: "Podcast", instructions: "", sampleInterval: nil, notesJSON: nil,
            tagRanges: tags, moments: [], analyzedTags: ["podcast"], provider: nil, model: nil, mode: "speech")
        let ranges = try await temp.database.sceneRanges(runID: runID).sorted { $0.start < $1.start }
        #expect(ranges.count == 2)
        #expect(ranges.map(\.start) == [0, 20])
        #expect(ranges.map(\.end) == [20, 40])
        let scenes = try await temp.database.fetchScenes().filter { $0.runID == runID }
        let required = Set(["podcast", "q&a", "person:host", "person:guest", "podcast:split"])
        #expect(scenes.allSatisfy { required.isSubset(of: Set($0.tags)) })
        #expect(scenes.filter { $0.tags.contains("reel-highlight") }.map(\.startTime) == [0])
    }

    @Test("Wizard trims unpunctuated exchanges at recovered turn and pause boundaries")
    func wizardUnpunctuatedTrim() async throws {
        let words = (0..<60).map { index in
            let start = Double(index < 20 ? index : index + 2)
            return TranscriptWord(word: "word\(index)", start: start, end: start + 1)
        }
        let segments = [TranscriptSegment(start: 0, end: 62,
                                          text: words.map(\.word).joined(separator: " "), words: words)]
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 10, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: 1, start: 10, end: 62, cluster: 1, confidence: 1)]
        var scene = Fixtures.scene(start: 0, end: 62)
        scene.tags = ["podcast"]
        // This is the same helper used when loading PlanningInputs.
        let ends = WizardEngine.podcastTrimPoints(segments: segments, turns: turns, scene: scene)
        #expect(ends == [10, 20])
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        let raw: [String: Any] = ["clips": [["scene_id": scene.id, "start": 0, "end": 62]]]
        for (target, expectedEnd) in [(15, 10.0), (25, 20.0)] {
            var options = WizardOptions()
            options.formatPreset = "podcast"
            options.targetDurationSeconds = target
            let plan = try #require(await engine.validatePlan(
                raw, scenes: [scene.id: scene], musicNames: [], options: options,
                podcastSentenceEnds: [scene.id: ends]))
            #expect(plan.clips.first?.start == 0)
            #expect(plan.clips.first?.end == expectedEnd)
        }
    }

    @Test("Wizard falls back to podcast scenes only when highlights are absent")
    func wizardHighlightFallback() {
        var podcast = Fixtures.scene(id: 1)
        podcast.tags = ["podcast"]
        var highlight = Fixtures.scene(id: 2)
        highlight.tags = ["podcast", "reel-highlight"]
        let unrelated = Fixtures.scene(id: 3)
        var messages: [String] = []
        let fallback = WizardEngine.podcastScenes([podcast, unrelated], log: { messages.append($0) })
        #expect(fallback.map(\.id) == [1])
        #expect(messages.contains { $0.contains("falling back to all podcast scenes") })
        messages = []
        let preferred = WizardEngine.podcastScenes([podcast, highlight, unrelated], log: { messages.append($0) })
        #expect(preferred.map(\.id) == [2])
        #expect(messages.isEmpty)
        #expect(WizardEngine.podcastScenes([unrelated], log: { _ in }).isEmpty)
    }

    @Test("podcast cache bypasses detection and the shared manual/batch route preserves language")
    func podcastCacheAndManualRouting() async throws {
        let temp = try TempDatabase()
        let id = try await temp.seedVideo(sceneCount: 0)
        var video = try #require(try await temp.database.fetchVideos().first)
        video.videoType = "podcast"
        // Deliberately not media: a cache hit must never try FFmpeg or Speech.
        try Data("cached podcast fixture".utf8).write(to: video.url)
        let directory = try TempDirectory()
        let service = TranscriptionService(cacheDirectory: directory.url)
        let hash = String(try ContentHash.fingerprint(of: video.url).prefix(32))
        let cached = TranscriptionService.CachedTranscript(
            provider: "apple", model: "SpeechTranscriber", language: "pt", detectedLanguage: "pt-BR",
            translate: false, segments: [TranscriptSegment(start: 0, end: 4, text: "Uma conversa", words: nil)])
        let cacheURL = directory.url.appendingPathComponent("\(hash).apple.SpeechTranscriber.pt.json")
        try JSONEncoder().encode(cached).write(to: cacheURL)
        // A corrupt earlier entry cannot hide a valid cache in another language.
        try Data("invalid".utf8).write(to: directory.url.appendingPathComponent("\(hash).apple.SpeechTranscriber.en.json"))
        let result = try await service.transcribeForVideo(video: video, database: temp.database, log: { _ in })
        #expect(result.map(\.text) == ["Uma conversa"])
        let persisted = try await temp.database.fetchTranscripts(videoID: id)
        #expect(persisted.first?.language == "pt-BR")
        // Corrections survive the next cache hit: the stored rows are the transcript.
        let row = try #require(persisted.first)
        try await temp.database.setTranscriptSpeaker(ids: [row.id], speaker: .person(key: "ann"))
        try await temp.database.updateTranscriptText(id: row.id, text: "Uma conversa boa")
        let again = try await service.transcribeForVideo(video: video, database: temp.database, log: { _ in })
        #expect(again.map(\.text) == ["Uma conversa boa"])
        let kept = try await temp.database.fetchTranscripts(videoID: id)
        #expect(kept.count == 1 && kept.first?.speakerKey == "ann" && kept.first?.originalText == "Uma conversa")
        #expect(try await service.cachedPodcast(video: video, force: true) == nil)
        try FileManager.default.removeItem(at: cacheURL)
        #expect(try await service.cachedPodcast(video: video, force: false) == nil)
    }

    @Test("ambiguous picture cannot override confident audio but clear or stronger picture can")
    func pictureConfidenceThreshold() {
        let cases: [(Double, Double, PodcastSpeakerSide)] = [
            (0.55, 0.9, .left), (0.69, 0.9, .left), (0.7, 0.9, .right), (0.6, 0.5, .right),
        ]
        for (pictureConfidence, audioConfidence, expected) in cases {
            let audio = [SpeakerTurn(videoID: 1, start: 0, end: 5, cluster: 0,
                                     confidence: audioConfidence, resolvedSide: .left)]
            let picture = [PictureTalkerSignal(start: 0, end: 5, side: .right, confidence: pictureConfidence)]
            let result = PodcastSpeakerTimelineResolver.resolve(audioTurns: audio, picture: picture,
                                                                 layout: .splitHorizontal, roster: [], minimumHold: 1.5)
            #expect(result.first?.resolvedSide == expected)
        }
    }

    @Test("source dimensions flow through database into aspect-aware Wizard windows")
    func splitFeedSourceDimensions() async throws {
        let temp = try TempDatabase()
        _ = try await temp.seedVideo()
        let stored = try #require(try await temp.database.fetchScenes().first)
        #expect(stored.videoWidth == 1920)
        #expect(stored.videoHeight == 1080)
        for (width, height) in [(1920, 1080), (1440, 1080), (2560, 1080)] {
            var scene = Fixtures.scene(start: 0, end: 10)
            scene.tags = ["podcast", "podcast:split"]
            scene.videoWidth = width
            scene.videoHeight = height
            let document = WizardEngine.timelineDocument(
                from: Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 10)]),
                sceneMap: [scene.id: scene], podcastFraming: .splitZoom)
            let expectedHeight = min(1, 0.5 * Double(width) / Double(height) / 1.125)
            let left = try #require(document.videoTrack.first?.areaWindow)
            #expect(abs(left.hFrac - expectedHeight) < 0.00001)
            #expect(abs(left.yFrac - (1 - expectedHeight) / 2) < 0.00001)
            #expect(document.videoTrack[1].areaWindow?.hFrac == left.hFrac)
        }
    }

    @MainActor
    @Test("Builder and Wizard use identical split-feed source windows")
    func builderSplitFeedWindows() throws {
        let model = BuilderTimelineModel()
        defer { model.cancelPendingAutosave() }
        for aspect in [16.0 / 9.0, 4.0 / 3.0, 21.0 / 9.0] {
            let clip = Fixtures.timelineClip()
            model.loadDocument(Fixtures.timelineDocument(clips: [clip]))
            model.splitZoomFeeds(clip.uid, leftName: "Host", rightName: "Guest", sourceAspect: aspect)
            let windows = PodcastFramingService.splitFeedWindows(sourceAspect: aspect)
            #expect(model.document.videoTrack.count == 2)
            #expect(model.document.videoTrack[0].areaWindow == windows.left)
            #expect(model.document.videoTrack[1].areaWindow == windows.right)
            #expect(model.document.videoTrack[1].muted)
        }
    }

    @Test("split-feed windows follow source aspect and remain inside their source halves")
    func splitFeedWindowGeometry() {
        for aspect in [16.0 / 9.0, 4.0 / 3.0, 21.0 / 9.0] {
            let windows = PodcastFramingService.splitFeedWindows(sourceAspect: aspect)
            let height = min(1, 0.5 * aspect / 1.125)
            #expect(abs(windows.left.hFrac - height) < 0.00001)
            #expect(abs(windows.left.yFrac - (1 - height) / 2) < 0.00001)
            #expect(windows.left.xFrac == 0)
            #expect(windows.right.xFrac == 0.5)
            #expect(windows.left.wFrac == 0.5)
            #expect(windows.right.wFrac == 0.5)
            #expect(windows.left.hFrac == windows.right.hFrac)
        }
    }


    @Test("a topic holding two or more exchanges becomes a chapter spanning exactly those exchanges")
    func chapters() {
        func exchange(_ start: Double, _ end: Double, _ title: String, _ keys: [String], score: Double = 5) -> PodcastExchange {
            PodcastExchange(start: start, end: end, title: title, summary: "", score: score, speakerKeys: keys)
        }
        let exchanges = [exchange(0, 30, "Origins", ["ann"], score: 4), exchange(30, 55, "The move", ["ann", "bob"], score: 8),
                         exchange(60, 100, "The fight", ["bob"]), exchange(100, 130, "Aftermath", ["bob"])]
        let topics = [TopicRange(id: 1, videoID: 1, title: "Where it started", startTime: 0, endTime: 58, summary: "", speakerKeys: []),
                      TopicRange(id: 2, videoID: 1, title: "Lonely", startTime: 58, endTime: 99, summary: "", speakerKeys: []),
                      TopicRange(id: 3, videoID: 1, title: "Tail", startTime: 99, endTime: 200, summary: "", speakerKeys: [])]
        let chapters = PodcastAnalysisService.chapters(topics: topics, exchanges: exchanges)
        #expect(chapters.count == 1)
        let first = try! #require(chapters.first)
        #expect(first.start == 0 && first.end == 55)
        #expect(first.title == "Where it started")
        #expect(first.exchanges.map(\.title) == ["Origins", "The move"])
        #expect(first.speakerKeys == ["ann", "bob"])
        #expect(first.score == 6)
        #expect(first.narrative == "Where it started — Origins · The move")
        let tags = PodcastAnalysisService.chapterTagRanges(chapters)
        #expect(tags["chapter"]?.count == 1 && tags["podcast"]?.count == 1)
        #expect(Set(tags.keys) == ["chapter", "podcast", "person:ann", "person:bob"])

        // A chapter never stacks with the exchange it starts on.
        var chapterScene = Fixtures.scene(id: 10, start: 0, end: 55); chapterScene.tags = ["podcast", "chapter"]
        var beat = Fixtures.scene(id: 11, start: 0, end: 30); beat.tags = ["podcast", "q&a"]
        let stacks = SceneStacks.group([chapterScene, beat], level: .standard)
        #expect(stacks.count == 2)
    }
}
