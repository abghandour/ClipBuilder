import Foundation
import Testing
@testable import Clip_Builder

@Suite("Effect rendering integration", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct EffectRenderTests {
    private func source(in directory: URL, edge: Bool = false) async throws -> URL {
        let url = directory.appendingPathComponent("effect-\(UUID().uuidString).mp4")
        var args = ["-y", "-f", "lavfi", "-i", "color=c=red:size=720x1280:rate=30"]
        if edge { args += ["-vf", "drawbox=x=360:y=0:w=360:h=1280:color=blue:t=fill"] }
        args += ["-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path]
        _ = try await FFmpeg.run(args, timeout: 60)
        return url
    }

    private func document(source: URL, effect: EffectSpec?, override: EffectSpec? = nil) -> TimelineDocument {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1, track: 0)
        clip.videoFile = source.path
        clip.muted = true
        clip.effect = override
        var document = Fixtures.timelineDocument(clips: [clip])
        document.trackSettings[0].effect = effect
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 1)]
        return document
    }

    private func render(_ document: TimelineDocument, temp: TempDatabase) async throws -> URL {
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("segments-\(UUID().uuidString)"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache)
        return try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(name: "Effects"),
                                         database: temp.database, preview: true, emit: { _ in }).url
    }

    private func pixel(_ url: URL, x: Double = 0.5, y: Double = 0.5, scratch: URL) async throws -> [Int] {
        let size = await FFmpeg.dimensions(of: url)
        let raw = scratch.appendingPathComponent("pixel-\(UUID().uuidString).rgb")
        defer { try? FileManager.default.removeItem(at: raw) }
        _ = try await FFmpeg.run(["-y", "-ss", "0.5", "-i", url.path, "-frames:v", "1",
            "-vf", "format=rgb24,crop=1:1:\(Int(Double(size.width) * x)):\(Int(Double(size.height) * y))",
            "-f", "rawvideo", raw.path], timeout: 60)
        let data = try Data(contentsOf: raw)
        try #require(data.count >= 3)
        return data.prefix(3).map(Int.init)
    }

    @Test func blackAndWhiteAreaLeavesOtherAreaAlone() async throws {
        let temp = try TempDatabase()
        let source = try await source(in: temp.directory.url)
        var doc = document(source: source, effect: .init(preset: "bw"))
        var second = doc.videoTrack[0]
        second.uid = UUID(); second.originKey = UUID().uuidString; second.track = 1
        doc.videoTrack.append(second)
        doc.trackCount = 2
        doc.cropBlocks = [.init(layout: .init(name: "50-50 Horizontal"), startTime: 0, duration: 1)]
        let output = try await render(doc, temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }
        let mono = try await pixel(output, y: 0.25, scratch: temp.directory.url)
        let color = try await pixel(output, y: 0.75, scratch: temp.directory.url)
        #expect(abs(mono[0] - mono[1]) < 8 && abs(mono[1] - mono[2]) < 8)
        #expect(color[0] > 230 && color[1] < 20 && color[2] < 20)
    }

    @Test func invertPixel() async throws {
        let temp = try TempDatabase()
        let source = try await source(in: temp.directory.url)
        let output = try await render(document(source: source, effect: .init(preset: "invert")), temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }
        let before = try await pixel(source, scratch: temp.directory.url)
        let after = try await pixel(output, scratch: temp.directory.url)
        for channel in 0..<3 { #expect(abs(after[channel] - (255 - before[channel])) < 25) }
    }

    @Test func halfIntensityInvertLandsBetween() async throws {
        // Intensity < 1 takes the split/blend graph: red inverted at 0.5 is
        // the mean of red and cyan, a mid gray with no dominant channel.
        let temp = try TempDatabase()
        let source = try await source(in: temp.directory.url)
        let output = try await render(document(source: source, effect: .init(preset: "invert", intensity: 0.5)), temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }
        let before = try await pixel(source, scratch: temp.directory.url)
        let after = try await pixel(output, scratch: temp.directory.url)
        for channel in 0..<3 {
            let expected = (before[channel] + (255 - before[channel])) / 2
            #expect(abs(after[channel] - expected) < 30, "channel \(channel): \(after[channel]) vs \(expected)")
        }
        #expect(abs(after[0] - after[1]) < 40 && abs(after[1] - after[2]) < 40)
    }

    @Test func bundledMonochromeLUT() async throws {
        let temp = try TempDatabase()
        let source = try await source(in: temp.directory.url)
        let output = try await render(document(source: source, effect: .init(preset: "lut:kodak_t-max_400")), temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }
        let before = try await pixel(source, scratch: temp.directory.url)
        let after = try await pixel(output, scratch: temp.directory.url)
        #expect(after != before)
        #expect(abs(after[0] - after[1]) < 8 && abs(after[1] - after[2]) < 8)
    }

    @Test func blurMixesBothSidesOfEdge() async throws {
        let temp = try TempDatabase()
        let source = try await source(in: temp.directory.url, edge: true)
        let plain = try await render(document(source: source, effect: nil), temp: temp)
        defer { try? FileManager.default.removeItem(at: plain) }
        let output = try await render(document(source: source, effect: .init(preset: "blur", params: ["sigma": 20])), temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }
        let before = try await pixel(plain, x: 0.49, scratch: temp.directory.url)
        let after = try await pixel(output, x: 0.49, scratch: temp.directory.url)
        #expect(after[0] > 20 && after[0] < before[0] - 10)
        #expect(after[2] > before[2] + 10 && after[2] < 230)
    }

    @Test func explicitNoneOverridesTrack() async throws {
        let temp = try TempDatabase()
        let source = try await source(in: temp.directory.url)
        let output = try await render(document(source: source, effect: .init(preset: "bw"), override: .init(preset: "none")), temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }
        let after = try await pixel(output, scratch: temp.directory.url)
        #expect(after[0] > 230 && after[1] < 20 && after[2] < 20)
    }

    @Test func noEffectPreservesSource() async throws {
        let temp = try TempDatabase()
        let source = try await source(in: temp.directory.url)
        let output = try await render(document(source: source, effect: nil), temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }
        let before = try await pixel(source, scratch: temp.directory.url)
        let after = try await pixel(output, scratch: temp.directory.url)
        for channel in 0..<3 { #expect(abs(before[channel] - after[channel]) < 8) }
    }
}
