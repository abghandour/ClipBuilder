import Foundation

/// What one file taught about one person's voice: the unit centroid of the
/// neural voice embedding over the windows the speaker map trusted for
/// their tile, and how many windows stand behind it. Kept per file so a
/// re-map replaces that file's contribution instead of compounding it.
nonisolated struct VoiceProfile: Codable, Sendable, Equatable {
    var personKey: String
    var videoID: Int64
    var vector: [Double]
    var windows: Int
    /// Windows the user's own attributions contributed.
    var correctionWindows: Int = 0
}

/// Voices remembered across files. A finished map stores a profile per
/// named tile; the next map seeds its enrollment with the people in the
/// tiles, and names a tile the face pass left unnamed when its voice is
/// one the app already knows.
nonisolated enum VoiceProfiles {
    /// The audio has to be trusted this much before a file's profiles are
    /// worth remembering.
    static let storeTrust = 0.8
    /// A tile is named by voice when the nearest remembered person is at
    /// least this close (the clustering merge threshold) and clearly ahead
    /// of the runner-up.
    static let nameCosine = 0.45
    static let nameMargin = 0.1

    struct Voice: Sendable, Equatable {
        var vector: [Double]
        var windows: Int
    }

    /// One voice per person across files: the window-weighted mean of the
    /// stored centroids, unit length. Vectors of different dimensions
    /// (an older model) are left out.
    static func combined(_ profiles: [VoiceProfile]) -> [String: Voice] {
        var sums: [String: (vector: [Double], windows: Int)] = [:]
        for profile in profiles where profile.windows > 0 && !profile.vector.isEmpty {
            if var current = sums[profile.personKey] {
                guard current.vector.count == profile.vector.count else { continue }
                for i in current.vector.indices { current.vector[i] += profile.vector[i] * Double(profile.windows) }
                current.windows += profile.windows
                sums[profile.personKey] = current
            } else {
                sums[profile.personKey] = (profile.vector.map { $0 * Double(profile.windows) }, profile.windows)
            }
        }
        return sums.mapValues { Voice(vector: SpeakerClustering.normalized($0.vector), windows: $0.windows) }
    }

    /// The tracker's priors: the remembered voice of each person sitting in
    /// a tile, keyed by the tile's index.
    static func priors(tiles: [PodcastTile], voices: [String: Voice]) -> [SpeakerTracker.Prior] {
        tiles.compactMap { tile in
            guard let key = tile.personKey, let voice = voices[key] else { return nil }
            return SpeakerTracker.Prior(slot: tile.index, vector: voice.vector, windows: voice.windows)
        }
    }

    /// What a finished map teaches: the file's own centroid for every named
    /// tile, when the voices were neural and trusted. Empty otherwise, so
    /// the file's earlier profiles are dropped rather than kept stale.
    static func learned(videoID: Int64, tiles: [PodcastTile], enrollment: SpeakerTracker.Enrollment?) -> [VoiceProfile] {
        guard let enrollment, enrollment.featureKind == .embedding, enrollment.trust >= storeTrust else { return [] }
        return tiles.compactMap { tile in
            guard let key = tile.personKey, let vector = enrollment.fileCentroids[tile.index] else { return nil }
            return VoiceProfile(personKey: key, videoID: videoID, vector: vector,
                                windows: enrollment.windowsPerSlot[tile.index] ?? 0,
                                correctionWindows: enrollment.correctionWindowsPerSlot[tile.index] ?? 0)
        }
    }

    struct Naming: Sendable, Equatable {
        var tile: Int
        var personKey: String
        var cosine: Double
    }

    /// Tiles the face pass left unnamed, named by the remembered voice
    /// nearest to what the file taught about the tile. People already
    /// sitting in another tile are not candidates, and each person names
    /// one tile at most.
    static func named(tiles: [PodcastTile], enrollment: SpeakerTracker.Enrollment?,
                      voices: [String: Voice]) -> (tiles: [PodcastTile], namings: [Naming]) {
        guard let enrollment, enrollment.featureKind == .embedding else { return (tiles, []) }
        var seated = Set(tiles.compactMap(\.personKey))
        var result = tiles
        var namings: [Naming] = []
        for (position, tile) in tiles.enumerated() where tile.personKey == nil {
            guard let vector = enrollment.fileCentroids[tile.index] else { continue }
            let ranked = voices.filter { !seated.contains($0.key) && $0.value.vector.count == vector.count }
                .map { (key: $0.key, cosine: SpeakerClustering.cosine(vector, $0.value.vector)) }
                .sorted { $0.cosine > $1.cosine }
            guard let best = ranked.first, best.cosine >= nameCosine,
                  best.cosine - (ranked.dropFirst().first?.cosine ?? -1) >= nameMargin else { continue }
            result[position].personKey = best.key
            seated.insert(best.key)
            namings.append(Naming(tile: tile.index, personKey: best.key, cosine: best.cosine))
        }
        return (result, namings)
    }
}
