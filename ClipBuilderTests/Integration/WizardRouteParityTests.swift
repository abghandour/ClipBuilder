import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Wizard route parity", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct WizardRouteParityTests {
    private let settings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)

    private func fixture(_ temp: TempDatabase) async throws -> SceneRecord {
        let source = temp.directory.url.appendingPathComponent("wizard-source.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "testsrc2=size=960x540:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "4",
            "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        let videoID = try await temp.database.registerVideo(hash: "wizard-parity", filename: source.lastPathComponent,
            path: source.path, duration: 4, width: 960, height: 540, wide: true)
        _ = try await temp.database.saveAnalysis(videoID: videoID, runName: "Fixture", instructions: "", sampleInterval: 1,
            notesJSON: nil, tagRanges: ["fixture": [(start: 0, end: 4)]], moments: [], analyzedTags: ["fixture"],
            provider: nil, model: nil, mode: "visual")
        return try #require(try await temp.database.fetchScenes(videoID: videoID).first)
    }

    /// The reference is an independently constructed Builder document, not the
    /// removed ordinary extractor. It exercises the established renderer with
    /// the same source clocks, including transitions and visual-only cutaways.
    @Test("ordinary cuts match Builder for paths, retiming, captions, overlays and joins",
          arguments: ["saved-path", "speed", "captions", "overlay", "crossfade", "broll", "combined"])
    func builderParity(_ feature: String) async throws {
        let temp = try await TempDatabase()
        var scene = try await fixture(temp)
        let combined = feature == "combined"
        let tracked = feature == "saved-path" || combined
        let speed = feature == "speed" || combined ? 1.5 : 1.0
        let captions = feature == "captions" || combined
        let overlay = feature == "overlay" || combined
        let joins = feature == "crossfade" || combined
        let broll = feature == "broll" || combined
        let path = SceneCameraPath(camera: "balanced", keyframes: [
            CameraPathKeyframe(t: 0, x: 0.2, y: 0, w: 81.0 / 256, h: 1),
            CameraPathKeyframe(t: 4, x: 0.4, y: 0, w: 81.0 / 256, h: 1)])
        if tracked { scene.centerStagePathJSON = String(data: try JSONEncoder().encode(path), encoding: .utf8) }
        var recipe = CropRecipe(kind: .talker)
        recipe.centerStage = true
        let framing: FramingPlan = tracked
            ? .tracked(recipe, region: nil, fit: .fill, feather: 0.08, blur: 0.5)
            : .static(window: nil, fit: .fill, feather: 0.08, blur: 0.5)
        var planned = Fixtures.planClip(sceneID: scene.id, start: 0.5, end: 3.5)
        planned.speed = speed
        var candidate = WizardOrdinaryTimeline.cutDocument(clip: planned, sceneMap: [scene.id: scene],
            settings: settings, framingPlan: framing)
        let duration = 3 / speed
        var referenceClip = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0.5, duration: duration, speed: speed)
        referenceClip.videoFile = scene.videoPath
        referenceClip.precision = .speech
        referenceClip.framingPlan = framing
        referenceClip.wide = tracked
        referenceClip.centerStage = tracked
        referenceClip.captions = "none"
        if tracked {
            referenceClip.areaRegion = FreeCropRect()
            referenceClip.cameraPath = CenterStageService.slice(path.keyframes, from: 0.5, duration: 3)
        }
        var reference = Fixtures.timelineDocument(clips: [referenceClip])
        reference.renderSettings = settings
        if captions {
            try await temp.database.replaceTranscripts(videoID: scene.videoID, transcriptionKey: "parity", language: "en", isTranslation: false,
                segments: [TranscriptSegment(start: 0, end: 0.4, text: "Before the cut"),
                           TranscriptSegment(start: 0.6, end: 1.6, text: "Source clock caption"),
                           TranscriptSegment(start: 2, end: 3.4, text: "Later words")], provider: nil, model: nil)
            candidate.videoTrack[0].captions = "bottom"
            reference.videoTrack[0].captions = "bottom"
        }
        if overlay {
            let title = TextOverlayItem(text: "Wizard parity", startTime: 0.2, endTime: duration - 0.2)
            candidate.textOverlays = [title]
            reference.textOverlays = [title]
        }
        if broll {
            var cutaway = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 0.6 / speed,
                startTime: 1 / speed, track: 1, speed: speed)
            cutaway.videoFile = scene.videoPath
            cutaway.role = .cutaway
            cutaway.coverAllAreas = true
            cutaway.muted = true
            cutaway.captions = "none"
            cutaway.precision = .speech
            candidate.videoTrack.append(cutaway)
            reference.videoTrack.append(cutaway)
        }
        if joins {
            var second = referenceClip
            second.uid = UUID(); second.originKey = "second"
            second.sourceStart = 1; second.sourceEnd = 2.5
            second.startTime = duration; second.duration = 1.5 / speed
            second.transIn = "fade"
            second.cameraPath = tracked ? CenterStageService.slice(path.keyframes, from: 1, duration: 1.5) : nil
            candidate.videoTrack.append(second)
            reference.videoTrack.append(second)
        }
        let actual = try await MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("actual"))).render(
                document: candidate, scenes: [scene], profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: actual.url) }
        let expected = try await MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("reference"))).render(
                document: reference, scenes: [scene], profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: expected.url) }
        let comparison = try await MultitrackRenderTests.compareDecoded(actual.url, expected.url, trailingFramesAllowed: 1)
        #expect(comparison.videoTimingIdentical)
        #expect(comparison.minimumSSIM >= 0.98)
        #expect(abs(actual.duration - expected.duration) <= 1.0 / 30 + 0.001)
        #expect(await FFmpeg.hasAudioStream(actual.url))
        #expect(!comparison.frameSSIM.isEmpty)
    }

    @Test("ordinary static segments skip tracking, reuse their cache and invalidate framing edits")
    func staticCache() async throws {
        let temp = try await TempDatabase()
        let scene = try await fixture(temp)
        let plan = FramingPlan.static(window: nil, fit: .fill, feather: 0.08, blur: 0.5)
        var document = WizardOrdinaryTimeline.cutDocument(clip: Fixtures.planClip(sceneID: scene.id, start: 0, end: 4),
            sceneMap: [scene.id: scene], settings: settings, framingPlan: plan)
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache, finishingCacheEnabled: false)
        for stage in ["cold", "warm", "edited"] {
            if stage == "edited" {
                document.videoTrack[0].framingPlan = .static(window: nil, fit: .blurredFill, feather: 0.2, blur: 1)
            }
            let messages = Mutex<[String]>([])
            let commands = Mutex<[[String]]>([])
            let result = try await FFmpeg.$commandCompleted.withValue({ args in commands.withLock { $0.append(args) } }) {
                try await renderer.render(document: document, scenes: [scene], profile: Fixtures.brand(), database: temp.database,
                    preview: true, emit: { line in messages.withLock { $0.append(line) } })
            }
            defer { try? FileManager.default.removeItem(at: result.url) }
            let lines = messages.withLock { $0 }
            #expect(!lines.contains { $0.hasPrefix("Framing prepass:") || $0.hasPrefix("Framing cache hit") })
            #expect(lines.contains("Segment 1: cache hit; encodes=0") == (stage == "warm"))
            #expect(commands.withLock { $0.filter { $0.last?.hasSuffix("_layered.mp4") == true }.count } == (stage == "warm" ? 0 : 1))
        }
    }

    @Test("legacy ordinary crop-scale-pad and original focus use the shared extraction path", arguments: [false, true])
    func directCropReference(_ focus: Bool) async throws {
        let temp = try await TempDatabase()
        let scene = try await fixture(temp)
        var clip = Fixtures.planClip(sceneID: scene.id, start: 1, end: 4)
        clip.speed = 1.5
        let plan: FramingPlan? = focus
            ? .static(window: FreeCropRect(xFrac: 0.5, wFrac: 0.5), fit: .fill, feather: 0.08, blur: 0.5) : nil
        let document = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: settings, framingPlan: plan)
        let output = temp.directory.url.appendingPathComponent("new-route.mp4")
        let expected = temp.directory.url.appendingPathComponent("direct.mp4")
        try await ExpressPodcastRenderer.extract(document: document, scenes: [scene], profile: Fixtures.brand(),
            database: temp.database, render: RenderEngine(), camera: "balanced", overlays: [], look: nil,
            mute: false, clipNumber: 1, duration: 2, output: output,
            cache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache")), emit: { _ in })
        let crop = focus ? "crop=iw*0.5:ih:iw*0.5:0,scale=360:640"
            : "crop='min(iw\\,ih*0.56250)':ih:(iw-min(iw\\,ih*0.56250))*0.5:0,scale=360:640:force_original_aspect_ratio=decrease,pad=360:640:(ow-iw)/2:(oh-ih)/2:color=black"
        try await RenderContext.$settings.withValue(settings) {
            try await FFmpeg.run(["-y", "-ss", "1", "-i", scene.videoPath,
                "-vf", "setpts=(PTS-STARTPTS)/1.5,fps=30,\(crop),setsar=1",
                "-af", "atempo=1.5", "-t", "2"] + FFmpeg.encodeArgs + [expected.path], timeout: 60)
        }
        let comparison = try await MultitrackRenderTests.compareDecoded(output, expected, trailingFramesAllowed: 1)
        #expect(comparison.videoTimingIdentical)
        #expect(comparison.minimumSSIM >= 0.98)
        #expect(comparison.frameSSIM.count >= 59)
        #expect(abs(await FFmpeg.duration(of: output) - 2) <= 1.0 / 30 + 0.001)
        #expect(await FFmpeg.hasAudioStream(output))
    }
}
