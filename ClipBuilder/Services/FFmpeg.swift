import Foundation
import CryptoKit

nonisolated enum FFmpegError: Error, CustomStringConvertible {
    case toolNotFound(String)
    case commandFailed(tool: String, exitCode: Int32, stderr: String)

    var description: String {
        switch self {
        case .toolNotFound(let tool):
            return "\(tool) not found. Install it with: brew install ffmpeg"
        case .commandFailed(let tool, let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "\(tool) failed (exit \(code)): \(tail)"
        }
    }
}

/// Thin async wrapper over the ffmpeg/ffprobe binaries — same filter graphs
/// as the Python app's pipeline, with hardware (VideoToolbox) encoding and
/// cached probes for speed.
nonisolated enum FFmpeg {
    static func ffmpegURL() throws -> URL {
        guard let url = ProcessRunner.locate("ffmpeg") else { throw FFmpegError.toolNotFound("ffmpeg") }
        return url
    }

    // MARK: - Encoder selection

    /// Whether this ffmpeg build carries the VideoToolbox H.264 encoder —
    /// hardware encoding is 5-10x faster than libx264 on Apple hardware.
    static let hasVideoToolbox: Bool = {
        guard let url = ProcessRunner.locate("ffmpeg") else { return false }
        let process = Process()
        process.executableURL = url
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.contains("h264_videotoolbox") ?? false
    }()

    /// Video encode arguments: hardware VideoToolbox when available
    /// (`-allow_sw 1` lets VT fall back to its software path), else libx264.
    static var videoEncodeArgs: [String] {
        hasVideoToolbox
            ? ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-allow_sw", "1"]
            : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]
    }

    static let audioEncodeArgs = ["-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "128k"]

    /// Standard full encode argument set shared by every render stage.
    static var encodeArgs: [String] {
        videoEncodeArgs + audioEncodeArgs + ["-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    }

    /// How many ffmpeg jobs to run concurrently during segment/clip renders.
    static let jobLimit = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

    static func ffprobeURL() throws -> URL {
        guard let url = ProcessRunner.locate("ffprobe") else { throw FFmpegError.toolNotFound("ffprobe") }
        return url
    }

    static var isAvailable: Bool { ProcessRunner.locate("ffmpeg") != nil }

    /// Run ffmpeg with the given arguments; throws with stderr tail on failure.
    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> String {
        let result = try await ProcessRunner.run(executable: ffmpegURL(),
                                                 arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw FFmpegError.commandFailed(tool: "ffmpeg", exitCode: result.exitCode,
                                            stderr: result.stderrText)
        }
        return result.stdoutText
    }

    static func probe(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable: ffprobeURL(),
                                                 arguments: arguments, timeout: 30)
        guard result.exitCode == 0 else {
            throw FFmpegError.commandFailed(tool: "ffprobe", exitCode: result.exitCode,
                                            stderr: result.stderrText)
        }
        return result.stdoutText
    }

    /// Cache key tied to the file's identity so overwritten paths re-probe.
    private static func probeKey(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(url.path)|\(size)|\(mtime)"
    }

    /// Duration, dimensions, and audio presence from a single cached ffprobe.
    static func info(of url: URL) async -> MediaProbe {
        await ProbeCache.shared.info(for: probeKey(url)) { await probeInfo(url) }
    }

    private static func probeInfo(_ url: URL) async -> MediaProbe {
        let output = (try? await probe(["-v", "quiet",
                                        "-show_entries", "stream=codec_type,width,height:format=duration",
                                        "-of", "json", url.path])) ?? ""
        var info = MediaProbe()
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return info }
        if let format = root["format"] as? [String: Any],
           let durationString = format["duration"] as? String {
            info.duration = Double(durationString) ?? 0
        }
        for stream in root["streams"] as? [[String: Any]] ?? [] {
            switch stream["codec_type"] as? String {
            case "video" where info.width == 0:
                info.width = stream["width"] as? Int ?? 0
                info.height = stream["height"] as? Int ?? 0
            case "audio":
                info.hasAudio = true
            default:
                break
            }
        }
        return info
    }

    static func duration(of url: URL) async -> Double {
        await info(of: url).duration
    }

    static func dimensions(of url: URL) async -> (width: Int, height: Int) {
        let info = await info(of: url)
        return (info.width, info.height)
    }

    /// One JPEG frame piped to stdout — fallback for containers AVFoundation
    /// cannot read (MKV/WebM). `maxDimension` fits the frame in a square box
    /// without upscaling, matching AVAssetImageGenerator.maximumSize.
    static func jpegFrame(of url: URL, at time: Double, maxDimension: CGFloat = 0) async -> Data? {
        var arguments = ["-v", "error",
                         "-ss", String(format: "%.3f", time),
                         "-i", url.path,
                         "-frames:v", "1", "-q:v", "4"]
        if maxDimension > 0 {
            let box = Int(maxDimension)
            arguments += ["-vf", "scale='min(\(box),iw)':'min(\(box),ih)':force_original_aspect_ratio=decrease"]
        }
        arguments += ["-f", "image2", "-"]
        guard let executable = try? ffmpegURL(),
              let result = try? await ProcessRunner.run(executable: executable,
                                                        arguments: arguments, timeout: 30),
              result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    static func hasAudioStream(_ url: URL) async -> Bool {
        await info(of: url).hasAudio
    }

    /// Timestamps (seconds) where the scene-change detector fires — objective
    /// cut positions used as ground truth for reel template analysis.
    static func sceneChangeTimestamps(of url: URL, threshold: Double = 0.3) async throws -> [Double] {
        let result = try await ProcessRunner.run(
            executable: ffmpegURL(),
            arguments: ["-hide_banner", "-i", url.path,
                        "-vf", "select='gt(scene,\(threshold))',showinfo",
                        "-f", "null", "-"],
            timeout: 300)
        guard result.exitCode == 0 else {
            throw FFmpegError.commandFailed(tool: "ffmpeg scene detection",
                                            exitCode: result.exitCode, stderr: result.stderrText)
        }
        // showinfo logs matched frames to stderr as "... pts_time:12.345 ...".
        var timestamps: [Double] = []
        for line in result.stderrText.split(separator: "\n") {
            guard let range = line.range(of: "pts_time:") else { continue }
            let digits = line[range.upperBound...].prefix { "0123456789.".contains($0) }
            if let time = Double(digits) {
                timestamps.append(time.rounded(toPlaces: 2))
            }
        }
        return timestamps
    }
}

/// Everything the pipeline asks ffprobe about a file, gathered in one spawn.
nonisolated struct MediaProbe: Sendable {
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var hasAudio: Bool = false

    var isEmpty: Bool { duration == 0 && width == 0 && !hasAudio }
}

/// Memoizes ffprobe results — source files get probed once per identity
/// instead of once per segment they appear in (each probe is a process spawn).
/// Stores the in-flight Task so concurrent callers racing past an empty cache
/// (e.g. parallel segment renders sharing a source) await one probe.
private actor ProbeCache {
    static let shared = ProbeCache()
    private var probes: [String: Task<MediaProbe, Never>] = [:]

    func info(for key: String, probe: @escaping @Sendable () async -> MediaProbe) async -> MediaProbe {
        if let existing = probes[key] { return await existing.value }
        let task = Task { await probe() }
        probes[key] = task
        let value = await task.value
        // Don't cache a failed probe (unreadable or still-copying file).
        if value.isEmpty { probes[key] = nil }
        return value
    }
}

/// Order-preserving concurrent map with a bounded number of in-flight tasks —
/// used to run independent ffmpeg jobs in parallel without oversubscribing.
nonisolated enum BoundedConcurrency {
    static func map<T: Sendable, R: Sendable>(
        _ items: [T], limit: Int,
        _ transform: @escaping @Sendable (Int, T) async throws -> R
    ) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        var results = [R?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var next = 0
            func addNextTask(_ group: inout ThrowingTaskGroup<(Int, R), Error>) {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, try await transform(index, item)) }
            }
            for _ in 0..<min(max(1, limit), items.count) { addNextTask(&group) }
            while let (index, value) = try await group.next() {
                results[index] = value
                addNextTask(&group)
            }
        }
        return results.compactMap { $0 }
    }
}

/// Content fingerprint matching the Python apps' hash_file(): SHA-256 over
/// the first 1 MB + last 1 MB + the file size as 8 bytes big-endian.
nonisolated enum ContentHash {
    static func fingerprint(of url: URL) throws -> String {
        let chunk = 1024 * 1024
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        if let head = try handle.read(upToCount: chunk) {
            hasher.update(data: head)
        }
        if size > chunk {
            try handle.seek(toOffset: UInt64(size - chunk))
            if let tail = try handle.read(upToCount: chunk) {
                hasher.update(data: tail)
            }
        }
        var sizeBE = UInt64(size).bigEndian
        withUnsafeBytes(of: &sizeBE) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
