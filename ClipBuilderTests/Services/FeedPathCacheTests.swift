import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct FeedPathCacheTests {
    @Test func identityAndJSONPersistence() async throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("source.mp4")
        try Data(repeating: 1, count: 100).write(to: source)
        let root = temp.url.appendingPathComponent("cache")
        let cache = FeedPathCache(cache: RenderSegmentCache(directory: root))
        let region = FreeCropRect(xFrac: 0.5, yFrac: 0.05, wFrac: 0.45, hFrac: 0.45)
        let identity = try FeedPathCache.identity(source: source, region: region, start: 2, duration: 4, aspect: 9.0 / 16)
        let path = FeedCameraPath(keyframes: [.init(t: 0, x: 0.6, y: 0.05, w: 0.2, h: 0.45),
                                             .init(t: 4, x: 0.65, y: 0.05, w: 0.2, h: 0.45)],
            samples: [], trackedShare: 1, sourceSize: CGSize(width: 1920, height: 1080), usedFallback: false)
        await cache.store(path, identity: identity)
        let reopened = FeedPathCache(cache: RenderSegmentCache(directory: root))
        #expect(await reopened.read(identity)?.keyframes == path.keyframes)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.count == 1 && files.allSatisfy { $0.pathExtension == "json" })
        for change: (inout FeedPathCache.Identity) -> Void in [
            { $0.region.xFrac += 0.01 }, { $0.start += 0.1 }, { $0.duration += 0.1 },
            { $0.tuning = "balanced" }, { $0.version = "changed" }, { $0.aspect = 1 },
            { $0.focus = AreaFocus(x: 0.6, y: 0.2) },
        ] {
            var changed = identity
            change(&changed)
            #expect(await reopened.read(changed) == nil)
        }
        #expect(await reopened.covering(source: source, region: region, start: 3, duration: 1) != nil)
        try Data(repeating: 2, count: 110).write(to: source)
        #expect(await reopened.covering(source: source, region: region, start: 3, duration: 1) == nil)
    }

    @Test func previewAndExpressionReuseTrackingEvidenceWithoutDecode() async throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("source.mp4")
        // Deliberately not a movie: a cache hit must never ask AVFoundation to decode it.
        try Data(repeating: 3, count: 100).write(to: source)
        let cache = FeedPathCache(cache: RenderSegmentCache(directory: temp.url.appendingPathComponent("cache")))
        var video = Fixtures.video()
        video.path = source.path; video.duration = 4
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        var scene = Fixtures.scene(start: 0, end: 4)
        scene.videoPath = source.path
        var options = WizardOptions()
        options.highlightFraming = .grid
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .grid), video: video, range: 0...4,
            turns: [], roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: options.renderSettings.aspectRatio)
        let slot = try #require(plan.slots.first)
        let region = try #require(slot.region)
        let area = try #require(ScreenCropStore.area(reference: plan.layout.reference(forTrack: 0)))
        let box = area.bounds
        let identity = try FeedPathCache.identity(source: source, region: region, start: 0, duration: 4,
            aspect: options.renderSettings.aspectRatio * box.w / box.h,
            focus: slot.focus.map { AreaFocus(x: $0.x, y: $0.y) })
        let keyframes = [CameraPathKeyframe(t: 0, x: 0.05, y: 0.1, w: 0.25, h: 0.5),
                         CameraPathKeyframe(t: 4, x: 0.15, y: 0.1, w: 0.25, h: 0.5)]
        let samples = (0..<16).map { index in
            FeedPathSample(time: Double(index) / 4, faces: [CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.2)],
                           expression: index == 8 ? 5 : 1)
        }
        await cache.store(FeedCameraPath(keyframes: keyframes, samples: samples, trackedShare: 1,
            sourceSize: CGSize(width: video.width, height: video.height), usedFallback: false), identity: identity)
        let preview = await WizardPreviewFraming.resolveCached(options: options, record: scene, video: video,
            face: nil, turns: [], roster: [], people: [], layouts: ScreenCropStore.builtIn, cache: cache)
        guard case .cells(let cells) = preview.framing else {
            Issue.record("Expected grid preview"); return
        }
        #expect(abs(try #require(cells.first).source.minX - 0.1) < 1e-9)
        let tile = PodcastTile(index: 0, x: region.xFrac, y: region.yFrac,
                              w: region.wFrac, h: region.hFrac, personKey: "vip")
        let roster = [VideoPersonRecord(videoID: video.id, personID: 1, key: "vip", name: "VIP",
            descriptor: "", portraitAt: 0, portraitBox: nil, vip: true)]
        let messages = Mutex<[String]>([])
        let tracks = await VIPExpression.measure(url: source, tiles: [tile], roster: roster,
            start: 0, duration: 4, cache: cache, log: { line in messages.withLock { $0.append(line) } })
        #expect(tracks.count == 1 && tracks.first?.samples.count == 16)
        #expect(tracks.first?.samples[8].score == 5)
        #expect(messages.withLock { $0.contains { $0.contains("decode=0") } })
        #expect(!messages.withLock { $0.contains { $0.hasPrefix("Decode:") } })
    }
}
