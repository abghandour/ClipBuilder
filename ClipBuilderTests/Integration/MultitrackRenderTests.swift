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

extension MultitrackRenderTests {
    @Test("editing an earlier caption preserves the later trimmed, slow framed segment")
    func framedCaptionOffsets() async throws {
        let temp = try TempDatabase()
        let (source, initialScene) = try await seedScene(in: temp, hash: "framed-captions")
        var scene = initialScene
        let path = SceneCameraPath(camera: "balanced", keyframes: [
            CameraPathKeyframe(t: 0, x: 0.3, y: 0, w: 81.0 / 256, h: 1),
            CameraPathKeyframe(t: 3, x: 0.35, y: 0, w: 81.0 / 256, h: 1),
        ])
        scene.centerStagePathJSON = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
        var first = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 1)
        first.videoFile = source.path
        first.centerStage = true
        first.wide = true
        first.captions = "bottom"
        var second = first
        second.uid = UUID()
        second.startTime = 1
        second.sourceStart = 1
        second.sourceEnd = 2
        second.duration = 2
        second.speed = 0.5
        var document = Fixtures.timelineDocument(clips: [first, second])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache)
        let messages = Mutex<[String]>([])
        var outputs: [URL] = []
        defer { for url in outputs { try? FileManager.default.removeItem(at: url) } }
        for text in ["FIRST", "EDITED FIRST"] {
            try await temp.database.replaceTranscripts(videoID: scene.videoID, language: "en", isTranslation: false,
                segments: [TranscriptSegment(start: 0, end: 1, text: text),
                           TranscriptSegment(start: 1, end: 2, text: "SECOND")], provider: nil, model: nil)
            messages.withLock { $0.removeAll() }
            let result = try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
            outputs.append(result.url)
            #expect(!messages.withLock { $0.contains { $0.hasPrefix("Framing failed") } })
            if text == "EDITED FIRST" {
                #expect(messages.withLock { $0.contains("Segment 2: cache hit; encodes=0") })
                #expect(messages.withLock { $0.contains("Segment 1: encode pass") })
                #expect(messages.withLock { $0.filter { $0.hasPrefix("Framing cache hit") }.count } == 2)
                #expect(!messages.withLock { $0.contains { $0.hasPrefix("Framing prepass:") } })
            }
        }
        // Independent cache + disabled prepass reuse forces the reference to
        // rebuild framing, segments and assembly from the original source.
        let reference = try await MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("reference")),
            framingCacheEnabled: false).render(document: document, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        outputs.append(reference.url)
        let cachedFrames = try await FFmpeg.run(["-v", "error", "-i", outputs[1].path,
            "-map", "0:v:0", "-map", "0:a:0", "-f", "framemd5", "-"], timeout: 60, mediaResource: .decoding)
        let referenceFrames = try await FFmpeg.run(["-v", "error", "-i", reference.url.path,
            "-map", "0:v:0", "-map", "0:a:0", "-f", "framemd5", "-"], timeout: 60, mediaResource: .decoding)
        #expect(cachedFrames == referenceFrames)

        let input = document
        let sourceScene = scene
        for hit in [true, false] {
            let cancelledRoot = temp.directory.url.appendingPathComponent("cancelled")
            let target = hit ? renderer : MultitrackRenderer(render: RenderEngine(),
                segmentCache: RenderSegmentCache(directory: cancelledRoot))
            let job = Task {
                try await target.render(document: input, scenes: [sourceScene], profile: Fixtures.brand(),
                    database: temp.database, preview: true, emit: { line in
                        if line.hasPrefix(hit ? "Framing cache hit" : "Framing prepass:") {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
            }
            await #expect(throws: CancellationError.self) { try await job.value }
            #expect(!FileManager.default.fileExists(atPath: cancelledRoot.path))
        }

        // A changed source must miss the stored prepasses; changing it again
        // after framing must prevent publishing the new entries.
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0, 0, 0, 72, 102, 114, 101, 101]) + Data(repeating: 0, count: 64))
        try handle.close()
        let root = temp.directory.url.appendingPathComponent("cache")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        messages.withLock { $0.removeAll() }
        let changed = try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { line in
                messages.withLock { $0.append(line) }
                if line.hasPrefix("Assembling ") {
                    do {
                        let handle = try FileHandle(forWritingTo: source)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data([0, 0, 0, 72, 102, 114, 101, 101]) + Data(repeating: 1, count: 64))
                        try handle.close()
                    } catch { Issue.record("Could not mutate fixture: \(error)") }
                }
            })
        outputs.append(changed.url)
        #expect(!messages.withLock { $0.contains { $0.hasPrefix("Framing cache hit") } })
        #expect(messages.withLock { $0.filter { $0.hasPrefix("Framing prepass:") }.count } == 2)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == before)
    }

    @Test("tracked-area fallback preserves caption timing and never publishes a prepass")
    func areaFallbackIsNotCached() async throws {
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "area-fallback")
        var clip = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 1, duration: 1)
        clip.videoFile = source.path
        clip.wide = true
        clip.captions = "bottom"
        var document = Fixtures.timelineDocument(clips: [clip])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 1)]
        let root = temp.directory.url.appendingPathComponent("cache")
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: RenderSegmentCache(directory: root))
        var decoded: [String] = []
        for caption in ["BEFORE", "CHANGED BEFORE"] {
            try await temp.database.replaceTranscripts(videoID: scene.videoID, language: "en", isTranslation: false,
                segments: [TranscriptSegment(start: 0, end: 1, text: caption),
                           TranscriptSegment(start: 1, end: 2, text: "RIGHT CAPTION")], provider: nil, model: nil)
            let messages = Mutex<[String]>([])
            let result = try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
            defer { try? FileManager.default.removeItem(at: result.url) }
            decoded.append(try await FFmpeg.run(["-v", "error", "-i", result.url.path,
                "-map", "0:v:0", "-map", "0:a:0", "-f", "framemd5", "-"], timeout: 60, mediaResource: .decoding))
            #expect(messages.withLock { $0.contains { $0.contains("using a static center window") } })
            #expect(!messages.withLock { $0.contains { $0.hasPrefix("Framing cache hit") } })
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty != false)
        #expect(decoded[0] == decoded[1])
    }

    @Test("finishing reuse preserves every decoded frame and audio sample, and invalidates caption/title edits")
    func finishingReuseAndEdits() async throws {
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "finishing-reuse")
        var first = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 3)
        first.videoFile = source.path
        first.captions = "bottom"
        var second = first
        second.uid = UUID()
        second.startTime = 3
        second.transIn = "fade"
        var document = Fixtures.timelineDocument(clips: [first, second])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        var title = TextOverlayItem(text: "Across the join", startTime: 0.1, endTime: 5.8)
        title.transIn = "fade"
        title.transOut = "fade"
        document.textOverlays = [title]
        var block = OverlayBlockItem()
        block.startTime = 1
        block.duration = 4
        block.composition.texts = [TextOverlayItem(text: "Block", startTime: 0, endTime: 4)]
        document.overlayBlocks = [block]
        try await temp.database.replaceTranscripts(videoID: scene.videoID, language: "en", isTranslation: false,
            segments: [TranscriptSegment(start: 0.2, end: 1.2, text: "Original caption")], provider: nil, model: nil)
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("segments"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache)
        let messages = Mutex<[String]>([])
        var outputs: [URL] = []
        defer { for url in outputs { try? FileManager.default.removeItem(at: url) } }
        let cold = try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        outputs.append(cold.url)
        messages.withLock { $0.removeAll() }
        let encodes = Mutex(0)
        let warm = try await FFmpeg.$commandCompleted.withValue({ args in
            if let index = args.firstIndex(of: "-c:v"), args.indices.contains(index + 1), args[index + 1] != "copy" {
                encodes.withLock { $0 += 1 }
            }
        }) {
            try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        }
        outputs.append(warm.url)
        #expect(messages.withLock { $0.contains("Finishing cache hit; assembly and overlay encodes=0") })
        #expect(encodes.withLock { $0 } == 0)
        #expect(try Data(contentsOf: warm.url) == Data(contentsOf: cold.url))
        let cancellationDocument = document
        let cancelled = Task {
            try await renderer.render(document: cancellationDocument, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in
                    if line.hasPrefix("Finishing cache hit") {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let reference = try await MultitrackRenderer(render: RenderEngine(), segmentCache: cache, finishingCacheEnabled: false)
            .render(document: document, scenes: [scene], profile: Fixtures.brand(), database: temp.database,
                    preview: true, emit: { _ in })
        outputs.append(reference.url)
        func decoded(_ url: URL) async throws -> String {
            try await FFmpeg.run(["-v", "error", "-i", url.path, "-map", "0:v:0", "-map", "0:a:0",
                                  "-f", "framemd5", "-"], timeout: 60, mediaResource: .decoding)
        }
        let warmFrames = try await decoded(warm.url)
        let referenceFrames = try await decoded(reference.url)
        #expect(warmFrames == referenceFrames)
        #expect(abs(warm.duration - reference.duration) < 0.001)
        messages.withLock { $0.removeAll() }
        try await temp.database.replaceTranscripts(videoID: scene.videoID, language: "en", isTranslation: false,
            segments: [TranscriptSegment(start: 0.2, end: 1.2, text: "Edited caption")], provider: nil, model: nil)
        let captionEdit = try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        outputs.append(captionEdit.url)
        #expect(!messages.withLock { $0.contains { $0.hasPrefix("Finishing cache hit") } })
        let captionFrames = try await decoded(captionEdit.url)
        #expect(captionFrames != warmFrames)
        messages.withLock { $0.removeAll() }
        document.textOverlays[0].text = "Changed title"
        let titleEdit = try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        outputs.append(titleEdit.url)
        #expect(!messages.withLock { $0.contains { $0.hasPrefix("Finishing cache hit") } })
        #expect(try await decoded(titleEdit.url) != captionFrames)
    }

    @Test("an unaffordable crossfade reports its hard-cut fallback")
    func assemblyReportsFallback() async throws {
        let temp = try TempDirectory()
        let source = try await FixtureVideo.make(in: temp.url)
        let output = temp.url.appendingPathComponent("joined.mp4")
        let fellBack = Mutex(false)
        let entries = Mutex<[RenderSegmentCache.Entry]>([])
        let cache = RenderEngine.AssemblyCache(
            cache: RenderSegmentCache(directory: temp.url.appendingPathComponent("cache")), stagingDirectory: temp.url,
            record: { entry in entries.withLock { $0.append(entry) } }, hit: { Issue.record("Unexpected fallback cache hit") })
        try await RenderEngine().concatenate(clips: [source, source], transitions: ["fade"], output: output,
            transitionDuration: 0.001, assemblyCache: cache, onFallback: { fellBack.withLock { $0 = true } })
        #expect(fellBack.withLock { $0 })
        #expect(entries.withLock { $0.isEmpty })
        #expect(abs(await FFmpeg.duration(of: output) - 6) < 0.15)
    }
}

extension MultitrackRenderTests {
    @Test("hard-cut fallbacks never satisfy the finishing cache")
    func finishingFallbackIsNotPublished() async throws {
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "finishing-fallback")
        var first = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 0.06)
        first.videoFile = source.path
        var second = first
        second.uid = UUID()
        second.startTime = 0.06
        second.transIn = "fade"
        var document = Fixtures.timelineDocument(clips: [first, second])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        document.textOverlays = [TextOverlayItem(text: "Tiny join", startTime: 0, endTime: 0.12)]
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("segments"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache)
        let messages = Mutex<[String]>([])
        for _ in 0..<2 {
            messages.withLock { $0.removeAll() }
            let result = try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
            defer { try? FileManager.default.removeItem(at: result.url) }
            #expect(result.duration > 0.1)
            #expect(!messages.withLock { $0.contains { $0.hasPrefix("Finishing cache hit") } })
            #expect(messages.withLock { $0.contains { $0.hasPrefix("Burning 1 overlay") } })
        }
    }
}

