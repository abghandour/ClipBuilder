import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Area framer fallback")
struct AreaFramerTests {
    @Test("long camera paths stay below ffmpeg's expression recursion limit",
          .enabled(if: FixtureVideo.integrationsAvailable))
    func longPathExpressions() async throws {
        let settings = RenderSettings(preset: .custom, customWidth: 180, customHeight: 320)
        try await RenderContext.$settings.withValue(settings) {
            let area = ScreenCropArea(name: "Full Screen", points: [
                .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
            let keys = (0..<250).map { index in
                CameraPathKeyframe(t: Double(index) * 0.3, x: 0.1 + Double(index) * 0.0001,
                    y: 0.1, w: 0.3 + Double(index) * 0.0001, h: 0.8 + Double(index) * 0.0001)
            }
            let filter = AreaFramer.pathFilter(keyframes: keys, source: CGSize(width: 320, height: 240), area: area)
            try await FFmpeg.run(["-v", "error", "-f", "lavfi", "-i", "testsrc2=s=320x240:d=0.1:r=30",
                "-vf", filter, "-f", "null", "-"], timeout: 60, mediaResource: .decoding)
        }
    }

    @Test("path crop interpolates pan and zoom at the midpoint against the export reference",
          .enabled(if: FixtureVideo.integrationsAvailable))
    func pathFilterInterpolates() async throws {
        let temp = try TempDirectory(prefix: "AreaPath")
        let source = try await FixtureVideo.make(in: temp.url, wide: true)
        let settings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        try await RenderContext.$settings.withValue(settings) {
            let area = ScreenCropArea(name: "Full Screen", points: [
                .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
            let path = [CameraPathKeyframe(t: 0, x: 0.1, y: 0, w: 0.31640625, h: 1),
                        CameraPathKeyframe(t: 2, x: 0.2, y: 0.01, w: 0.310078125, h: 0.98)]
            let fragment = AreaFramer.pathFilter(keyframes: path, source: CGSize(width: 1920, height: 1080), area: area)
            #expect(fragment.contains("sendcmd="))
            #expect(!fragment.contains("pad="))
            let candidate = temp.url.appendingPathComponent("path.mp4")
            try await FFmpeg.run(["-y", "-i", source.path, "-vf", fragment, "-t", "2"]
                + FFmpeg.encodeArgs + [candidate.path], timeout: 60)
            func midpointSSIM(against reference: URL, name: String) async throws -> Double {
                let stats = temp.url.appendingPathComponent("\(name).log")
                try await FFmpeg.run(["-v", "error", "-i", candidate.path, "-i", reference.path,
                    "-lavfi", "[0:v]trim=start_frame=30:end_frame=31,setpts=PTS-STARTPTS[a];[1:v]trim=start_frame=30:end_frame=31,setpts=PTS-STARTPTS[b];[a][b]ssim=stats_file=\(stats.path)",
                    "-an", "-f", "null", "-"], timeout: 60, mediaResource: .decoding)
                let text = try String(contentsOf: stats, encoding: .utf8)
                let suffix = try #require(text.range(of: "All:")).upperBound
                return try #require(Double(text[suffix...].prefix { "0123456789.".contains($0) }))
            }
            // Exact check: at t = 1 the path is halfway between the keyframes
            // (x 0.15, y 0.005, w 0.313242, h 0.99; w/h rounded down to even
            // pixels like the filter does). Same scaler, so the only
            // difference left is the interpolation itself.
            let exact = temp.url.appendingPathComponent("exact.mp4")
            try await FFmpeg.run(["-y", "-i", source.path, "-vf",
                "crop=600:1068:288:5.4,scale=360:640,setsar=1,fps=30,format=yuv420p", "-t", "2"]
                + FFmpeg.encodeArgs + [exact.path], timeout: 60)
            #expect(try await midpointSSIM(against: exact, name: "exact") >= 0.99)
            let actualDuration = await FFmpeg.duration(of: candidate)
            #expect(abs(actualDuration - (await FFmpeg.duration(of: exact))) < 0.05)
            #expect(try await MultitrackRenderTests.audioMatches(candidate, exact))
            // Renderer agreement: the AVFoundation export of the same path
            // scales with a different filter, so the sharp-edged test pattern
            // lands near 0.97; the bound only catches a wrong crop window.
            let reference = try await CenterStageService().reframeClip(source: source, start: 0, duration: 2,
                path: path, frame: CGSize(width: 360, height: 640))
            defer { try? FileManager.default.removeItem(at: reference) }
            #expect(try await midpointSSIM(against: reference, name: "export") >= 0.95)
            #expect(abs(actualDuration - (await FFmpeg.duration(of: reference))) < 0.05)
        }
    }

    @Test("equal-time camera keys jump to the new crop, including its zoom",
          .enabled(if: FixtureVideo.integrationsAvailable))
    func pathFilterKeepsEqualTimeJump() async throws {
        let temp = try TempDirectory(prefix: "AreaJump")
        let source = try await FixtureVideo.make(in: temp.url, wide: true)
        let settings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        try await RenderContext.$settings.withValue(settings) {
            let area = ScreenCropArea(name: "Full Screen", points: [
                .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
            let path = [CameraPathKeyframe(t: 0, x: 0.1, y: 0, w: 0.31640625, h: 1),
                        CameraPathKeyframe(t: 0, x: 0.25, y: 0.1, w: 0.253125, h: 0.8),
                        CameraPathKeyframe(t: 5, x: 0.25, y: 0.1, w: 0.253125, h: 0.8)]
            // Deliberately different metadata: all crop axes must use the
            // decoded stream's dimensions, not the AVFoundation size.
            let filter = AreaFramer.pathFilter(keyframes: path, source: CGSize(width: 1280, height: 720), area: area)
            let candidate = temp.url.appendingPathComponent("jump.mp4")
            let reference = temp.url.appendingPathComponent("static.mp4")
            try await FFmpeg.run(["-y", "-i", source.path, "-vf", filter, "-t", "2"]
                + FFmpeg.encodeArgs + [candidate.path], timeout: 60)
            try await FFmpeg.run(["-y", "-i", source.path, "-vf",
                "crop=486:864:480:108,scale=360:640,setsar=1,fps=30,format=yuv420p", "-t", "2"]
                + FFmpeg.encodeArgs + [reference.path], timeout: 60)
            let stats = temp.url.appendingPathComponent("jump-ssim.log")
            try await FFmpeg.run(["-v", "error", "-i", candidate.path, "-i", reference.path,
                "-lavfi", "[0:v]trim=start_frame=30:end_frame=31,setpts=PTS-STARTPTS[a];[1:v]trim=start_frame=30:end_frame=31,setpts=PTS-STARTPTS[b];[a][b]ssim=stats_file=\(stats.path)",
                "-an", "-f", "null", "-"], timeout: 60, mediaResource: .decoding)
            let text = try String(contentsOf: stats, encoding: .utf8)
            let suffix = try #require(text.range(of: "All:")).upperBound
            let score = try #require(Double(text[suffix...].prefix { "0123456789.".contains($0) }))
            #expect(score >= 0.99)
        }
    }

    @Test("a portrait fallback in a landscape feed centers on the known face")
    func knownFace() {
        let window = AreaFramer.fallbackWindow(aspect: 9.0 / 16.0,
            sourceSize: CGSize(width: 1920, height: 1080), center: (x: 0.37, y: 0.4))
        #expect(window.xFrac >= 0)
        #expect(window.xFrac <= 0.37 && window.xFrac + window.wFrac >= 0.37)
        #expect(abs(window.xFrac + window.wFrac / 2 - 0.37) < 1e-9)
        #expect(abs(window.wFrac - 81.0 / 256.0) < 1e-9)
        #expect(window.yFrac == 0 && window.hFrac == 1)
    }

    @Test("faces near either horizontal edge keep the window inside the feed", arguments: [0.01, 0.99])
    func edgeFace(x: Double) {
        let window = AreaFramer.fallbackWindow(aspect: 9.0 / 16.0,
            sourceSize: CGSize(width: 1920, height: 1080), center: (x: x, y: 0.5))
        #expect(window.xFrac >= 0 && window.xFrac + window.wFrac <= 1)
        #expect(window.xFrac <= x && window.xFrac + window.wFrac >= x)
        let expectedLeft = x < 0.5 ? 0 : 1 - window.wFrac
        #expect(abs(window.xFrac - expectedLeft) < 1e-9)
    }

    @Test("a wide fallback also clamps vertically", arguments: [0.01, 0.99])
    func verticalEdgeFace(y: Double) {
        let window = AreaFramer.fallbackWindow(aspect: 16.0 / 9.0,
            sourceSize: CGSize(width: 1080, height: 1920), center: (x: 0.5, y: y))
        #expect(window.xFrac == 0 && window.wFrac == 1)
        #expect(window.yFrac >= 0 && window.yFrac + window.hFrac <= 1)
        #expect(window.yFrac <= y && window.yFrac + window.hFrac >= y)
        let expectedTop = y < 0.5 ? 0 : 1 - window.hFrac
        #expect(abs(window.yFrac - expectedTop) < 1e-9)
    }

    @Test("without a face the fallback matches the original centered window")
    func unknownFace() {
        let window = AreaFramer.fallbackWindow(aspect: 9.0 / 16.0,
            sourceSize: CGSize(width: 1920, height: 1080), center: nil)
        let width = (9.0 / 16.0) / (1920.0 / 1080.0)
        #expect(window == FreeCropRect(xFrac: (1 - width) / 2, yFrac: 0, wFrac: width, hFrac: 1))
    }
}
