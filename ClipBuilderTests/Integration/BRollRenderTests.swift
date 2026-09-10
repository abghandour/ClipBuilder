import Foundation
import Testing
@testable import Clip_Builder

/// What the pipeline actually produces for B-roll: the picture inside the
/// area, the dialogue underneath, and the dissolve in between. These render
/// short real files, so they only run where ffmpeg is installed.
@Suite("B-roll rendering integration", .tags(.integration), .serialized,
       .enabled(if: FixtureVideo.integrationsAvailable,
                "Install ffmpeg and ffprobe to run."))
struct BRollRenderTests {
    /// A solid-red clip, optionally with a tone of its own — visibly and
    /// audibly different from the testsrc fixture underneath it.
    private func redSource(in directory: URL, tone: Bool) async throws -> URL {
        let output = directory.appendingPathComponent("broll-\(tone ? "tone" : "silent").mp4")
        var arguments = ["-y", "-f", "lavfi", "-i", "color=c=red:size=720x1280:rate=30"]
        if tone { arguments += ["-f", "lavfi", "-i", "sine=frequency=880"] }
        arguments += ["-t", "3", "-c:v", "libx264", "-pix_fmt", "yuv420p"]
        if tone { arguments += ["-c:a", "aac", "-shortest"] }
        arguments.append(output.path)
        _ = try await FFmpeg.run(arguments, timeout: 60)
        return output
    }

