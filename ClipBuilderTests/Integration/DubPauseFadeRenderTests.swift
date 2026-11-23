import Foundation
import Testing
@testable import Clip_Builder

@Suite("Dub pause fades and ducking", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct DubPauseFadeRenderTests {
    @Test("Decoded cuts fade for 10 ms and source ducking releases during silence", arguments: [1.0, 1.1])
    func fadesAndDucking(stretch: Double) async throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("constant.caf")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i",
            "aevalsrc=0.25|0.25:s=48000:d=3.3", "-c:a", "pcm_f32le", source.path], timeout: 60)
        let line = DubLine(clipUID: UUID(), speakerKey: "host", voice: "fixture", text: "Speech",
            sourceStart: 0, sourceEnd: 3, start: 0.5, duration: 3, stretch: stretch,
            audio: source.lastPathComponent)
        let freezes = [1.5..<2.5]
        let track = temp.url.appendingPathComponent("paused.caf")
        try await DubMixer.buildTrack(lines: [line], duration: 5, output: track, directory: temp.url, freezes: freezes)
        let speech = temp.url.appendingPathComponent("speech.f32")
        try await FFmpeg.run(["-y", "-i", track.path, "-ac", "1", "-ar", "48000",
            "-f", "f32le", speech.path], timeout: 60, mediaResource: .decoding)

        // A silent dub input isolates the source envelope from the mixed voice.
        let original = temp.url.appendingPathComponent("ducked.f32")
        let settings = DubSettings(language: "en-US", originalLevel: 0.15, replaceOriginal: false)
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "aevalsrc=0.25:s=48000:d=5",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono:d=5",
            "-filter_complex", DubMixer.overlayFilter(lines: [line], settings: settings, freezes: freezes),
            "-map", "[aout]", "-ac", "1", "-ar", "48000", "-f", "f32le", original.path], timeout: 60)
        try await Self.check(speech: speech, original: original)
    }

    @concurrent
    nonisolated private static func check(speech: URL, original: URL) async throws {
        let voice = try samples(speech), bed = try samples(original)
        try #require(voice.count >= 240000 && bed.count >= 240000)
        let full = energy(voice, at: 1, duration: 0.1)
        #expect(full > 0.01)
        // A linear fade has one third of the unfaded energy over its 10 ms.
        for start in [1.49, 2.5] {
            let fraction = energy(voice, at: start, duration: 0.01) / full
            #expect(fraction > 0.28 && fraction < 0.39)
        }
        for start in [1.499, 2.5] {
            #expect(energy(voice, at: start, duration: 0.001) / full < 0.02)
        }
        #expect(energy(voice, at: 1.6, duration: 0.8) < 1e-10)
        let source = energy(bed, at: 0.1, duration: 0.1)
        #expect(source > 0.01)
        for start in [1.0, 2.8] {
            let fraction = energy(bed, at: start, duration: 0.1) / source
            #expect(abs(fraction - 0.15 * 0.15) < 0.005)
        }
        #expect(abs(energy(bed, at: 1.8, duration: 0.3) / source - 1) < 0.01)
        // Four probes through each 40 ms ramp must see intermediate levels.
        // 1024-sample volume frames can miss these; 256 samples cannot.
        let release = [1.466, 1.477, 1.488, 1.499].map { sqrt(energy(bed, at: $0, duration: 0.001) / source) }
        let attack = [2.506, 2.517, 2.528, 2.539].map { sqrt(energy(bed, at: $0, duration: 0.001) / source) }
        #expect(zip(release, release.dropFirst()).allSatisfy { $0 < $1 })
        #expect(zip(attack, attack.dropFirst()).allSatisfy { $0 > $1 })
        #expect(release[1] > 0.3 && release[1] < 0.65)
        #expect(attack[1] > 0.6 && attack[1] < 0.85)
    }

    nonisolated private static func samples(_ url: URL) throws -> [Double] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count, by: 4).map {
                Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))))
            }
        }
    }

    nonisolated private static func energy(_ samples: [Double], at start: Double, duration: Double) -> Double {
        let lower = Int((start * 48000).rounded()), upper = Int(((start + duration) * 48000).rounded())
        return samples[lower..<upper].reduce(0) { $0 + $1 * $1 } / Double(upper - lower)
    }
}
