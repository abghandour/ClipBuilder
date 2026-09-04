import Foundation
import Testing
@testable import Clip_Builder

@Suite("Multitrack renderer integration", .tags(.integration), .serialized,
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

    @Test("two tracks, a slow-motion clip, and library music render to the timeline's length")
    func layeredTracksSlowMotionAndMusic() async throws {
        let scope = try DataFolderOverride()
        let temp = try TempDatabase()
        let (source, scene) = try await seedScene(in: temp, hash: "layered-fixture")

        // Music lives in the (overridden) assets library so the renderer
        // resolves it by name like the app does.
        let musicFolder = AssetKind.music.rootURL
        try FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        _ = try await FixtureVideo.makeMusic(in: musicFolder, seconds: 8, name: "Fixture Beat")
        AssetStore.invalidateCatalog(.music)
        #expect(WizardEngine.availableMusic().map(\.name) == ["Fixture Beat"])

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
        var music = SoundItem()
        music.name = "Fixture Beat"
        music.startTime = 0
        music.duration = 4
        document.soundTrack = [music]

        var profile = Fixtures.brand(name: "Layered")
        profile.outputFolder = scope.directory.url.appendingPathComponent("Output").path
        let renderer = MultitrackRenderer(render: RenderEngine())
        let result = try await renderer.render(
            document: document, scenes: [scene], profile: profile, database: temp.database,
            preview: true, emit: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        let duration = await FFmpeg.duration(of: result.url)
        #expect(abs(duration - 4) < 0.2, "duration \(duration)")
        #expect(await FFmpeg.hasAudioStream(result.url))
        let dimensions = await FFmpeg.dimensions(of: result.url)
        #expect(dimensions.width == RenderEngine.outputWidth)
        #expect(dimensions.height == RenderEngine.outputHeight)
    }
}
