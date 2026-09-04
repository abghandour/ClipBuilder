import Foundation
import Testing
@testable import Clip_Builder

@Suite("Render engine integration", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable,
                "Install ffmpeg and ffprobe to run."))
struct RenderEngineTests {
    @Test("extracts a playable speed-adjusted portrait clip")
    func extractClip() async throws {
        let temp = try TempDirectory(prefix: "ClipBuilderRenderTest")
        let source = try await FixtureVideo.make(in: temp.url, wide: true)
        let output = temp.url.appendingPathComponent("output.mp4")
        let render = RenderEngine()
        try await render.extractClip(source: source, start: 0, duration: 2,
                                     wide: .autoCrop(0.5), speed: 0.5, output: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let duration = await FFmpeg.duration(of: output)
        #expect(abs(duration - 2) < 0.15)
        let dimensions = await FFmpeg.dimensions(of: output)
        #expect(dimensions.width == RenderEngine.outputWidth)
        #expect(dimensions.height == RenderEngine.outputHeight)
        #expect(await FFmpeg.hasAudioStream(output))
    }

    @Test("subclip and normalize produce standard-format output of the requested length")
    func subclipAndNormalize() async throws {
        let temp = try TempDirectory(prefix: "ClipBuilderRenderTest")
        let source = try await FixtureVideo.make(in: temp.url, wide: false, silent: true)
        let render = RenderEngine()

        let subclip = temp.url.appendingPathComponent("subclip.mp4")
        try await render.extractSubclip(source: source, start: 1, duration: 1.5, output: subclip)
        #expect(abs((await FFmpeg.duration(of: subclip)) - 1.5) < 0.15)
        let subclipSize = await FFmpeg.dimensions(of: subclip)
        #expect(subclipSize.width == RenderEngine.outputWidth)
        #expect(subclipSize.height == RenderEngine.outputHeight)

        // An intro/outro of arbitrary size comes out at the standard size
        // and its full length.
        let normalized = temp.url.appendingPathComponent("normalized.mp4")
        try await render.normalizeClip(source: source, output: normalized)
        #expect(abs((await FFmpeg.duration(of: normalized)) - 3) < 0.15)
        let normalizedSize = await FFmpeg.dimensions(of: normalized)
        #expect(normalizedSize.width == RenderEngine.outputWidth)
        #expect(normalizedSize.height == RenderEngine.outputHeight)
    }

    @Test("concatenation with every transition keeps the summed length minus the overlap it consumes")
    func concatenateWithEveryTransition() async throws {
        // Crossfade length comes from the (overridden, default) settings.
        let scope = try DataFolderOverride()
        _ = scope
        let xfadeDuration = TransitionSettings().xfadeDuration
        let temp = try TempDirectory(prefix: "ClipBuilderRenderTest")
        let source = try await FixtureVideo.make(in: temp.url, wide: false)
        let render = RenderEngine()
        let first = temp.url.appendingPathComponent("first.mp4")
        let second = temp.url.appendingPathComponent("second.mp4")
        try await render.extractSubclip(source: source, start: 0, duration: 2, output: first)
        try await render.extractSubclip(source: source, start: 1, duration: 2, output: second)

        let names: [String?] = [nil, "cut"] + RenderEngine.allTransitions
        for name in names {
            let output = temp.url.appendingPathComponent("joined-\(name ?? "nil").mp4")
            try await render.concatenate(clips: [first, second], transitions: [name], output: output)
            let expected = 4 - RenderEngine.consumedOverlap(name, xfadeDuration: xfadeDuration)
            let duration = await FFmpeg.duration(of: output)
            #expect(abs(duration - expected) < 0.2,
                    "transition \(name ?? "nil"): got \(duration), expected \(expected)")
            #expect(await FFmpeg.hasAudioStream(output), "transition \(name ?? "nil") lost the audio")
        }
    }

    @Test("music overlays onto silent and voiced clips")
    func overlayMusic() async throws {
        let temp = try TempDirectory(prefix: "ClipBuilderRenderTest")
        let music = try await FixtureVideo.makeMusic(in: temp.url, seconds: 6)
        let render = RenderEngine()
        for silent in [true, false] {
            let source = try await FixtureVideo.make(in: temp.url, wide: false, silent: silent)
            let output = temp.url.appendingPathComponent("music-\(silent ? "silent" : "voiced").mp4")
            try await render.overlayMusic(video: source, music: music, output: output)
            #expect(await FFmpeg.hasAudioStream(output))
            // Music never extends the picture.
            #expect(abs((await FFmpeg.duration(of: output)) - 3) < 0.2)
        }
    }

    @Test("content box detection finds the picture inside letterbox bars")
    func detectContentBox() async throws {
        let temp = try TempDirectory(prefix: "ClipBuilderRenderTest")
        let letterboxed = try await FixtureVideo.makeLetterboxed(in: temp.url)
        let render = RenderEngine()
        let box = try #require(await render.detectContentBox(source: letterboxed, start: 0, duration: 3))
        // The picture is the middle 50% of the frame height: bars above and below.
        #expect(box.y > 0.15 && box.y < 0.35, "box.y = \(box.y)")
        #expect(box.h > 0.4 && box.h < 0.6, "box.h = \(box.h)")
        #expect(box.x < 0.05, "box.x = \(box.x)")
        #expect(box.w > 0.95, "box.w = \(box.w)")
    }
}
