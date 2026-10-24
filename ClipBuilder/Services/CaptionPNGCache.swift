import Foundation

/// Serializes and memoizes caption PNG rasterization — identical text, word, emphasis, colour and animation states
/// render once per run, even across concurrent segment jobs.
actor CaptionPNGCache {
    private nonisolated let renderers: CaptionRendererSet
    private let directory: URL
    private var cache: [CaptionOverlayPlan.Raster: CaptionRenderer.RenderedCaption] = [:]

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
        if let hit = cache[raster] { return hit }
        let renderer = renderer(styleID: raster.styleID)
        let rendered = try renderer.render(text: raster.text, activeIndex: raster.activeIndex,
                                          emphasis: raster.emphasis, textColor: raster.textColor,
                                          frame: raster.frame, to: directory)
        cache[raster] = rendered
        return rendered
    }
}
