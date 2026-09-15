import Foundation
import Testing
@testable import Clip_Builder

struct RenderFinishingKeyTests {
    @Test func scratchNamesAndOverlayUUIDsDoNotAffectIdentity() async throws {
        let temp = try TempDirectory()
        let segment = temp.url.appendingPathComponent("segment.mp4")
        let raster = temp.url.appendingPathComponent("overlay.png")
        try Data("video and source audio".utf8).write(to: segment)
        try Data("raster pixels".utf8).write(to: raster)
        var overlay = MultitrackRenderer.TimedOverlayPNG(png: raster, startTime: 0.5, endTime: 3,
                                                         transIn: "fade", transOut: "slide_up", identity: UUID().uuidString)
        let before = try await RenderFinishingKey.make(segments: [segment], transitions: [], transitionDuration: 0.3,
            overlays: [overlay], settings: RenderSettings(), encoder: ["-c:v", "libx264"])
        let moved = temp.url.appendingPathComponent("different-segment.mp4")
        try FileManager.default.moveItem(at: segment, to: moved)
        let renamedRaster = temp.url.appendingPathComponent(UUID().uuidString + ".png")
        try FileManager.default.moveItem(at: raster, to: renamedRaster)
        overlay.png = renamedRaster
        overlay.identity = UUID().uuidString
        let after = try await RenderFinishingKey.make(segments: [moved], transitions: [], transitionDuration: 0.3,
            overlays: [overlay], settings: RenderSettings(), encoder: ["-c:v", "libx264"])
        #expect(before == after)
    }

    @Test func middleOfSegmentAndRasterChangesInvalidate() async throws {
        let temp = try TempDirectory()
        let segment = temp.url.appendingPathComponent("segment.mp4")
        let raster = temp.url.appendingPathComponent("overlay.png")
        var bytes = Data(repeating: 7, count: 4 * 1024 * 1024)
        try bytes.write(to: segment)
        try Data("old pixels".utf8).write(to: raster)
        let overlay = MultitrackRenderer.TimedOverlayPNG(png: raster, startTime: 0, endTime: 3,
                                                         transIn: "none", transOut: "none")
        func key() async throws -> String {
            try await RenderFinishingKey.make(segments: [segment], transitions: [], transitionDuration: 0.3,
                overlays: [overlay], settings: RenderSettings(), encoder: ["-c:v", "libx264"])
        }
        let original = try await key()
        bytes[2 * 1024 * 1024] = 8
        try bytes.write(to: segment)
        let edited = try await key()
        #expect(edited != original)
        try Data("new pixels".utf8).write(to: raster)
        #expect(try await key() != edited)
        let job = Task { try await key() }
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        try FileManager.default.removeItem(at: segment)
        await #expect(throws: (any Error).self) { try await key() }
    }

    @Test func orderTimingTransitionsAndEncodingAffectIdentity() throws {
        let input = RenderFinishingKey(segments: ["first", "second"], transitions: ["fade"], transitionDuration: 0.3,
            overlays: [.init(pixels: "bottom", start: 0, end: 6, transIn: "fade", transOut: "none"),
                       .init(pixels: "top", start: 1, end: 5, transIn: "none", transOut: "fade")],
            settings: RenderSettings(), encoder: ["-c:v", "libx264"])
        let original = try RenderSegmentCache.key(input)
        let changes: [(inout RenderFinishingKey) -> Void] = [
            { $0.segments.reverse() }, { $0.transitions = ["wipeleft"] },
            { $0.transitionDuration = 0.7 }, { $0.overlays.reverse() },
            { $0.overlays[0].start = 0.2 }, { $0.overlays[0].end = 4 },
            { $0.overlays[0].transIn = "slide_up" }, { $0.overlays[1].transOut = "pop" },
            { $0.settings.preset = .square1080 }, { $0.settings.customCRF = 24 },
            { $0.encoder = ["-c:v", "h264_videotoolbox"] }, { $0.segmentVersion = "future-renderer" },
            { $0.maximumOverlap = 0.1 },
        ]
        for change in changes {
            var edited = input
            change(&edited)
            #expect(try RenderSegmentCache.key(edited) != original)
        }
    }
}
