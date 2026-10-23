import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard fixed overlay")
struct WizardFixedOverlayTests {
    private var templates: [OverlayTemplate] {
        var text = TextOverlayItem()
        text.text = "Subscribe"
        text.unbounded = true
        return [OverlayTemplate(name: "Lower Third", composition: OverlayComposition(texts: [text])),
                OverlayTemplate(name: "Empty", composition: OverlayComposition())]
    }

    @Test func unboundedOverlayCoversTheWholeVideoFromItsStart() throws {
        var options = WizardOptions()
        #expect(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30) == nil)
        options.fixedOverlayTemplate = "lower third"
        let whole = try #require(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30))
        #expect(whole.name == "Lower Third" && whole.startTime == 0 && whole.duration == 30)
        #expect(whole.exactPlacement, "lands where the Overlays editor shows it")
        #expect(whole.composition.texts.first?.text == "Subscribe")
        options.fixedOverlayStart = 4
        let later = try #require(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30))
        #expect(later.startTime == 4 && later.duration == 26)
    }

    @Test func boundedOverlayIsClampedToTheVideoAndDroppedWhenOutside() throws {
        var options = WizardOptions()
        options.fixedOverlayTemplate = "Lower Third"
        options.fixedOverlayStart = 25
        options.fixedOverlayDuration = 10
        let clamped = try #require(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30))
        #expect(clamped.startTime == 25 && clamped.duration == 5)
        options.fixedOverlayStart = 40
        #expect(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30) == nil)
        options.fixedOverlayStart = -3
        options.fixedOverlayDuration = 0.2
        #expect(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30) == nil)
        options.fixedOverlayDuration = 2
        #expect(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30)?.startTime == 0)
        options.fixedOverlayTemplate = "Empty"
        #expect(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30) == nil)
        options.fixedOverlayTemplate = "Missing"
        #expect(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 30) == nil)
        #expect(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 0) == nil)
    }

