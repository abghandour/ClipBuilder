import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration hold rendering", .enabled(if: FFmpeg.isAvailable))
struct TelestrationHoldRenderTests {
    @concurrent
    private func source(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=640x360:r=30:d=3",
            "-f", "lavfi", "-i", "color=c=red:s=100x180:r=30:d=3",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3",
            "-filter_complex", "[0:v][1:v]overlay=x='90+90*t':y=90[v]",
            "-map", "[v]", "-map", "2:a", "-t", "3", "-c:v", "libx264", "-crf", "10",
            "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
    }

    @concurrent
    private func frame(_ source: URL, at time: Double, folder: URL) async throws -> URL {
        let output = folder.appendingPathComponent(UUID().uuidString + ".mkv")
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", source.path,
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-map", "0:v:0", "-map", "1:a:0", "-vf", "setpts=PTS-STARTPTS",
            "-t", "0.033333", "-c:v", "ffv1", "-c:a", "pcm_s16le", output.path], timeout: 60)
        return output
    }

    @concurrent
    private func rms(_ source: URL, start: Double, duration: Double, folder: URL) async throws -> Double {
        let output = folder.appendingPathComponent(UUID().uuidString + ".pcm")
        try await FFmpeg.run(["-y", "-ss", String(start), "-i", source.path, "-t", String(duration),
            "-vn", "-ac", "1", "-ar", "44100", "-f", "f32le", output.path], timeout: 60)
        let samples = try Data(contentsOf: output).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(!samples.isEmpty)
        return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
    }

    @Test("Drawing animates over the silent held frame, fades away, and continues across a segment split")
    func drawnHoldAndContinuation() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("moving.mp4")
        try await source(input)
        var head = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1)
        head.videoFile = input.path
        head.wide = false
        head.captions = "none"
        var hold = head
        hold.uid = UUID()
        hold.hold = true
        hold.startTime = 1
        hold.sourceStart = 1
        hold.sourceEnd = 1
        hold.duration = 2
        hold.speed = nil
        var tail = head
        tail.uid = UUID()
        tail.startTime = 3
        tail.sourceStart = 1
        tail.sourceEnd = 2
        var plain = Fixtures.timelineDocument(clips: [head, hold, tail])
        plain.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        plain.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 4)]
        var drawn = plain
        drawn.videoTrack[1].telestration = Telestration(time: 1, figures: [.init(kind: .rectangle,
            points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.65)], color: .yellow, width: 0.016)],
            stay: 0.7, drawSpeed: 0.5, fade: 0.3)
        var split = drawn
        split.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 1.8),
                            .init(layout: .fullScreen, startTime: 1.8, duration: 2.2)]
        let segments = MultitrackRenderer.buildLayeredSegments(MultitrackRenderer.resolveClips(document: split, scenes: []))
        #expect(segments.count { $0.clips.contains { $0.hold } } == 2)
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false)
        var outputs: [URL] = []
        defer { for output in outputs { try? FileManager.default.removeItem(at: output) } }
        for document in [plain, drawn, split] {
            let rendered = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
            outputs.append(rendered.url)
        }
        for output in outputs {
            #expect(abs(await FFmpeg.duration(of: output) - 4) < 0.07)
            #expect(try await rms(output, start: 1.1, duration: 1.7, folder: folder) < 0.001)
            #expect(try await rms(output, start: 0.2, duration: 0.5, folder: folder) > 0.01)
            #expect(try await rms(output, start: 3.2, duration: 0.5, folder: folder) > 0.01)
        }
        let plainMid = try await frame(outputs[0], at: 1.9, folder: folder)
        let plainEnd = try await frame(outputs[0], at: 2.7, folder: folder)
        #expect(try await MultitrackRenderTests.compareDecoded(plainMid, plainEnd).minimumSSIM >= 0.99)
        for output in outputs.dropFirst() {
            let early = try await frame(output, at: 1.1, folder: folder)
            let mid = try await frame(output, at: 1.9, folder: folder)
            let faded = try await frame(output, at: 2.7, folder: folder)
            let moving = try await frame(output, at: 3.5, folder: folder)
            #expect(try await MultitrackRenderTests.compareDecoded(mid, plainMid).minimumSSIM < 0.99)
            #expect(try await MultitrackRenderTests.compareDecoded(early, mid).minimumSSIM < 0.99)
            #expect(try await MultitrackRenderTests.compareDecoded(faded, plainEnd).minimumSSIM >= 0.99)
            #expect(try await MultitrackRenderTests.compareDecoded(faded, moving).minimumSSIM < 0.99)
        }
        let comparison = try await MultitrackRenderTests.compareDecoded(outputs[2], outputs[1], trailingFramesAllowed: 1)
        #expect(comparison.videoTimingIdentical)
        #expect(comparison.minimumSSIM >= 0.97)
        // A restarted second segment would still show its drawing at 2.7 s,
        // and lose its complete rectangle immediately after the split.
        for time in [1.8, 1.9, 2.3, 2.7] {
            let a = try await frame(outputs[1], at: time, folder: folder)
            let b = try await frame(outputs[2], at: time, folder: folder)
            #expect(try await MultitrackRenderTests.compareDecoded(a, b).minimumSSIM >= 0.99)
        }
    }
}

