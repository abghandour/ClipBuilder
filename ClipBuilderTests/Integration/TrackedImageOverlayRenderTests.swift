import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Clip_Builder

/// A tracked sticker rides ffmpeg position expressions through the real
/// renderer: the export must succeed and the sticker must sit at different
/// places on frames taken at the two ends of the track.
@Suite(.serialized)
struct TrackedImageOverlayRenderTests {
    private static func stickerPNG(at url: URL) throws {
        let size = 120
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Mean red dominance in a column band of a frame: where the red circle is.
    private static func redColumnCenter(_ frame: URL) throws -> Double {
        let source = try #require(CGImageSourceCreateWithURL(frame as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var sum = 0.0, weight = 0.0
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            if r > 180 && g < 90 && b < 90 { sum += Double(x); weight += 1 }
        } }
        #expect(weight > 50, "no red sticker pixels found")
        return weight > 0 ? sum / weight / Double(width) : -1
    }

    @Test("a tracked sticker renders and moves between its keys")
    func trackedStickerMoves() async throws {
        guard FixtureVideo.integrationsAvailable else { return }
        let temp = try await TempDatabase()
        // A flat gray source: the test pattern has red bars that would
        // confuse the sticker search below.
        let source = temp.directory.url.appendingPathComponent("gray.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=0x404040:size=720x1280:rate=30", "-t", "3",
                              "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path], timeout: 60)
        let sticker = temp.directory.url.appendingPathComponent("sticker.png")
        try Self.stickerPNG(at: sticker)

        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3)
        clip.videoFile = source.path; clip.captions = "none"
        var document = Fixtures.timelineDocument(clips: [clip])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        var item = ImageOverlayItem(path: sticker.path, startTime: 0, endTime: 3)
        item.transIn = "cut"; item.transOut = "cut"
        item.wFrac = 0.2; item.keepsPlacement = true
        item.track = [
            ImageTrackKey(time: 0, xFrac: 0.2, yFrac: 0.5, wFrac: 0.2),
            ImageTrackKey(time: 1.5, xFrac: 0.5, yFrac: 0.5, wFrac: 0.2),
            ImageTrackKey(time: 3, xFrac: 0.8, yFrac: 0.5, wFrac: 0.2),
        ]
        document.imageOverlays = [item]

        let output = try await MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache")),
            framingCacheEnabled: false).render(document: document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: output.url) }

        let early = temp.directory.url.appendingPathComponent("early.png")
        let late = temp.directory.url.appendingPathComponent("late.png")
        try await FFmpeg.run(["-y", "-ss", "0.2", "-i", output.url.path, "-frames:v", "1", early.path], timeout: 60)
        try await FFmpeg.run(["-y", "-ss", "2.8", "-i", output.url.path, "-frames:v", "1", late.path], timeout: 60)
        let first = try Self.redColumnCenter(early)
        let last = try Self.redColumnCenter(late)
        #expect(first < 0.4, "sticker should start on the left, got \(first)")
        #expect(last > 0.6, "sticker should end on the right, got \(last)")
    }
}
