import Foundation

nonisolated enum GazeAnalysis {
    static let passVersion = 1

    struct Region: Sendable {
        var tile: Int
        var personKey: String?
        var crop: FreeCropRect?
    }

    struct TileResult: Sendable {
        var tile: Int
        var personKey: String?
        var spans: [GazeMeter.Span]
    }

    static func supports(_ video: VideoRecord) -> Bool {
        video.type == .interview || video.type == .podcast
    }

    static func usesSeparateFeeds(_ video: VideoRecord) -> Bool {
        video.podcastTiles.count > 1 || video.podcastLayout == PodcastLayout.splitHorizontal.rawValue
            || video.podcastLayout == PodcastLayout.grid.rawValue
    }

    static func regions(_ video: VideoRecord) throws -> [Region] {
        guard usesSeparateFeeds(video) else { return [Region(tile: 0, personKey: nil, crop: nil)] }
        var tiles = video.podcastTiles
        // Older side-by-side analyses stored only the seam, before PodcastTile.
        if tiles.isEmpty, video.podcastLayout == PodcastLayout.splitHorizontal.rawValue {
            let seam = min(0.99, max(0.01, video.podcastSeamX ?? 0.5))
            tiles = [.init(index: 0, x: 0, y: 0, w: seam, h: 1),
                     .init(index: 1, x: seam, y: 0, w: 1 - seam, h: 1)]
        }
        guard !tiles.isEmpty else { throw ScriptError.invalid("Analyze the recording's feed layout before measuring gaze.") }
        return tiles.sorted { $0.index < $1.index }.map {
            Region(tile: $0.index, personKey: $0.personKey,
                   crop: FreeCropRect(xFrac: $0.x, yFrac: $0.y, wFrac: $0.w, hFrac: $0.h))
        }
    }

    /// Only numeric samples accumulate, one tile at a time. Decoded images and
    /// Vision requests are bounded to a 60-second chunk and released by measure.
    @concurrent static func measure(video: VideoRecord, log: @escaping @Sendable (String) -> Void) async throws -> [TileResult] {
        guard supports(video), video.duration.isFinite, video.duration > 0 else {
            throw ScriptError.invalid("Gaze needs an interview or podcast recording with a known duration.")
        }
        try video.requirePresent()
        let regions = try regions(video)
        var results: [TileResult] = []
        for (index, region) in regions.enumerated() {
            var samples: [GazeMeter.Sample] = []
            var start = 0.0
            while start < video.duration {
                try Task.checkCancellation()
                let end = min(video.duration, start + 60)
                log("Measuring gaze · tile \(index + 1)/\(regions.count) · \(Int(start))/\(Int(video.duration)) s")
                samples += try await GazeMeter.measure(url: video.url, range: start...end, region: region.crop, fps: 5)
                try Task.checkCancellation()
                start = end
                log("PROGRESS:\((Double(index) + start / video.duration) / Double(regions.count))")
            }
            let spans = GazeMeter.spans(samples)
            try Task.checkCancellation()
            results.append(TileResult(tile: region.tile, personKey: region.personKey, spans: spans))
        }
        return results
    }
}
