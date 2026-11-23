import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike impact rendering", .enabled(if: FFmpeg.isAvailable))
struct StrikeImpactRenderIntegrationTests {
    @concurrent private func source(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=640x360:r=30:d=4",
            "-f", "lavfi", "-i", "color=c=red:s=80x180:r=30:d=4",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4",
            "-filter_complex", "[0:v][1:v]overlay=x='60+60*t':y=90[v]",
            "-map", "[v]", "-map", "2:a", "-t", "4", "-c:v", "libx264", "-crf", "10",
            "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
    }

    @concurrent private func pixels(_ url: URL, at time: Double, folder: URL) async throws -> [UInt8] {
        let output = folder.appendingPathComponent(UUID().uuidString + ".rgb")
        defer { try? FileManager.default.removeItem(at: output) }
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", url.path,
            "-frames:v", "1", "-vf", "format=rgb24", "-f", "rawvideo", output.path], timeout: 60)
        return [UInt8](try Data(contentsOf: output))
    }

    @concurrent private func frame(_ url: URL, at time: Double, folder: URL) async throws -> URL {
        let output = folder.appendingPathComponent(UUID().uuidString + ".mkv")
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", url.path,
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-map", "0:v:0", "-map", "1:a:0",
            "-vf", "setpts=PTS-STARTPTS", "-t", "0.033333", "-c:v", "ffv1", "-c:a", "pcm_s16le", output.path], timeout: 60)
        return output
    }

    @Test("Flash clears; a 0.6-second lead plays for 2.4 seconds at 0.25x", arguments: [false, true])
    func flashAndSlowMotion(hold: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("moving.mp4")
        try await source(input)
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3)
        clip.videoFile = input.path
        clip.sourceEnd = 3
        clip.speed = 1
        clip.wide = false
        clip.captions = "none"
        let paused = hold ? StrikeFreezeRules.pieces(clip, contacts: [1.5], hold: 0.8) : [clip]
        let slowed = StrikeImpactRules.slowed(paused, contacts: [1.5], strength: .strong)
        let pieces = StrikeImpactRules.flashed(slowed, contacts: [1.5])
        let slow = try #require(pieces.first { $0.speed == 0.25 })
        #expect(abs(slow.duration - 2.4) < 1e-9)
        let flash = try #require(pieces.first { $0.flashIn != nil })
        #expect(abs(flash.startTime - 3.3) < 1e-9)
        let duration = 4.8 + (hold ? 0.8 : 0)
        var document = Fixtures.timelineDocument(clips: pieces)
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: duration)]
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false)
        let rendered = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        #expect(abs(await FFmpeg.duration(of: rendered.url) - duration) < 0.08)
        let white = try await pixels(rendered.url, at: flash.startTime, folder: folder)
        let clear = try await pixels(rendered.url, at: flash.startTime + 0.2, folder: folder)
        #expect(white.count == 640 * 360 * 3 && clear.count == white.count)
        #expect(Double(white.filter { $0 > 235 }.count) / Double(max(1, white.count)) > 0.95)
        #expect(Double(clear.filter { $0 > 235 }.count) / Double(max(1, clear.count)) < 0.5)
        // Probe the moving source through the stretch, not just its metadata.
        for offset in [0.5, 1.5, 2.3] {
            let actual = try await frame(rendered.url, at: slow.startTime + offset, folder: folder)
            let expected = try await frame(input, at: 0.9 + offset * 0.25, folder: folder)
            #expect(try await MultitrackRenderTests.compareDecoded(actual, expected).minimumSSIM >= 0.98)
        }
        // A preview entering a flashed piece never starts a second flash.
        let window = MultitrackRenderer.windowed(document, from: flash.startTime + 0.05, to: flash.startTime + 0.5)
        let preview = try await renderer.render(document: window, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: preview.url) }
        let entered = try await pixels(preview.url, at: 0, folder: folder)
        #expect(Double(entered.filter { $0 > 235 }.count) / Double(max(1, entered.count)) < 0.5)
    }
}
