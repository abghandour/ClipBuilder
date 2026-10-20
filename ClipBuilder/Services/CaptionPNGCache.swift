import Foundation

/// Serializes and memoizes caption PNG rasterization — identical text, word, emphasis, colour and animation states
/// render once per run, even across concurrent segment jobs.
actor CaptionPNGCache {
    private let renderer: CaptionRenderer
    private let directory: URL
    private var cache: [CaptionOverlayPlan.Raster: CaptionRenderer.RenderedCaption] = [:]

    init(renderer: CaptionRenderer, directory: URL) {
        self.renderer = renderer
        self.directory = directory
    }

    func rendered(_ raster: CaptionOverlayPlan.Raster) throws -> CaptionRenderer.RenderedCaption {
        if let hit = cache[raster] { return hit }
        let rendered = try renderer.render(text: raster.text, activeIndex: raster.activeIndex,
                                          emphasis: raster.emphasis, textColor: raster.textColor,
                                          frame: raster.frame, to: directory)
        cache[raster] = rendered
        return rendered
    }
}