extension MultitrackRenderTests {
    @Test("caption edits reuse only unaffected crossfade groups with identical decoded output")
    func captionEditReusesUnaffectedAssembly() async throws {
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "assembly-reuse")
        var first = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 1.5)
        first.videoFile = source.path
        first.captions = "bottom"
        var second = first
        second.uid = UUID()
        second.startTime = 1.5
        second.sourceStart = 1.5
        var third = second
        third.uid = UUID()
        third.startTime = 3
        third.transIn = "fade"
        var document = Fixtures.timelineDocument(clips: [first, second, third])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        document.textOverlays = [TextOverlayItem(text: "Across all clips", startTime: 0.1, endTime: 4.4)]
        let input = document
        func captions(_ firstText: String, _ laterText: String) async throws {
            try await temp.database.replaceTranscripts(videoID: scene.videoID, language: "en", isTranslation: false,
                segments: [TranscriptSegment(start: 0.1, end: 1.2, text: firstText),
                           TranscriptSegment(start: 1.6, end: 2.8, text: laterText)], provider: nil, model: nil)
        }
        try await captions("First", "Later")
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache, finishingCacheEnabled: false)
        let messages = Mutex<[String]>([])
        var outputs: [URL] = []
        defer { for url in outputs { try? FileManager.default.removeItem(at: url) } }
        func render(_ renderer: MultitrackRenderer) async throws -> MultitrackRenderer.RenderResult {
            messages.withLock { $0.removeAll() }
            return try await renderer.render(document: input, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        }
        outputs.append(try await render(renderer).url)
        #expect(!messages.withLock { $0.contains { $0.hasPrefix("Assembly cache hit") } })
        try await captions("Edited first", "Later")
        let crossfades = Mutex(0)
        let edited = try await FFmpeg.$commandCompleted.withValue({ args in
            if args.contains(where: { $0.contains("xfade=") }) { crossfades.withLock { $0 += 1 } }
        }) { try await render(renderer) }
        outputs.append(edited.url)
        #expect(messages.withLock { $0.filter { $0.hasPrefix("Assembly cache hit") }.count } == 1)
        #expect(crossfades.withLock { $0 } == 0)
        let reference = try await render(MultitrackRenderer(render: RenderEngine(), segmentCache: cache,
            finishingCacheEnabled: false, assemblyCacheEnabled: false))
        outputs.append(reference.url)
        func decoded(_ url: URL) async throws -> String {
            try await FFmpeg.run(["-v", "error", "-i", url.path, "-map", "0:v:0", "-map", "0:a:0",
                                  "-f", "framemd5", "-"], timeout: 60, mediaResource: .decoding)
        }
        #expect(try await decoded(edited.url) == decoded(reference.url))
        #expect(abs(edited.duration - reference.duration) < 0.001)
        let cancelled = Task {
            try await renderer.render(document: input, scenes: [scene], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in
                    if line.hasPrefix("Assembly cache hit") { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await captions("Edited first", "Edited later")
        outputs.append(try await render(renderer).url)
        #expect(!messages.withLock { $0.contains { $0.hasPrefix("Assembly cache hit") } })
    }
}
