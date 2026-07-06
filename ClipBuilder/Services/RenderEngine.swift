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

    private static let encodeArgs = ["-c:v", "libx264", "-preset", "fast", "-crf", "23",
                                     "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "128k",
                                     "-pix_fmt", "yuv420p", "-movflags", "+faststart"]

    // MARK: - Subclip extraction

    /// Trim [start, start+duration] and normalize to portrait 1080x1920@30.
    /// Sources without audio get a silent stereo track so every intermediate
    /// clip is concat-compatible.
    func extractSubclip(source: URL, start: Double, duration: Double, output: URL) async throws {
        if await FFmpeg.hasAudioStream(source) {
            try await FFmpeg.run(["-y", "-ss", String(format: "%.2f", start), "-i", source.path,
                                  "-t", String(format: "%.2f", duration),
                                  "-vf", Self.normalizeFilter]
                                 + Self.encodeArgs + [output.path], timeout: 600)
        } else {
            try await FFmpeg.run(["-y", "-ss", String(format: "%.2f", start), "-i", source.path,
                                  "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                                  "-t", String(format: "%.2f", duration),
                                  "-filter_complex", "[0:v]\(Self.normalizeFilter)[vout]",
                                  "-map", "[vout]", "-map", "1:a"]
                                 + Self.encodeArgs + [output.path], timeout: 600)
        }
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
        var frames: [(pixels: [UInt8], width: Int, height: Int)] = []
        for i in 0..<7 {
            let fraction = 0.05 + 0.90 * Double(i) / 6.0
            let t = start + duration * fraction
            if let frame = await ThumbnailService.grayscaleFrame(url: source, at: t, width: 384) {
                frames.append(frame)
            }
        }
        guard frames.count >= 2, let first = frames.first else { return 0.5 }
        let width = first.width
        let height = first.height
        guard frames.allSatisfy({ $0.width == width && $0.height == height }), width > 0, height > 0 else {
            return 0.5
        }

        // Column detail: stdev down each column, averaged across frames.
        var detail = [Double](repeating: 0, count: width)
        for frame in frames {
            for x in 0..<width {
                var sum = 0.0, sumSquares = 0.0
                for y in 0..<height {
                    let v = Double(frame.pixels[y * width + x])
                    sum += v
                    sumSquares += v * v
                }
                let mean = sum / Double(height)
                detail[x] += max(0, sumSquares / Double(height) - mean * mean).squareRoot()
            }
        }
        // Column motion: mean abs diff between consecutive frames.
        var motion = [Double](repeating: 0, count: width)
        for index in 1..<frames.count {
            let a = frames[index - 1].pixels
            let b = frames[index].pixels
            for x in 0..<width {
                var diff = 0.0
                for y in 0..<height {
                    diff += abs(Double(b[y * width + x]) - Double(a[y * width + x]))
                }
                motion[x] += diff / Double(height)
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

    /// Wide → portrait: crop a 9:16 window centered on the action.
    func extractWideSubclipAutocrop(source: URL, start: Double, duration: Double, output: URL) async throws {
        let xFraction = await autoCropXFraction(source: source, start: start, duration: duration)
        let filter = String(format: "crop=ih*9/16:ih:(iw-ih*9/16)*%.4f:0,scale=%d:%d,setsar=1,fps=30",
                            xFraction, Self.outputWidth, Self.outputHeight)
        if await FFmpeg.hasAudioStream(source) {
            try await FFmpeg.run(["-y", "-ss", String(format: "%.2f", start), "-i", source.path,
                                  "-t", String(format: "%.2f", duration), "-vf", filter]
                                 + Self.encodeArgs + [output.path], timeout: 600)
        } else {
            try await FFmpeg.run(["-y", "-ss", String(format: "%.2f", start), "-i", source.path,
                                  "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                                  "-t", String(format: "%.2f", duration),
                                  "-filter_complex", "[0:v]\(filter)[vout]",
                                  "-map", "[vout]", "-map", "1:a"]
                                 + Self.encodeArgs + [output.path], timeout: 600)
        }
    }

    /// Wide → portrait split-screen: left/right halves stacked to fill the
    /// full 9:16 frame with no black bars.
    func extractWideSplit(source: URL, start: Double, duration: Double, output: URL) async throws {
        let half = Self.outputHeight / 2
        let filter = """
        [0:v]split=2[left][right];\
        [left]crop=iw/2:ih:0:0,scale=\(Self.outputWidth):\(half):force_original_aspect_ratio=increase,\
        crop=\(Self.outputWidth):\(half)[top];\
        [right]crop=iw/2:ih:iw/2:0,scale=\(Self.outputWidth):\(half):force_original_aspect_ratio=increase,\
        crop=\(Self.outputWidth):\(half)[bottom];\
        [top][bottom]vstack,setsar=1,fps=30[vout]
        """
        let hasAudio = await FFmpeg.hasAudioStream(source)
        var arguments = ["-y", "-ss", String(format: "%.2f", start), "-i", source.path]
        if !hasAudio {
            arguments += ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo"]
        }
        arguments += ["-t", String(format: "%.2f", duration),
                      "-filter_complex", filter,
                      "-map", "[vout]", "-map", hasAudio ? "0:a" : "1:a"]
        try await FFmpeg.run(arguments + Self.encodeArgs + [output.path], timeout: 600)
    }

    // MARK: - Concatenation

    /// Concatenate normalized clips with per-gap xfade transitions and audio
    /// crossfades. Falls back to the concat demuxer when transitions can't
    /// apply (single clip or degenerate durations).
    func concatenate(clips: [URL], transitions: [String], output: URL) async throws {
        guard !clips.isEmpty else { return }
        if clips.count == 1 {
            try FileManager.default.copyItemReplacing(at: clips[0], to: output)
            return
        }

        var durations: [Double] = []
        for clip in clips {
            durations.append(await FFmpeg.duration(of: clip))
        }
        let requestedXfade = 0.5
        let actualXfade = max(0.1, min(requestedXfade, (durations.min() ?? 1) * 0.4))
        guard durations.allSatisfy({ $0 > actualXfade }) else {
            try await concatPlain(clips: clips, output: output)
            return
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

        do {
            try await FFmpeg.run(arguments + [
                "-filter_complex", filterParts.joined(separator: ";"),
                "-map", "[vout]", "-map", "[aout]",
                "-c:v", "libx264", "-preset", "fast", "-crf", "22",
                "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "128k",
                "-pix_fmt", "yuv420p", "-movflags", "+faststart", output.path,
            ], timeout: 1800)
        } catch {
            try await concatPlain(clips: clips, output: output)
        }
    }

    private func concatPlain(clips: [URL], output: URL) async throws {
        let listFile = workDirectory.appendingPathComponent("concat_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listFile) }
        let listing = clips
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listing.write(to: listFile, atomically: true, encoding: .utf8)
        try await FFmpeg.run(["-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
                              "-c:v", "libx264", "-preset", "fast", "-crf", "22",
                              "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "128k",
                              "-pix_fmt", "yuv420p", "-movflags", "+faststart", output.path],
                             timeout: 1800)
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

    /// Replace the audio track with silence (wizard "mute source" option).
    func muteAudio(video: URL, output: URL) async throws {
        try await FFmpeg.run(["-y", "-i", video.path,
                              "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                              "-map", "0:v", "-map", "1:a",
                              "-c:v", "copy", "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "128k",
                              "-shortest", output.path], timeout: 600)
    }

    // MARK: - Overlays

    /// Burn transcript captions: one PNG per segment, overlaid inside its
    /// [start, end] window via enable='between(t,...)'.
    func burnCaptions(video: URL, segments: [TranscriptSegment], style: CaptionStyle, output: URL) async throws {
        guard !segments.isEmpty else {
            try FileManager.default.copyItemReplacing(at: video, to: output)
            return
        }
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: Self.outputWidth, videoHeight: Self.outputHeight, style: style)

        var arguments = ["-y", "-i", video.path]
        var filterParts: [String] = []
        var previous = "[0:v]"
        for (index, segment) in segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let rendered = try renderer.render(text: text, to: scratch)
            let (x, y) = renderer.position(for: rendered)
            arguments += ["-i", rendered.pngURL.path]
            let inputIndex = filterParts.count + 1
            let label = index == segments.count - 1 ? "[vout]" : "[ov\(inputIndex)]"
            filterParts.append("\(previous)[\(inputIndex):v]overlay=x=\(x):y=\(y):" +
                               String(format: "enable='between(t,%.3f,%.3f)'", segment.start, segment.end) + label)
            previous = label
        }
        guard !filterParts.isEmpty else {
            try FileManager.default.copyItemReplacing(at: video, to: output)
            return
        }
        // Ensure the last filter writes [vout] even if trailing segments were empty.
        if var last = filterParts.popLast() {
            if !last.hasSuffix("[vout]") {
                if let bracket = last.lastIndex(of: "[") {
                    last = String(last[..<bracket]) + "[vout]"
                }
            }
            filterParts.append(last)
        }
        try await FFmpeg.run(arguments + [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[vout]", "-map", "0:a?",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
            "-c:a", "copy", "-pix_fmt", "yuv420p", output.path,
        ], timeout: 1200)
    }

    /// Punchy full-clip text overlay (wizard text_overlay) — bigger type,
    /// upper third, shown for the whole clip.
    func addTextOverlay(video: URL, text: String, output: URL) async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var style = CaptionStyle()
        style.position = "top"
        let renderer = CaptionRenderer(videoWidth: Self.outputWidth, videoHeight: Self.outputHeight, style: style)
        let rendered = try renderer.render(text: text.uppercased(), to: scratch,
                                           fontSize: CGFloat(Self.outputWidth) / 14)
        let x = (Self.outputWidth - rendered.width) / 2
        let y = Self.outputHeight / 5
        try await FFmpeg.run(["-y", "-i", video.path, "-i", rendered.pngURL.path,
                              "-filter_complex", "[0:v][1:v]overlay=x=\(x):y=\(y)[vout]",
                              "-map", "[vout]", "-map", "0:a?",
                              "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                              "-c:a", "copy", "-pix_fmt", "yuv420p", output.path], timeout: 600)
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