    @Test func onlyReplaceableTextsTakeOverridesAndBlanksKeepTheTemplate() throws {
        var fixed = TextOverlayItem()
        fixed.text = "JEAN SILVA"
        var headline = TextOverlayItem()
        headline.text = "AND YOU CAN'T TALK ABOUT IT"
        headline.isDynamic = true
        var second = TextOverlayItem()
        second.text = "Second"
        second.isDynamic = true
        let composition = OverlayComposition(texts: [headline, fixed, second])
        #expect(WizardFixedOverlay.dynamicTexts(in: composition) == ["AND YOU CAN'T TALK ABOUT IT", "Second"])
        let replaced = WizardFixedOverlay.replacingDynamicTexts(in: composition, with: ["  New hook  ", ""])
        #expect(replaced.texts.map(\.text) == ["New hook", "JEAN SILVA", "Second"])
        #expect(WizardFixedOverlay.replacingDynamicTexts(in: composition, with: []) == composition)
        var options = WizardOptions()
        options.fixedOverlayTemplate = "Hook"
        options.fixedOverlayTexts = ["Override", "Other"]
        let block = try #require(WizardFixedOverlay.block(options: options,
            templates: [OverlayTemplate(name: "Hook", composition: composition)], totalDuration: 10))
        #expect(block.composition.texts.map(\.text) == ["Override", "JEAN SILVA", "Other"])
    }

    @Test func watermarkOverlayFadesEverythingAndSpansTheVideo() throws {
        var text = TextOverlayItem()
        text.text = "Peace Grappler"
        text.boxOpacity = 0.6
        text.shadowOpacity = 0.5
        text.strokeWidthEm = 0.1
        text.strokeColor = "#000000"
        text.startTime = 1
        text.endTime = 2
        var image = ImageOverlayItem()
        image.path = "/logo.png"
        image.opacity = 0.9
        let composition = OverlayComposition(texts: [text], images: [image])
        var options = WizardOptions()
        options.watermarkOverlayTemplate = "Mark"
        options.includeWatermark = false
        #expect(WizardFixedOverlay.watermarkBlock(options: options,
            templates: [OverlayTemplate(name: "Mark", composition: composition)], totalDuration: 20) == nil)
        options.includeWatermark = true
        let block = try #require(WizardFixedOverlay.watermarkBlock(options: options,
            templates: [OverlayTemplate(name: "mark", composition: composition)], totalDuration: 20))
        #expect(block.startTime == 0 && block.duration == 20 && block.name == "mark" && block.exactPlacement)
        let styledText = try #require(block.composition.texts.first)
        #expect(styledText.opacity == WizardFixedOverlay.watermarkOpacity && styledText.boxOpacity == 0)
        #expect(styledText.shadowOpacity == 0 && styledText.strokeWidthEm == 0)
        #expect(styledText.transIn == "cut" && styledText.transOut == "cut" && styledText.unbounded && styledText.startTime == 0)
        #expect(styledText.text == "Peace Grappler" && styledText.xFrac == text.xFrac)
        let styledImage = try #require(block.composition.images.first)
        #expect(styledImage.opacity == WizardFixedOverlay.watermarkOpacity && styledImage.unbounded && styledImage.transIn == "cut")
        options.watermarkOpacity = 0.7
        let stronger = try #require(WizardFixedOverlay.watermarkBlock(options: options,
            templates: [OverlayTemplate(name: "Mark", composition: composition)], totalDuration: 20))
        #expect(stronger.composition.texts.first?.opacity == 0.7 && stronger.composition.images.first?.opacity == 0.7)
        options.watermarkOpacity = 1.5
        #expect(WizardFixedOverlay.effectiveWatermarkOpacity(options: options) == 1)
        options.watermarkOpacity = nil
        options.watermarkOverlayTemplate = nil
        #expect(WizardFixedOverlay.effectiveWatermarkOpacity(options: options) == BrandRenderer.logoWatermarkOpacity)
        options.watermarkOverlayTemplate = "Missing"
        #expect(WizardFixedOverlay.watermarkBlock(options: options,
            templates: [OverlayTemplate(name: "Mark", composition: composition)], totalDuration: 20) == nil)
    }

    @Test func summaryNamesTheTemplateAndItsWindow() {
        var options = WizardOptions()
        #expect(WizardFixedOverlay.summary(options: options) == nil)
        options.fixedOverlayTemplate = "Lower Third"
        #expect(WizardFixedOverlay.summary(options: options) == "overlay Lower Third")
        options.fixedOverlayStart = 2.5
        options.fixedOverlayDuration = 4
        #expect(WizardFixedOverlay.summary(options: options) == "overlay Lower Third from 2.5 s for 4 s")
    }

    @Test func draggedPositionMovesTheWholeDesignToThePoint() throws {
        var text = TextOverlayItem()
        text.text = "Subscribe"
        text.xFrac = 0.5
        text.yFrac = 0.2
        text.wFrac = 0.6
        text.hFrac = 0.1
        var image = ImageOverlayItem()
        image.xFrac = 0.5
        image.yFrac = 0.35
        image.wFrac = 0.2
        let composition = OverlayComposition(texts: [text], images: [image])
        let box = try #require(WizardFixedOverlay.bounds(of: composition, canvasAspect: 9.0 / 16))
        #expect(abs(box.minX - 0.2) < 0.0001 && abs(box.width - 0.6) < 0.0001)
        #expect(abs(box.minY - 0.15) < 0.0001, "the text's top edge")
        let imageHeight = 0.2 * 9.0 / 16
        #expect(abs(box.maxY - (0.35 + imageHeight / 2)) < 0.0001, "the image's bottom edge, assumed square")
        let moved = WizardFixedOverlay.repositioned(composition, center: CustomPosition(x: 0.5, y: 0.8), canvasAspect: 9.0 / 16)
        let after = try #require(WizardFixedOverlay.bounds(of: moved, canvasAspect: 9.0 / 16))
        #expect(abs(after.midX - 0.5) < 0.0001 && abs(after.midY - 0.8) < 0.0001)
        let shift = after.minY - box.minY
        #expect(abs((moved.texts[0].yFrac ?? 0) - (0.2 + shift)) < 0.0001)
        #expect(abs(moved.images[0].yFrac - (0.35 + shift)) < 0.0001, "text and image keep their arrangement")
        // Dragged past the edge the design stops at the frame.
        let edge = WizardFixedOverlay.repositioned(composition, center: CustomPosition(x: 1, y: 1), canvasAspect: 9.0 / 16)
        let clamped = try #require(WizardFixedOverlay.bounds(of: edge, canvasAspect: 9.0 / 16))
        #expect(abs(clamped.maxX - 1) < 0.0001 && abs(clamped.maxY - 1) < 0.0001)
        // The block applies it only when the option is a custom position.
        var options = WizardOptions()
        options.fixedOverlayTemplate = "Moved"
        let templates = [OverlayTemplate(name: "Moved", composition: composition)]
        let asDesigned = try #require(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 10))
        #expect(asDesigned.composition.texts[0].yFrac == 0.2)
        options.fixedOverlayPosition = CustomPosition(x: 0.5, y: 0.8).string
        let dragged = try #require(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 10))
        #expect((dragged.composition.texts[0].yFrac ?? 0) > 0.6)
    }
}
