import Foundation
import Testing
@testable import Clip_Builder

struct VideoDetectorsTests {
    @Test func cacheInvalidation() async throws {
        let temp = try TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("INSERT INTO videos (id, hash, filename, path) VALUES (1, 'detectors', 'fixture.mp4', '/tmp/fixture.mp4')")
        let database = try Database(path: temp.path)
        let signals = VideoDetectors(black: [0...2], frozen: [18...20], cuts: [3, 8])
        try await database.cacheDetectors(signals, videoID: 1, fingerprint: "1:100:1")
        #expect(try await database.cachedDetectors(videoID: 1, fingerprint: "1:100:1")?.black == [0...2])
        #expect(try await database.cachedDetectors(videoID: 1, fingerprint: "1:101:1") == nil)
        #expect(try await database.cachedDetectors(videoID: 1, fingerprint: "1:100:2") == nil)
    }
    @Test(.enabled(if: FixtureVideo.integrationsAvailable))
    func paddedFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try await FixtureVideo.make(in: root)
        let output = root.appendingPathComponent("padded.mp4")
        try await FFmpeg.run(["-y", "-stream_loop", "2", "-i", input.path, "-vf",
            "tpad=start_duration=2:stop_duration=2:color=black", "-an", "-c:v", "libx264", output.path], timeout: 120)
        let duration = await FFmpeg.duration(of: output)
        let signals = try await FFmpeg.detectors(of: output, duration: duration)
        let window = try #require(signals.contentWindow(duration: duration))
        #expect(abs(window.lowerBound - 2) < 0.2)
        #expect(abs(window.upperBound - (duration - 2)) < 0.2)
        // Hardware and software passes report the same events.
        let software = try await FFmpeg.detectorSignals(of: output, duration: duration, timeout: 120, hardware: false)
        #expect(signals.black == software.black && signals.frozen == software.frozen)
        #expect(signals.cuts == (try await FFmpeg.sceneChangeTimestamps(of: output, hardware: false)))
        #expect(signals.cuts.contains { abs($0 - 2) < 0.2 })
    }

    @Test func parsersIgnoreEachOthersLines() {
        let stderr = """
        [blackdetect @ 0x1] black_start:0 black_end:2 black_duration:2
        [Parsed_showinfo_3 @ 0x2] n:   0 pts:   60 pts_time:2.0 duration: 20 fmt:yuv420p
        [freezedetect @ 0x3] lavfi.freezedetect.freeze_start: 7.5
        frame=  100 fps=0.0 q=-0.0 size=N/A time=00:00:03.33 [Parsed_showinfo_3 @ 0x2] n:   1 pts:  300 pts_time:10.004 duration: 20
        [freezedetect @ 0x3] lavfi.freezedetect.freeze_end: 10
        [blackdetect @ 0x1] black_start:11 black_end:12.5 black_duration:1.5
        """
        let signals = VideoDetectors.parse(stderr, duration: 12.5)
        #expect(signals.black == [0...2, 11...12.5])
        #expect(signals.frozen == [7.5...10])
        #expect(FFmpeg.sceneChangeTimestamps(parsing: stderr) == [2, 10])
        #expect(FFmpeg.decodeArguments(hardware: false).isEmpty)
        #expect(FFmpeg.decodeArguments(hardware: true) == (FFmpeg.hasVideoToolboxDecode ? ["-hwaccel", "videotoolbox"] : []))
        #expect(FFmpeg.detectorTimeout(duration: 10) == 300)
        #expect(FFmpeg.detectorTimeout(duration: 3600) == 3600)
    }
    @Test func parsing() {
        let result = VideoDetectors.parse("black_start:0 black_end:2 black_duration:2\nlavfi.freezedetect.freeze_start: 18\nlavfi.freezedetect.freeze_end: 20", duration: 20)
        #expect(result.black == [0...2])
        #expect(result.frozen == [18...20])
        #expect(result.contentWindow(duration: 20) == 2...18)
        #expect(VideoDetectors().contentWindow(duration: 20) == 0...20)
        #expect(VideoDetectors(black: [0...19]).contentWindow(duration: 20) == nil)
        #expect(VideoDetectors.decimatedGaps("pts_time:0\npts_time:3\npts_time:3.1", duration: 6) == [0...3, 3.1...6])
    }
}

extension VideoDetectorsTests {
    @Test func parseEdges() {
        // An unterminated run reaches the end; an `=` separator and stray text are fine.
        let open = VideoDetectors.parse("[blackdetect] black_start=17.5 something\n", duration: 20)
        #expect(open.black == [17.5...20])
        // Starts past the end and ends before their start are dropped.
        #expect(VideoDetectors.parse("black_start:25 black_end:26", duration: 20).black.isEmpty)
        #expect(VideoDetectors.parse("black_start:5 black_end:4", duration: 20).black.isEmpty)
        // Ends are clamped to the duration.
        #expect(VideoDetectors.parse("freeze_start: 18 freeze_end: 40", duration: 20).frozen == [18...20])
        let empty = VideoDetectors.parse("", duration: 20)
        #expect(empty.black.isEmpty && empty.frozen.isEmpty)
    }
    @Test func contentWindowRules() {
        // Interior black is not a trim.
        #expect(VideoDetectors(black: [8...10]).contentWindow(duration: 20) == 0...20)
        // Leading black plus trailing freeze both come off.
        #expect(VideoDetectors(black: [0...2], frozen: [17...20]).contentWindow(duration: 20) == 2...17)
        // Under three seconds of trim is not confident: the model decides.
        #expect(VideoDetectors(black: [0...2]).contentWindow(duration: 20) == nil)
        // Chained ranges at the head accumulate.
        #expect(VideoDetectors(black: [0...2], frozen: [2.1...4]).contentWindow(duration: 20) == 4...20)
        #expect(VideoDetectors().contentWindow(duration: 0) == nil)
        #expect(VideoDetectors().contentWindow(duration: .nan) == nil)
    }
}
