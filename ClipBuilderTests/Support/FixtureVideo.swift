import Foundation
@testable import Clip_Builder

/// Generated on demand into a temp directory — never committed.
enum FixtureVideo {
    nonisolated static var integrationsAvailable: Bool {
        ProcessRunner.locate("ffmpeg") != nil
            && ProcessRunner.locate("ffprobe") != nil
    }

    /// A 3-second test pattern: 1920x1080 (`wide`) or 720x1280, with a
    /// 440 Hz tone unless `silent`.
    static func make(in directory: URL, wide: Bool = false, silent: Bool = false) async throws -> URL {
        let output = directory.appendingPathComponent(
            "fixture-\(wide ? "wide" : "portrait")-\(silent ? "silent" : "audio").mp4"
        )
        let size = wide ? "1920x1080" : "720x1280"
        var arguments = ["-y", "-f", "lavfi", "-i", "testsrc=size=\(size):rate=30"]
        if !silent {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=440"]
        }
        arguments += ["-t", "3", "-c:v", "libx264", "-pix_fmt", "yuv420p"]
        if !silent { arguments += ["-c:a", "aac", "-shortest"] }
        arguments.append(output.path)
        _ = try await FFmpeg.run(arguments, timeout: 60)
        return output
    }

    /// A 16:9 picture letterboxed into a 720x1280 portrait frame: black
    /// bars above and below, the picture in the middle half.
    static func makeLetterboxed(in directory: URL) async throws -> URL {
        let output = directory.appendingPathComponent("fixture-letterboxed.mp4")
        _ = try await FFmpeg.run([
            "-y", "-f", "lavfi", "-i", "testsrc=size=720x640:rate=30",
            "-t", "3", "-vf", "pad=720:1280:0:320:black",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", output.path,
        ], timeout: 60)
        return output
    }

    /// A tone in an m4a container, usable as a music asset.
    static func makeMusic(in directory: URL, seconds: Double = 6, name: String = "fixture-music") async throws -> URL {
        let output = directory.appendingPathComponent("\(name).m4a")
        _ = try await FFmpeg.run([
            "-y", "-f", "lavfi", "-i", "sine=frequency=220",
            "-t", String(seconds), "-c:a", "aac", output.path,
        ], timeout: 60)
        return output
    }

    /// Four alternating tones under stable colored left/right panels. This
    /// gives podcast diarization and split-feed rendering a deterministic,
    /// generated-on-demand integration fixture.
    static func makePodcast(in directory: URL) async throws -> URL {
        let output = directory.appendingPathComponent("fixture-podcast.mp4")
        let filter = """
        [1:a]pan=stereo|c0=c0|c1=0*c0[a1];\
        [2:a]pan=stereo|c0=0*c0|c1=c0[a2];\
        [3:a]pan=stereo|c0=c0|c1=0*c0[a3];\
        [4:a]pan=stereo|c0=0*c0|c1=c0[a4];\
        [a1][a2][a3][a4]concat=n=4:v=0:a=1[a]
        """
        _ = try await FFmpeg.run([
            "-y", "-f", "lavfi", "-i",
            "color=c=0x24324a:size=1280x720:rate=30,drawbox=x=640:y=0:w=640:h=720:color=0x704035:t=fill",
            "-f", "lavfi", "-t", "1", "-i", "sine=frequency=220:sample_rate=16000",
            "-f", "lavfi", "-t", "1", "-i", "sine=frequency=660:sample_rate=16000",
            "-f", "lavfi", "-t", "1", "-i", "sine=frequency=220:sample_rate=16000",
            "-f", "lavfi", "-t", "1", "-i", "sine=frequency=660:sample_rate=16000",
            "-filter_complex", filter, "-map", "0:v", "-map", "[a]", "-t", "4",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", output.path,
        ], timeout: 60)
        return output
    }
}
