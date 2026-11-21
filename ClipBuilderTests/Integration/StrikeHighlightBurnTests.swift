import AppKit
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike highlight burn", .enabled(if: FFmpeg.isAvailable))
struct StrikeHighlightBurnTests {
    /// A punch across the middle of the frame, landing right of centre, 0.8–1.2 s.
    private var track: StrikeHighlightRules.Track {
        let highlight = StrikeHighlightRules.Highlight(
            limb: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.35, y: 0.5), CGPoint(x: 0.5, y: 0.5)],
            target: CGPoint(x: 0.7, y: 0.5), radius: 0.12, cost: 0.1, limbSide: .left, usesArm: true, attackerOnLeft: true)
        return .init(keyframes: [.init(time: 0.8, highlight: highlight), .init(time: 1.2, highlight: highlight)],
                     contact: 1.0, aspect: 16.0 / 9)
    }

    private func grey(_ url: URL, seconds: Double = 2) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=640x360:r=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", String(seconds),
            "-c:v", "libx264", "-crf", "10", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
    }

    /// The colour at a point (0…1, top-left origin) of the frame at `time`.
    private func color(_ url: URL, at time: Double, x: Double, y: Double, in folder: URL) async throws -> (r: Int, g: Int, b: Int) {
        let png = folder.appendingPathComponent(UUID().uuidString + ".png")
        try await FFmpeg.run(["-y", "-ss", String(format: "%.3f", time), "-i", url.path, "-frames:v", "1", png.path], timeout: 60)
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: png)))
        let pixel = try #require(rep.colorAt(x: Int(x * Double(rep.pixelsWide)), y: Int(y * Double(rep.pixelsHigh)))?
            .usingColorSpace(.sRGB))
        return (Int(pixel.redComponent * 255), Int(pixel.greenComponent * 255), Int(pixel.blueComponent * 255))
    }

    @Test("Picture times sit on the stretch's frame grid and stop at its ends")
    func frameTimes() {
        let all = StrikeHighlightBurn.frameTimes(track, start: 0, duration: 2)
        #expect(abs((all.first ?? 0) - 22.0 / 30) < 0.0001)   // 0.8 − fade, rounded up to a frame
        #expect(abs((all.last ?? 0) - 38.0 / 30) < 0.0001)
        #expect(all.count == 17)
        // A stretch that starts mid-strike gets only what is left of it.
        let late = StrikeHighlightBurn.frameTimes(track, start: 1.0, duration: 1)
        #expect(late.first == 1.0 && late.count == 9)
        #expect(StrikeHighlightBurn.frameTimes(track, start: 3, duration: 1).isEmpty)
        #expect(StrikeHighlightBurn.tracks([track], start: 1.5, duration: 1).isEmpty)
        #expect(StrikeHighlightBurn.tracks([track], start: 0.5, duration: 0.4).count == 1)
    }

    @Test("The limb is green and the impact red only while the strike shows; the copy keeps its length and sound")
    func burn() async throws {
        let temp = try TempDirectory(prefix: "StrikeBurn")
        let source = temp.url.appendingPathComponent("grey.mp4")
        try await grey(source)
        let burned = try #require(try await StrikeHighlightBurn.burn(source: source, start: 0, duration: 2,
                                                                     tracks: [track], scratch: temp.url))
        #expect(abs(await FFmpeg.duration(of: burned) - 2) < 0.1)
        let before = try await color(burned, at: 0.3, x: 0.35, y: 0.5, in: temp.url)
        #expect(abs(before.g - before.r) < 12 && abs(before.g - before.b) < 12)
        let limb = try await color(burned, at: 1.0, x: 0.35, y: 0.5, in: temp.url)
        #expect(limb.g > limb.r + 30 && limb.g > limb.b + 30)
        let impact = try await color(burned, at: 1.0, x: 0.7, y: 0.5, in: temp.url)
        #expect(impact.r > impact.g + 30 && impact.r > impact.b + 30)
        let after = try await color(burned, at: 1.7, x: 0.35, y: 0.5, in: temp.url)
        #expect(abs(after.g - after.r) < 12 && abs(after.g - after.b) < 12)
        // A stretch from the middle of the source starts its own clock at 0.
        let part = try #require(try await StrikeHighlightBurn.burn(source: source, start: 0.5, duration: 1,
                                                                   tracks: [track], scratch: temp.url))
        let shifted = try await color(part, at: 0.5, x: 0.35, y: 0.5, in: temp.url)
        #expect(shifted.g > shifted.r + 30)
        #expect(try await StrikeHighlightBurn.burn(source: source, start: 1.5, duration: 0.5, tracks: [track], scratch: temp.url) == nil)
    }

    @Test("A clip with highlights switched on renders them through its crop; switched off it does not")
    func render() async throws {
        let temp = try await TempDatabase()
        let source = temp.directory.url.appendingPathComponent("fight.mp4")
        try await grey(source)
        let videoID = try await temp.database.registerVideo(hash: UUID().uuidString, filename: "fight.mp4", path: source.path,
                                                            duration: 2, width: 640, height: 360, wide: true)
        try await temp.database.saveStrikeHighlights(videoID: videoID, [
            .init(videoID: videoID, time: 1.0, fighterKey: "a", track: track),
        ], generation: 0)
        let settings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        for enabled in [true, false] {
            var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
            clip.videoFile = source.path; clip.wide = true; clip.captions = "none"
            // The right half of the picture fills the frame: the impact at
            // x 0.7 of the source lands at x 0.4 of the output.
            clip.framingPlan = .static(window: FreeCropRect(xFrac: 0.5, wFrac: 0.5), fit: .fill, feather: 0, blur: 0)
            clip.strikeHighlights = enabled ? true : nil
            var document = Fixtures.timelineDocument(clips: [clip])
            document.renderSettings = settings
            let output = try await MultitrackRenderer(render: RenderEngine(),
                segmentCache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache-\(enabled)")),
                framingCacheEnabled: false).render(document: document, scenes: [], profile: Fixtures.brand(),
                    database: temp.database, preview: true, emit: { _ in })
            defer { try? FileManager.default.removeItem(at: output.url) }
            let impact = try await color(output.url, at: 1.0, x: 0.4, y: 0.5, in: temp.directory.url)
            if enabled { #expect(impact.r > impact.g + 30 && impact.r > impact.b + 30) }
            else { #expect(abs(impact.r - impact.g) < 12 && abs(impact.r - impact.b) < 12) }
            let quiet = try await color(output.url, at: 0.3, x: 0.4, y: 0.5, in: temp.directory.url)
            #expect(abs(quiet.r - quiet.g) < 12)
        }
        // The switch survives a save and load, and stays out of older documents.
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        clip.strikeHighlights = true
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(TimelineClip.self, from: data).strikeHighlights == true)
        clip.strikeHighlights = nil
        #expect(!String(decoding: try JSONEncoder().encode(clip), as: UTF8.self).contains("strike_highlights"))
    }
}