extension TelestrationHoldRenderTests {
    @MainActor
    @Test("A Builder store-made pause renders its drawing, silent freeze and resumed source clock")
    func builderDrawnHold() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("builder-moving.mp4")
        try await source(input)
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3)
        clip.videoFile = input.path
        clip.wide = false
        clip.captions = "none"
        var document = Fixtures.timelineDocument(clips: [clip])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 3)]
        let model = BuilderTimelineModel(mode: .transient)
        model.seed(document: document, scenes: [])
        let drawing = Telestration(figures: [.init(kind: .rectangle,
            points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.65)], color: .yellow, width: 0.016)],
            stay: 0.7, drawSpeed: 0.5, fade: 0.3)
        let uid = try model.drawOnPause(clip.uid, at: 1, drawing: drawing).get()
        let drawn = model.document
        let held = try #require(model.clip(uid))
        #expect(abs(held.duration - drawing.duration) < 1e-9)
        #expect(drawn.videoTrack.allSatisfy { $0.strikeImpactsFrozen == nil })
        // Clearing this drawing keeps the same (under-five-second) hold length.
        try model.setDrawing(uid, drawing: nil).get()
        let plain = model.document
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("builder-cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false)
        var outputs: [URL] = []
        defer { for output in outputs { try? FileManager.default.removeItem(at: output) } }
        for timeline in [plain, drawn] {
            let rendered = try await renderer.render(document: timeline, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
            outputs.append(rendered.url)
        }
        let resume = 1 + drawing.duration
        for output in outputs {
            #expect(abs(await FFmpeg.duration(of: output) - (3 + drawing.duration)) < 0.07)
            #expect(try await rms(output, start: 1.1, duration: drawing.duration - 0.2, folder: folder) < 0.001)
            #expect(try await rms(output, start: 0.2, duration: 0.5, folder: folder) > 0.01)
            #expect(try await rms(output, start: resume + 0.2, duration: 0.5, folder: folder) > 0.01)
        }
        let plainMid = try await frame(outputs[0], at: 1.8, folder: folder)
        let plainEnd = try await frame(outputs[0], at: resume - 0.04, folder: folder)
        #expect(try await MultitrackRenderTests.compareDecoded(plainMid, plainEnd).minimumSSIM >= 0.99)
        let early = try await frame(outputs[1], at: 1.1, folder: folder)
        let mid = try await frame(outputs[1], at: 1.8, folder: folder)
        let fading = try await frame(outputs[1], at: resume - 0.04, folder: folder)
        let fullDifference = try await MultitrackRenderTests.compareDecoded(mid, plainMid)
        let fadeDifference = try await MultitrackRenderTests.compareDecoded(fading, plainEnd)
        #expect(fullDifference.minimumSSIM < 0.99)
        #expect(try await MultitrackRenderTests.compareDecoded(early, mid).minimumSSIM < 0.99)
        #expect(fadeDifference.minimumSSIM > fullDifference.minimumSSIM)
        let resumed = try await frame(outputs[1], at: resume + 0.5, folder: folder)
        let expected = try await frame(input, at: 1.5, folder: folder)
        #expect(try await MultitrackRenderTests.compareDecoded(resumed, expected).minimumSSIM >= 0.97)
        #expect(try await MultitrackRenderTests.compareDecoded(resumed, plainEnd).minimumSSIM < 0.99)
    }
}
