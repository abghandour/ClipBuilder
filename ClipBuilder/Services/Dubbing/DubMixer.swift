import Foundation

nonisolated enum DubMixer {
    /// Pure filter construction, shared by the mixer and string tests.
    static func trackFilter(lines: [DubLine], duration: Double, freezes: [Range<Double>] = []) -> String {
        var filters = ["[0:a]atrim=duration=\(DubPlanning.number(duration)),asetpts=PTS-STARTPTS[bed]"]
        for (index, line) in lines.enumerated() {
            let layout = DubPauseRules.layout(line, freezes: freezes)
            if layout.stopsForFreeze {
                filters += pausedFilters(line, segments: layout.segments, input: index + 1, output: "line\(index)")
                continue
            }
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

    private static func pausedFilters(_ line: DubLine, segments: [DubPauseRules.Segment], input: Int, output: String) -> [String] {
        let number = DubPlanning.number
        let stretch = number(min(1.15, max(1, line.stretch)))
        let labels = segments.indices.map { "[\(output)s\($0)]" }.joined()
        var filters = ["[\(input):a]asetpts=PTS-STARTPTS,atempo=\(stretch),aresample=48000," +
            "aformat=channel_layouts=stereo,asplit=\(segments.count)\(labels)"]
        for (index, segment) in segments.enumerated() {
            var cut = "[\(output)s\(index)]atrim=start=\(number(segment.audioStart)):end=\(number(segment.audioStart + segment.duration)),asetpts=PTS-STARTPTS"
            if segment.fadeIn > 0 { cut += ",afade=t=in:st=0:d=\(number(segment.fadeIn))" }
            if segment.fadeOut > 0 {
                cut += ",afade=t=out:st=\(number(segment.duration - segment.fadeOut)):d=\(number(segment.fadeOut))"
            }
            // Trim on the timeline clock after cutting/fading: a preview may
            // start in speech, or in the silence between two speech pieces.
            if segment.start < 0 {
                cut += ",atrim=start=\(number(-segment.start)),asetpts=PTS-STARTPTS"
            }
            let delay = Int((max(0, segment.start) * 48000).rounded())
            cut += ",adelay=\(delay)S:all=1[\(output)p\(index)]"
            filters.append(cut)
        }
        let parts = segments.indices.map { "[\(output)p\($0)]" }.joined()
        filters.append("\(parts)amix=inputs=\(segments.count):duration=longest:dropout_transition=0:normalize=0[\(output)]")
        return filters
    }

    /// Replacing the original silences the whole source track, speech and
    /// background noise alike; otherwise it is ducked under each line.
    static func overlayFilter(lines: [DubLine], settings: DubSettings, freezes: [Range<Double>] = [],
                              bumpers: [Range<Double>] = [], sourceAlreadyReplaced: Bool = false) -> String {
        var settings = settings
        if sourceAlreadyReplaced { settings.replaceOriginal = false }
        let ranges = DubSourceEnvelope.sourceRanges(lines: lines, settings: settings, freezes: freezes, bumpers: bumpers)
        var expression = ranges.replace ? "0.0"
            : DubPlanning.duckExpression(envelopes: ranges.duck, level: ranges.level, ramp: 0.15)
        if ranges.replace, !ranges.replacementExclusions.isEmpty {
            let mask = ranges.replacementExclusions.map { "between(t\\,\(DubPlanning.number($0.lowerBound))\\,\(DubPlanning.number($0.upperBound)))" }
            let duck = DubPlanning.duckExpression(envelopes: ranges.duck, level: ranges.level, ramp: 0.15)
            expression = "if(\(DubPlanning.balancedMax(mask[...]))\\,\(duck)\\,0.0)"
        }
        let shortFrames = (!settings.replaceOriginal || !bumpers.isEmpty) && lines.contains {
            DubPauseRules.layout($0, freezes: freezes).stopsForFreeze
        } ? "aresample=48000,asetnsamples=n=256:p=0," : ""
        return "[0:a]\(shortFrames)volume='\(expression)':eval=frame[orig];" +
            "[orig][1:a]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]"
    }

    @concurrent
    static func buildTrack(lines: [DubLine], duration: Double, output: URL,
                           directory: URL = DubSynthesizer.cacheDirectory,
                           freezes: [Range<Double>] = []) async throws {
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
        try await FFmpeg.run(arguments + ["-filter_complex", trackFilter(lines: lines, duration: duration, freezes: freezes),
            "-map", "[aout]", "-c:a", "pcm_f32le", output.path],
            timeout: 600, capture: .boundedStderrTail(), purpose: "dub track with timed speech")
    }

    @concurrent
    static func overlay(video: URL, track: URL, lines: [DubLine], settings: DubSettings, output: URL,
                        freezes: [Range<Double>] = [], bumpers: [Range<Double>] = [],
                        sourceAlreadyReplaced: Bool = false) async throws {
        try Task.checkCancellation()
        var arguments = ["-y", "-i", video.path, "-i", track.path]
        if await FFmpeg.hasAudioStream(video) {
            arguments += ["-filter_complex", overlayFilter(lines: lines, settings: settings, freezes: freezes,
                bumpers: bumpers, sourceAlreadyReplaced: sourceAlreadyReplaced), "-map", "0:v", "-map", "[aout]"]
        } else {
            arguments += ["-map", "0:v", "-map", "1:a"]
        }
        try await FFmpeg.run(arguments + ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
            "-shortest", "-movflags", "+faststart", output.path],
            timeout: 600, capture: .boundedStderrTail(), purpose: "dub mix; video stream copy")
    }
}
