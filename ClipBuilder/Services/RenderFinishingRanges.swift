import Foundation

/// The final overlay pass split into cacheable ranges. Ranges cut only at
/// hard-cut assembly boundaries, keep the original overlay animation clock,
/// and each one is encoded by its own seeked FFmpeg process, so a later edit
/// re-encodes only the ranges whose assembly groups changed.
///
/// The planning and clock rules mirror scripts/incremental_overlay_prototype.py,
/// whose outputs matched the full pass frame-for-frame in timing and audio.
nonisolated enum RenderFinishingRanges {
    static let version = "multitrack-finishing-range-v1"
    /// Every segment is normalized to this rate before assembly.
    static let frameRate = 30.0
    static let frameRateLabel = "30/1"
    static let minimumLength = 4.0

    struct Part: Codable, Sendable, Equatable {
        /// Seconds into the assembled video, summed from group durations.
        var start: Double
        var end: Double
        /// Inclusive assembly-group indices covered by this range.
        var first: Int
        var last: Int
        /// The same boundaries on the filter clock: rounded to whole frames
        /// and offset by the assembled stream's start time.
        var clockStart: Double = 0
        var clockEnd: Double = 0
        var trimEnd: Double = 0

        var length: Double { clockEnd - clockStart }
    }

    /// One pre-concatenation assembly group: a single hard-cut segment or a
    /// crossfaded run of segments.
    struct Group: Sendable, Equatable {
        var duration: Double
        var identity: String
    }

    private struct GroupIdentity: Encodable {
        var segments: [String]
        var transitions: [String]
        var transitionDuration: Double
    }

    struct Key: Encodable, Sendable {
        var part: Part
        /// The covered groups plus one neighbor on each side: frame
        /// resampling around a hard cut can reach into the adjacent group.
        var groups: [String]
        var overlays: [RenderFinishingKey.Overlay]
        var settings: RenderSettings
        var encoder: [String]
        var segmentVersion = RenderSegmentCache.rendererVersion
    }

    /// Longer outputs use longer ranges so the number of range files and
    /// processes stays bounded; short outputs keep four-second ranges.
    static func targetLength(totalDuration: Double) -> Double {
        max(minimumLength, totalDuration / 24)
    }

    static func groupIdentity(segmentDigests: [String], transitions: [String],
                              transitionDuration: Double) throws -> String {
        try RenderSegmentCache.key(GroupIdentity(segments: segmentDigests, transitions: transitions,
                                                 transitionDuration: transitionDuration), version: version)
    }

    /// Ranges of at least `target` seconds; the final range takes the rest.
    static func plan(durations: [Double], target: Double) throws -> [Part] {
        guard !durations.isEmpty, durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Every assembly group must have a positive finite duration"])
        }
        var parts: [Part] = []
        var start = 0.0
        var first = 0
        var end = 0.0
        for (index, duration) in durations.enumerated() {
            end += duration
            if end - start >= target - 1e-6 || index == durations.count - 1 {
                parts.append(Part(start: start, end: end, first: first, last: index))
                start = end
                first = index + 1
            }
        }
        return parts
    }

    /// Place the planned boundaries on the whole-frame clock. `limit` is the
    /// full pass's output cap; the last range's trim keeps the final frame
    /// but stops before the extra one that output rounding could add.
    static func clock(_ parts: inout [Part], startTime: Double, limit: Double) {
        guard !parts.isEmpty else { return }
        let rate = frameRate
        var boundaries = [(startTime * rate).rounded() / rate]
        boundaries += parts.dropFirst().map { ((startTime + $0.start) * rate).rounded() / rate }
        for index in parts.indices {
            let isLast = index + 1 == parts.count
            let end = isLast ? limit : boundaries[index + 1]
            parts[index].clockStart = boundaries[index]
            parts[index].clockEnd = end
            parts[index].trimEnd = isLast
                ? (end * rate - 1e-9).rounded(.up) / rate - 1 / (2 * rate)
                : end - 1 / (2 * rate)
        }
    }

    static func key(part: Part, groups: [Group], overlays: [RenderFinishingKey.Overlay],
                    settings: RenderSettings, encoder: [String]) throws -> String {
        let lower = max(0, part.first - 1)
        let upper = min(groups.count - 1, part.last + 1)
        let dependencies = lower <= upper ? groups[lower...upper].map(\.identity) : []
        return try RenderSegmentCache.key(Key(part: part, groups: dependencies, overlays: overlays,
                                              settings: settings, encoder: encoder), version: version)
    }

    // MARK: - FFmpeg arguments

    /// Half a frame early so the trim's first frame is decoded, never dropped.
    static func trimStart(_ part: Part) -> Double {
        max(0, part.clockStart - 1 / (2 * frameRate))
    }

    /// Input seek for the assembled video and every looped raster. With
    /// `-copyts` the overlay clock stays absolute, so enable windows, fades
    /// and slides evaluate exactly as they do in the full pass.
    static func seekArguments(_ part: Part) -> [String] {
        ["-ss", String(format: "%.6f", trimStart(part))]
    }

    static func inputArguments(video: URL, part: Part) -> [String] {
        ["-y", "-copyts"] + seekArguments(part) + ["-i", video.path]
    }

    /// Select on the original clock, then reset timestamps for the range file.
    static func rangeFilter(previous: String, part: Part) -> String {
        String(format: "%@trim=start=%.9f:end=%.9f,setpts=PTS-%.9f/TB[range]",
               previous, trimStart(part), part.trimEnd, part.clockStart)
    }

    /// Explicit VFR preserves the assembled video's timing gaps; the per-range
    /// cap stops encoder rounding from adding a frame past the boundary.
    static func outputArguments(part: Part, encoder: [String], output: URL) -> [String] {
        ["-map", "[range]"] + encoder + ["-pix_fmt", "yuv420p", "-an", "-fps_mode", "vfr",
                                         "-t", String(format: "%.9f", part.length), output.path]
    }

    static func concatListing(_ files: [URL]) -> String {
        files.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'\n" }.joined()
    }

    /// Stream-copy the range videos in order and the assembled audio once.
    static func joinArguments(listing: URL, audio: URL, firstClockStart: Double, output: URL) -> [String] {
        ["-y", "-itsoffset", String(format: "%.9f", firstClockStart), "-f", "concat", "-safe", "0",
         "-i", listing.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a?", "-c", "copy",
         "-movflags", "+faststart", output.path]
    }
}
