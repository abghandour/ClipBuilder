import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

/// Shared decoded-pixel fixture for the review and transition regressions.
struct StayRenderFixture {
    static func document(source: URL, linger: Double? = 1.5) -> TimelineDocument {
        let drawing = Telestration(figures: [.init(kind: .line,
            points: [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.7, y: 0.4)],
            color: .yellow, width: 0.03, linger: linger)], stay: 1, drawSpeed: 0.5, fade: 0.2)
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: drawing.duration)
        hold.startTime = 0
        hold.videoFile = source.path
        hold.wide = false
        hold.captions = "none"
        hold.hold = true
        hold.telestration = drawing
        var tail = hold
        tail.uid = UUID()
        tail.startTime = hold.duration
        tail.duration = 2
        tail.hold = nil
        tail.telestration = nil
        var doc = Fixtures.timelineDocument(clips: [hold, tail])
        doc.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        return doc
    }

    @concurrent static func source(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=black:s=640x360:r=30:d=6",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path], timeout: 60)
    }

    @concurrent static func pixels(_ url: URL, time: Double, folder: URL) async throws -> [UInt8] {
        let raw = folder.appendingPathComponent(UUID().uuidString + ".rgb")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", url.path,
            "-frames:v", "1", "-vf", "format=rgb24", "-f", "rawvideo", raw.path], timeout: 60)
        return [UInt8](try Data(contentsOf: raw))
    }

    nonisolated static func graph(_ command: [String]) -> String? {
        if let i = command.firstIndex(of: "-/filter_complex"), i + 1 < command.count {
            return try? String(contentsOfFile: command[i + 1], encoding: .utf8)
        }
        if let i = command.firstIndex(of: "-filter_complex"), i + 1 < command.count { return command[i + 1] }
        return nil
    }

    static func renderer(_ folder: URL) -> MultitrackRenderer {
        MultitrackRenderer(render: RenderEngine(), segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent(UUID().uuidString)),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false)
    }
}

@Suite("Stay review decoded pixels", .enabled(if: FixtureVideo.integrationsAvailable))
struct TelestrationReviewRenderTests {
    @Test func flashCoversFixedFigure() async throws {
        let temp = try await TempDatabase()
        let input = temp.directory.url.appendingPathComponent("source.mp4")
        try await StayRenderFixture.source(input)
        var doc = StayRenderFixture.document(source: input)
        doc.videoTrack[1].flashIn = 0.12
        let result = try await StayRenderFixture.renderer(temp.directory.url).render(document: doc, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: result.url) }
        let pixels = try await StayRenderFixture.pixels(result.url, time: doc.videoTrack[0].duration, folder: temp.directory.url)
        #expect(pixels.count == 640 * 360 * 3)
        let i = (144 * 640 + 320) * 3
        #expect(pixels[i] > 245 && pixels[i + 1] > 245 && pixels[i + 2] > 245)
    }

    @Test func pinnedNoStayGraph() async throws {
        let temp = try await TempDatabase()
        let input = temp.directory.url.appendingPathComponent("source.mp4")
        try await StayRenderFixture.source(input)
        let doc = StayRenderFixture.document(source: input, linger: nil)
        let graphs = Mutex<[String]>([])
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: doc.videoTrack[0].duration, to: doc.videoTrack[1].startTime + doc.videoTrack[1].duration)
        let result = try await FFmpeg.$commandCompleted.withValue({ command in
            if let graph = StayRenderFixture.graph(command) { graphs.withLock { $0.append(graph) } }
        }) {
            try await StayRenderFixture.renderer(temp.directory.url).render(document: window.document, scenes: [],
                profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(!graphs.withLock { $0 }.isEmpty)
        #expect(graphs.withLock { $0 }.allSatisfy { !$0.contains("before_stay") && !$0.contains("drawing") })
    }

    @Test func fallbackNoticeOnceAndOnlyDuringStay() async throws {
        let temp = try await TempDatabase()
        let input = temp.directory.url.appendingPathComponent("source.mp4")
        try await StayRenderFixture.source(input)
        var doc = StayRenderFixture.document(source: input, linger: 0.4)
        doc.videoTrack[0].freeCrops = [.init(src: .init(wFrac: 0.5), dst: .init())]
        let join = doc.videoTrack[0].duration
        doc.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: join + 0.2),
            .init(layout: .fullScreen, startTime: join + 0.2, duration: 0.8),
            .init(layout: .fullScreen, startTime: join + 1, duration: 1)]
        let logs = Mutex<[String]>([])
        let result = try await StayRenderFixture.renderer(temp.directory.url).render(document: doc, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true, emit: { line in logs.withLock { $0.append(line) } })
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(logs.withLock { $0.filter { $0 == TelestrationScreenStay.fallbackMessage }.count } == 1)
        logs.withLock { $0 = [] }
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: join + 1, to: join + 2)
        let preview = try await StayRenderFixture.renderer(temp.directory.url).render(document: window.document, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true, lingering: window.lingering,
            lingerHolds: window.lingerHolds, emit: { line in logs.withLock { $0.append(line) } })
        defer { try? FileManager.default.removeItem(at: preview.url) }
        #expect(!logs.withLock { $0 }.contains(TelestrationScreenStay.fallbackMessage))
    }
}
