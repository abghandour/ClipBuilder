import Foundation
import Testing
@testable import Clip_Builder

/// Cost of validating every cached exact-preview slice after one edit: the
/// work `pruneBuilderPreviewCache` does on the main actor per document
/// revision. Prints the measurement; the bound only guards against a
/// regression of an order of magnitude.
struct PreviewKeyCostTests {
    static func fixture(clipCount: Int) -> (TimelineDocument, [SceneRecord]) {
        var scenes: [SceneRecord] = []
        var clips: [TimelineClip] = []
        let width = (9.0 / 16) * 1080 / 1920
        let path = SceneCameraPath(camera: "balanced", keyframes: (0..<7).map {
            CameraPathKeyframe(t: Double($0) * 0.3, x: 0.2 + Double($0) * 0.02, y: 0, w: width, h: 1)
        })
        let json = String(decoding: try! JSONEncoder().encode(path), as: UTF8.self)
        for index in 0..<clipCount {
            var scene = Fixtures.scene(id: Int64(index + 1), start: Double(index * 2), end: Double(index * 2 + 2))
            scene.centerStagePathJSON = json
            scenes.append(scene)
            var clip = Fixtures.timelineClip(sceneID: scene.id, sourceStart: scene.startTime, duration: 2,
                                             startTime: Double(index * 2))
            clip.wide = true
            clip.centerStage = index % 4 == 0
            clip.captions = "bottom"
            clip.transIn = index % 10 == 0 ? "fade" : nil
            clips.append(clip)
        }
        var document = Fixtures.timelineDocument(clips: clips)
        document.textOverlays = [TextOverlayItem(text: "Performance baseline", startTime: 0, endTime: 80)]
        var block = OverlayBlockItem()
        block.duration = 80
        block.composition.texts = [TextOverlayItem(text: "Overlay block", startTime: 0, endTime: 80)]
        document.overlayBlocks = [block]
        return (document, scenes)
    }

    private static func pruneMilliseconds(clipCount: Int) -> (median: Double, minimum: Double, maximum: Double) {
        let (document, scenes) = fixture(clipCount: clipCount)
        let profile = Fixtures.brand()
        let total = Double(clipCount * 2)
        let windows = (0..<12).map { AppStore.exactPreviewRange(from: Double($0) * total / 12, seconds: 5, totalDuration: total) }
        var samples: [Double] = []
        for _ in 0..<30 {
            let elapsed = ContinuousClock().measure {
                for window in windows {
                    _ = AppStore.builderPreviewKey(document: document, scenes: scenes, profile: profile,
                                                   camera: "balanced", window: window)
                }
            }
            samples.append((Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * 1000)
        }
        samples.sort()
        return (samples[samples.count / 2], samples[0], samples[samples.count - 1])
    }

    @Test("validating twelve cached slices after an edit stays far below one display frame")
    func pruneCost() {
        var lines: [String] = []
        for clipCount in [40, 200] {
            let cost = Self.pruneMilliseconds(clipCount: clipCount)
            lines.append(String(format: "PREVIEW_KEY_COST slices=12 clips=%d median=%.2f ms min=%.2f ms max=%.2f ms",
                                clipCount, cost.median, cost.minimum, cost.maximum))
            // 50 ms is over twenty times the measured Debug cost; only an order-of-magnitude regression trips it.
            #expect(cost.median < 50, Comment(rawValue: lines.last!))
        }
        // The test host's stdout is not surfaced by xcodebuild; leave the measurement where a reader can find it.
        try? lines.joined(separator: "\n").write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("PreviewKeyCost.txt"),
            atomically: true, encoding: .utf8)
    }
}
