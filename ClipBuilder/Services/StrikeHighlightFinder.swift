import CoreGraphics
import Foundation
import ImageIO
import Vision

/// The media half of `StrikeHighlightRules`: reads body poses from the
/// frames around a strike and returns the highlight track for it.
/// Nothing is stored; a track takes about a second to build and is rebuilt
/// when needed.
nonisolated enum StrikeHighlightFinder {
    /// Joints the detector is less sure of than this are treated as unseen.
    static let minConfidence: Float = 0.25

    private static let joints: [(HumanBodyPoseObservation.JointName, StrikeHighlightRules.Joint)] = [
        (.nose, .nose), (.neck, .neck), (.root, .root),
        (.leftShoulder, .leftShoulder), (.leftElbow, .leftElbow), (.leftWrist, .leftWrist),
        (.rightShoulder, .rightShoulder), (.rightElbow, .rightElbow), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.leftKnee, .leftKnee), (.leftAnkle, .leftAnkle),
        (.rightHip, .rightHip), (.rightKnee, .rightKnee), (.rightAnkle, .rightAnkle),
    ]

    /// What looking for one strike's highlight came to. `failed` means the
    /// frames could not be read or the pose detector errored: nothing is
    /// known, so nothing should be saved and it is worth trying again.
    enum Outcome: Sendable, Equatable {
        case found(StrikeHighlightRules.Track)
        case noMatch
        case failed

        var track: StrikeHighlightRules.Track? {
            if case .found(let track) = self { return track }
            return nil
        }

        func record(videoID: Int64, time: Double, fighterKey: String) -> StrikeHighlightRecord? {
            guard self != .failed else { return nil }
            return StrikeHighlightRecord(videoID: videoID, time: time, fighterKey: fighterKey, track: track)
        }
    }

    /// Poses already read, by frame number on the file-wide sampling grid.
    /// Strikes close together share most of their frames.
    nonisolated struct PoseCache: Sendable {
        var aspect: CGFloat = 0
        var poses: [Int: [StrikeHighlightRules.Pose]] = [:]

        static func index(_ time: Double) -> Int { Int((time / StrikeHighlightRules.step).rounded()) }

        /// Drops frames no later strike can need.
        mutating func forget(before time: Double) {
            let first = Self.index(time)
            poses = poses.filter { $0.key >= first }
        }
    }

    /// The highlight for a strike logged at `time` in the file at `url`.
    @concurrent
    static func find(url: URL, time: Double, detail: StrikeDetail?, duration: Double = .infinity) async -> Outcome {
        var cache = PoseCache()
        return await find(url: url, time: time, detail: detail, duration: duration, cache: &cache)
    }

    private static func find(url: URL, time: Double, detail: StrikeDetail?, duration: Double,
                             cache: inout PoseCache) async -> Outcome {
        // duration is the exclusive end of the file, not a decodable frame.
        let times = StrikeHighlightRules.sampleTimes(around: time, duration: duration).filter { $0 < duration }
        let missing = times.filter { cache.poses[PoseCache.index($0)] == nil }
        if !missing.isEmpty {
            let stills = await ThumbnailService.jpegFrames(url: url, at: missing, maxDimension: 960, tolerance: 0)
            for (time, jpeg) in zip(missing, stills) {
                guard !Task.isCancelled else { return .failed }
                // Missing in-bounds frames remain absent from the cache, so
                // this strike can be retried instead of caching a negative.
                guard let jpeg else { continue }
                if cache.aspect == 0 { cache.aspect = Self.aspect(jpeg) ?? 0 }
                guard let poses = await poses(jpeg) else { return .failed }
                cache.poses[PoseCache.index(time)] = poses
            }
        }
        return outcome(times: times, time: time, detail: detail, cache: cache)
    }

    static func outcome(times: [Double], time: Double, detail: StrikeDetail?, cache: PoseCache) -> Outcome {
        guard !times.isEmpty, times.allSatisfy({ cache.poses[PoseCache.index($0)] != nil }) else { return .failed }
        guard cache.aspect > 0 else { return .failed }
        let frames = times.compactMap { time in cache.poses[PoseCache.index(time)].map { (time: time, poses: $0) } }
        return StrikeHighlightRules.track(frames: frames, time: time, detail: detail, aspect: cache.aspect).map(Outcome.found) ?? .noMatch
    }

    /// The highlight of every strike among `events`, for saving with the
    /// video. A strike with no match still gets a record, so it is not
    /// searched for again; one whose frames could not be read gets none.
    @concurrent
    static func records(url: URL, videoID: Int64, events: [FightEventRecord], duration: Double) async -> [StrikeHighlightRecord] {
        var records: [StrikeHighlightRecord] = []
        var cache = PoseCache()
        for strike in StrikeStatsSummary.deduplicatedStrikes(events).sorted(by: { $0.time < $1.time })
        where strike.videoID == videoID {
            guard !Task.isCancelled else { break }
            cache.forget(before: strike.time - StrikeHighlightRules.lead - 0.5)
            let outcome = await find(url: url, time: strike.time, detail: StrikeDetail(strike.detail),
                                     duration: duration, cache: &cache)
            if let record = outcome.record(videoID: videoID, time: strike.time, fighterKey: strike.fighterKey) {
                records.append(record)
            }
        }
        return records
    }

    /// Every body in one still, joints in top-left 0…1 coordinates; nil
    /// when the detector could not run.
    static func poses(_ jpeg: Data) async -> [StrikeHighlightRules.Pose]? {
        guard let permit = try? await MediaWorkScheduler.current.acquire(.vision) else { return nil }
        defer { withExtendedLifetime(permit) {} }
        guard let observations = try? await DetectHumanBodyPoseRequest().perform(on: jpeg) else { return nil }
        let pixels = Pixels(jpeg)
        return observations.map { observation in
            let seen = observation.allJoints()
            var found: [StrikeHighlightRules.Joint: CGPoint] = [:]
            for (name, joint) in joints {
                guard let point = seen[name], point.confidence >= minConfidence else { continue }
                // Vision's origin is the bottom left.
                found[joint] = CGPoint(x: point.location.x, y: 1 - point.location.y)
            }
            return StrikeHighlightRules.Pose(joints: found, bare: pixels.flatMap { bareTorso(found, in: $0) })
        }
    }

    /// A still as RGBA bytes, for reading single pixels.
    private struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]

        init?(_ jpeg: Data) {
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            // A quarter of the still is plenty for torso colour.
            let width = max(2, image.width / 4), height = max(2, image.height / 4)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// Whether the pixel at a top-left 0…1 point is skin coloured, by
        /// its chroma: skin of every shade sits in one narrow band there.
        func isSkin(_ point: CGPoint) -> Bool? {
            let x = Int(point.x * CGFloat(width)), y = Int(point.y * CGFloat(height))
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let at = (y * width + x) * 4
            let r = Double(bytes[at]), g = Double(bytes[at + 1]), b = Double(bytes[at + 2])
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
            return luma > 40 && cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173
        }
    }

    /// The share of skin among points spread over the torso (shoulders to
    /// hips, away from its edges); nil when the torso is not all seen.
    private static func bareTorso(_ joints: [StrikeHighlightRules.Joint: CGPoint], in pixels: Pixels) -> CGFloat? {
        guard let leftShoulder = joints[.leftShoulder], let rightShoulder = joints[.rightShoulder],
              let leftHip = joints[.leftHip], let rightHip = joints[.rightHip] else { return nil }
        var skin = 0, read = 0
        for row in 1...6 {
            for column in 1...6 {
                let down = 0.1 + 0.6 * CGFloat(row) / 7, across = 0.15 + 0.7 * CGFloat(column) / 7
                let left = CGPoint(x: leftShoulder.x + (leftHip.x - leftShoulder.x) * down,
                                   y: leftShoulder.y + (leftHip.y - leftShoulder.y) * down)
                let right = CGPoint(x: rightShoulder.x + (rightHip.x - rightShoulder.x) * down,
                                    y: rightShoulder.y + (rightHip.y - rightShoulder.y) * down)
                guard let isSkin = pixels.isSkin(CGPoint(x: left.x + (right.x - left.x) * across,
                                                         y: left.y + (right.y - left.y) * across)) else { continue }
                read += 1
                if isSkin { skin += 1 }
            }
        }
        return read >= 12 ? CGFloat(skin) / CGFloat(read) : nil
    }

    private static func aspect(_ jpeg: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 else { return nil }
        return width / height
    }
}
