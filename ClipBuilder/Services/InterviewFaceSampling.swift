import CoreGraphics
import Foundation

/// Fresh face boxes for Interview focus. The planner frames from the roster's
/// portrait boxes, which were measured once, often minutes away from the
/// clip; before an Interview focus plan is built the roster is refined with
/// faces seen at the shot starts the plan will use. The maths here is pure;
/// `refinedRoster` is the only piece that decodes frames, one per sample.
nonisolated enum InterviewFaceSampling {
    static let maximumSamples = 6

    /// Source times to look at: the range start and every planned move,
    /// thinned evenly to `maximumSamples`.
    static func sampleTimes(video: VideoRecord, range: ClosedRange<Double>, turns: [SpeakerTurn],
                            roster: [VideoPersonRecord], limit: Int = maximumSamples,
                            punchIn: InterviewPunchIn = .vip, cuts: Bool = false) -> [Double] {
        guard range.upperBound > range.lowerBound else { return [] }
        var tiles = feedTiles(video: video, roster: roster, turns: turns)
        if tiles.isEmpty { tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 1, h: 1)] }
        let vipTiles = VIPRecipePlanning.tiles(tiles, roster: roster).map(\.index)
        let hold = max(CropRecipe(kind: .interview).minimumHold, VIPRotation.minimumHold)
        let segments = CropRecipePlanner.segments(turns: turns, tiles: tiles, range: range, hold: hold,
            fillOpening: punchIn == .vip)
        let moves = InterviewFocusPlanning.moves(segments: segments, vipTiles: vipTiles, range: range, hold: hold, punchIn: punchIn)
        // The first shot settles a moment after the range starts; a move's
        // shot is in place once its ramp has finished.
        var times = [min(range.upperBound, range.lowerBound + 0.1)]
            + moves.dropFirst().map { min(range.upperBound, $0.time + (cuts ? 0 : InterviewFocusPlanning.moveSeconds)) }
        times = Array(Set(times)).sorted()
        return thinned(times, limit: limit)
    }

    /// The planner's feed naming, including the speech fallback for a VIP
    /// whose portrait lands nowhere, so the sampled face lands on the same feed.
    static func feedTiles(video: VideoRecord, roster: [VideoPersonRecord], turns: [SpeakerTurn]) -> [PodcastTile] {
        let named = VIPRecipePlanning.namedTiles(CropRecipePlanner.tiles(video: video, roster: roster), roster: roster)
        let placed = VIPRecipePlanning.placingUnplacedVIP(named, roster: roster, turns: turns).tiles
        return VIPRecipePlanning.namingLastFreeFeed(placed, roster: roster)
    }

    /// Every `limit`-th pick spread over the list, first and last kept.
    static func thinned(_ times: [Double], limit: Int) -> [Double] {
        guard limit > 0, times.count > limit else { return times }
        guard limit > 1 else { return [times[0]] }
        return (0..<limit).map { times[Int((Double($0) * Double(times.count - 1) / Double(limit - 1)).rounded())] }
    }

    /// The mean box of the faces seen; nil without any.
    static func merged(_ boxes: [CGRect]) -> CGRect? {
        let boxes = boxes.filter { !$0.isNull && !$0.isEmpty && $0.width.isFinite && $0.height.isFinite }
        guard !boxes.isEmpty else { return nil }
        let count = Double(boxes.count)
        return CGRect(x: boxes.map(\.minX).reduce(0, +) / count, y: boxes.map(\.minY).reduce(0, +) / count,
                      width: boxes.map(\.width).reduce(0, +) / count, height: boxes.map(\.height).reduce(0, +) / count)
    }

    /// The roster with each feed person's portrait replaced by the faces seen
    /// at `times` inside their feed. People whose feed is unknown, and feeds
    /// where no face is seen, keep their portrait.
    static func applying(faces: [String: CGRect], at time: Double, to roster: [VideoPersonRecord]) -> [VideoPersonRecord] {
        roster.map { person in
            guard let face = faces[person.key] else { return person }
            var person = person
            person.portraitBox = .init(x: face.minX, y: face.minY, w: face.width, h: face.height)
            person.portraitAt = time
            return person
        }
    }

    /// Sample the shot starts of `range` and return the refined roster.
    static func refinedRoster(video: VideoRecord, roster: [VideoPersonRecord], range: ClosedRange<Double>,
                              turns: [SpeakerTurn], punchIn: InterviewPunchIn = .vip, cuts: Bool = false,
                              log: @escaping @Sendable (String) -> Void) async -> [VideoPersonRecord] {
        guard video.isPresent, roster.count >= 2 else { return roster }
        let tiles = feedTiles(video: video, roster: roster, turns: turns)
        let feeds = tiles.filter { $0.personKey != nil }
        guard !feeds.isEmpty else {
            log("Interview focus: no feed is linked to a person; keeping the roster portraits")
            return roster
        }
        let times = sampleTimes(video: video, range: range, turns: turns, roster: roster, punchIn: punchIn, cuts: cuts)
        guard let first = times.first else { return roster }
        var faces: [String: CGRect] = [:]
        for tile in feeds {
            guard let key = tile.personKey else { continue }
            let picture = tile.picture
            let region = FreeCropRect(xFrac: picture.x, yFrac: picture.y, wFrac: picture.w, hFrac: picture.h)
            var seen: [CGRect] = []
            for time in times {
                if Task.isCancelled { return roster }
                if let face = try? await CenterStageService.faceCenter(source: video.url, at: time, region: region) {
                    seen.append(face)
                }
            }
            if let face = merged(seen) {
                faces[key] = face
                log("Interview focus: face of \(key) seen at \(seen.count) of \(times.count) shot starts")
            } else {
                log("Interview focus: no face seen for \(key) at \(times.count) shot starts; keeping the portrait")
            }
        }
        return applying(faces: faces, at: first, to: roster)
    }
}
