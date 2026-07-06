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

/// Thin async wrapper over the ffmpeg/ffprobe binaries — same commands the
/// Python app runs, so output files are bit-compatible with its pipeline.
nonisolated enum FFmpeg {
    static func ffmpegURL() throws -> URL {
        guard let url = ProcessRunner.locate("ffmpeg") else { throw FFmpegError.toolNotFound("ffmpeg") }
        return url
    }

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

    static func duration(of url: URL) async -> Double {
        let output = (try? await probe(["-v", "quiet", "-show_entries", "format=duration",
                                        "-of", "csv=p=0", url.path])) ?? ""
        return Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
        let output = (try? await probe(["-v", "quiet", "-select_streams", "a",
                                        "-show_entries", "stream=index",
                                        "-of", "csv=p=0", url.path])) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
