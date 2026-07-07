import Foundation

/// Headless linear render engine — the Swift port of video.py's wizard path:
/// trim → normalize to 1080x1920@30 → concat with xfade transitions → music
/// overlay → caption/text burn-in. Multi-track compositing (the manual
/// builder) is intentionally out of scope for now.
actor RenderEngine {
    static let outputWidth = 1080
    static let outputHeight = 1920

    /// xfade transition names accepted by the planner (video.py TRANSITIONS).
    static let transitions: [String] = [
        "fade", "fadeblack", "fadewhite", "wipeleft", "wiperight", "wipeup", "wipedown",
        "slideleft", "slideright", "circlecrop", "circleopen", "circleclose", "radial",
        "dissolve", "smoothleft", "smoothright", "diagtl", "diagbr", "horzopen", "horzclose",
        "vertopen", "vertclose", "hlslice", "hrslice", "zoomin",
        "coverleft", "coverright", "revealleft", "revealright", "pixelize",
    ]

    private let workDirectory: URL

    init() {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBuilderRender", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    func makeScratchDirectory() throws -> URL {
        let dir = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let normalizeFilter =
        "scale=\(outputWidth):\(outputHeight):force_original_aspect_ratio=decrease," +
        "pad=\(outputWidth):\(outputHeight):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30"

    // MARK: - Subclip extraction

    /// A PNG composited over a clip during extraction (caption or text
    /// overlay). `start`/`end` bound the enable window in clip-local time;
    /// nil shows the overlay for the whole clip.
    nonisolated struct ClipOverlay: Sendable {
        var png: URL
        var x: Int
        var y: Int
        var start: Double?
        var end: Double?
    }

    /// How a wide (landscape) source fills the portrait frame.
    nonisolated enum WideTreatment: Sendable {
        case none                 // letterbox/normalize
        case autoCrop(Double)     // 9:16 window at the given x fraction
        case split                // left/right halves stacked top/bottom
    }

    /// Trim [start, start+duration], normalize to portrait 1080x1920@30, and
    /// burn any overlays — all in ONE decode→encode pass (captions, text and
    /// mute used to be separate full re-encodes). Sources without audio get a
    /// silent stereo track so every intermediate clip is concat-compatible.
    func extractClip(source: URL, start: Double, duration: Double,
                     wide: WideTreatment = .none,
                     overlays: [ClipOverlay] = [],
                     mute: Bool = false,
                     output: URL) async throws {
        let hasAudio = mute ? false : await FFmpeg.hasAudioStream(source)
        var arguments = ["-y", "-ss", String(format: "%.2f", start), "-i", source.path]
        if !hasAudio { arguments += ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo"] }
        let overlayBase = hasAudio ? 1 : 2
        for overlay in overlays { arguments += ["-i", overlay.png.path] }

        var filters: [String] = []
        let baseLabel = overlays.isEmpty ? "[vout]" : "[base]"
        switch wide {
        case .none:
            filters.append("[0:v]\(Self.normalizeFilter)\(baseLabel)")
        case .autoCrop(let xFraction):
            filters.append(String(format: "[0:v]crop=ih*9/16:ih:(iw-ih*9/16)*%.4f:0," +
                                  "scale=%d:%d,setsar=1,fps=30%@",
                                  xFraction, Self.outputWidth, Self.outputHeight, baseLabel))
        case .split:
            let half = Self.outputHeight / 2
            filters.append("""
            [0:v]split=2[left][right];\
            [left]crop=iw/2:ih:0:0,scale=\(Self.outputWidth):\(half):force_original_aspect_ratio=increase,\
            crop=\(Self.outputWidth):\(half)[top];\
            [right]crop=iw/2:ih:iw/2:0,scale=\(Self.outputWidth):\(half):force_original_aspect_ratio=increase,\
            crop=\(Self.outputWidth):\(half)[bottom];\
            [top][bottom]vstack,setsar=1,fps=30\(baseLabel)
            """)
        }

        // Overlay chain (single-frame PNG inputs persist via repeatlast).
        var previous = baseLabel
        for (index, overlay) in overlays.enumerated() {
            let outLabel = index == overlays.count - 1 ? "[vout]" : "[ovl\(index)]"
            var step = "\(previous)[\(overlayBase + index):v]overlay=x=\(overlay.x):y=\(overlay.y)"
            if let windowStart = overlay.start, let windowEnd = overlay.end {
                step += String(format: ":enable='between(t,%.3f,%.3f)'", windowStart, windowEnd)
            }
            filters.append(step + outLabel)
            previous = outLabel
        }

        arguments += ["-filter_complex", filters.joined(separator: ";"),
                      "-map", "[vout]", "-map", hasAudio ? "0:a" : "1:a",
                      "-t", String(format: "%.2f", duration)]
        try await FFmpeg.run(arguments + FFmpeg.encodeArgs + [output.path], timeout: 900)
    }

    /// Plain trim + normalize (no overlays).
    func extractSubclip(source: URL, start: Double, duration: Double, output: URL) async throws {
        try await extractClip(source: source, start: start, duration: duration, output: output)
    }

    /// Re-encode an arbitrary clip (intro/outro) to the standard format.
    func normalizeClip(source: URL, output: URL) async throws {
        let duration = await FFmpeg.duration(of: source)
        try await extractSubclip(source: source, start: 0, duration: max(duration, 0.1), output: output)
    }

    // MARK: - Wide-source handling

    /// Score horizontal crop positions across sampled frames: 0.4·detail
    /// (column stdev) + 0.6·motion (frame-to-frame column diff), sliding a
    /// 9:16 window to find the busiest region. Port of auto_crop_x_frac.
    func autoCropXFraction(source: URL, start: Double, duration: Double) async -> Double {
        // Grab the sample frames concurrently — each is an independent
        // AVAssetImageGenerator (or ffmpeg fallback) call.
        let frames: [(pixels: [UInt8], width: Int, height: Int)] =
            await withTaskGroup(of: (Int, (pixels: [UInt8], width: Int, height: Int)?).self) { group in
                for i in 0..<7 {
                    let fraction = 0.05 + 0.90 * Double(i) / 6.0
                    let t = start + duration * fraction
                    group.addTask {
                        (i, await ThumbnailService.grayscaleFrame(url: source, at: t, width: 384))
                    }
                }
                var collected: [(Int, (pixels: [UInt8], width: Int, height: Int))] = []
                for await (i, frame) in group {
                    if let frame { collected.append((i, frame)) }
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
        guard frames.count >= 2, let first = frames.first else { return 0.5 }
        let width = first.width
        let height = first.height
        guard frames.allSatisfy({ $0.width == width && $0.height == height }), width > 0, height > 0 else {
            return 0.5
        }

        // Column detail: stdev down each column, averaged across frames.
        // (Row-major scans with per-column accumulators for cache locality.)
        var detail = [Double](repeating: 0, count: width)
        for frame in frames {
            var sums = [Double](repeating: 0, count: width)
            var squares = [Double](repeating: 0, count: width)
            frame.pixels.withUnsafeBufferPointer { pixels in
                var offset = 0
                for _ in 0..<height {
                    for x in 0..<width {
                        let v = Double(pixels[offset])
                        offset += 1
                        sums[x] += v
                        squares[x] += v * v
                    }
                }
            }
            for x in 0..<width {
                let mean = sums[x] / Double(height)
                detail[x] += max(0, squares[x] / Double(height) - mean * mean).squareRoot()
            }
        }
        // Column motion: mean abs diff between consecutive frames.
        var motion = [Double](repeating: 0, count: width)
        for index in 1..<frames.count {
            var diffs = [Double](repeating: 0, count: width)
            frames[index - 1].pixels.withUnsafeBufferPointer { a in
                frames[index].pixels.withUnsafeBufferPointer { b in
                    var offset = 0
                    for _ in 0..<height {
                        for x in 0..<width {
                            diffs[x] += abs(Double(b[offset]) - Double(a[offset]))
                            offset += 1
                        }
                    }
                }
            }
            for x in 0..<width {
                motion[x] += diffs[x] / Double(height)
            }
        }

        func normalized(_ values: [Double]) -> [Double] {
            guard let maxValue = values.max(), maxValue > 0 else { return values }
            return values.map { $0 / maxValue }
        }
        let normalizedDetail = normalized(detail)
        let normalizedMotion = normalized(motion)
        let score = (0..<width).map { 0.4 * normalizedDetail[$0] + 0.6 * normalizedMotion[$0] }

        let targetWidth = Int((Double(height) * 9.0 / 16.0).rounded())
        guard targetWidth < width else { return 0.5 }
        var windowSum = score.prefix(targetWidth).reduce(0, +)
        var bestSum = windowSum
        var bestLeft = 0
        for left in 1...(width - targetWidth) {
            windowSum += score[left + targetWidth - 1] - score[left - 1]
            if windowSum > bestSum {
                bestSum = windowSum
                bestLeft = left
            }
        }
        return min(1, max(0, Double(bestLeft) / Double(width - targetWidth)))
    }

    // MARK: - Concatenation

    /// Concatenate normalized clips with per-gap transitions or hard cuts —
    /// the port of video.py concatenate_clips(). Each transitions entry is an
    /// xfade name or nil (hard cut). Mixed lists group consecutive clips that
    /// share transitions, xfade within each group, then plain-concat the
    /// groups. Falls back to the concat demuxer on degenerate durations.
    func concatenate(clips: [URL], transitions: [String?], output: URL) async throws {
        guard !clips.isEmpty else { return }
        if clips.count == 1 {
            try FileManager.default.copyItemReplacing(at: clips[0], to: output)
            return
        }
        var padded = transitions
        while padded.count < clips.count - 1 { padded.append(nil) }
        padded = Array(padded.prefix(clips.count - 1))

        if padded.allSatisfy({ $0 == nil }) {
            try await concatPlain(clips: clips, output: output)
            return
        }
        if padded.allSatisfy({ $0 != nil }) {
            do {
                try await xfadeAll(clips: clips, transitions: padded.compactMap { $0 }, output: output)
            } catch {
                try await concatPlain(clips: clips, output: output)
            }
            return
        }

        // Mixed: group runs of transition-joined clips.
        var groups: [(clips: [URL], transitions: [String])] = []
        var currentClips = [clips[0]]
        var currentTransitions: [String] = []
        for index in 1..<clips.count {
            if let name = padded[index - 1] {
                currentClips.append(clips[index])
                currentTransitions.append(name)
            } else {
                groups.append((currentClips, currentTransitions))
                currentClips = [clips[index]]
                currentTransitions = []
            }
        }
        groups.append((currentClips, currentTransitions))

        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var groupOutputs: [URL] = []
        for (index, group) in groups.enumerated() {
            if group.clips.count == 1 {
                groupOutputs.append(group.clips[0])
            } else {
                let groupOutput = scratch.appendingPathComponent("group_\(index).mp4")
                do {
                    try await xfadeAll(clips: group.clips, transitions: group.transitions, output: groupOutput)
                } catch {
                    try await concatPlain(clips: group.clips, output: groupOutput)
                }
                groupOutputs.append(groupOutput)
            }
        }
        if groupOutputs.count == 1 {
            try FileManager.default.copyItemReplacing(at: groupOutputs[0], to: output)
        } else {
            try await concatPlain(clips: groupOutputs, output: output)
        }
    }

    /// xfade every gap in one pass; throws when durations can't support the
    /// crossfade so callers can fall back to a plain concat.
    private func xfadeAll(clips: [URL], transitions: [String], output: URL) async throws {
        let durations = try await BoundedConcurrency.map(clips, limit: FFmpeg.jobLimit) { _, clip in
            await FFmpeg.duration(of: clip)
        }
        let requestedXfade = 0.5
        let actualXfade = min(requestedXfade, (durations.min() ?? 0) * 0.4)
        guard actualXfade >= 0.1, durations.allSatisfy({ $0 > actualXfade }) else {
            throw CocoaError(.featureUnsupported)
        }

        var arguments = ["-y"]
        for clip in clips {
            arguments += ["-i", clip.path]
        }

        var filterParts: [String] = []
        var previousVideo = "[0:v]"
        var previousAudio = "[0:a]"
        var offset = durations[0] - actualXfade
        for index in 1..<clips.count {
            let name = Self.transitions.contains(transitions[safe: index - 1] ?? "fade")
                ? (transitions[safe: index - 1] ?? "fade") : "fade"
            let outVideo = index == clips.count - 1 ? "[vout]" : "[v\(index)]"
            let outAudio = index == clips.count - 1 ? "[aout]" : "[a\(index)]"
            filterParts.append("\(previousVideo)[\(index):v]xfade=transition=\(name):" +
                               String(format: "duration=%.3f:offset=%.3f", actualXfade, offset) + outVideo)
            filterParts.append("\(previousAudio)[\(index):a]acrossfade=" +
                               String(format: "d=%.3f", actualXfade) + outAudio)
            previousVideo = outVideo
            previousAudio = outAudio
            offset += durations[index] - actualXfade
        }

        try await FFmpeg.run(arguments + [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[vout]", "-map", "[aout]",
        ] + FFmpeg.encodeArgs + [output.path], timeout: 1800)
    }

    /// Every input is one of our own normalized intermediates (identical
    /// codec/resolution/fps/pixel format), so the video stream can be
    /// stream-copied — a sub-second remux instead of re-encoding the whole
    /// timeline. Audio is re-encoded (fast) to smooth AAC priming gaps at
    /// the joins.
    private func concatPlain(clips: [URL], output: URL) async throws {
        let listFile = workDirectory.appendingPathComponent("concat_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listFile) }
        let listing = clips
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listing.write(to: listFile, atomically: true, encoding: .utf8)
        try await FFmpeg.run(["-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
                              "-c:v", "copy"] + FFmpeg.audioEncodeArgs +
                             ["-movflags", "+faststart", output.path],
                             timeout: 600)
    }

    // MARK: - Audio

    /// Mix a music bed under the video: music at 0.18 (0.25 when the video
    /// is silent), with a 2s fade-out at the end. Port of overlay_music().
    func overlayMusic(video: URL, music: URL, output: URL) async throws {
        let duration = await FFmpeg.duration(of: video)
        let fadeStart = max(0, duration - 2.0)
        let hasAudio = await FFmpeg.hasAudioStream(video)
        if hasAudio {
            let filter = String(format: "[1:a]volume=0.18,afade=t=out:st=%.2f:d=2.0[music];" +
                                "[0:a][music]amix=inputs=2:duration=first:dropout_transition=2[aout]", fadeStart)
            try await FFmpeg.run(["-y", "-i", video.path, "-stream_loop", "-1", "-i", music.path,
                                  "-filter_complex", filter,
                                  "-map", "0:v", "-map", "[aout]",
                                  "-c:v", "copy", "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "192k",
                                  "-shortest", output.path], timeout: 1200)
        } else {
            let filter = String(format: "[1:a]volume=0.25,afade=t=out:st=%.2f:d=2.0[aout]", fadeStart)
            try await FFmpeg.run(["-y", "-i", video.path, "-stream_loop", "-1", "-i", music.path,
                                  "-filter_complex", filter,
                                  "-map", "0:v", "-map", "[aout]",
                                  "-c:v", "copy", "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "192k",
                                  "-shortest", output.path], timeout: 1200)
        }
    }

}

nonisolated extension FileManager {
    func copyItemReplacing(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
