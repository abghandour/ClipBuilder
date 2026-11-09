import Testing
@testable import Clip_Builder

struct FramingTranscriptionTests {
    @Test("Stored feeds keep the turns of the transcription that measured them")
    func feedsKeepTheirTranscription() {
        #expect(FramingTranscription.key(tilesKey: "feeds", hasStoredFeeds: true,
                                         keysWithTurns: ["feeds", "active"], activeKey: "active") == "feeds")
    }

    @Test("Matching keys read the active transcription")
    func matchingKeys() {
        #expect(FramingTranscription.key(tilesKey: "active", hasStoredFeeds: true,
                                         keysWithTurns: ["active"], activeKey: "active") == "active")
    }

    @Test("Feeds whose transcription lost its turns fall back to the active one")
    func missingTurnsFallBack() {
        #expect(FramingTranscription.key(tilesKey: "gone", hasStoredFeeds: true,
                                         keysWithTurns: ["active"], activeKey: "active") == "active")
    }

    @Test("No stored feeds or no feeds key reads the active transcription")
    func noFeeds() {
        #expect(FramingTranscription.key(tilesKey: "feeds", hasStoredFeeds: false,
                                         keysWithTurns: ["feeds"], activeKey: "active") == "active")
        #expect(FramingTranscription.key(tilesKey: nil, hasStoredFeeds: true,
                                         keysWithTurns: ["active"], activeKey: "active") == "active")
        #expect(FramingTranscription.key(tilesKey: nil, hasStoredFeeds: false,
                                         keysWithTurns: [], activeKey: nil) == nil)
    }

    private let tiles = [
        PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "alice"),
        PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "marcello"),
    ]

    private func turn(_ start: Double, _ end: Double, tile: Int?, key: String?, cluster: Int = 0) -> SpeakerTurn {
        var turn = SpeakerTurn(videoID: 1, start: start, end: end, cluster: cluster, confidence: 0.8)
        turn.tile = tile
        turn.personKey = key
        return turn
    }

    private func row(_ start: Double, _ end: Double, speakerKey: String?) -> TranscriptRow {
        TranscriptRow(id: 1, videoID: 1, language: "pt", isTranslation: false, startTime: start, endTime: end,
                      text: "…", originalText: nil, wordsJSON: nil, provider: "apple", model: "SpeechTranscriber",
                      speakerKey: speakerKey)
    }

    @Test("A renamed turn frames the named person's tile, not the tracker's old tile index")
    func nameBeatsStaleTileIndex() {
        // The tracker heard Alice in Marcello's tile; the Speakers menu fixed the name only.
        let fixed = turn(0, 10, tile: 1, key: "alice")
        #expect(CropRecipePlanner.tile(for: fixed, tiles: tiles) == 0)
        #expect(SpeakerSpotlight.tile(for: fixed, in: tiles)?.index == 0)
        let unnamed = turn(0, 10, tile: 1, key: nil)
        #expect(CropRecipePlanner.tile(for: unnamed, tiles: tiles) == 1)
        let outsider = turn(0, 10, tile: 1, key: "guest")
        #expect(CropRecipePlanner.tile(for: outsider, tiles: tiles) == 1)
    }

    @Test("Lines attributed by hand replace the turns under them; Unknown leaves a gap")
    func handAttributionsOverlayTurns() {
        let turns = [turn(0, 10, tile: 1, key: "marcello", cluster: 1), turn(10, 20, tile: 0, key: "alice")]
        let rows = [row(2, 6, speakerKey: "alice"), row(12, 14, speakerKey: ""), row(15, 18, speakerKey: nil)]
        let result = FramingTranscription.attributed(turns, rows: rows)
        #expect(result.map(\.start) == [0, 2, 6, 10, 14])
        #expect(result.map(\.end) == [2, 6, 10, 12, 20])
        #expect(result.map(\.personKey) == ["marcello", "alice", "marcello", "alice", "alice"])
        #expect(result[1].tile == 0 && result[1].cluster == 0)
        #expect(CropRecipePlanner.tile(for: result[1], tiles: tiles) == 0)
        #expect(FramingTranscription.attributed(turns, rows: [row(0, 5, speakerKey: nil)]) == turns)
    }

    @Test("An attributed line borrows the person's own side and tile, so unnamed feeds still resolve")
    func attributedLineKeepsSpatialEvidence() throws {
        var alice = turn(20, 30, tile: nil, key: "alice")
        alice.resolvedSide = .right
        let turns = [turn(0, 10, tile: nil, key: "bob"), alice]
        let result = FramingTranscription.attributed(turns, rows: [row(2, 6, speakerKey: "alice")])
        let line = try #require(result.first { $0.start == 2 })
        #expect(line.resolvedSide == .right && line.personKey == "alice")
        let unnamed = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1), PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        #expect(CropRecipePlanner.tile(for: line, tiles: unnamed) == 1)
    }

    @Test("A run of short attributed lines becomes one turn that focus does not drop")
    func shortAttributedLinesJoin() {
        let turns = [turn(0, 5, tile: 0, key: "alice"), turn(5, 7.4, tile: 0, key: "alice"), turn(9, 12, tile: 1, key: "bob")]
        let rows = [row(5, 5.8, speakerKey: "bob"), row(5.8, 6.6, speakerKey: "bob"), row(6.6, 7.4, speakerKey: "bob")]
        let result = FramingTranscription.attributed(turns, rows: rows)
        #expect(result.map(\.personKey) == ["alice", "bob", "bob"])
        #expect(result[1].start == 5 && result[1].end == 7.4 && result[1].tile == 1)
        let segments = CropRecipePlanner.segments(turns: result, tiles: tiles, range: 0...12, hold: 0)
        #expect(segments.map(\.talker) == [0, 1])
    }
}
