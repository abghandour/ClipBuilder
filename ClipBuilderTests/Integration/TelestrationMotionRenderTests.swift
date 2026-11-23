import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration drawing over moving footage", .enabled(if: FFmpeg.isAvailable))
struct TelestrationMotionRenderTests {
    @concurrent private func source(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=640x360:r=30:d=6",
            "-f", "lavfi", "-i", "color=c=red:s=80x180:r=30:d=6",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=6",
            "-filter_complex", "[0:v][1:v]overlay=x='60+60*t':y=90[v]",
            "-map", "[v]", "-map", "2:a", "-t", "6", "-c:v", "libx264", "-crf", "10",
            "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
    }

    @concurrent private func yellowPixels(_ url: URL, at time: Double, folder: URL) async throws -> Int {
        let output = folder.appendingPathComponent(UUID().uuidString + ".rgb")
        defer { try? FileManager.default.removeItem(at: output) }
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", url.path,
            "-frames:v", "1", "-vf", "format=rgb24", "-f", "rawvideo", output.path], timeout: 60)
        let pixels = [UInt8](try Data(contentsOf: output))
        #expect(pixels.count == 640 * 360 * 3)
        guard pixels.count == 640 * 360 * 3 else { return 0 }
        return (0..<640).count { x in
            let i = (72 * 640 + x) * 3
            return pixels[i] > 190 && pixels[i + 1] > 190 && pixels[i + 2] < 80
        }
    }

    /// The figure occupies y=72; compare the untouched footage below it.
    @concurrent private func frame(_ url: URL, at time: Double, folder: URL) async throws -> URL {
        let output = folder.appendingPathComponent(UUID().uuidString + ".mkv")
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", url.path,
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-map", "0:v:0", "-map", "1:a:0",
            "-vf", "crop=640:260:0:100,setpts=PTS-STARTPTS", "-t", "0.033333",
            "-c:v", "ffv1", "-c:a", "pcm_s16le", output.path], timeout: 60)
        return output
    }

    @Test("Picture advances at the drawing rate; animation progresses, expires, and preserves audio", arguments: [0.25, 0.5, 1.0])
    func movingDrawing(motion: Double) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("moving.mp4")
        try await source(input)
        let drawing = Telestration(time: 1, figures: [.init(kind: .line,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.2)], color: .yellow, width: 0.016)],
            stay: 1, drawSpeed: 0.5, fade: 0.5, motion: motion)
        var sourceClip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 5)
        sourceClip.videoFile = input.path
        sourceClip.wide = false
        sourceClip.captions = "none"
        var pieces = TelestrationMotionRules.moving([sourceClip], drawings: [drawing]).pieces
        for index in pieces.indices { pieces[index].timedAssembly = true }
        let duration = 5 + drawing.duration * (1 - motion)
        var document = Fixtures.timelineDocument(clips: pieces)
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        // Also split the drawing for a crop block, keeping its original clock.
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 1.8),
                               .init(layout: .fullScreen, startTime: 1.8, duration: duration - 1.8)]
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false)
        let rendered = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        #expect(abs(await FFmpeg.duration(of: rendered.url) - duration) < 0.08)
        let early = try await yellowPixels(rendered.url, at: 1.2, folder: folder)
        let drawn = try await yellowPixels(rendered.url, at: 1.6, folder: folder)
        #expect(early > 0 && early < drawn && drawn > 450)
        #expect(try await yellowPixels(rendered.url, at: 2.1, folder: folder) > 450)
        #expect(try await yellowPixels(rendered.url, at: 3.2, folder: folder) == 0)
        for elapsed in [0.4, 1.2, 1.8, 2.4, 3.0] {
            let expectedTime = 1 + min(elapsed, drawing.duration) * motion + max(0, elapsed - drawing.duration)
            let actual = try await frame(rendered.url, at: 1 + elapsed, folder: folder)
            let expected = try await frame(input, at: expectedTime, folder: folder)
            let comparison = try await MultitrackRenderTests.compareDecoded(actual, expected)
            #expect(comparison.videoTimingIdentical && comparison.minimumSSIM >= 0.98)
        }
        var clean = document
        for index in clean.videoTrack.indices { clean.videoTrack[index].telestration = nil }
        let reference = try await renderer.render(document: clean, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: reference.url) }
        let comparison = try await MultitrackRenderTests.compareDecoded(rendered.url, reference.url)
        #expect(comparison.videoTimingIdentical && comparison.audioIdentical)
        let window = MultitrackRenderer.windowed(document, scenes: [], from: 1.8, to: 3.5)
        let preview = try await renderer.render(document: window.document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, lingering: window.lingering, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: preview.url) }
        #expect(try await yellowPixels(preview.url, at: 0.1, folder: folder) > 450)
        #expect(try await yellowPixels(preview.url, at: 1.5, folder: folder) == 0)
    }
}
