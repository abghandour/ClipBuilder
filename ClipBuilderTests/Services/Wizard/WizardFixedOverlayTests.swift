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

    @Test func editsPlaceEachComponentByPositionAndLockPlacedTextBoxes() throws {
        var fixed = TextOverlayItem(text: "Fixed")
        fixed.xFrac = 0.5; fixed.yFrac = 0.1; fixed.wFrac = 0.4; fixed.hFrac = 0.05
        var first = TextOverlayItem(text: "Hook")
        first.isDynamic = true
        first.xFrac = 0.5; first.yFrac = 0.3; first.wFrac = 0.6; first.hFrac = 0.1
        var second = TextOverlayItem(text: "Second")
        second.isDynamic = true
        second.alignment = "right"
        var logo = ImageOverlayItem(path: "/tmp/logo.png")
        logo.xFrac = 0.5; logo.yFrac = 0.8; logo.wFrac = 0.2
        let composition = OverlayComposition(texts: [fixed, first, second], images: [logo])
        #expect(WizardFixedOverlay.dynamicTextIndices(in: composition) == [1, 2])
        let box = WizardFixedOverlay.designBox(of: first)
        #expect(abs(box.minX - 0.2) < 0.0001 && abs(box.minY - 0.25) < 0.0001)
        let defaulted = WizardFixedOverlay.designBox(of: second)
        #expect(abs(defaulted.width - 0.6) < 0.0001 && abs(defaulted.height - 0.1) < 0.0001, "unset fractions use the defaults")
        let image = WizardFixedOverlay.designBox(of: logo, aspect: 0.5)
        #expect(abs(image.width - 0.2) < 0.0001 && abs(image.height - 0.1) < 0.0001 && abs(image.midY - 0.8) < 0.0001)

        var edits = OverlayEdits()
        edits.text(0) { $0.alignment = "left" }
        edits.place(.text(1), at: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.2))
        edits.text(2) { $0.alignment = "sideways" }
        edits.place(.image(0), at: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.15))
        let edited = WizardFixedOverlay.applyingEdits(in: composition, with: edits)
        #expect(edited.texts[0].alignment == "left" && edited.texts[0].wFrac == 0.4, "any text can be aligned, not only replaceable ones")
        let placed = edited.texts[1]
        #expect(placed.resolvedLockedWidth && placed.alignment == "center")
        #expect(abs((placed.xFrac ?? 0) - 0.25) < 0.0001 && abs((placed.yFrac ?? 0) - 0.6) < 0.0001)
        #expect(abs((placed.wFrac ?? 0) - 0.3) < 0.0001 && abs((placed.hFrac ?? 0) - 0.2) < 0.0001)
        #expect(edited.texts[2].alignment == "right" && !edited.texts[2].resolvedLockedWidth, "an unknown alignment is ignored")
        #expect(abs(edited.images[0].xFrac - 0.75) < 0.0001 && abs(edited.images[0].yFrac - 0.675) < 0.0001)
        #expect(abs(edited.images[0].wFrac - 0.3) < 0.0001, "an image takes its centre and width")
        #expect(WizardFixedOverlay.applyingEdits(in: composition, with: OverlayEdits()) == composition)

        // The block applies edits after the words and before a legacy drag.
        var options = WizardOptions()
        options.fixedOverlayTemplate = "Edited"
        options.fixedOverlayTexts = ["New hook", ""]
        options.fixedOverlayEdits = edits
        let templates = [OverlayTemplate(name: "Edited", composition: composition)]
        let block = try #require(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 10))
        #expect(block.composition.texts[1].text == "New hook" && block.composition.texts[0].alignment == "left")
        #expect(abs((block.composition.texts[1].wFrac ?? 0) - 0.3) < 0.0001)
        options.fixedOverlayPosition = CustomPosition(x: 0.5, y: 0.8).string
        let dragged = try #require(WizardFixedOverlay.block(options: options, templates: templates, totalDuration: 10))
        let design = WizardFixedOverlay.designComposition(options: options, template: templates[0])
        let shift = WizardFixedOverlay.shift(of: design, center: CustomPosition(x: 0.5, y: 0.8), canvasAspect: 9.0 / 16)
        #expect(abs((dragged.composition.texts[1].yFrac ?? 0) - (0.6 + shift.y)) < 0.0001, "the placed box moves with the design")
        #expect(abs((dragged.composition.texts[1].wFrac ?? 0) - 0.3) < 0.0001, "and keeps its size")
        #expect(WizardFixedOverlay.shift(of: design, center: CustomPosition(x: 0, y: 0), canvasAspect: 9.0 / 16) != .zero)
    }

    @Test func editsRoundTripAsOneJSONStringAndDropUntouchedTails() throws {
        #expect(OverlayEdits().joined == "" && OverlayEdits.split("").isEmpty && OverlayEdits.split(nil).isEmpty)
        #expect(OverlayEdits(texts: [OverlayTextEdit(), OverlayTextEdit()]).trimmed == nil)
        var edits = OverlayEdits()
        edits.text(1) { $0.alignment = "right"; $0.box = CGRect(x: 0.12345678, y: 0.2, width: 0.5, height: 0.1) }
        edits.text(2) { _ in }
        edits.image(0) { $0 = OverlayImageEdit(center: CGPoint(x: 0.5, y: 0.25), width: 0.3) }
        edits.image(1) { _ in }
        let joined = edits.joined
        let back = OverlayEdits.split(joined)
        #expect(back.texts.count == 2 && back.images.count == 1, "untouched tails are dropped, untouched heads kept for their index")
        #expect(back.texts[0].isEmpty && back.texts[1].alignment == "right")
        let box = try #require(back.texts[1].box)
        #expect(abs(box.minX - 0.1235) < 0.00001 && box.width == 0.5, "fractions keep four decimals")
        #expect(back.images[0].center == CGPoint(x: 0.5, y: 0.25) && back.images[0].width == 0.3)
        #expect(OverlayEdits.split("not json").isEmpty && OverlayEdits.split("{}").isEmpty)
        var cleared = back.texts[1]
        cleared.box = nil
        #expect(cleared.box == nil && cleared.alignment == "right" && cleared.x == nil)
        var degenerate = OverlayTextEdit()
        degenerate.box = CGRect(x: 0, y: 0, width: 0, height: 0.1)
        #expect(degenerate.isEmpty, "a box without area is no box")
        #expect(OverlayImageEdit(width: 0).isEmpty)
        // Express settings carry the edits through presets and UserDefaults.
        var settings = MiniWizardSettings()
        settings.overlay = true
        settings.overlayTemplate = "Edited"
        settings.overlayEdits = edits
        let fields = WizardPresetBridge.wizardFields(from: settings)
        #expect(fields["fixedOverlayEdits"] == .string(joined))
        #expect(WizardPresetBridge.miniSettings(from: fields).overlayEdits == back)
        #expect(settings.previewOptions(profile: Fixtures.brand(name: "P")).fixedOverlayEdits == back)
        let defaults = UserDefaults(suiteName: "overlay-edits-\(UUID().uuidString)")!
        settings.remember(profileName: "P", defaults: defaults)
        #expect(MiniWizardSettings.remembered(profile: Fixtures.brand(name: "P"), defaults: defaults).overlayEdits == back)
    }
}
