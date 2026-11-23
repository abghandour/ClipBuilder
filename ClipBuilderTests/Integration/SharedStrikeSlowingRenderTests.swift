import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Whole-frame slow-motion rendering", .enabled(if: FFmpeg.isAvailable))
struct SharedStrikeSlowingRenderTests {
    @concurrent private static func source(_ url: URL, offset: Int) async throws {
        let filter = "geq=lum='32+192*mod(floor((N+\(offset))/pow(2,floor(X/80))),2)':cb=128:cr=128"
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "nullsrc=s=640x360:r=30:d=4",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4",
            "-vf", filter, "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest", url.path], timeout: 60)
    }

    @concurrent private static func numbers(_ url: URL, folder: URL) async throws -> [[Int]] {
        let raw = folder.appendingPathComponent(UUID().uuidString + ".gray")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await FFmpeg.run(["-y", "-i", url.path, "-map", "0:v:0", "-fps_mode", "passthrough",
            "-pix_fmt", "gray", "-f", "rawvideo", raw.path], timeout: 60)
        let bytes = [UInt8](try Data(contentsOf: raw))
        let size = 640 * 720
        guard bytes.count.isMultiple(of: size) else { throw CocoaError(.fileReadCorruptFile) }
        return stride(from: 0, to: bytes.count, by: size).map { start in
            (0..<2).map { area in
                (0..<8).reduce(0) { value, bit in
                    value | (bytes[start + (area * 360 + 180) * 640 + bit * 80 + 40] > 128 ? 1 << bit : 0)
                }
            }
        }
    }

    @concurrent private static func samples(_ url: URL, folder: URL) async throws -> [Float] {
        let raw = folder.appendingPathComponent(UUID().uuidString + ".f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await FFmpeg.run(["-y", "-i", url.path, "-vn", "-ac", "1", "-ar", "44100", "-f", "f32le", raw.path], timeout: 60)
        return try Data(contentsOf: raw).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private nonisolated static func rms(_ samples: [Float], from start: Double, duration: Double) -> Double {
        let lower = max(0, Int(start * 44100)), upper = min(samples.count, Int((start + duration) * 44100))
        guard upper > lower else { return 0 }
        return sqrt(samples[lower..<upper].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(upper - lower))
    }

    @Test("Both frame counters slow together, optionally hold, and resume; tracking preserves every source frame", arguments: [false, true])
    func bothPicturesAndAudio(hold: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let sources = [folder.appendingPathComponent("main.mp4"), folder.appendingPathComponent("other.mp4")]
        for (index, url) in sources.enumerated() { try await Self.source(url, offset: index * 128) }
        let layout = ScreenCropLayout(name: "Slow pictures", areas: [
            .init(name: "Top", points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 0.5), .init(x: 0, y: 0.5)]),
            .init(name: "Bottom", points: [.init(x: 0, y: 0.5), .init(x: 1, y: 0.5), .init(x: 1, y: 1), .init(x: 0, y: 1)])])
        var tracks = sources.enumerated().map { index, url -> [TimelineClip] in
            var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3, track: index)
            clip.videoFile = url.path; clip.wide = false; clip.captions = "none"
            clip.precision = .speech; clip.muted = index > 0
            clip.areaWindow = FreeCropRect()
            clip.screenCrop = ScreenCropStore.reference(layout: layout.name, area: layout.areas[index].name)
            clip.framingPlan = .composed(layout: layout, areas: [], fit: .fill)
            return [clip]
        }
        if hold { tracks = try #require(StrikeFreezeRules.sharedPieces(tracks, pauses: [.init(time: 2, duration: 0.8)])) }
        let slow = try #require(StrikeImpactRules.sharedSlowing(tracks, contacts: [2], strength: .strong))
        var document = Fixtures.timelineDocument(clips: slow.tracks.flatMap { $0 })
        document.trackCount = 2; document.trackSequential[1] = false
        for index in document.videoTrack.indices { document.videoTrack[index].timedAssembly = true }
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 720)
        let duration = 4.8 + (hold ? 0.8 : 0)
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false)
        let plain = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: plain.url) }
        #expect(abs(await FFmpeg.duration(of: plain.url) - duration) < 0.07)
        let frames = try await Self.numbers(plain.url, folder: folder)
        #expect(frames.count >= Int(duration * 30) - 1)
        for frame in 42..<114 where frame < frames.count {
            // Source fps sampling may select either adjacent source frame at
            // a fractional timestamp; both areas must select the SAME one.
            let expected = 42 + Double(frame - 42) * 0.25
            #expect(abs(Double(frames[frame][0]) - expected) <= 1)
            #expect(frames[frame][1] - 128 == frames[frame][0])
        }
        if hold {
            for frame in 114..<138 where frame < frames.count {
                #expect(frames[frame] == [60, 188])
            }
        }
        let resumed = Int((3.8 + (hold ? 0.8 : 0) + 0.3) * 30)
        #expect(abs(Double(frames[resumed][0]) - 69) <= 1)
        let audio = try await Self.samples(plain.url, folder: folder)
        for start in [1.2, 1.5, 2.2, 3.5, 3.8 + (hold ? 0.8 : 0) + 0.1] {
            #expect(Self.rms(audio, from: start, duration: 0.1) > 0.01)
        }
        if hold { #expect(Self.rms(audio, from: 4, duration: 0.4) < 0.001) }

        // Use the production tracking seam, without altering the prepass or
        // crop code. Different-speed pieces must read exactly the same frames.
        var tracked = document
        for index in tracked.videoTrack.indices { tracked.videoTrack[index].areaRegion = FreeCropRect() }
        let logs = Mutex<[String]>([])
        let result = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
            FeedCameraPath(keyframes: [.init(t: 0, x: 0, y: 0, w: 1, h: 1), .init(t: 3, x: 0, y: 0, w: 1, h: 1)],
                samples: [], trackedShare: 1, sourceSize: CGSize(width: 640, height: 360), usedFallback: false)
        }) {
            try await renderer.render(document: tracked, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in logs.withLock { $0.append(line) } })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(!logs.withLock { $0 }.contains { $0.contains("pieces framed separately") })
        let trackedFrames = try await Self.numbers(result.url, folder: folder)
        #expect(trackedFrames == frames)
        let comparison = try await MultitrackRenderTests.compareDecoded(result.url, plain.url)
        #expect(comparison.videoTimingIdentical && comparison.audioIdentical)
    }
}
