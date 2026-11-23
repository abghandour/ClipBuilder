import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("A stay preserves the framing input", .enabled(if: FixtureVideo.integrationsAvailable))
struct TelestrationTrackingSourceTests {
    private nonisolated struct Input: Sendable {
        var source: URL
        var start: Double
        var duration: Double
    }

    private var strike: StrikeHighlightRules.Track {
        let highlight = StrikeHighlightRules.Highlight(
            limb: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.35, y: 0.2), CGPoint(x: 0.5, y: 0.2)],
            target: CGPoint(x: 0.7, y: 0.2), radius: 0.06, cost: 0.1,
            limbSide: .left, usesArm: true, attackerOnLeft: true)
        return .init(keyframes: [.init(time: 1.0, highlight: highlight), .init(time: 1.8, highlight: highlight)],
            contact: 1.4, aspect: 16.0 / 9)
    }

    /// Compare the lower picture, away from both the drawing and highlight.
    /// Hardware encodes are compared as decoded pixels, never file bytes.
    @concurrent
    private func pictureSSIM(_ baseline: URL, _ stayed: URL, folder: URL) async throws -> Double {
        let stats = folder.appendingPathComponent(UUID().uuidString + ".ssim")
        let sample = "trim=start_frame=12:end_frame=13,setpts=PTS-STARTPTS,crop=iw:ih*0.3:0:ih*0.6"
        try await FFmpeg.run(["-v", "error", "-i", baseline.path, "-i", stayed.path,
            "-lavfi", "[0:v]\(sample)[a];[1:v]\(sample)[b];[a][b]ssim=stats_file=\(stats.path)",
            "-an", "-f", "null", "-"], timeout: 60, mediaResource: .decoding)
        let text = try String(contentsOf: stats, encoding: .utf8)
        let suffix = try #require(text.range(of: "All:")).upperBound
        return try #require(Double(text[suffix...].prefix { "0123456789.".contains($0) }))
    }

    @Test("Prepass tracks the pre-stay picture, retaining any strike burn and its clock",
          arguments: ["area", "centerStage", "vip"], [false, true])
    func prepass(mode: String, highlights: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let source = try await FixtureVideo.make(in: folder, wide: true)
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0.75, duration: 1, speed: 1.5)
        clip.videoFile = source.path
        clip.wide = true
        clip.captions = "none"
        clip.strikeHighlights = highlights ? true : nil
        clip.centerStage = mode != "area"
        if mode == "area" {
            let area = ScreenCropArea(name: "Tracking", points: [
                .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
            clip.framingPlan = .composed(layout: ScreenCropLayout(name: "Tracking", areas: [area]), areas: [], fit: .fill)
        } else if mode == "vip" {
            var recipe = CropRecipe(kind: .vip)
            recipe.centerStage = true
            recipe.centerStageVIPs = true
            recipe.steady = true
            clip.framingPlan = .tracked(recipe, region: nil, fit: .fill, feather: 0, blur: 0)
        }
        var document = Fixtures.timelineDocument(clips: [clip])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        var drawing = Telestration(time: 0.75, figures: [.init(kind: .line,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.2)],
            color: .yellow, width: 0.016, linger: 1.5)], stay: 0.5, drawSpeed: 0.5, fade: 0.2)
        drawing.offset = 0.15 // A preview can already be part-way through the stay.
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false)
        let inputs = Mutex<[Input]>([])
        let commands = Mutex<[[String]]>([])
        var outputs: [URL] = []
        defer { for output in outputs { try? FileManager.default.removeItem(at: output) } }
        for stays in [false, true] {
            inputs.withLock { $0.removeAll() }
            commands.withLock { $0.removeAll() }
            let output = try await CenterStageService.$trackingInputObserver.withValue({ source, start, duration in
                inputs.withLock { $0.append(Input(source: source, start: start, duration: duration)) }
            }) {
                try await FFmpeg.$commandCompleted.withValue({ command in
                    commands.withLock { $0.append(command) }
                }) {
                    try await renderer.render(document: document, scenes: [], profile: Fixtures.brand(),
                        database: temp.database, centerStageCamera: "steady", preview: true,
                        strikeHighlightTracks: highlights ? [source.path: [strike]] : [:],
                        lingering: stays ? [clip.uid: drawing] : [:], emit: { _ in })
                }
            }
            outputs.append(output.url)
            let decoded = inputs.withLock { $0 }
            // The synthetic pattern may fall back to a static crop. Observing
            // the actual tracker input prevents that from hiding wrong routing.
            #expect(decoded.count == 1)
            let input = try #require(decoded.first)
            #expect(abs(input.duration - 1.5) < 1e-9)
            let burns = commands.withLock { $0.filter { $0.contains("[drawing]") && $0.last?.hasSuffix("burned.mov") == true } }
            #expect(burns.count == (stays ? 1 : 0))
            if stays {
                let burn = try #require(burns.first)
                let sourceIndex = try #require(burn.firstIndex(of: "-i")) + 1
                let startIndex = try #require(burn.firstIndex(of: "-ss")) + 1
                #expect(input.source.path == burn[sourceIndex])
                #expect(input.start == Double(burn[startIndex]))
                #expect(input.source.path != burn.last)
            }
            if highlights {
                #expect(input.source != source)
                #expect(input.start == 0)
            } else {
                #expect(input.source == source)
                #expect(input.start == 0.75)
            }
        }
        #expect(try await pictureSSIM(outputs[0], outputs[1], folder: folder) >= 0.97)
    }
}
