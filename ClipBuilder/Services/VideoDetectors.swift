import Foundation

nonisolated struct VideoDetectors: Codable, Sendable {
    var black: [ClosedRange<Double>] = []
    var frozen: [ClosedRange<Double>] = []
    var cuts: [Double] = []

    static func parse(_ stderr: String, duration: Double) -> VideoDetectors {
        var result = VideoDetectors()
        let regex = try! NSRegularExpression(pattern: #"(black_start|black_end|freeze_start|freeze_end)\s*[:=]\s*([0-9.]+)"#)
        var starts: [String: Double] = [:]
        let source = stderr as NSString
        for match in regex.matches(in: stderr, range: NSRange(location: 0, length: source.length)) {
            let key = source.substring(with: match.range(at: 1))
            guard let value = Double(source.substring(with: match.range(at: 2))), value.isFinite else { continue }
            let kind = key.hasPrefix("black") ? "black" : "freeze"
            if key.hasSuffix("start") { starts[kind] = max(0, value) }
            else if let start = starts.removeValue(forKey: kind), value >= start, start <= duration {
                if kind == "black" { result.black.append(start...min(duration, value)) }
                else { result.frozen.append(start...min(duration, value)) }
            }
        }
        if let start = starts["black"], start < duration { result.black.append(start...duration) }
        if let start = starts["freeze"], start < duration { result.frozen.append(start...duration) }
        return result
    }

    func contentWindow(duration: Double) -> ClosedRange<Double>? {
        guard duration.isFinite, duration > 0 else { return nil }
        let ranges = (black + frozen).sorted { $0.lowerBound < $1.lowerBound }
        var start = 0.0, end = duration
        for range in ranges where range.lowerBound <= start + 0.15 { start = max(start, range.upperBound) }
        for range in ranges.reversed() where range.upperBound >= end - 0.15 { end = min(end, range.lowerBound) }
        let trimmed = start + duration - end
        if trimmed == 0 { return 0...duration }
        guard trimmed >= 3, trimmed <= duration * 0.4, end > start else { return nil }
        return start...end
    }
}

extension FFmpeg {
    nonisolated static func runCapturingStderr(_ arguments: [String], timeout: TimeInterval = 120) async throws -> String {
        let result = try await ProcessRunner.run(executable: ffmpegURL(), arguments: arguments,
                                                 timeout: timeout, mediaResource: .decoding)
        guard result.exitCode == 0 else {
            throw FFmpegError.commandFailed(tool: "ffmpeg", exitCode: result.exitCode, stderr: result.stderrText)
        }
        return result.stderrText
    }
    /// The black/freeze scan and the scene-change scan run concurrently,
    /// each decoding through VideoToolbox when the build offers it. Hardware
    /// decoding leaves the filters bound by their own single thread, so two
    /// passes finish sooner than one combined graph, at a fraction of the
    /// CPU of two software decodes. `CLIPBUILDER_DETECTOR_MODE=legacy`
    /// restores the sequential software passes for same-binary measurement.
    /// The filters, thresholds and parsers are unchanged, so events match
    /// the earlier scan exactly and cached results stay valid; changes to
    /// them still require bumping the ReelDetectorCache key version.
    nonisolated static var legacyDetectorPasses: Bool {
        ProcessInfo.processInfo.environment["CLIPBUILDER_DETECTOR_MODE"] == "legacy"
    }

    nonisolated static func detectorTimeout(duration: Double) -> TimeInterval {
        max(300, min(3600, duration * 5))
    }

    nonisolated static func detectors(of url: URL, duration: Double) async throws -> VideoDetectors {
        let timeout = detectorTimeout(duration: duration)
        if legacyDetectorPasses {
            var result = try await detectorSignals(of: url, duration: duration, timeout: timeout, hardware: false)
            result.cuts = try await sceneChangeTimestamps(of: url, timeout: timeout, hardware: false)
            return result
        }
        async let signals = detectorSignals(of: url, duration: duration, timeout: timeout, hardware: true)
        async let cuts = sceneChangeTimestamps(of: url, timeout: timeout, hardware: true)
        var result = try await signals
        result.cuts = try await cuts
        return result
    }

    /// Black and frozen runs. A hardware-decode failure retries in software
    /// before the older-build mpdecimate fallback is considered.
    nonisolated static func detectorSignals(of url: URL, duration: Double, timeout: TimeInterval,
                                            hardware: Bool) async throws -> VideoDetectors {
        let filters = "blackdetect=d=1.0:pic_th=0.98,freezedetect=n=-50dB:d=2"
        do {
            let stderr = try await runCapturingStderr(decodeArguments(hardware: hardware) +
                ["-hide_banner", "-i", url.path, "-vf", filters, "-an", "-f", "null", "-"], timeout: timeout)
            return VideoDetectors.parse(stderr, duration: duration)
        } catch FFmpegError.commandFailed(_, _, let stderr) where stderr.contains("No such filter") && stderr.contains("freezedetect") {
            let stderr = try await runCapturingStderr(["-hide_banner", "-i", url.path, "-vf",
                "blackdetect=d=1.0:pic_th=0.98,mpdecimate,showinfo", "-an", "-f", "null", "-"], timeout: timeout)
            var result = VideoDetectors.parse(stderr, duration: duration)
            result.frozen = VideoDetectors.decimatedGaps(stderr, duration: duration)
            return result
        } catch FFmpegError.commandFailed where hardware && hardwareDecodeArguments.isEmpty == false {
            try Task.checkCancellation()
            return try await detectorSignals(of: url, duration: duration, timeout: timeout, hardware: false)
        }
    }
    nonisolated static func blackSegments(of url: URL) async throws -> [ClosedRange<Double>] {
        try await detectors(of: url, duration: duration(of: url)).black
    }
    nonisolated static func frozenSegments(of url: URL) async throws -> [ClosedRange<Double>] {
        try await detectors(of: url, duration: duration(of: url)).frozen
    }
}

extension VideoDetectors {
    /// Retained-frame timestamp gaps measure runs removed by mpdecimate.
    nonisolated static func decimatedGaps(_ stderr: String, duration: Double) -> [ClosedRange<Double>] {
        let regex = try! NSRegularExpression(pattern: #"pts_time:\s*([0-9.]+)"#)
        let source = stderr as NSString
        let times = regex.matches(in: stderr, range: NSRange(location: 0, length: source.length))
            .compactMap { Double(source.substring(with: $0.range(at: 1))) }
            .filter { $0.isFinite && $0 >= 0 && $0 <= duration }.sorted()
        guard !times.isEmpty else { return [] }
        return zip(times, times.dropFirst() + [duration]).compactMap { start, end in
            end - start >= 2 ? start...end : nil
        }
    }
}
