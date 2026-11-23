import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration stays over moving footage", .enabled(if: FFmpeg.isAvailable))
struct TelestrationLingerRenderTests {
    @concurrent
    private func source(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=640x360:r=30:d=7",
            "-f", "lavfi", "-i", "color=c=red:s=80x180:r=30:d=7",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=7",
            "-filter_complex", "[0:v][1:v]overlay=x='60+60*t':y=90[v]",
            "-map", "[v]", "-map", "2:a", "-t", "7", "-c:v", "libx264", "-crf", "10",
            "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
    }

    @concurrent
    private func pixels(_ source: URL, at time: Double, folder: URL) async throws -> [UInt8] {
        let output = folder.appendingPathComponent(UUID().uuidString + ".rgb")
        defer { try? FileManager.default.removeItem(at: output) }
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", source.path,
            "-frames:v", "1", "-vf", "format=rgb24", "-f", "rawvideo", output.path], timeout: 60)
        let pixels = [UInt8](try Data(contentsOf: output))
        #expect(pixels.count == 640 * 360 * 3)
        return pixels
    }

    private func yellow(_ pixels: [UInt8]) -> Bool {
        guard pixels.count == 640 * 360 * 3 else { return false }
        let index = (72 * 640 + 320) * 3
        return pixels[index] > 190 && pixels[index + 1] > 190 && pixels[index + 2] < 80
    }

    private func redCenter(_ pixels: [UInt8]) -> Double {
        guard pixels.count == 640 * 360 * 3 else { return -1 }
        let xs = (0..<640).filter { x in
            let index = (180 * 640 + x) * 3
            return pixels[index] > 170 && pixels[index + 1] < 70 && pixels[index + 2] < 70
        }
        return xs.isEmpty ? -1 : Double(xs.reduce(0, +)) / Double(xs.count)
    }

    @Test("Stays are fixed over motion, fade in screen time, and continue through crop and preview cuts", arguments: [1.0, 0.5, 2.0])
    func movingStay(speed: Double) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("moving.mp4")
        try await source(input)
        let drawing = Telestration(time: 1, figures: [.init(kind: .line,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.2)], color: .yellow, width: 0.016, linger: 0.8)],
            stay: 0.5, drawSpeed: 0.5, fade: 0.2)
        var head = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1)
        head.videoFile = input.path
        head.wide = false
        head.captions = "none"
        var hold = head
        hold.uid = UUID()
        hold.startTime = 1
        hold.sourceStart = 1
        hold.sourceEnd = 1
        hold.hold = true
        hold.duration = drawing.duration
        hold.telestration = drawing
        let resume = 1 + drawing.duration
        var tail = head
        tail.uid = UUID()
        tail.startTime = resume
        tail.sourceStart = 1
        tail.duration = 2.5
        tail.sourceEnd = 1 + tail.duration * speed
        tail.speed = speed
        var document = Fixtures.timelineDocument(clips: [head, hold, tail])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: resume + 0.4),
                               .init(layout: .fullScreen, startTime: resume + 0.4, duration: 2.1)]
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false)
        let full = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: full.url) }
        let early = try await pixels(full.url, at: resume + 0.2, folder: folder)
        let late = try await pixels(full.url, at: resume + 1.1, folder: folder)
        #expect(yellow(early))
        #expect(!yellow(late))
        #expect(redCenter(early) > 0 && redCenter(late) - redCenter(early) > 15)
        // The next crop segment must not restart the stay or the fade.
        #expect(!yellow(try await pixels(full.url, at: resume + 0.95, folder: folder)))
        let window = MultitrackRenderer.windowed(document, scenes: [], from: resume + 0.35, to: resume + 1.4)
        let preview = try await renderer.render(document: window.document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, lingering: window.lingering, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: preview.url) }
        #expect(yellow(try await pixels(preview.url, at: 0.1, folder: folder)))
        #expect(!yellow(try await pixels(preview.url, at: 0.8, folder: folder)))
    }
}
