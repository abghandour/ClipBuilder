import Foundation
import ImageIO
import Testing
@testable import Clip_Builder

struct CaptionPresetsTests {
    @Test func libraryContainsEveryNamedPresetAndDistinctStyles() throws {
        let originals = ["Clean", "Boxed", "Karaoke", "Hormozi", "Three-Word", "Lower Third", "Interview Serif", "Retro 3D"]
        let additions = ["Cove", "Energy", "M81", "Arion Pink", "Quintessence", "Bellatrix", "Prism", "Freshly",
                         "Thuban", "Mars", "Runway", "Grace", "Copernicus", "Aldebaran", "Nova", "Alcyone Blue",
                         "Travel", "Andromeda", "Cassiopeia", "Citadelle", "Beast", "Iman", "Ali"]
        let presets = CaptionPresets.styles
        #expect(presets.count == 31)
        #expect(Set(presets.map(\.name)) == Set(originals + additions))
        #expect(Set(presets.map(\.name)).count == presets.count)
        #expect(Set(presets.map(\.style)).count == presets.count)
        for preset in presets {
            let data = try JSONEncoder().encode(preset)
            #expect(try JSONDecoder().decode(NamedCaptionStyle.self, from: data) == preset)
            let styleData = try JSONEncoder().encode(preset.style)
            #expect(try JSONDecoder().decode(CaptionStyle.self, from: styleData) == preset.style)
            #expect(preset.family != nil)
        }
    }

    @Test func highlightEmphasisAndSpeakerDefaultsNeverCollide() {
        let speaker = CaptionSpeakerColors.palette[0].lowercased()
        for preset in CaptionPresets.styles {
            let emphasis = preset.style.resolvedEmphasisColor.lowercased()
            let highlights = [preset.style.resolvedHighlightColor] + (preset.style.highlightColors ?? [])
            #expect(emphasis != speaker, "\(preset.name): emphasis must differ from the speaker")
            for highlight in highlights.map({ $0.lowercased() }) {
                #expect(highlight != emphasis, "\(preset.name): highlight must differ from emphasis")
                #expect(highlight != speaker, "\(preset.name): highlight must differ from the speaker")
            }
        }
    }

