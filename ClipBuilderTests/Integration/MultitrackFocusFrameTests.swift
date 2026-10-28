import Foundation
import Testing
@testable import Clip_Builder

extension MultitrackRenderTests {
    @Test("original focus frame renders the selected source at normal and retimed source clocks", arguments: [false, true])
    func originalFocusFrameContainment(_ retimed: Bool) async throws {
        let temp = try await TempDatabase()
        let source = temp.directory.url.appendingPathComponent("focus-source.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "testsrc2=size=960x540:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "4",
            "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        let start = retimed ? 1.0 : 0
        let speed = retimed ? 1.5 : 1
        let duration = retimed ? 2.0 : 4
        let settings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        let plan = FramingPlan.static(window: FreeCropRect(xFrac: 0.5, wFrac: 0.5), fit: .fill, feather: 0.08, blur: 0.5)
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: start, duration: duration, speed: speed)
        clip.videoFile = source.path; clip.wide = true; clip.captions = "none"
        clip.framingPlan = plan
        var document = Fixtures.timelineDocument(clips: [clip])
        document.renderSettings = settings
        let output = try await MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache")),
            framingCacheEnabled: false).render(document: document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: output.url) }
        let expected = temp.directory.url.appendingPathComponent("direct-crop.mp4")
        try await RenderContext.$settings.withValue(settings) {
            // Exact free-crop semantics: retain the entire right half and map it
            // onto the destination; no second aspect crop or area prepass.
            try await FFmpeg.run(["-y", "-ss", String(start), "-i", source.path,
                "-vf", "setpts=(PTS-STARTPTS)/\(speed),fps=30,crop=iw*0.5:ih:iw*0.5:0,scale=360:640,setsar=1",
                "-af", "atempo=\(speed)", "-t", String(duration)] + FFmpeg.encodeArgs + [expected.path], timeout: 60)
        }
        let comparison = try await Self.compareDecoded(output.url, expected, trailingFramesAllowed: 1)
        #expect(comparison.videoTimingIdentical)
        #expect(comparison.frameSSIM.count >= Int(duration * 30) - 1)
        #expect(comparison.minimumSSIM >= 0.98)
        let resolved = try #require(MultitrackRenderer.resolveClips(document: document, scenes: []).first)
        #expect(resolved.freeCrops?.first?.src == plan.sourceWindow)
        #expect(resolved.areaWindow == nil && resolved.cameraPath == nil)
    }
}
