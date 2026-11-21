import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Hold rendering", .enabled(if: FFmpeg.isAvailable))
struct HoldRenderTests {
    @concurrent
    private func movingSource(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=640x360:r=30:d=3",
            "-f", "lavfi", "-i", "color=c=red:s=100x180:r=30:d=3",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3",
            "-filter_complex", "[0:v][1:v]overlay=x='90+90*t':y=90[v]",
            "-map", "[v]", "-map", "2:a", "-t", "3", "-c:v", "libx264", "-crf", "10",
            "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
    }

    /// Lossless one-frame movies with the same silent audio let compareDecoded
    /// compare the held pictures without hardware-encoder byte comparisons.
    @concurrent
    private func frame(_ source: URL, at time: Double, folder: URL) async throws -> URL {
        let output = folder.appendingPathComponent(UUID().uuidString + ".mkv")
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", source.path,
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-map", "0:v:0", "-map", "1:a:0", "-vf", "setpts=PTS-STARTPTS",
            "-t", "0.033333", "-c:v", "ffv1", "-c:a", "pcm_s16le", output.path], timeout: 60)
        return output
    }

    @concurrent
    private func rms(_ source: URL, start: Double, duration: Double, folder: URL) async throws -> Double {
        let output = folder.appendingPathComponent(UUID().uuidString + ".pcm")
        try await FFmpeg.run(["-y", "-ss", String(start), "-i", source.path, "-t", String(duration),
            "-vn", "-ac", "1", "-ar", "44100", "-f", "f32le", output.path], timeout: 60)
        let samples = try Data(contentsOf: output).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(!samples.isEmpty)
        return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
    }

    private func check(centerStage: Bool) async throws {
        let temp = try await TempDatabase()
        let source = temp.directory.url.appendingPathComponent("moving.mp4")
        try await movingSource(source)
        let path = [CameraPathKeyframe(t: 0, x: 0.15, y: 0, w: 0.5, h: 1),
                    CameraPathKeyframe(t: 1, x: 0.2, y: 0, w: 0.5, h: 1),
                    CameraPathKeyframe(t: 2, x: 0.25, y: 0, w: 0.5, h: 1)]
        var head = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1)
        head.videoFile = source.path
        head.wide = centerStage
        head.captions = "none"
        head.centerStage = centerStage
        head.cameraPath = centerStage ? CenterStageService.slice(path, from: 0, duration: 1) : nil
        var hold = head
        hold.uid = UUID()
        hold.hold = true
        hold.startTime = 1
        hold.sourceStart = 1
        hold.sourceEnd = 1
        hold.duration = 0.8
        hold.speed = nil
        // Keep a real advancing path here: the renderer must sample its first
        // position, not animate the crop over the frozen picture.
        hold.cameraPath = centerStage ? CenterStageService.slice(path, from: 1, duration: 1) : nil
        var tail = head
        tail.uid = UUID()
        tail.startTime = 1.8
        tail.sourceStart = 1
        tail.sourceEnd = 2
        tail.cameraPath = hold.cameraPath
        var document = Fixtures.timelineDocument(clips: [head, hold, tail])
        // A 320×360 canvas is exactly half the 640×360 source for the path case.
        document.renderSettings = RenderSettings(preset: .custom, customWidth: centerStage ? 320 : 640, customHeight: 360)
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 2.8)]
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache")),
            framingCacheEnabled: false)
        let rendered = try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
                                                database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        #expect(abs(await FFmpeg.duration(of: rendered.url) - 2.8) < 0.07)
        let first = try await frame(rendered.url, at: 1.1, folder: temp.directory.url)
        let last = try await frame(rendered.url, at: 1.7, folder: temp.directory.url)
        let boundary = try await frame(rendered.url, at: 1.0, folder: temp.directory.url)
        let before = try await frame(rendered.url, at: 29.0 / 30, folder: temp.directory.url)
        let moving = try await frame(rendered.url, at: 1.9, folder: temp.directory.url)
        #expect(try await MultitrackRenderTests.compareDecoded(first, last).minimumSSIM >= 0.99)
        #expect(try await MultitrackRenderTests.compareDecoded(first, boundary).minimumSSIM >= 0.97)
        #expect(try await MultitrackRenderTests.compareDecoded(first, before).minimumSSIM >= 0.97)
        #expect(try await MultitrackRenderTests.compareDecoded(first, moving).minimumSSIM < 0.99)
        // The encoded audio runs up to 50 ms behind the picture (measured:
        // silence from 1.026 to 1.852 s), so the window starts 50 ms into the
        // hold. It must be below -40 dBFS and the interior below -60 dBFS.
        // Surrounding dialogue stays audible.
        #expect(try await rms(rendered.url, start: 1.05, duration: 0.75, folder: temp.directory.url) < 0.01)
        #expect(try await rms(rendered.url, start: 1.1, duration: 0.6, folder: temp.directory.url) < 0.001)
        #expect(try await rms(rendered.url, start: 0.2, duration: 0.5, folder: temp.directory.url) > 0.01)
        #expect(try await rms(rendered.url, start: 2, duration: 0.5, folder: temp.directory.url) > 0.01)
    }

    @Test("Moving, held, moving: 2.8 seconds, one frozen picture and silent hold audio")
    func hold() async throws { try await check(centerStage: false) }

    @Test("Center Stage holds the crop at the boundary without a jump")
    func centerStageHold() async throws { try await check(centerStage: true) }

    @concurrent
    private func pauseSource(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=10",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=10",
            "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-crf", "10",
            "-pix_fmt", "yuv420p", "-c:a", "aac", url.path], timeout: 60)
    }

    /// Ten-millisecond RMS windows can detect a 50 ms hold; silencedetect's
    /// default minimum silence cannot. AAC boundary ringing can cost a window.
    @concurrent
    private func silenceWindows(_ source: URL, folder: URL) async throws -> [Range<Double>] {
        let output = folder.appendingPathComponent(UUID().uuidString + ".pcm")
        try await FFmpeg.run(["-y", "-i", source.path, "-vn", "-ac", "1", "-ar", "44100",
            "-f", "f32le", output.path], timeout: 60)
        let samples = try Data(contentsOf: output).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(!samples.isEmpty)
        let size = 441
        var ranges: [Range<Double>] = []
        var start: Int?
        for offset in stride(from: 0, to: samples.count, by: size) {
            let end = min(samples.count, offset + size)
            let square = samples[offset..<end].reduce(0.0) { $0 + Double($1) * Double($1) }
            if sqrt(square / Double(end - offset)) < 0.003 {
                if start == nil { start = offset }
            } else if let first = start {
                ranges.append(Double(first) / 44100..<Double(offset) / 44100)
                start = nil
            }
        }
        if let start { ranges.append(Double(start) / 44100..<Double(samples.count) / 44100) }
        return ranges.filter { $0.upperBound - $0.lowerBound >= 0.02 - 1e-9 }
    }

    @MainActor
    private func expectDecoded(_ candidate: URL, _ reference: URL, minimumSSIM: Double,
                               trailingFramesAllowed: Int = 0) async throws {
        let comparison = try await MultitrackRenderTests.compareDecoded(candidate, reference,
            trailingFramesAllowed: trailingFramesAllowed)
        #expect(comparison.videoTimingIdentical)
        #expect(comparison.minimumSSIM >= minimumSSIM)
    }

    @Test("Phase 7 prepared cuts and saved documents render the same pauses",
          arguments: ["minimum", "several", "slow", "fast", "source-offset", "transition"])
    func pauseAssembly(_ fixture: String) async throws {
        let temp = try await TempDatabase()
        try await checkPauseAssembly(fixture, folder: temp.directory.url, database: temp.database,
            sourceScene: Fixtures.scene(start: 0, end: 10, wide: false), profile: Fixtures.brand())
    }

    @concurrent
    private func checkPauseAssembly(_ fixture: String, folder: URL, database: Database,
                                    sourceScene: SceneRecord, profile: BrandProfile) async throws {
        let source = folder.appendingPathComponent("pause-source.mp4")
        try await pauseSource(source)
        var scene = sourceScene
        scene.videoPath = source.path
        scene.videoFilename = source.lastPathComponent
        let offset = fixture == "source-offset" ? 2.0 : 0.0
        let speed = fixture == "slow" ? 0.5 : fixture == "fast" ? 2.0 : 1.0
        let hold = fixture == "minimum" ? 0.05 : 0.8
        let contacts: [Double] = fixture == "several" ? [1, 3, 5]
            : fixture == "source-offset" ? [4, 6] : [4]
        var first = WizardPlanClip(sceneID: scene.id, start: offset, end: offset + 6)
        first.speed = speed
        var plan = WizardPlan(targetDuration: 6, rationale: "fixture", musicName: nil,
            musicVolume: 3, clips: [first], transitions: [])
        if fixture == "transition" {
            plan.clips.append(WizardPlanClip(sceneID: scene.id, start: 8, end: 9))
            plan.transitions = ["fade"]
        }
        let settings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        var options = WizardOptions(renderSettings: settings)
        options.strikeImpactFreeze = hold
        options.useBRoll = false
        options.useMusic = false
        options.includeOutro = false
        options.framing = Framing(subject: .original)
        let map = [scene.id: scene]
        let rawCuts = Dictionary(uniqueKeysWithValues: plan.clips.enumerated().map { index, clip in
            var cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: settings, framingPlan: nil)
            // Force the layered path where the 50 ms interval used to vanish.
            cut.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: (clip.end - clip.start) / clip.speed)]
            return (index, cut)
        })
        let prepared = WizardStrikePauses.prepare(plan: plan, cuts: rawCuts, sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: [source.path: contacts], options: options, xfadeDuration: 0.5)
        #expect(prepared.messages.isEmpty)
        #expect(prepared.timings[0]?.pauses.count == contacts.count)
        let document = WizardEngine.timelineDocument(from: plan, sceneMap: map, renderSettings: settings,
            framing: Framing(subject: .original), podcastCuts: prepared.cuts,
            videoTypes: [scene.videoID: .fight], pauseTimings: prepared.timings)
        // Round-trip the editable artifact, not an invented renderer duration.
        let saved = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(document))
        let engine = RenderEngine()
        let renderer = MultitrackRenderer(render: engine,
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, framingCacheEnabled: false)
        var transitions = TransitionSettings()
        transitions.xfadeDuration = 0.5
        var profile = profile
        profile.editing = ProfileEditingDefaults()
        profile.editing?.transitions = transitions
        try await RenderContext.$transitions.withValue(transitions) {
            let editable = try await renderer.render(document: saved, scenes: [scene], profile: profile,
                database: database, preview: true, emit: { _ in })
            defer { try? FileManager.default.removeItem(at: editable.url) }
            var files: [URL] = []
            defer { for file in files { try? FileManager.default.removeItem(at: file) } }
            for index in plan.clips.indices {
                let cut = try #require(prepared.cuts[index])
                let result = try await renderer.render(document: cut, scenes: [scene], profile: profile,
                    database: database, preview: true, emit: { _ in })
                files.append(result.url)
            }
            let compositor = WizardEngine.preparedDocument(from: saved, clipURLs: files, transitions: plan.transitions)
            let extracted = try await renderer.render(document: compositor, scenes: [scene], profile: profile,
                database: database, preview: true, prerenderedSources: Set(files.map(\.path)), emit: { _ in })
            defer { try? FileManager.default.removeItem(at: extracted.url) }
            let joined = folder.appendingPathComponent("joined.mp4")
            try await RenderContext.$settings.withValue(settings) {
                try await engine.concatenate(clips: files, transitions: plan.transitions.map { Optional($0) }, output: joined,
                    clipDurations: plan.clips.indices.map { prepared.timings[$0]!.outputDuration })
            }
            let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 1, note: nil, plan: plan,
                sceneIDs: [scene.id], proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
            let preview = WizardPreviewClips.rendered(saved, take: take, name: fixture, scenes: [scene], xfadeDuration: 0.5)
            #expect(saved.videoTrack.allSatisfy { $0.sceneID == nil }, "trimmed pieces serialize by file and range")
            #expect(preview.count == saved.videoTrack.count)
            // 1 s incoming cut affords 0.4 s of the requested 0.5 s join.
            let expectedDuration = 6 / speed + Double(contacts.count) * hold + (fixture == "transition" ? 0.6 : 0.0)
            #expect(abs(RoughCut.plannedDuration(of: preview) - expectedDuration) < 1e-9)
            for (route, movie) in [("editable", editable.url), ("extracted", extracted.url), ("joined", joined)] {
                // One frame of quantization is allowed, but omitting a 50 ms
                // hold fails this bound (as well as the picture/audio checks).
                let duration = await FFmpeg.duration(of: movie)
                #expect(abs(duration - expectedDuration) < 0.035, "\(fixture) / \(route): \(duration), expected \(expectedDuration)")
                let silences = try await silenceWindows(movie, folder: folder)
                for (index, contact) in contacts.enumerated() {
                    let at = (contact - offset) / speed + Double(index) * hold
                    let silence = try #require(silences.min { abs($0.lowerBound - at) < abs($1.lowerBound - at) })
                    #expect(abs(silence.lowerBound - at) < 0.08, "\(fixture) / \(route): silence \(silence), contact \(at)")
                    #expect(abs(silence.upperBound - (at + hold)) < 0.09, "\(fixture) / \(route): silence \(silence), hold \(hold)")
                    #expect(abs((silence.upperBound - silence.lowerBound) - hold) < 0.07)
                    #expect(try await rms(movie, start: at - 0.2, duration: 0.1, folder: folder) > 0.01)
                    #expect(try await rms(movie, start: at + hold + 0.12, duration: 0.1, folder: folder) > 0.01)
                    let held = try await frame(movie, at: at + min(hold / 2, 0.2), folder: folder)
                    let expected = try await frame(source, at: contact, folder: folder)
                    try await expectDecoded(held, expected, minimumSSIM: 0.97)
                    if hold > 0.1 {
                        let last = try await frame(movie, at: at + hold - 0.1, folder: folder)
                        try await expectDecoded(held, last, minimumSSIM: 0.99)
                    }
                }
            }
            // Same ffmpeg pipeline, an extra encode on extraction: use timing
            // and per-frame SSIM, plus silence/speech windows above for audio.
            for movie in [extracted.url, joined] {
                try await expectDecoded(movie, editable.url, minimumSSIM: 0.97, trailingFramesAllowed: 1)
            }
        }
    }

}