    @Test func oldNamedStylesDecodeAndRenamedCopiesRetainTheirFamily() throws {
        let original = try #require(CaptionPresets.styles.first { $0.name == "Beast" })
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "family")
        let old = try JSONDecoder().decode(NamedCaptionStyle.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.family == nil)
        #expect(CaptionPresets.family(for: old) == .creator)
        var renamed = original
        renamed.name = "My own look"
        let decoded = try JSONDecoder().decode(NamedCaptionStyle.self, from: JSONEncoder().encode(renamed))
        #expect(CaptionPresets.family(for: decoded) == .creator)
        #expect(CaptionPresets.family(for: NamedCaptionStyle(name: "Custom", style: CaptionStyle())) == nil)
    }

    @Test func highlightColorsCycleAndMissingOrEmptyListsFallBack() throws {
        var style = CaptionStyle()
        style.highlightColor = "#123456"
        #expect(CaptionRenderer.highlightColor(forPage: 99, style: style) == "#123456")
        style.highlightColors = []
        #expect(CaptionRenderer.highlightColor(forPage: 99, style: style) == "#123456")
        style.highlightColors = ["#ff0000", "#00ff00", "#0000ff"]
        #expect((0..<7).map { CaptionRenderer.highlightColor(forPage: $0, style: style) }
                == ["#ff0000", "#00ff00", "#0000ff", "#ff0000", "#00ff00", "#0000ff", "#ff0000"])
        #expect(CaptionRenderer.highlightColor(forPage: -1, style: style) == "#ff0000")
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: data) == style)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["highlight_colors"] as? [String] == style.highlightColors)
        let legacy = try JSONDecoder().decode(CaptionStyle.self, from: Data("{}".utf8))
        #expect(legacy.highlightColors == nil)
        #expect(CaptionRenderer.highlightColor(forPage: 4, style: legacy) == legacy.resolvedHighlightColor)
        let null = try JSONDecoder().decode(CaptionStyle.self, from: Data(#"{"highlight_colors":null}"#.utf8))
        #expect(null.highlightColors == nil)
    }

    @Test func pageColorsStayFixedThroughWordsAndMotionAndRepeatAcrossPages() throws {
        var style = try #require(CaptionPresets.styles.first { $0.name == "Prism" }).style
        style.animation = "pop"
        style.reveal = "word"
        style.revealMotion = true
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        let segments = (0..<4).map { TranscriptSegment(start: Double($0 * 3), end: Double(($0 + 1) * 3), text: "one two three") }
        let pages = CaptionOverlayPlan.pages(segments: segments, renderer: renderer,
            sourceStart: 0, speed: 1, duration: 12, position: "bottom")
        #expect(pages.count == 4)
        let plan = try CaptionOverlayPlan.plan(pages: pages, style: style)
        for index in 0..<4 {
            let overlays = plan.overlays.filter { $0.start >= Double(index * 3) && $0.start < Double((index + 1) * 3) }
            #expect(overlays.count > 3)
            #expect(Set(overlays.compactMap { $0.raster.highlightColor })
                    == [CaptionRenderer.highlightColor(forPage: index, style: style)])
        }
        #expect(plan.overlays.first?.raster == plan.overlays.first { $0.start == 9 }?.raster)
        #expect(plan.overlays.first?.raster != plan.overlays.first { $0.start == 3 }?.raster)

        var otherStream = pages[0]
        otherStream.streamID = "other"
        let separate = try CaptionOverlayPlan.plan(pages: pages + [otherStream], style: style)
        #expect(separate.overlays.last?.raster.highlightColor == style.highlightColors?.first)
        let fallback = try CaptionOverlayPlan.plan(pages: pages, style: style, limit: 1)
        #expect(fallback.usedPageFallback)
        #expect(fallback.overlays.first?.raster.highlightColor == style.highlightColors?.first)
    }

    @Test func cyclingReachesThePNGCacheAndModernDecor() async throws {
        var style = try #require(CaptionPresets.styles.first { $0.name == "Prism" }).style
        style.decor = TextDecor(shadowOn: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: 540, videoHeight: 960, style: style, safeArea: nil)
        let cache = CaptionPNGCache(renderer: renderer, directory: scratch)
        let pages = (0..<4).map {
            CaptionOverlayPlan.Page(caption: .init(text: "hello", start: Double($0), end: Double($0 + 1)), position: "bottom")
        }
        let plan = try CaptionOverlayPlan.plan(pages: pages, style: style)
        let first = try await cache.rendered(plan.overlays[0].raster)
        let second = try await cache.rendered(plan.overlays[1].raster)
        let repeated = try await cache.rendered(plan.overlays[3].raster)
        #expect(first.pngURL == repeated.pngURL)
        #expect(try Data(contentsOf: first.pngURL) != Data(contentsOf: second.pngURL))
        let direct = try renderer.render(text: "hello", activeIndex: 0, to: scratch)
        #expect(try Data(contentsOf: first.pngURL) == Data(contentsOf: direct.pngURL))
    }

    @Test func bounceOvershootsAndSettlesAtThePopDuration() throws {
        let style = try #require(CaptionPresets.styles.first { $0.name == "Thuban" }).style
        #expect(style.resolvedAnimation == "bounce")
        let duration = CaptionAnimation.duration(for: "bounce")
        #expect(duration == CaptionAnimation.duration(for: "pop"))
        let frames = CaptionAnimation.frames(for: "bounce", duration: duration)
        #expect(try #require(frames.first).scale < 1)
        #expect(frames.contains { $0.scale > 1 })
        #expect(frames.dropFirst(2).contains { $0.scale < 1 })
        #expect(frames.last?.scale == 1 && frames.last?.at == duration)
        #expect(frames.map(\.scale).max() == CGFloat(CaptionAnimation.maximumScale(for: "bounce")))
        #expect(CaptionAnimation.frames(for: "bounce", duration: 0) == [.init()])
    }

    @Test(arguments: CaptionPresets.Family.allCases)
    func onePreviewRendersPerFamily(_ family: CaptionPresets.Family) throws {
        let representatives: [CaptionPresets.Family: String] = [
            .wordByWord: "Thuban", .highlights: "Prism", .boldStacks: "Quintessence", .creator: "Ali",
        ]
        let preset = try #require(CaptionPresets.styles.first { $0.name == representatives[family] })
        #expect(preset.family == family)
        let preview = try CaptionPreviewImage.render(style: preset.style)
        #expect(preview.size.width > 0 && preview.size.height > 0)
        let source = try #require(CGImageSourceCreateWithData(preview.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == Int(preview.size.width) && image.height == Int(preview.size.height))
        #expect(preview.start <= 0.3 && preview.end > 0.3)
    }
}
