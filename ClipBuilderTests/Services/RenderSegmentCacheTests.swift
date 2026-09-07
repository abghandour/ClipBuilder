import Foundation
import Testing
@testable import Clip_Builder

@Suite("Render segment cache")
struct RenderSegmentCacheTests {
    @Test("keys are stable and invalidate every encode input")
    func keys() throws {
        let clip = MultitrackRenderer.ResolvedClip(
            sourcePath: "/source.mp4", videoID: 1, sourceStart: 0,
            startTime: 0, duration: 3, track: 0, wide: false,
            muted: false, transIn: nil, transOut: nil, effectivePosition: "center",
            effectiveCropXFrac: nil, freeCrops: nil, screenCrop: nil,
            areaWindow: nil, captionsPosition: nil, sourceFingerprint: "source-v1")
        let caption = MultitrackRenderer.CaptionOverlay(png: URL(fileURLWithPath: "/caption-digest"),
            x: 0, y: 100, start: 0.5, end: 2)
        let overlay = MultitrackRenderer.TimedOverlayPNG(png: URL(fileURLWithPath: "/asset-digest"),
            startTime: 0, endTime: 2, transIn: "fade", transOut: "pop", identity: "text-and-font")
        let input = RenderSegmentKey(start: 0, duration: 3, clips: [clip], captions: [caption],
            overlays: [overlay], masks: ["0": "mask-a", "1": "mask-b"], fontFingerprints: ["font-v1"],
            captionStyle: CaptionStyle(), settings: RenderSettings(), encoder: ["-c:v", "h264_videotoolbox"])
        let key = try RenderSegmentCache.key(input)
        #expect(try RenderSegmentCache.key(input) == key)
        var reordered = input
        reordered.masks = ["1": "mask-b", "0": "mask-a"]
        #expect(try RenderSegmentCache.key(reordered) == key)
        #expect(try RenderSegmentCache.key(input, version: "next-renderer") != key)
        let changes: [(inout RenderSegmentKey) -> Void] = [
            { $0.clips[0].sourceFingerprint = "source-v2" },
            { $0.clips[0].sourcePath = "/replacement.mp4" },
            { $0.clips[0].sourceStart = 0.5 },
            { $0.duration = 2 },
            { $0.clips[0].speed = 0.5 },
            { $0.clips[0].cameraPath = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.5, h: 1)] },
            { $0.clips[0].staticAreaFilter = "crop=100:100,scale=240:240" },
            { $0.clips[0].framingIdentity = "different-prepass" },
            { $0.masks["0"] = "changed-mask" },
            { $0.overlays[0].png = URL(fileURLWithPath: "/changed-asset-digest") },
            { $0.overlays[0].identity = "changed-text-or-font" },
            { $0.overlays[0].startTime = 0.25 },
            { $0.overlays[0].endTime = 2.5 },
            { $0.overlays[0].transOut = "slide_up" },
            { $0.captions[0].png = URL(fileURLWithPath: "/changed-caption-digest") },
            { $0.captions[0].text = "Changed caption text" },
            { $0.captions[0].end = 1 },
            { $0.captions[0].y = 200 },
            { $0.captionStyle.font = "mono" },
            { $0.fontFingerprints = ["font-v2"] },
            { $0.settings.preset = .square1080 },
            { $0.settings.customCRF = 24 },
            { $0.encoder = ["-c:v", "libx264"] },
            { $0.clips[0].muted = true },
        ]
        for (index, change) in changes.enumerated() {
            var changed = input
            change(&changed)
            #expect(try RenderSegmentCache.key(changed) != key, "input mutation \(index) must invalidate")
        }
    }

    @Test("restore refreshes LRU order, eviction persists across cache instances")
    func eviction() async throws {
        let temp = try TempDirectory()
        let root = temp.url.appendingPathComponent("cache")
        let source = temp.url.appendingPathComponent("segment.mp4")
        try Data(repeating: 1, count: 4).write(to: source)
        let cache = RenderSegmentCache(directory: root, byteLimit: 8)
        await cache.store(key: "a", from: source)
        await cache.store(key: "b", from: source)
        for (key, time) in [("a", 100.0), ("b", 200.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)],
                ofItemAtPath: root.appendingPathComponent(key + ".mp4").path)
        }
        #expect(await cache.restore(key: "a", to: temp.url.appendingPathComponent("restored.mp4")))
        // Restored copies have independent ownership, even after eviction.
        let reopened = RenderSegmentCache(directory: root, byteLimit: 8)
        await reopened.store(key: "c", from: source)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.mp4").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.mp4").path))
        #expect(try Data(contentsOf: temp.url.appendingPathComponent("restored.mp4")) == Data(repeating: 1, count: 4))
        await reopened.store(key: "missing", from: temp.url.appendingPathComponent("absent.mp4"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing.mp4").path))
    }

    @Test("cancelled producers cannot publish")
    func cancellation() async throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("segment.mp4")
        try Data(repeating: 1, count: 4).write(to: source)
        let root = temp.url.appendingPathComponent("cache")
        let cache = RenderSegmentCache(directory: root)
        let job = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await cache.store(key: "cancelled", from: source)
        }
        await job.value
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.mp4").path))
    }
}
