import Foundation

/// Where on the picture the speaker map says the talker is at a moment of
/// playback, for the preview player's outline. A line the user attributed
/// by hand wins; otherwise the turn covering the moment names a tile (grid
/// layouts), a side (side by side) or nothing (single camera). The outline
/// shows the stored map, not live detection, so a wrong outline is a wrong
/// map — the thing Map Speakers Again needs feedback on.
nonisolated struct SpeakerSpotlight: Equatable, Sendable {
    /// Normalized to the source frame, top-left origin.
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// The name in the outline's corner: the person, else the feed, else
    /// the voice cluster — the same words the transcript column uses.
    var label: String

    /// The spotlight at `time`. `row` is the transcript line being spoken,
    /// whose manual attribution overrides the turns; `tiles` empty means
    /// the layout has no cells, and `seamX` splits a side-by-side frame.
    static func at(_ time: Double, tiles: [PodcastTile], layout: PodcastLayout?, seamX: Double?,
                   turns: [SpeakerTurn], roster: [VideoPersonRecord], people: [PersonRecord] = [],
                   row: TranscriptRow? = nil) -> SpeakerSpotlight? {
        switch row?.speaker {
        case .unknown:
            return nil
        case .person(let key):
            if let tile = tiles.first(where: { $0.personKey == key }) {
                return spotlight(tile: tile, label: TranscriptSpeakers.name(forKey: key, roster: roster, people: people))
            }
            // The person has no cell of their own; fall back to the turn so
            // a side-by-side frame still lights the side it heard them on.
        case .automatic, nil:
            break
        }
        guard let turn = Self.turn(at: time, in: turns) else { return nil }
        let label = Self.name(for: turn, roster: roster, people: people)
        if !tiles.isEmpty {
            guard let tile = Self.tile(for: turn, in: tiles) else { return nil }
            return spotlight(tile: tile, label: label)
        }
        if layout == .splitHorizontal {
            let seam = min(max(seamX ?? 0.5, 0.05), 0.95)
            let side = turn.resolvedSide == .unknown ? turn.pictureSide : turn.resolvedSide
            switch side {
            case .left: return SpeakerSpotlight(x: 0, y: 0, w: seam, h: 1, label: label)
            case .right: return SpeakerSpotlight(x: seam, y: 0, w: 1 - seam, h: 1, label: label)
            case .full, .unknown: return nil
            }
        }
        return nil
    }

    /// The turn covering `time`; when turns overlap, the one that started
    /// last (the most recent handover).
    static func turn(at time: Double, in turns: [SpeakerTurn]) -> SpeakerTurn? {
        turns.filter { $0.start <= time && time < $0.end }.max { $0.start < $1.start }
    }

    /// The cell a turn points at: the tile it was seen in, else the tile of
    /// the person it names.
    static func tile(for turn: SpeakerTurn, in tiles: [PodcastTile]) -> PodcastTile? {
        if let index = turn.tile, let tile = tiles.first(where: { $0.index == index }) { return tile }
        if let key = turn.personKey { return tiles.first { $0.personKey == key } }
        return nil
    }

    static func name(for turn: SpeakerTurn, roster: [VideoPersonRecord], people: [PersonRecord]) -> String {
        if let key = turn.personKey { return TranscriptSpeakers.name(forKey: key, roster: roster, people: people) }
        if let tile = turn.tile { return "Feed \(tile + 1)" }
        return "Speaker \(turn.cluster + 1)"
    }

    private static func spotlight(tile: PodcastTile, label: String) -> SpeakerSpotlight {
        let picture = tile.picture
        return SpeakerSpotlight(x: picture.x, y: picture.y, w: picture.w, h: picture.h, label: label)
    }
}
