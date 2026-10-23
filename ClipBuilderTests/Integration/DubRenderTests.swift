import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Dubbing renderer integration", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct DubRenderTests {
    @Test("decoded audio has timed dub energy, lowered original, and no stale finishing cache")
    func dubWindowsAndOriginalLevel() async throws {
        let temp = try TempDatabase()
        let source = temp.directory.url.appendingPathComponent("source.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=blue:s=360x640:r=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        let dubDirectory = temp.directory.url.appendingPathComponent("dubs")
        try FileManager.default.createDirectory(at: dubDirectory, withIntermediateDirectories: true)
        let speech = dubDirectory.appendingPathComponent("fixture.caf")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
            "-t", "1", "-c:a", "pcm_f32le", speech.path], timeout: 60)
        var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3)
        first.videoFile = source.path; first.transOut = "cut"
        var second = first
        second.uid = UUID(); second.originKey = UUID().uuidString; second.startTime = 3
        var document = Fixtures.timelineDocument(clips: [first, second])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        document.dubLines = [first, second].map { clip in
            // Cached fixtures make this test independent of installed voices.
            DubLine(clipUID: clip.uid, speakerKey: "unknown", voice: "fixture", text: "Speech",
                sourceStart: 1, sourceEnd: 2, start: clip.startTime + 1, duration: 1, audio: speech.lastPathComponent)
        }
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("render-cache"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache,
            dubSynthesizer: DubSynthesizer(directory: dubDirectory))
        var outputs: [URL] = []
        defer { for url in outputs { try? FileManager.default.removeItem(at: url) } }
        // Nil settings must ignore even present dubLines and preserve source audio.
        let original = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        outputs.append(original.url)
        document.dub = DubSettings(language: "en-US", replaceOriginal: false)
        let messages = Mutex<[String]>([])
        let dubbed = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        outputs.append(dubbed.url)
        #expect(!messages.withLock { $0.contains("Finishing cache hit; assembly and overlay encodes=0") })
        #expect(abs(original.duration - dubbed.duration) < 0.05)
        let reference = try await decode(original.url, in: temp.directory.url)
        let candidate = try await decode(dubbed.url, in: temp.directory.url)
        for start in [1.2, 4.2] {
            let before = try await Self.amplitude(reference, frequency: 440, start: start, duration: 0.6)
            let after = try await Self.amplitude(candidate, frequency: 440, start: start, duration: 0.6)
            #expect(before > 0.03)
            #expect(after / before > 0.08 && after / before < 0.23)
            #expect(try await Self.amplitude(candidate, frequency: 1000, start: start, duration: 0.6) > 0.04)
        }
        for start in [0.3, 2.4, 3.3, 5.3] {
            let before = try await Self.amplitude(reference, frequency: 440, start: start, duration: 0.3)
            let after = try await Self.amplitude(candidate, frequency: 440, start: start, duration: 0.3)
            #expect(after / before > 0.8 && after / before < 1.2)
            #expect(try await Self.amplitude(candidate, frequency: 1000, start: start, duration: 0.3) < 0.01)
        }
        messages.withLock { $0 = [] }
        let cached = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        outputs.append(cached.url)
        #expect(messages.withLock { $0.contains("Finishing cache hit; assembly and overlay encodes=0") })
        document.dub?.replaceOriginal = true
        messages.withLock { $0 = [] }
        let replaced = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        outputs.append(replaced.url)
        #expect(!messages.withLock { $0.contains("Finishing cache hit; assembly and overlay encodes=0") })
        let clean = try await decode(replaced.url, in: temp.directory.url)
        #expect(try await Self.amplitude(clean, frequency: 440, start: 1.2, duration: 0.6) < 0.005)
        #expect(try await Self.amplitude(clean, frequency: 1000, start: 1.2, duration: 0.6) > 0.04)
        // Muted means the whole source track, background between lines included.
        #expect(try await Self.amplitude(clean, frequency: 440, start: 0.3, duration: 0.3) < 0.005)
    }

    private func decode(_ video: URL, in directory: URL) async throws -> URL {
        let output = directory.appendingPathComponent(UUID().uuidString + ".f32")
        try await FFmpeg.run(["-y", "-i", video.path, "-vn", "-ac", "1", "-ar", "48000",
            "-c:a", "pcm_f32le", "-f", "f32le", output.path], timeout: 60, mediaResource: .decoding)
        return output
    }

    /// Like compareDecoded, inspect decoded media rather than hardware encode
    /// bytes. Quadrature energy tolerates AAC priming/phase shifts while separating
    /// the original (440 Hz) and dub (1000 Hz) in the same audible window.
    @concurrent
    nonisolated private static func amplitude(_ pcm: URL, frequency: Double, start: Double, duration: Double) async throws -> Double {
        let data = try Data(contentsOf: pcm)
        let lower = Int(start * 48000), count = Int(duration * 48000)
        guard count > 0, (lower + count) * 4 <= data.count else {
            throw ScriptError.invalid("Decoded audio did not cover the expected dub window.")
        }
        return data.withUnsafeBytes { bytes in
            var sine = 0.0, cosine = 0.0
            for index in 0..<count {
                let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: (lower + index) * 4, as: UInt32.self))
                let sample = Double(Float(bitPattern: bits))
                let phase = 2 * Double.pi * frequency * Double(index) / 48000
                sine += sample * sin(phase)
                cosine += sample * cos(phase)
            }
            return 2 * hypot(sine, cosine) / Double(count)
        }
    }
}
