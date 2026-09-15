import Foundation
import Testing
@testable import Clip_Builder

@Suite("Framing cache identity")
struct FramingCacheKeyTests {
    @Test("framing identity covers media, trim, path, geometry and render settings")
    func invalidation() throws {
        let temp = try TempDirectory()
        defer { withExtendedLifetime(temp) {} }
        let source = temp.url.appendingPathComponent("source.mp4")
        try Data(repeating: 1, count: 1024).write(to: source)
        var item = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 3)
        item.videoFile = source.path
        let clip = try #require(MultitrackRenderer.resolveClips(document: Fixtures.timelineDocument(clips: [item]), scenes: []).first)
        let settings = RenderSettings()
        func key(_ clip: MultitrackRenderer.ResolvedClip) throws -> String {
            try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "balanced", settings: settings, encoder: ["encoder"])
        }
        let original = try key(clip)
        for mutate: (inout MultitrackRenderer.ResolvedClip) -> Void in [
            { $0.sourceStart += 0.5 }, { $0.duration += 1 }, { $0.speed = 0.5 },
            { $0.cameraPath = [CameraPathKeyframe(t: 0, x: 0.3, y: 0, w: 0.3, h: 1)] },
            { $0.framingIdentity = "changed-upstream-framing" },
        ] {
            var changed = clip
            mutate(&changed)
            #expect(try key(changed) != original)
        }
        let area = try #require(ScreenCropStore.area(reference: CropLayoutRef(name: "50-50 Horizontal").reference(forTrack: 0)))
        #expect(try MultitrackRenderer.prepassKey(clip, area: area, tuning: "balanced", settings: settings, encoder: ["encoder"]) != original)
        #expect(try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "fastAction", settings: settings, encoder: ["encoder"]) != original)
        #expect(try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "balanced", settings: RenderSettings(preset: .square1080), encoder: ["encoder"]) != original)
        #expect(try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "balanced", settings: settings, encoder: ["different-encoder"]) != original)
        #expect(try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "balanced", settings: settings, encoder: ["encoder"], version: "future-framing") != original)
        var placed = clip
        placed.startTime += 10
        placed.track = 2
        placed.captionsPosition = "top"
        placed.transcriptSourceStart = 20
        #expect(try key(placed) == original)
        var chained = clip
        chained.framingIdentity = "upstream-key"
        let chainedKey = try key(chained)
        chained.sourcePath = "/new-scratch-path.mp4"
        #expect(try key(chained) == chainedKey)
        try Data(repeating: 2, count: 2048).write(to: source)
        #expect(try key(clip) != original)
    }
}
