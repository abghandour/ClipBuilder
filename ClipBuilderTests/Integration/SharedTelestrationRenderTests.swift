import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Shared telestration rendering", .enabled(if: FFmpeg.isAvailable))
struct SharedTelestrationRenderTests {
    @concurrent private func source(_ url: URL, color: String) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=640x360:r=30:d=3",
            "-f", "lavfi", "-i", "color=c=\(color):s=100x180:r=30:d=3",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3",
            "-filter_complex", "[0:v][1:v]overlay=x='90+90*t':y=90[v]",
            "-map", "[v]", "-map", "2:a", "-t", "3", "-c:v", "libx264", "-crf", "10",
            "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
    }

    @concurrent private func frame(_ source: URL, at time: Double, area: Int,
                                   patch: Bool = false, folder: URL) async throws -> URL {
        let output = folder.appendingPathComponent(UUID().uuidString + ".mkv")
        // The custom canvas has two 640x360 areas. The patch straddles the
        // drawing's left edge at x=.2, y=.35 in the companion's source frame.
        let crop = "crop=iw:ih/2:0:\(area == 0 ? "0" : "ih/2")"
            + (patch ? ",crop=32:32:112:110" : "")
        try await FFmpeg.run(["-y", "-ss", String(time), "-i", source.path,
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-map", "0:v:0", "-map", "1:a:0", "-vf", crop + ",setpts=PTS-STARTPTS",
            "-t", "0.033333", "-c:v", "ffv1", "-c:a", "pcm_s16le", output.path], timeout: 60)
        return output
    }

    @concurrent private func rms(_ source: URL, start: Double, folder: URL) async throws -> Double {
        let output = folder.appendingPathComponent(UUID().uuidString + ".pcm")
        try await FFmpeg.run(["-y", "-ss", String(start), "-i", source.path, "-t", "0.4",
            "-vn", "-ac", "1", "-ar", "44100", "-f", "f32le", output.path], timeout: 60)
        let samples = try Data(contentsOf: output).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(!samples.isEmpty)
        return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
    }

    @Test("Both areas freeze and resume together; a track-one drawing stays in its area and fades away")
    func sharedHold() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let main = folder.appendingPathComponent("main.mp4")
        let companion = folder.appendingPathComponent("companion.mp4")
        try await source(main, color: "red")
        try await source(companion, color: "blue")
        let layout = ScreenCropLayout(name: "Shared pause", areas: [
            .init(name: "Top", points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 0.5), .init(x: 0, y: 0.5)]),
            .init(name: "Bottom", points: [.init(x: 0, y: 0.5), .init(x: 1, y: 0.5), .init(x: 1, y: 1), .init(x: 0, y: 1)])])
        var tracks: [[TimelineClip]] = []
        for (slot, url) in [main, companion].enumerated() {
            var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2, track: slot)
            clip.videoFile = url.path
            clip.wide = false
            clip.precision = .speech
            clip.captions = "none"
            clip.muted = slot > 0
            clip.areaWindow = FreeCropRect()
            clip.screenCrop = ScreenCropStore.reference(layout: layout.name, area: layout.areas[slot].name)
            clip.framingPlan = .composed(layout: layout, areas: [], fit: .fill)
            tracks.append([clip])
        }
        let drawing = Telestration(time: 1, figures: [.init(kind: .rectangle,
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.7)], color: .yellow, width: 0.016)],
            stay: 0.7, drawSpeed: 0.5, fade: 0.3)
        let plainPieces = try #require(StrikeFreezeRules.sharedPieces(tracks, pauses: [.init(time: 1, duration: 2)]))
        let drawnPieces = try #require(StrikeFreezeRules.sharedPieces(tracks,
            pauses: [.init(time: 1, duration: 2, drawing: drawing, source: companion.path)]))
        var plain = Fixtures.timelineDocument(clips: plainPieces.flatMap { $0 })
        plain.trackCount = 2
        plain.trackSequential[1] = false
        plain.cropBlocks = []
        plain.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 720)
        var drawn = plain
        drawn.videoTrack = drawnPieces.flatMap { $0 }
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false)
        var outputs: [URL] = []
        defer { for url in outputs { try? FileManager.default.removeItem(at: url) } }
        for document in [plain, drawn] {
            let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
            #expect(resolved.filter(\.hold).count == 2)
            #expect(resolved.filter(\.hold).allSatisfy { $0.muted })
            #expect(MultitrackRenderer.usesTimedAssembly(document, transitions: []))
            let result = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
            outputs.append(result.url)
            #expect(abs(await FFmpeg.duration(of: result.url) - 4) < 0.07)
            #expect(try await rms(result.url, start: 1.4, folder: folder) < 0.001)
            #expect(try await rms(result.url, start: 3.2, folder: folder) > 0.01)
        }
        let comparison = try await MultitrackRenderTests.compareDecoded(outputs[1], outputs[0], trailingFramesAllowed: 1)
        #expect(comparison.videoTimingIdentical)
        #expect(comparison.audioIdentical)
        for area in [0, 1] {
            let held = try await frame(outputs[0], at: 1.9, area: area, folder: folder)
            let late = try await frame(outputs[0], at: 2.7, area: area, folder: folder)
            let moved = try await frame(outputs[0], at: 3.5, area: area, folder: folder)
            #expect(try await MultitrackRenderTests.compareDecoded(held, late).minimumSSIM >= 0.99)
            #expect(try await MultitrackRenderTests.compareDecoded(held, moved).minimumSSIM < 0.99)
            let marked = try await frame(outputs[1], at: 1.9, area: area, folder: folder)
            let faded = try await frame(outputs[1], at: 2.7, area: area, folder: folder)
            let resumed = try await frame(outputs[1], at: 3.5, area: area, folder: folder)
            let score = try await MultitrackRenderTests.compareDecoded(marked, held).minimumSSIM
            #expect(area == 0 ? score >= 0.99 : score < 0.99)
            #expect(try await MultitrackRenderTests.compareDecoded(faded, late).minimumSSIM >= 0.99)
            #expect(try await MultitrackRenderTests.compareDecoded(resumed, moved).minimumSSIM >= 0.99)
        }
        let spot = try await frame(outputs[1], at: 1.9, area: 1, patch: true, folder: folder)
        let bareSpot = try await frame(outputs[0], at: 1.9, area: 1, patch: true, folder: folder)
        #expect(try await MultitrackRenderTests.compareDecoded(spot, bareSpot).minimumSSIM < 0.95)
    }
}
