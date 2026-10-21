import Foundation

nonisolated enum VIPBRollWindows {
    /// Speech by non-VIPs, subtracting any overlapping VIP speech. Times stay on the source clock.
    static func windows(turns: [SpeakerTurn], vipKeys: Set<String>, range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        guard !vipKeys.isEmpty, range.upperBound > range.lowerBound else { return [] }
        let boundaries = Set([range.lowerBound, range.upperBound] + turns.flatMap {
            [max(range.lowerBound, min(range.upperBound, $0.start)),
             max(range.lowerBound, min(range.upperBound, $0.end))]
        }).sorted()
        let pieces = zip(boundaries, boundaries.dropFirst()).compactMap { start, end -> ClosedRange<Double>? in
            guard end > start else { return nil }
            let active = turns.filter { $0.start < end && $0.end > start }
            guard !active.isEmpty, !active.contains(where: { $0.personKey.map(vipKeys.contains) == true }) else { return nil }
            return start...end
        }
        return CropRecipePlanner.merged(pieces).filter { $0.upperBound - $0.lowerBound >= 2 }
    }

    /// Keep the VIP's live feed first. B-roll is needed only when no separate VIP feed is available.
    static func needingFootage(turns: [SpeakerTurn], roster: [VideoPersonRecord], tiles: [PodcastTile],
                               range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        let tiles = VIPRecipePlanning.namedTiles(tiles, roster: roster)
        let keys = Set(roster.filter(\.isVIP).map(\.key))
        let vipTiles = VIPRecipePlanning.tiles(tiles, roster: roster)
        let covered = turns.filter { turn in
            guard let talker = CropRecipePlanner.tile(for: turn, tiles: tiles) else { return false }
            return vipTiles.contains { $0.index != talker }
        }.map { turn -> SpeakerTurn in
            var turn = turn
            // Treat a live VIP feed as coverage, equivalent to VIP speech for window subtraction.
            turn.personKey = keys.sorted().first
            return turn
        }
        return windows(turns: turns + covered, vipKeys: keys, range: range)
    }
}
