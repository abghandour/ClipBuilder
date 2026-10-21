import Foundation
import Testing
import Synchronization
@testable import Clip_Builder

@Suite("Intermediate media policy")
struct FFmpegIntermediateTests {
    @Test("disabled hardware decode preserves the pre-experiment cache key layout")
    func softwareCacheIdentity() throws {
        try ExpressRenderTesting.$hardwareDecodeIntermediates.withValue(false) {
            #expect(FFmpeg.intermediateCacheIdentity.isEmpty)
            let encoder = ["-c:v", "h264_videotoolbox", "-c:a", "aac"]
            var input = RenderSegmentKey(start: 0, duration: 1, clips: [], captions: [],
                overlays: [], masks: [:], fontFingerprints: [], captionStyle: CaptionStyle(),
                settings: RenderSettings(), encoder: encoder)
            let before = try RenderSegmentCache.key(input)
            input.encoder = encoder + FFmpeg.intermediateCacheIdentity
            #expect(try RenderSegmentCache.key(input) == before)
            #expect(!String(decoding: try JSONEncoder().encode(input), as: UTF8.self).contains("hw-decode"))
        }
        ExpressRenderTesting.$hardwareDecodeIntermediates.withValue(true) {
            #expect(FFmpeg.intermediateCacheIdentity == ["hw-decode=true"])
        }
    }

    @Test("software retry strips every hardware input without changing filters or encoding")
    func softwareArguments() {
        let software = ["-y", "-ss", "1", "-i", "first.mp4", "-i", "second.mp4",
            "-filter_complex", "[0:v][1:v]overlay[v]", "-map", "[v]",
            "-c:v", "h264_videotoolbox", "output.mp4"]
        var hardware = software
        hardware.insert(contentsOf: ["-hwaccel", "videotoolbox"], at: 5)
        hardware.insert(contentsOf: ["-hwaccel", "videotoolbox"], at: 1)
        #expect(FFmpeg.softwareDecodeArguments(hardware) == software)
        #expect(FFmpeg.softwareDecodeArguments(software) == software)
        #expect(FFmpeg.softwareDecodeArguments(["-hwaccel"]) == ["-hwaccel"])
    }

    @Test("a failed hardware command retries once in software and logs the fallback")
    func softwareRetry() async throws {
        let calls = Mutex<[[String]]>([])
        let messages = Mutex<[String]>([])
        let arguments = ["-y", "-hwaccel", "videotoolbox", "-i", "clip.mp4", "output.mp4"]
        let result = try await FFmpeg.$renderLog.withValue({ line in messages.withLock { $0.append(line) } }) {
            try await FFmpeg.withSoftwareDecodeFallback(arguments) { attempt in
                calls.withLock { $0.append(attempt) }
                if attempt.contains("-hwaccel") {
                    throw FFmpegError.commandFailed(tool: "ffmpeg", exitCode: 1, stderr: "hardware unavailable")
                }
                return "success"
            }
        }
        #expect(result == "success")
        #expect(calls.withLock { $0 } == [arguments, ["-y", "-i", "clip.mp4", "output.mp4"]])
        #expect(messages.withLock { $0 } == ["Decode: hardware failed; retrying in software"])
    }

    @Test("software failure is propagated without another retry")
    func softwareFailure() async {
        let calls = Mutex(0)
        do {
            _ = try await FFmpeg.withSoftwareDecodeFallback(["-i", "missing.mp4", "output.mp4"]) { _ in
                calls.withLock { $0 += 1 }
                throw FFmpegError.commandFailed(tool: "ffmpeg", exitCode: 1, stderr: "missing input")
            }
            Issue.record("Expected the software command failure")
        } catch {
            #expect(calls.withLock { $0 } == 1)
        }
    }

    @Test("hardware candidates require portrait 1080p H.264")
    func probeEligibility() {
        let valid = MediaProbe(duration: 1, width: 1080, height: 1920, hasAudio: true,
            videoCodec: "h264")
        #expect(valid.isPortraitH264Intermediate)
        var changed = valid; changed.videoCodec = "hevc"
        #expect(!changed.isPortraitH264Intermediate)
        changed = valid; changed.width = 1920; changed.height = 1080
        #expect(!changed.isPortraitH264Intermediate)
    }
}
