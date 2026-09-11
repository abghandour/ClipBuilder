import Foundation
import Testing
import Synchronization
@testable import Clip_Builder

@Suite("Multitrack renderer integration", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable,
                "Install ffmpeg and ffprobe to run."))
struct MultitrackRenderTests {
    /// A registered, analyzed 3-second wide fixture: one scene spanning it.
    private func seedScene(in temp: TempDatabase, hash: String) async throws -> (source: URL, scene: SceneRecord) {
        let source = try await FixtureVideo.make(in: temp.directory.url, wide: true)
        let videoID = try await temp.database.registerVideo(
            hash: hash, filename: source.lastPathComponent, path: source.path,
            duration: 3, width: 1920, height: 1080, wide: true
        )
        _ = try await temp.database.saveAnalysis(
            videoID: videoID, runName: "Fixture", instructions: "", sampleInterval: 1,
            notesJSON: nil, tagRanges: ["fixture": [(start: 0, end: 3)]], moments: [],
            analyzedTags: ["fixture"], provider: nil, model: nil, mode: "visual"
        )
        let scene = try #require(try await temp.database.fetchScenes(videoID: videoID).first)
        return (source, scene)
    }

    @Test("static area fuses its crop with zero intermediates and reuses the segment")
    func staticAreaFusionAndReuse() async throws {
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "static-area-fixture")
        var clip = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 3)
        clip.videoFile = source.path
        clip.wide = true
        clip.areaWindow = FreeCropRect(xFrac: 0.1, yFrac: 0.1, wFrac: 0.7, hFrac: 0.7)
        var document = Fixtures.timelineDocument(clips: [clip])
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"),
                                             startTime: 0, duration: 3)]
        let profile = Fixtures.brand(name: "Static")
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("segments"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache)
        let messages = Mutex<[String]>([])
        let result = try await renderer.render(document: document, scenes: [scene], profile: profile,
            database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        defer { try? FileManager.default.removeItem(at: result.url) }
        let lines = messages.withLock { $0 }
        #expect(lines.contains { $0.contains("static area fused; intermediates=0") })
        #expect(!lines.contains { $0.contains("Framing prepass:") })
        #expect(lines.filter { $0.contains("encode pass") }.count == 1)
        let dimensions = await FFmpeg.dimensions(of: result.url)
        #expect(dimensions.width == document.renderSettings.width)
        #expect(dimensions.height == document.renderSettings.height)
        #expect(abs(result.duration - 3) < 0.15)
        // Standalone AreaFramer is the old static prepass; compare its output
        // geometry and duration with the fused render using the same window.
        let resolved = try #require(MultitrackRenderer.resolveClips(document: document, scenes: [scene]).first)
        let area = try #require(ScreenCropStore.area(reference: resolved.screenCrop))
        let old = try await AreaFramer.frame(source: source, start: 0, duration: 3, area: area,
                                             window: try #require(clip.areaWindow), scratch: temp.directory.url)
        let oldDimensions = await FFmpeg.dimensions(of: old)
        #expect(oldDimensions.width == dimensions.width && oldDimensions.height == dimensions.height)
        #expect(abs(await FFmpeg.duration(of: old) - result.duration) < 0.15)
        messages.withLock { $0.removeAll() }
        let warm = try await renderer.render(document: document, scenes: [scene], profile: profile,
            database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        defer { try? FileManager.default.removeItem(at: warm.url) }
        #expect(messages.withLock { $0.contains { $0.contains("cache hit; encodes=0") } })
        #expect(!messages.withLock { $0.contains { $0.contains("encode pass") } })
        #expect(abs(warm.duration - result.duration) < 0.05)
    }

    @Test("local and transition-spanning overlays need two segment burns and one final overlay pass")
    func mixedOverlayPasses() async throws {
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "overlay-passes-fixture")
        var first = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 3)
        first.videoFile = source.path
        var second = first
        second.uid = UUID()
        second.startTime = 3
        second.transIn = "fade"
        var document = Fixtures.timelineDocument(clips: [first, second])
        document.textOverlays = [TextOverlayItem(text: "Local", startTime: 0.2, endTime: 1),
                                 TextOverlayItem(text: "Across", startTime: 2.5, endTime: 3.5)]
        let messages = Mutex<[String]>([])
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("segments")))
        let encodes = Mutex(0)
        let result = try await FFmpeg.$commandCompleted.withValue({ arguments in
            if let index = arguments.firstIndex(of: "-c:v"),
               arguments.indices.contains(index + 1), arguments[index + 1] != "copy" {
                encodes.withLock { $0 += 1 }
            }
        }) {
            try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        let lines = messages.withLock { $0 }
        #expect(lines.contains("Overlay plan: segment=1; timeline=1"))
        #expect(lines.filter { $0.contains("encode pass") }.count == 2)
        #expect(lines.filter { $0.hasPrefix("Burning 1 overlay") }.count == 1)
        #expect(!lines.contains { $0.contains("failed") })
        // Two segment encodes, one xfade assembly, one remaining overlay burn.
        // Stream-copy concat/music calls are deliberately excluded.
        #expect(encodes.withLock { $0 } == 4)
        let expected = 6 - min(SettingsStore.loadSettings().transitions.xfadeDuration, 1.2)
        #expect(abs(result.duration - expected) < 0.15)
    }

    @Test("regression: wide masked clip and delayed faded text render successfully")
    func maskedWideClipAndDelayedText() async throws {
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "render-fixture")
        var clip = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 3)
        clip.videoFile = source.path
        clip.wide = true
        var document = Fixtures.timelineDocument(clips: [clip])
        document.cropBlocks = [
            CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 3),
        ]
        var text = TextOverlayItem(text: "Delayed", startTime: 1, endTime: 2.5)
        text.transIn = "fade"
        text.transOut = "fade"
        document.textOverlays = [text]

        var profile = Fixtures.brand(name: "Render")
        profile.outputFolder = temp.directory.url.path
        let renderer = MultitrackRenderer(render: RenderEngine())
        let result = try await renderer.render(
            document: document, scenes: [scene], profile: profile, database: temp.database,
            preview: true, emit: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        let duration = await FFmpeg.duration(of: result.url)
        #expect(abs(duration - 3) < 0.15)
    }

    @Test("two tracks, a slow-motion clip, and music overlay render to the timeline's length")
    func layeredTracksSlowMotionAndMusic() async throws {
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "layered-fixture")

        // Keep music local to this test; catalog lookup has no injectable root.
        let musicURL = try await FixtureVideo.makeMusic(in: temp.directory.url, seconds: 8,
                                                        name: "Fixture Beat")

        // Track 0: two seconds at half speed (1 s of source), then the rest
        // of the scene. Track 1: a second clip layered over the first two
        // seconds. Timeline length: 2 + 2 = 4 s.
        var slow = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 2, speed: 0.5)
        slow.videoFile = source.path
        slow.wide = true
        var tail = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 1, duration: 2, startTime: 2)
        tail.videoFile = source.path
        tail.wide = true
        var upper = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 1, duration: 2, startTime: 0, track: 1)
        upper.videoFile = source.path
        upper.wide = true

        var document = Fixtures.timelineDocument(clips: [slow, tail, upper])
        document.trackCount = 2
        document.cropBlocks = [
            CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 4),
        ]
        var profile = Fixtures.brand(name: "Layered")
        profile.outputFolder = temp.directory.url.appendingPathComponent("Output").path
        let renderer = MultitrackRenderer(render: RenderEngine())
        let result = try await renderer.render(
            document: document, scenes: [scene], profile: profile, database: temp.database,
            preview: true, emit: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: result.url) }
        let output = temp.directory.url.appendingPathComponent("with-music.mp4")
        try await RenderEngine().overlayMusic(video: result.url, music: musicURL, output: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let duration = await FFmpeg.duration(of: output)
        #expect(abs(duration - 4) < 0.2, "duration \(duration)")
        #expect(await FFmpeg.hasAudioStream(output))
        let dimensions = await FFmpeg.dimensions(of: output)
        #expect(dimensions.width == RenderEngine.outputWidth)
        #expect(dimensions.height == RenderEngine.outputHeight)
    }
}
