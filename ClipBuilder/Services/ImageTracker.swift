import CoreGraphics
import Foundation

nonisolated struct ImageTrackKey: Codable, Sendable, Equatable {
    var time: Double
    var xFrac: Double
    var yFrac: Double
    var wFrac: Double

    enum CodingKeys: String, CodingKey {
        case time
        case xFrac = "x_frac"
        case yFrac = "y_frac"
        case wFrac = "w_frac"
    }

    /// Tracks have strictly increasing times. Outside the keys, hold the endpoint.
    static func interpolate(_ keys: [Self], at time: Double) -> Self? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if time <= first.time { return first }
        if time >= last.time { return last }
        var low = 0, high = keys.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if keys[middle].time <= time { low = middle } else { high = middle }
        }
        let a = keys[low], b = keys[high]
        let fraction = (time - a.time) / max(0.000001, b.time - a.time)
        return Self(time: time, xFrac: a.xFrac + (b.xFrac - a.xFrac) * fraction,
                    yFrac: a.yFrac + (b.yFrac - a.yFrac) * fraction,
                    wFrac: a.wFrac + (b.wFrac - a.wFrac) * fraction)
    }
}

nonisolated enum ImageTracker {
    struct Sample: Sendable {
        var time: Double
        var sourceTime: Double
        var placement: ImageGeneration.Placement
    }

    static func times(start: Double, end: Double, step: Double = 0.25) -> [Double] {
        guard start.isFinite, end.isFinite, end > start, step.isFinite, step > 0 else { return [] }
        return Array(stride(from: start, to: end, by: max(0.05, step))) + [end]
    }

    static func nearestFace(_ faces: [CGRect], to previous: CGRect) -> CGRect? {
        faces.filter { face in
            face.width > 0 && face.height > 0 && previous.width > 0 && previous.height > 0
                && (0.5...2).contains(face.width / previous.width)
                && (0.5...2).contains(face.height / previous.height)
                && hypot(face.midX - previous.midX, face.midY - previous.midY) <= 0.15
        }.min {
            hypot($0.midX - previous.midX, $0.midY - previous.midY)
                < hypot($1.midX - previous.midX, $1.midY - previous.midY)
        }
    }

    struct FollowState: Sendable {
        var face: CGRect
        var misses = 0
        var ended: Bool { misses >= 3 }
    }

    /// A miss holds the last source box. Three consecutive misses end sampling.
    static func advance(_ state: FollowState, faces: [CGRect]) -> FollowState {
        guard !state.ended else { return state }
        if let face = nearestFace(faces, to: state.face) { return FollowState(face: face) }
        return FollowState(face: state.face, misses: state.misses + 1)
    }

    static func smoothed(_ keys: [ImageTrackKey]) -> [ImageTrackKey] {
        guard keys.count > 2 else { return keys }
        var result = keys
        for index in 1..<(keys.count - 1) {
            result[index].xFrac = (keys[index - 1].xFrac + keys[index].xFrac + keys[index + 1].xFrac) / 3
            result[index].yFrac = (keys[index - 1].yFrac + keys[index].yFrac + keys[index + 1].yFrac) / 3
        }
        return result
    }

    @concurrent
    static func track(video: URL, clip: TimelineClip,
                      model placement: @Sendable (Double) -> ImageGeneration.Placement,
                      sourceTime: @Sendable (Double) -> Double,
                      start: Double, end: Double, seed: CGRect, step: Double = 0.25) async throws -> [ImageTrackKey] {
        let samples = times(start: start, end: min(end, clip.startTime + clip.duration), step: step).map {
            Sample(time: $0, sourceTime: sourceTime($0), placement: placement($0))
        }
        return try await track(video: video, samples: samples, seed: seed, end: end)
    }

    /// Geometry and source clocks are captured before work starts; no live store is read here.
    @concurrent
    static func track(video: URL, samples: [Sample], seed: CGRect, end: Double) async throws -> [ImageTrackKey] {
        var state = FollowState(face: seed)
        var keys: [ImageTrackKey] = []
        // Small batches bound decoded frame memory and stop fetching soon after a lost face.
        for offset in stride(from: 0, to: samples.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(samples[offset..<min(offset + 8, samples.count)])
            let frames = await ThumbnailService.jpegFrames(url: video, at: batch.map(\.sourceTime), maxDimension: 640)
            for (sample, data) in zip(batch, frames) {
                try Task.checkCancellation()
                let faces: [CGRect]
                if let data {
                    faces = try await CenterStageService.faces(in: ImageGeneration.decode(data))
                } else { faces = [] }
                state = advance(state, faces: faces)
                // On a miss `state.face` is the held source box; projecting it
                // through this sample's placement keeps the sticker on the
                // face while the crop window keeps moving.
                let geometry = ImageGeneration.overlayGeometry(mode: .sticker, subject: state.face, placement: sample.placement)
                keys.append(ImageTrackKey(time: sample.time, xFrac: geometry.xFrac,
                                          yFrac: geometry.yFrac, wFrac: geometry.wFrac))
                if state.ended { break }
            }
            if state.ended { break }
        }
        var result = smoothed(keys)
        if var last = result.last, last.time < end {
            last.time = end
            result.append(last)
        }
        return result
    }

    /// ffmpeg expression for a center fraction, holding before/after the track.
    /// `clock` lets segment-local t be converted to the timeline clock.
    static func expression(_ keys: [ImageTrackKey], axis: KeyPath<ImageTrackKey, Double>,
                           clock: String = "t") -> String {
        guard let first = keys.first else { return "0" }
        func number(_ value: Double) -> String {
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        // As in AreaFramer, sum clamped ramps in a balanced tree. Nested ifs
        // (or a flat sum) exceed ffmpeg's recursion limit on longer tracks.
        var terms = [number(first[keyPath: axis])]
        for (a, b) in zip(keys, keys.dropFirst()) where b.time > a.time {
            let delta = b[keyPath: axis] - a[keyPath: axis]
            guard delta != 0 else { continue }
            terms.append("(\(number(delta)))*clip((\(clock)-\(number(a.time)))/\(number(b.time - a.time)),0,1)")
        }
        func sum(_ range: Range<Int>) -> String {
            if range.count == 1 { return terms[range.lowerBound] }
            let middle = range.lowerBound + range.count / 2
            return "(" + sum(range.lowerBound..<middle) + "+" + sum(middle..<range.upperBound) + ")"
        }
        return sum(terms.indices)
    }
}
