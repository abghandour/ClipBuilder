import Foundation
import Testing
import Synchronization
@testable import Clip_Builder

@Suite("Render engine integration", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable,
                "Install ffmpeg and ffprobe to run."))
struct RenderEngineTests {
    @Test("hardware intermediate passes match software; final audio still encodes", arguments: ["extract", "areas"])
    func intermediateExtractParity(pass: String) async throws {
        guard FFmpeg.hasVideoToolboxDecode else { return }
        let temp = try TempDirectory(prefix: "IntermediateExtract")
        let fixture = try await FixtureVideo.make(in: temp.url)
        let render = RenderEngine()
        let source = temp.url.appendingPathComponent("normalized.mp4")
        try await render.extractClip(source: fixture, start: 0, duration: 1, output: source)
        let mask = temp.url.appendingPathComponent("mask.png")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=white:s=1080x1920",
            "-frames:v", "1", mask.path], timeout: 60)
        var outputs: [URL] = []
        for hardware in [false, true] {
            let output = temp.url.appendingPathComponent("hardware-\(hardware).mp4")
            let commands = Mutex<[[String]]>([])
            let messages = Mutex<[String]>([])
            try await ExpressRenderTesting.$hardwareDecodeIntermediates.withValue(hardware) {
                try await FFmpeg.$renderLog.withValue({ line in messages.withLock { $0.append(line) } }) {
                    try await FFmpeg.$commandCompleted.withValue({ args in commands.withLock { $0.append(args) } }) {
                        if pass == "areas" {
                            try await render.compositeAreas([(clip: source, mask: mask)], duration: 1, output: output)
                        } else {
                            try await render.extractClip(source: source, start: 0, duration: 1,
                                effect: EffectSpec(preset: "faded"), intermediateSource: true, output: output)
                        }
                    }
                }
            }
            outputs.append(output)
            let command = try #require(commands.withLock { $0.last })
            #expect(command.contains("-hwaccel") == hardware)
            let audio = try #require(command.firstIndex(of: "-c:a"))
            #expect(command[audio + 1] == "aac")
            #expect(messages.withLock { $0.contains("Decode: hardware (intermediate)") } == hardware)
        }
        let comparison = try await MultitrackRenderTests.compareDecoded(outputs[1], outputs[0])
        #expect(comparison.videoTimingIdentical)
        #expect(comparison.minimumSSIM >= 0.99)
        #expect(try await MultitrackRenderTests.audioMatches(outputs[1], outputs[0]))
    }

    @Test("stream-copy finishing is logged only after an actual concat")
    func concatStreamCopyLogging() async throws {
        let temp = try TempDirectory(prefix: "ConcatLogging")
        let source = try await FixtureVideo.make(in: temp.url)
        let render = RenderEngine()
        for count in [1, 2] {
            let commands = Mutex<[[String]]>([])
            let messages = Mutex<[String]>([])
            try await FFmpeg.$renderLog.withValue({ line in messages.withLock { $0.append(line) } }) {
                try await FFmpeg.$commandCompleted.withValue({ args in commands.withLock { $0.append(args) } }) {
                    try await render.concatenate(clips: Array(repeating: source, count: count), transitions: [],
                        output: temp.url.appendingPathComponent("join-\(count).mp4"))
                }
            }
            #expect(messages.withLock { $0.filter { $0 == "Finishing: stream copy" }.count } == count - 1)
            let concats = commands.withLock { $0.filter { $0.contains("concat") } }
            #expect(concats.count == count - 1)
            #expect(concats.allSatisfy { args in
                guard let index = args.firstIndex(of: "-c:v") else { return false }
                return args[safe: index + 1] == "copy"
            })
        }
    }

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

    @Test("a look grades the extracted clip, at full and partial intensity")
    func extractClipWithLook() async throws {
        let temp = try TempDirectory(prefix: "ClipBuilderRenderTest")
        let source = try await FixtureVideo.make(in: temp.url, wide: false)
        let render = RenderEngine()
        for (name, spec) in [("full", EffectSpec(preset: "bw")), ("half", EffectSpec(preset: "bw", intensity: 0.5))] {
            let output = temp.url.appendingPathComponent("look-\(name).mp4")
            try await render.extractClip(source: source, start: 0, duration: 2, effect: spec, output: output)
            #expect(abs((await FFmpeg.duration(of: output)) - 2) < 0.15)
            let dimensions = await FFmpeg.dimensions(of: output)
            #expect(dimensions.width == RenderEngine.outputWidth && dimensions.height == RenderEngine.outputHeight)
            #expect(await FFmpeg.hasAudioStream(output))
        }
        // Black & white at full strength leaves no colour: every channel of a
        // middle frame agrees. testsrc is strongly coloured, so this is a real check.
        let frame = temp.url.appendingPathComponent("look-frame.ppm")
        _ = try await FFmpeg.run(["-y", "-ss", "1", "-i", temp.url.appendingPathComponent("look-full.mp4").path,
                                  "-frames:v", "1", "-vf", "scale=8:8", "-pix_fmt", "rgb24", frame.path], timeout: 60)
        let data = try Data(contentsOf: frame)
        let pixels = Array(data.suffix(8 * 8 * 3))
        let spread = stride(from: 0, to: pixels.count, by: 3).map { i in
            Int(max(pixels[i], pixels[i + 1], pixels[i + 2])) - Int(min(pixels[i], pixels[i + 1], pixels[i + 2]))
        }.max() ?? 255
        #expect(spread <= 8)
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
        // Match the settings used by concatenate in the scratch test host.
        let xfadeDuration = SettingsStore.loadSettings().transitions.xfadeDuration
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