    /// Mean volume in dBFS, straight from ffmpeg's volumedetect.
    private func meanVolume(of url: URL) async throws -> Double {
        let result = try await ProcessRunner.run(
            executable: try #require(ProcessRunner.locate("ffmpeg")),
            arguments: ["-v", "info", "-i", url.path, "-af", "volumedetect", "-f", "null", "-"],
            timeout: 60)
        let line = try #require(result.stderrText.split(separator: "\n")
            .first { $0.contains("mean_volume:") })
        let value = line.split(separator: "mean_volume:").last?
            .replacingOccurrences(of: "dB", with: "")
            .trimmingCharacters(in: .whitespaces) ?? ""
        return try #require(Double(value))
    }

    /// One pixel of one frame, as (red, green, blue).
    private func pixel(of url: URL, at time: Double, xFrac: Double, yFrac: Double,
                       scratch: URL) async throws -> (r: Int, g: Int, b: Int) {
        let dimensions = await FFmpeg.dimensions(of: url)
        let x = max(0, min(dimensions.width - 1, Int(Double(dimensions.width) * xFrac)))
        let y = max(0, min(dimensions.height - 1, Int(Double(dimensions.height) * yFrac)))
        let raw = scratch.appendingPathComponent("pixel-\(UUID().uuidString).rgb")
        _ = try await FFmpeg.run(["-y", "-ss", String(format: "%.3f", time), "-i", url.path,
                                  "-frames:v", "1",
                                  // Convert first: cropping a subsampled
                                  // plane and converting afterwards reads
                                  // the wrong chroma for a single pixel.
                                  "-vf", "format=rgb24,crop=1:1:\(x):\(y)",
                                  "-f", "rawvideo", raw.path], timeout: 60)
        let data = try Data(contentsOf: raw)
        try? FileManager.default.removeItem(at: raw)
        #expect(data.count >= 3)
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func document(main: URL, broll: URL?, audio: CutawayAudio = .muted,
                          fadeIn: Double = 0) -> TimelineDocument {
        var top = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3, track: 0)
        top.videoFile = main.path
        var bottom = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3, track: 1)
        bottom.videoFile = main.path
        bottom.muted = true
        var clips = [top, bottom]
        if let broll {
            var cutaway = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 3, track: 0)
            cutaway.videoFile = broll.path
            cutaway.role = .cutaway
            cutaway.cutawayAudio = audio
            cutaway.fadeIn = fadeIn
            cutaway.enforceCutawayRules()
            clips.append(cutaway)
        }
        var document = Fixtures.timelineDocument(clips: clips)
        document.trackCount = 2
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"),
                                             startTime: 0, duration: 3)]
        return document
    }

    private func render(_ document: TimelineDocument, temp: TempDatabase) async throws -> URL {
        let cache = RenderSegmentCache(directory: temp.directory.url
            .appendingPathComponent("segments-\(UUID().uuidString)"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache)
        let result = try await renderer.render(document: document, scenes: [],
                                               profile: Fixtures.brand(name: "B-roll"),
                                               database: temp.database, preview: true,
                                               emit: { _ in })
        return result.url
    }

    @Test("a muted cutaway keeps the dialogue; a mixed one adds to it")
    func audioLevels() async throws {
        let scope = try DataFolderOverride()
        defer { withExtendedLifetime(scope) {} }
        let temp = try TempDatabase()
        let main = try await FixtureVideo.make(in: temp.directory.url)
        let silent = try await redSource(in: temp.directory.url, tone: false)
        let noisy = try await redSource(in: temp.directory.url, tone: true)

        let plain = try await render(document(main: main, broll: nil), temp: temp)
        defer { try? FileManager.default.removeItem(at: plain) }
        let muted = try await render(document(main: main, broll: silent), temp: temp)
        defer { try? FileManager.default.removeItem(at: muted) }
        let mixed = try await render(document(main: main, broll: noisy, audio: .mixed), temp: temp)
        defer { try? FileManager.default.removeItem(at: mixed) }

        let plainLevel = try await meanVolume(of: plain)
        let mutedLevel = try await meanVolume(of: muted)
        let mixedLevel = try await meanVolume(of: mixed)
        #expect(abs(mutedLevel - plainLevel) < 1.0,
                "B-roll over a talking clip must not change what is heard")
        #expect(mixedLevel > mutedLevel + 0.5, "mixing the cutaway's own sound in is audible")
    }

    @Test("the cutaway fills its area and leaves the rest of the frame alone")
    func areaPixels() async throws {
        let scope = try DataFolderOverride()
        defer { withExtendedLifetime(scope) {} }
        let temp = try TempDatabase()
        let main = try await FixtureVideo.make(in: temp.directory.url)
        let broll = try await redSource(in: temp.directory.url, tone: false)
        let output = try await render(document(main: main, broll: broll), temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }

        let inside = try await pixel(of: output, at: 1.5, xFrac: 0.5, yFrac: 0.25,
                                     scratch: temp.directory.url)
        let outside = try await pixel(of: output, at: 1.5, xFrac: 0.5, yFrac: 0.75,
                                      scratch: temp.directory.url)
        #expect(inside.r > 120 && inside.g < 90 && inside.b < 90,
                "track 1's area shows the B-roll")
        #expect(!(outside.r > 120 && outside.g < 90 && outside.b < 90),
                "track 2's area still shows its own clip")
    }

    @Test("a dissolving cutaway is part way in halfway through the fade")
    func dissolveFrames() async throws {
        let scope = try DataFolderOverride()
        defer { withExtendedLifetime(scope) {} }
        let temp = try TempDatabase()
        let main = try await FixtureVideo.make(in: temp.directory.url)
        let broll = try await redSource(in: temp.directory.url, tone: false)
        let output = try await render(document(main: main, broll: broll, fadeIn: 1.4), temp: temp)
        defer { try? FileManager.default.removeItem(at: output) }

        let start = try await pixel(of: output, at: 0.05, xFrac: 0.5, yFrac: 0.25,
                                    scratch: temp.directory.url)
        let middle = try await pixel(of: output, at: 0.7, xFrac: 0.5, yFrac: 0.25,
                                     scratch: temp.directory.url)
        let end = try await pixel(of: output, at: 2.5, xFrac: 0.5, yFrac: 0.25,
                                  scratch: temp.directory.url)
        #expect(end.r > 120 && end.g < 90, "the dissolve finishes on the B-roll")
        #expect(middle.r != start.r || middle.g != start.g || middle.b != start.b,
                "halfway through the fade is not the frame it started on")
        #expect(middle.r != end.r || middle.g != end.g || middle.b != end.b,
                "nor the frame it ends on")
    }
}
