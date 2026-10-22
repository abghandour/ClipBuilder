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

    /// Interview focus only. When the recording's one VIP has a portrait that
    /// lands on no feed (an analysis from before portraits were snapped to
    /// faces can cover the whole frame), the VIP is placed on the feed that
    /// speaks longest: interviewees answer at length, interviewers ask briefly.
    /// Feeds already named for someone else are never taken.
    static func placingUnplacedVIP(_ tiles: [PodcastTile], roster: [VideoPersonRecord],
                                   turns: [SpeakerTurn]) -> (tiles: [PodcastTile], note: String?) {
        guard Self.tiles(tiles, roster: roster).isEmpty, tiles.count >= 2 else { return (tiles, nil) }
        let vips = roster.filter(\.isVIP)
        guard vips.count == 1, let vip = vips.first else { return (tiles, nil) }
        var speech: [Int: Double] = [:]
        for turn in turns where turn.end > turn.start {
            guard let index = CropRecipePlanner.tile(for: turn, tiles: tiles) else { continue }
            speech[index, default: 0] += turn.end - turn.start
        }
        let free = tiles.filter { $0.personKey == nil || $0.personKey == vip.key }
        guard let chosen = free.max(by: { speech[$0.index, default: 0] < speech[$1.index, default: 0] }),
              speech[chosen.index, default: 0] > 0 else { return (tiles, nil) }
        let placed = tiles.map { tile in
            var tile = tile
            if tile.index == chosen.index { tile.personKey = vip.key }
            return tile
        }
        let name = vip.name.isEmpty ? vip.key : vip.name
        return (placed, "Interview focus: the portrait of \(name) lands on no feed; placing them on the feed "
            + "that speaks longest (\(Int(speech[chosen.index, default: 0].rounded())) s)")
    }

    /// Two people, two feeds, one feed still unnamed and one roster person
    /// on no feed: that feed is theirs. Lets the interviewer get a name tag
    /// when their portrait, like the VIP's, lands nowhere.
    static func namingLastFreeFeed(_ tiles: [PodcastTile], roster: [VideoPersonRecord]) -> [PodcastTile] {
        let free = tiles.filter { $0.personKey == nil }
        let placed = Set(tiles.compactMap(\.personKey))
        let left = roster.filter { !placed.contains($0.key) }
        guard free.count == 1, left.count == 1, tiles.count == roster.count, let feed = free.first, let person = left.first
        else { return tiles }
        return tiles.map { tile in
            var tile = tile
            if tile.index == feed.index { tile.personKey = person.key }
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
