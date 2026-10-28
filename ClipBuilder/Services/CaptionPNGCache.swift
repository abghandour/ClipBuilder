import Foundation

/// Serializes and memoizes caption PNG rasterization — identical text, word, emphasis, colour and animation states
/// render once per run, even across concurrent segment jobs.
actor CaptionPNGCache {
    private nonisolated let renderers: CaptionRendererSet
    private let directory: URL
    private struct Key: Hashable {
        var raster: CaptionOverlayPlan.Raster
        var decor: [TextDecor]
        var style: CaptionStyle
    }
    private var cache: [Key: CaptionRenderer.RenderedCaption] = [:]

    init(renderer: CaptionRenderer, directory: URL) {
        self.renderers = CaptionRendererSet(base: renderer)
        self.directory = directory
    }

    init(renderers: CaptionRendererSet, directory: URL) {
        self.renderers = renderers
        self.directory = directory
    }

    nonisolated func renderer(styleID: String?) -> CaptionRenderer {
        renderers.renderer(styleID: styleID)
    }

    func rendered(_ raster: CaptionOverlayPlan.Raster) throws -> CaptionRenderer.RenderedCaption {
        let renderer = renderer(styleID: raster.styleID)
        let key = Key(raster: raster, decor: CaptionStyle.WordState.allCases.map { renderer.style.resolvedTextDecor(for: $0) }
            + [renderer.style.pageDecor], style: renderer.style)
        if let hit = cache[key] { return hit }
        let rendered = try renderer.render(text: raster.text, activeIndex: raster.activeIndex,
                                          emphasis: raster.emphasis, textColor: raster.textColor,
                                          frame: raster.frame, to: directory)
        cache[key] = rendered
        return rendered
    }
}
