import Foundation

nonisolated enum DubMixer {
    /// Pure filter construction, shared by the mixer and string tests.
    static func trackFilter(lines: [DubLine], duration: Double) -> String {
        var filters = ["[0:a]atrim=duration=\(DubPlanning.number(duration)),asetpts=PTS-STARTPTS[bed]"]
        for (index, line) in lines.enumerated() {
            let delay = Int((max(0, line.start) * 1000).rounded())
            let stretch = DubPlanning.number(min(1.15, max(1, line.stretch)))
            let trim = line.start < 0
                ? "atrim=start=\(DubPlanning.number(-line.start * min(1.15, max(1, line.stretch))))," : ""
            filters.append("[\(index + 1):a]\(trim)asetpts=PTS-STARTPTS,atempo=\(stretch)," +
                "aresample=48000,aformat=channel_layouts=stereo,adelay=\(delay):all=1[line\(index)]")
        }
        let inputs = "[bed]" + lines.indices.map { "[line\($0)]" }.joined()
        filters.append("\(inputs)amix=inputs=\(lines.count + 1):duration=first:dropout_transition=0:normalize=0[aout]")
        return filters.joined(separator: ";")
    }

    /// Replacing the original silences the whole source track, speech and
    /// background noise alike; otherwise it is ducked under each line.
    static func overlayFilter(lines: [DubLine], settings: DubSettings) -> String {
        let expression = settings.replaceOriginal ? "0.0"
            : DubPlanning.duckExpression(lines: lines, level: settings.originalLevel, ramp: 0.15)
        return "[0:a]volume='\(expression)':eval=frame[orig];" +
            "[orig][1:a]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]"
    }

    @concurrent
    static func buildTrack(lines: [DubLine], duration: Double, output: URL,
                           directory: URL = DubSynthesizer.cacheDirectory) async throws {
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0 else { throw ScriptError.invalid("The dub track has no duration.") }
        var arguments = ["-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=\(DubPlanning.number(duration))"]
        for line in lines {
            guard let name = line.audio, name == URL(fileURLWithPath: name).lastPathComponent,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw ScriptError.invalid("The dub audio is missing; prepare the dubbed lines before rendering.")
            }
            arguments += ["-i", directory.appendingPathComponent(name).path]
        }
        try await FFmpeg.run(arguments + ["-filter_complex", trackFilter(lines: lines, duration: duration),
            "-map", "[aout]", "-c:a", "pcm_f32le", output.path],
            timeout: 600, capture: .boundedStderrTail(), purpose: "dub track with timed speech")
    }

    @concurrent
    static func overlay(video: URL, track: URL, lines: [DubLine], settings: DubSettings, output: URL) async throws {
        try Task.checkCancellation()
        var arguments = ["-y", "-i", video.path, "-i", track.path]
        if await FFmpeg.hasAudioStream(video) {
            arguments += ["-filter_complex", overlayFilter(lines: lines, settings: settings), "-map", "0:v", "-map", "[aout]"]
        } else {
            arguments += ["-map", "0:v", "-map", "1:a"]
        }
        try await FFmpeg.run(arguments + ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
            "-shortest", "-movflags", "+faststart", output.path],
            timeout: 600, capture: .boundedStderrTail(), purpose: "dub mix; video stream copy")
    }
}
