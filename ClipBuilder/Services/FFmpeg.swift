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

    static func duration(of url: URL) async -> Double {
        let key = probeKey(url)
        if let cached = await ProbeCache.shared.duration(key) { return cached }
        let output = (try? await probe(["-v", "quiet", "-show_entries", "format=duration",
                                        "-of", "csv=p=0", url.path])) ?? ""
        let value = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if value > 0 { await ProbeCache.shared.setDuration(value, for: key) }
        return value
    }

    static func dimensions(of url: URL) async -> (width: Int, height: Int) {
        let output = (try? await probe(["-v", "quiet", "-select_streams", "v:0",
                                        "-show_entries", "stream=width,height",
                                        "-of", "csv=p=0", url.path])) ?? ""
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard parts.count >= 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return (0, 0) }
        return (w, h)
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
        let key = probeKey(url)
        if let cached = await ProbeCache.shared.hasAudio(key) { return cached }
        let output = (try? await probe(["-v", "quiet", "-select_streams", "a",
                                        "-show_entries", "stream=index",
                                        "-of", "csv=p=0", url.path])) ?? ""
        let value = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        await ProbeCache.shared.setHasAudio(value, for: key)
        return value
    }
}

/// Memoizes ffprobe results — source files get probed once per identity
/// instead of once per segment they appear in (each probe is a process spawn).
private actor ProbeCache {
    static let shared = ProbeCache()
    private var durations: [String: Double] = [:]
    private var audio: [String: Bool] = [:]

    func duration(_ key: String) -> Double? { durations[key] }
    func setDuration(_ value: Double, for key: String) { durations[key] = value }
    func hasAudio(_ key: String) -> Bool? { audio[key] }
    func setHasAudio(_ value: Bool, for key: String) { audio[key] = value }
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
