import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

/// The wizard hands the compositor clips it already normalized to the output
/// format. Those segments are copied, not encoded a second time.
@Suite("Prerendered segment passthrough", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct PrerenderedSegmentTests {
    /// A 3-second clip at the document's output size with audio, like a wizard clip.
    private func prerenderedClip(in directory: URL, name: String, settings: RenderSettings) async throws -> URL {
        let output = directory.appendingPathComponent("\(name).mp4")
        _ = try await FFmpeg.run([
            "-y", "-f", "lavfi", "-i", "testsrc=size=\(settings.width)x\(settings.height):rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440", "-t", "3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "44100", "-ac", "2", output.path,
        ], timeout: 120)
        return output
    }

    @Test func wholeNormalizedClipsAreCopiedNotEncoded() async throws {
        let temp = try await TempDatabase()
        let document0 = Fixtures.timelineDocument(clips: [])
        let first = try await prerenderedClip(in: temp.directory.url, name: "clip-a", settings: document0.renderSettings)
        let second = try await prerenderedClip(in: temp.directory.url, name: "clip-b", settings: document0.renderSettings)
        var clipA = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3, startTime: 0)
        clipA.videoFile = first.path
        clipA.captions = "none"
        var clipB = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3, startTime: 3)
        clipB.videoFile = second.path
        clipB.captions = "none"
        var document = Fixtures.timelineDocument(clips: [clipA, clipB])
        var text = TextOverlayItem()
        text.text = "Express overlay"
        text.unbounded = true
        var block = OverlayBlockItem()
        block.composition = OverlayComposition(texts: [text])
        block.startTime = 0
        block.duration = 6
        block.exactPlacement = true
        document.overlayBlocks = [block]
        let profile = Fixtures.brand(name: "Passthrough")
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("segments"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache)

        let lines = Mutex<[String]>([])
        let result = try await renderer.render(document: document, scenes: [], profile: profile, database: temp.database,
            preview: true, prerenderedSources: [first.path, second.path], emit: { line in lines.withLock { $0.append(line) } })
        defer { try? FileManager.default.removeItem(at: result.url) }
        let log = lines.withLock { $0 }
        #expect(log.filter { $0.contains("prerendered clip; copied") }.count == 2, "\(log)")
        #expect(!log.contains { $0.contains("encode pass") })
        // The overlay is not fused into copied segments; it runs as one final pass.
        #expect(!log.contains { $0.contains("fused into segments") })
        #expect(abs(result.duration - 6) < 0.2)
        let dimensions = await FFmpeg.dimensions(of: result.url)
        #expect(dimensions.width == document.renderSettings.width && dimensions.height == document.renderSettings.height)

        // The same document without the hint, or with a trimmed clip, encodes as before.
        lines.withLock { $0.removeAll() }
        let plain = try await renderer.render(document: document, scenes: [], profile: profile, database: temp.database,
            preview: true, emit: { line in lines.withLock { $0.append(line) } })
        defer { try? FileManager.default.removeItem(at: plain.url) }
        #expect(lines.withLock { $0 }.filter { $0.contains("encode pass") }.count == 2)
        #expect(!lines.withLock { $0 }.contains { $0.contains("prerendered clip") })

        var trimmed = document
        trimmed.videoTrack[0].sourceStart = 0.5
        trimmed.videoTrack[0].sourceEnd = 3
        trimmed.videoTrack[0].duration = 2.5
        trimmed.videoTrack[1].startTime = 2.5
        lines.withLock { $0.removeAll() }
        let mixed = try await renderer.render(document: trimmed, scenes: [], profile: profile, database: temp.database,
            preview: true, prerenderedSources: [first.path, second.path], emit: { line in lines.withLock { $0.append(line) } })
        defer { try? FileManager.default.removeItem(at: mixed.url) }
        #expect(lines.withLock { $0 }.filter { $0.contains("prerendered clip; copied") }.count == 1)
        #expect(lines.withLock { $0 }.filter { $0.contains("encode pass") }.count == 1)
    }
}
