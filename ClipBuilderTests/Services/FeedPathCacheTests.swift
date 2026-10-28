import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct FeedPathCacheTests {
    @Test(arguments: [100.0, 200.0, 400.0])
    func focusedPreviewTracksOnlyAClampedWindowAndReusesNearbyMoments(time: Double) async throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("source.mp4")
        try Data(repeating: 3, count: 100).write(to: source)
        let cache = FeedPathCache(cache: RenderSegmentCache(directory: temp.url.appendingPathComponent("cache")))
        var video = Fixtures.video()
        video.path = source.path
        video.duration = 500
        video.videoType = VideoType.training.rawValue
        var scene = Fixtures.scene(start: 100, end: 400)
        scene.videoPath = source.path
        var options = WizardOptions()
        options.framing = Framing(subject: .centerStage,
            focusFrame: FreeCropRect(xFrac: 0.1, yFrac: 0.1, wFrac: 0.8, hFrac: 0.8))
        let calls = Mutex<[FeedPathCache.Identity]>([])
        let tracker: WizardPreviewFraming.FocusTracker = { _, identity in
            calls.withLock { $0.append(identity) }
            return FeedCameraPath(keyframes: [
                .init(t: 0, x: 0.2, y: 0.2, w: 0.3, h: 0.5),
                .init(t: identity.duration, x: 0.3, y: 0.2, w: 0.3, h: 0.5)],
                samples: [], trackedShare: 1, sourceSize: CGSize(width: 1920, height: 1080), usedFallback: false)
        }
        _ = await WizardPreviewFraming.resolveCached(options: options, record: scene, video: video,
            face: nil, turns: [], roster: [], people: [], layouts: [], cache: cache, track: tracker, time: time)
        let identity = try #require(calls.withLock { $0.first })
        #expect(identity.start == max(100, time - 2))
        #expect(identity.duration == min(400, time + 2) - identity.start)
        #expect(identity.duration <= 4)
        #expect(identity.tuning == "balanced")
        #expect(await cache.read(identity) != nil)

        let nearby = time == 400 ? time - 0.5 : time + 0.5
        let result = await WizardPreviewFraming.resolveCached(options: options, record: scene, video: video,
            face: nil, turns: [], roster: [], people: [], layouts: [], cache: cache, track: tracker, time: nearby)
        #expect(calls.withLock { $0.count } == 1)
        let cached = try #require(await cache.covering(source: source, region: identity.region,
            start: nearby, duration: 0, tuning: "balanced", aspect: identity.aspect, focus: identity.focus))
        #expect(cached.identity == identity)
        // A balanced preview path must not leak into conversation tracking.
        #expect(await cache.covering(source: source, region: identity.region, start: nearby,
            duration: 0, aspect: identity.aspect, focus: identity.focus) == nil)
        guard case .cells(let cells) = result.framing else {
            Issue.record("Expected focused preview cells"); return
        }
        let expectedX = 0.2 + 0.1 * (nearby - identity.start) / identity.duration
        #expect(abs(try #require(cells.first).source.minX - expectedX) < 1e-9)
    }

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
        options.framing = Framing(subject: .layout)
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
