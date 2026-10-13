import AVFoundation
import CoreGraphics
import Foundation

/// A person's portrait moment should show their face. The people pass picks
/// the moment and the box; when no face is visible there (turned away,
/// blocked), nearby frames are tried, closest first, with the box widened a
/// little per second of drift, and the first frame with a face inside the
/// box wins.
nonisolated enum PortraitMoment {
    /// Seconds around the chosen moment, nearest first. Six seconds either
    /// way keeps the box meaningful for a person who moves.
    static let offsets: [Double] = [0, -0.5, 0.5, -1, 1, -1.5, 1.5, -2, 2, -3, 3, -4, 4, -6, 6]

    struct Found: Sendable {
        var time: Double
        var face: CGRect
        var frame: Data
    }

    /// Candidate times inside the video (and inside the person's on-screen
    /// ranges when known), nearest to `time` first, without duplicates.
    static func candidateTimes(around time: Double, duration: Double?,
                               ranges: [ClosedRange<Double>] = []) -> [Double] {
        var seen: [Double] = []
        for offset in offsets {
            var candidate = time + offset
            if candidate < 0 { candidate = 0 }
            if let duration, duration > 0 { candidate = min(candidate, max(0, duration - 0.1)) }
            candidate = (candidate * 10).rounded() / 10
            if !ranges.isEmpty, !ranges.contains(where: { $0.contains(candidate) }) { continue }
            if seen.contains(where: { abs($0 - candidate) < 0.05 }) { continue }
            seen.append(candidate)
        }
        return seen
    }

    /// The marker widened for drift: 5% of its size per second away from
    /// the chosen moment, each side, clamped to the frame.
    static func drifted(_ marker: PersonMarker, by seconds: Double) -> PersonMarker {
        let grow = min(0.5, 0.05 * abs(seconds))
        var value = marker
        value.x = max(0, marker.x - marker.width * grow)
        value.y = max(0, marker.y - marker.height * grow)
        value.width = min(1 - value.x, marker.width * (1 + 2 * grow))
        value.height = min(1 - value.y, marker.height * (1 + 2 * grow))
        return value
    }

    /// The nearest frame around the marker's moment with a face inside the
    /// (drifted) box, or nil when none of the candidates shows one.
    static func faceFrame(url: URL, marker: PersonMarker, duration: Double?,
                          ranges: [ClosedRange<Double>] = []) async -> Found? {
        for time in candidateTimes(around: marker.atTime, duration: duration, ranges: ranges) {
            guard !Task.isCancelled else { return nil }
            guard let frame = await ThumbnailService.jpegFrame(url: url, at: time, maxDimension: 1280) else { continue }
            let box = drifted(marker, by: time - marker.atTime)
            if let face = AvatarCrop.face(among: await PersonFaceAvatar.detectFaces(in: frame), inside: box) {
                return Found(time: time, face: face, frame: frame)
            }
        }
        return nil
    }

    /// Seconds of media in the file, when it can be read; frame requests
    /// past the end are then skipped instead of falling through to ffmpeg.
    static func duration(of url: URL) async -> Double? {
        guard let asset = try? await DriveLocalAsset.make(url),
              let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
