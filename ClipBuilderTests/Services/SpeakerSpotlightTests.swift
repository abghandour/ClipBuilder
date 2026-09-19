import Foundation
import Testing
@testable import Clip_Builder

@Suite("Speaker spotlight")
struct SpeakerSpotlightTests {
    private let tiles = [
        PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 0.5, personKey: "marcello"),
        PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 0.5, personKey: "thiago",
                    pictureX: 0.55, pictureY: 0.05, pictureW: 0.4, pictureH: 0.4),
        PodcastTile(index: 2, x: 0, y: 0.5, w: 0.5, h: 0.5),
    ]
    private let roster = [
        VideoPersonRecord(videoID: 1, personID: 1, key: "marcello", name: "Marcello", descriptor: "", portraitAt: 0),
        VideoPersonRecord(videoID: 1, personID: 2, key: "thiago", name: "Thiago", descriptor: "", portraitAt: 0),
    ]

    private func turn(_ start: Double, _ end: Double, tile: Int? = nil, key: String? = nil,
                      cluster: Int = 0, side: PodcastSpeakerSide = .unknown) -> SpeakerTurn {
        var turn = SpeakerTurn(videoID: 1, start: start, end: end, cluster: cluster, confidence: 1)
        turn.tile = tile
        turn.personKey = key
        turn.resolvedSide = side
        return turn
    }

    private func row(_ start: Double, _ end: Double, speakerKey: String? = nil) -> TranscriptRow {
        TranscriptRow(id: 1, videoID: 1, language: "pt", isTranslation: false, startTime: start, endTime: end,
                      text: "…", originalText: nil, wordsJSON: nil, provider: "apple", model: "SpeechTranscriber",
                      speakerKey: speakerKey)
    }

    @Test("the turn covering the moment lights its tile, trimmed to the picture, named after the person")
    func tileFromTurn() {
        let turns = [turn(0, 10, tile: 0, key: "marcello"), turn(10, 20, tile: 1, key: "thiago")]
        let first = SpeakerSpotlight.at(5, tiles: tiles, layout: .grid, seamX: nil, turns: turns, roster: roster)
        #expect(first == SpeakerSpotlight(x: 0, y: 0, w: 0.5, h: 0.5, label: "Marcello"))
        let second = SpeakerSpotlight.at(12, tiles: tiles, layout: .grid, seamX: nil, turns: turns, roster: roster)
        #expect(second == SpeakerSpotlight(x: 0.55, y: 0.05, w: 0.4, h: 0.4, label: "Thiago"))
        #expect(SpeakerSpotlight.at(25, tiles: tiles, layout: .grid, seamX: nil, turns: turns, roster: roster) == nil)
    }

    @Test("a turn without a tile finds the person's cell; a bare tile or cluster is named as a feed or speaker")
    func fallbacks() {
        let byPerson = SpeakerSpotlight.at(1, tiles: tiles, layout: .grid, seamX: nil,
                                           turns: [turn(0, 5, key: "thiago")], roster: roster)
        #expect(byPerson?.x == 0.55 && byPerson?.label == "Thiago")
        let bareTile = SpeakerSpotlight.at(1, tiles: tiles, layout: .grid, seamX: nil,
                                           turns: [turn(0, 5, tile: 2)], roster: roster)
        #expect(bareTile == SpeakerSpotlight(x: 0, y: 0.5, w: 0.5, h: 0.5, label: "Feed 3"))
        let voiceOnly = SpeakerSpotlight.at(1, tiles: tiles, layout: .grid, seamX: nil,
                                            turns: [turn(0, 5, cluster: 1)], roster: roster)
        #expect(voiceOnly == nil)
        #expect(SpeakerSpotlight.name(for: turn(0, 5, cluster: 1), roster: roster, people: []) == "Speaker 2")
    }

    @Test("the line's manual attribution wins over the turn, and Unknown switches the outline off")
    func manualAttribution() {
        let turns = [turn(0, 10, tile: 0, key: "marcello")]
        let corrected = SpeakerSpotlight.at(5, tiles: tiles, layout: .grid, seamX: nil, turns: turns, roster: roster,
                                            row: row(0, 10, speakerKey: "thiago"))
        #expect(corrected?.label == "Thiago" && corrected?.x == 0.55)
        let unknown = SpeakerSpotlight.at(5, tiles: tiles, layout: .grid, seamX: nil, turns: turns, roster: roster,
                                          row: row(0, 10, speakerKey: ""))
        #expect(unknown == nil)
        // A person without a cell falls back to the turn's tile.
        let noCell = SpeakerSpotlight.at(5, tiles: tiles, layout: .grid, seamX: nil, turns: turns, roster: roster,
                                         row: row(0, 10, speakerKey: "guest"))
        #expect(noCell == SpeakerSpotlight(x: 0, y: 0, w: 0.5, h: 0.5, label: "Marcello"))
    }

    @Test("side by side lights the resolved side of the seam; single camera lights nothing")
    func sides() {
        let left = SpeakerSpotlight.at(1, tiles: [], layout: .splitHorizontal, seamX: 0.6,
                                       turns: [turn(0, 5, key: "marcello", side: .left)], roster: roster)
        #expect(left == SpeakerSpotlight(x: 0, y: 0, w: 0.6, h: 1, label: "Marcello"))
        let right = SpeakerSpotlight.at(1, tiles: [], layout: .splitHorizontal, seamX: 0.6,
                                        turns: [turn(0, 5, key: "thiago", side: .right)], roster: roster)
        #expect(right?.x == 0.6 && right?.label == "Thiago")
        #expect(SpeakerSpotlight.at(1, tiles: [], layout: .singleCamera, seamX: nil,
                                    turns: [turn(0, 5, key: "thiago")], roster: roster) == nil)
    }

    @Test("overlapping turns: the most recent handover wins")
    func overlap() {
        let turns = [turn(0, 10, tile: 0, key: "marcello"), turn(6, 8, tile: 1, key: "thiago")]
        #expect(SpeakerSpotlight.turn(at: 7, in: turns)?.personKey == "thiago")
        #expect(SpeakerSpotlight.turn(at: 9, in: turns)?.personKey == "marcello")
    }
}
