import Foundation

nonisolated enum VIPRecipePlanning {
    /// Portrait-derived columns in a single camera are not independent live reaction feeds.
    static func recordedFeeds(video: VideoRecord, roster: [VideoPersonRecord]) -> [PodcastTile] {
        guard video.podcastTiles.count >= 2 || video.podcastLayout == PodcastLayout.splitHorizontal.rawValue else { return [] }
        return namedTiles(CropRecipePlanner.tiles(video: video, roster: roster), roster: roster)
    }

    static func namedTiles(_ tiles: [PodcastTile], roster: [VideoPersonRecord]) -> [PodcastTile] {
        tiles.map { tile in
            var tile = tile
            if tile.personKey == nil {
                tile.personKey = roster.first { person in
                    guard let box = person.portraitBox else { return false }
                    return tile.contains(x: box.x + box.w / 2, y: box.y + box.h / 2)
                }?.key
            }
            return tile
        }
    }

    static func tiles(_ tiles: [PodcastTile], roster: [VideoPersonRecord]) -> [PodcastTile] {
        let people = roster.filter(\.isVIP)
        return tiles.filter { tile in
            people.contains { person in
                if tile.personKey == person.key { return true }
                guard let box = person.portraitBox else { return false }
                return tile.contains(x: box.x + box.w / 2, y: box.y + box.h / 2)
            }
        }.sorted { $0.index < $1.index }
    }

    static func events(segments: [CropRecipePlanner.Segment], tiles: [PodcastTile],
                       roster: [VideoPersonRecord], turns: [SpeakerTurn], start: Double, end: Double? = nil)
        -> [(time: Double, tile: Int?)] {
        let vipTiles = Self.tiles(tiles, roster: roster)
        let indices = Set(vipTiles.map(\.index))
        guard !vipTiles.isEmpty else { return segments.map { ($0.start, $0.talker) } }
        let recent = turns.filter { $0.end <= start }
            .sorted { $0.end > $1.end }
            .compactMap { CropRecipePlanner.tile(for: $0, tiles: tiles) }
            .first { indices.contains($0) }
        let end = end ?? segments.map(\.end).max() ?? start
        return VIPRotation.shots(range: start...max(start, end), segments: segments,
                                 vipTiles: vipTiles.map(\.index), recentFirst: recent)
            .map { ($0.time, $0.tile) }
    }
}
