import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Express batch watermark planning")
struct ExpressBatchWatermarkTests {
    @Test("missing images are skipped once while valid watermark items survive")
    func missingImage() throws {
        let temp = try TempDirectory(prefix: "WatermarkMissingImage")
        var block = OverlayBlockItem()
        block.name = "Watermark"; block.duration = 1
        block.composition.images = [ImageOverlayItem(path: temp.url.appendingPathComponent("missing-logo.png").path)]
        block.composition.texts = [TextOverlayItem(text: "Still visible", startTime: 0, endTime: 1)]
        block.composition = WizardFixedOverlay.watermarkStyled(block.composition)
        let messages = Mutex<[String]>([])
        let overlays = ExpressBatchWatermark.rasterize(block,
            settings: RenderSettings(preset: .custom, customWidth: 360, customHeight: 640), scratch: temp.url,
            log: { line in messages.withLock { $0.append(line) } })
        #expect(overlays.count == 1)
        #expect(overlays.allSatisfy { FileManager.default.fileExists(atPath: $0.png.path) })
        #expect(messages.withLock { $0 } == ["Watermark: missing-logo skipped: unreadable image"])
        block.composition.texts = []
        #expect(ExpressBatchWatermark.rasterize(block, settings: RenderSettings(), scratch: temp.url, log: { _ in }).isEmpty)
    }

    @Test("later overlays, cutaways and brand cards retain final watermark ordering")
    func foldingEligibility() {
        var options = WizardOptions()
        options.includeWatermark = true; options.includeOutro = false
        options.useBRoll = false; options.framing = Framing()
        options.fixedOverlayTemplate = nil
        let plan = Fixtures.plan()
        #expect(ExpressBatchWatermark.canFold(options: options, plan: plan, hasPodcastDocument: true, batchID: "batch"))
        #expect(!ExpressBatchWatermark.canFold(options: options, plan: plan, hasPodcastDocument: true, batchID: nil))
        #expect(!ExpressBatchWatermark.canFold(options: options, plan: plan, hasPodcastDocument: false, batchID: "batch"))
        for mutation: (inout WizardOptions) -> Void in [
            { $0.fixedOverlayTemplate = "Lower third" }, { $0.includeOutro = true },
            { $0.framing = Framing(subject: .vipFocus) },
            { $0.useBRoll = true; $0.brollInstructions = "Add reactions" },
            { $0.includeWatermark = false },
        ] {
            var changed = options; mutation(&changed)
            #expect(!ExpressBatchWatermark.canFold(options: changed, plan: plan, hasPodcastDocument: true, batchID: "batch"))
        }
    }
}
