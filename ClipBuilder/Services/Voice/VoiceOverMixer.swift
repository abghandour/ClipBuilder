import Foundation

/// Mixes the voice-over recordings into an assembled reel: the reel's own
/// sound is lowered under each recording and the voices are laid on top.
/// One pass over the whole reel, video stream copied.
nonisolated enum VoiceOverMixer {
    struct Line: Sendable, Equatable {
        var url: URL
        /// Seconds on the reel's clock.
        var start: Double
        var duration: Double
    }

    static let ramp = 0.15
    static let defaultBedLevel = 0.25

    /// The reel's own volume over time: 1 away from the recordings, `level`
    /// under them, with a short ramp either side.
    static func bedExpression(lines: [Line], level: Double, ramp: Double = ramp) -> String {
        let level = min(1, max(0, level))
        let windows = lines.map { line in
            String(format: "clip((t-%.3f)/%.3f,0,1)*clip((%.3f-t)/%.3f,0,1)",
                   line.start - ramp, ramp, line.start + line.duration + ramp, ramp)
        }
        guard !windows.isEmpty else { return "1" }
        return String(format: "1-%.3f*min(1,%@)", 1 - level, windows.joined(separator: "+"))
    }

    /// The bed is padded so a reel whose sound ends early never cuts a voice;
    /// `-t` ends the output at the reel's length.
    /// Input 0 is the reel, inputs 1... are the recordings in `lines` order.
    /// A reel without sound gets silence made inside the graph (an `anullsrc`
    /// input can stall ffmpeg 8.1 at the end of a segment).
    static func filter(lines: [Line], level: Double, reelHasAudio: Bool, reelDuration: Double) -> String {
        var filters: [String] = []
        if reelHasAudio {
            filters.append("[0:a]aresample=48000,aformat=channel_layouts=stereo,"
                + "volume='\(bedExpression(lines: lines, level: level))':eval=frame,apad[bed]")
        } else {
            filters.append(String(format: "anullsrc=r=48000:cl=stereo:d=%.3f,asetpts=PTS-STARTPTS[bed]", reelDuration))
        }
        for (index, line) in lines.enumerated() {
            let delay = Int((max(0, line.start) * 1000).rounded())
            // A recording that would run past the end is cut there with a short fade.
            let room = max(0.05, reelDuration - line.start)
            let length = min(line.duration, room)
            let fade = length < line.duration
                ? String(format: ",afade=t=out:st=%.3f:d=%.3f", max(0, length - ramp), min(ramp, length)) : ""
            filters.append(String(format: "[%d:a]atrim=duration=%.3f,asetpts=PTS-STARTPTS%@,aresample=48000,"
                + "aformat=channel_layouts=stereo,adelay=%d:all=1[voice%d]", index + 1, length, fade, delay, index))
        }
        let inputs = "[bed]" + lines.indices.map { "[voice\($0)]" }.joined()
        filters.append("\(inputs)amix=inputs=\(lines.count + 1):duration=first:dropout_transition=0:normalize=0[aout]")
        return filters.joined(separator: ";")
    }

    @concurrent
    static func mix(video: URL, lines: [Line], level: Double, output: URL) async throws {
        try Task.checkCancellation()
        let lines = lines.filter { $0.duration > 0 && FileManager.default.fileExists(atPath: $0.url.path) }
        guard !lines.isEmpty else {
            try FileManager.default.copyItemReplacing(at: video, to: output)
            return
        }
        let duration = await FFmpeg.duration(of: video)
        let hasAudio = await FFmpeg.hasAudioStream(video)
        var arguments = ["-y", "-i", video.path]
        for line in lines { arguments += ["-i", line.url.path] }
        arguments += ["-filter_complex", filter(lines: lines, level: level, reelHasAudio: hasAudio, reelDuration: duration),
                      "-map", "0:v", "-map", "[aout]", "-c:v", "copy", "-c:a", "aac", "-ar", "48000", "-b:a", "192k",
                      "-t", String(format: "%.3f", duration), "-movflags", "+faststart", output.path]
        try await FFmpeg.run(arguments, timeout: 600, capture: .boundedStderrTail(),
                             purpose: "voice-over mix; video stream copy")
    }
}
