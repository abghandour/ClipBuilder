import CoreGraphics
import Foundation

/// The Express "Overlay" setting: one saved overlay template laid over the
/// finished video as a single block. Pure placement; the caller supplies the
/// template list and the assembled video's length.
nonisolated enum WizardFixedOverlay {
    static let minimumDuration = 0.5

    /// Nil when no template is chosen, it no longer exists, its composition
    /// is empty, or the window falls outside the video. The start is clamped
    /// to 0 and the block never runs past `totalDuration`.
    static func block(options: WizardOptions, templates: [OverlayTemplate],
                      totalDuration: Double) -> OverlayBlockItem? {
        guard let name = options.fixedOverlayTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let template = templates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              !template.composition.isEmpty, totalDuration.isFinite, totalDuration > 0 else { return nil }
        let start = min(max(0, options.fixedOverlayStart ?? 0), totalDuration)
        let remaining = totalDuration - start
        let requested = options.fixedOverlayDuration.map { max(0, $0) } ?? remaining
        let duration = min(requested, remaining)
        guard duration >= minimumDuration else { return nil }
        var block = OverlayBlockItem()
        block.name = template.name
        block.composition = designComposition(options: options, template: template)
        if let custom = CustomPosition(options.fixedOverlayPosition) {
            block.composition = repositioned(block.composition, center: custom,
                                             canvasAspect: options.renderSettings.aspectRatio)
        }
        block.exactPlacement = true
        block.startTime = (start * 100).rounded() / 100
        block.duration = (duration * 100).rounded() / 100
        return block
    }

    /// The template with the user's words and hand placements applied,
    /// before the whole design is moved to a (legacy) dragged position.
    static func designComposition(options: WizardOptions, template: OverlayTemplate) -> OverlayComposition {
        applyingEdits(in: replacingDynamicTexts(in: template.composition, with: options.fixedOverlayTexts ?? []),
                      with: options.fixedOverlayEdits ?? OverlayEdits())
    }

    /// How far `repositioned` moves the design for `center`, as canvas
    /// fractions; zero when nothing moves.
    static func shift(of composition: OverlayComposition, center: CustomPosition, canvasAspect: Double) -> CGPoint {
        guard let box = bounds(of: composition, canvasAspect: canvasAspect) else { return .zero }
        let origin = center.origin(size: box.size, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let dx = origin.x - box.minX, dy = origin.y - box.minY
        guard abs(dx) > 0.00001 || abs(dy) > 0.00001 else { return .zero }
        return CGPoint(x: dx, y: dy)
    }

    /// The design's bounding box as canvas fractions: texts from their
    /// centre and size fractions, images from their width (assumed square,
    /// their height depends on the file). nil for an empty design.
    static func bounds(of composition: OverlayComposition, canvasAspect: Double) -> CGRect? {
        var union = CGRect.null
        for text in composition.texts {
            let w = text.wFrac ?? 0.6, h = text.hFrac ?? 0.1
            union = union.union(CGRect(x: (text.xFrac ?? 0.5) - w / 2, y: (text.yFrac ?? 0.2) - h / 2, width: w, height: h))
        }
        for image in composition.images {
            let w = image.wFrac, h = image.wFrac * max(0.01, canvasAspect)
            union = union.union(CGRect(x: image.xFrac - w / 2, y: image.yFrac - h / 2, width: w, height: h))
        }
        return union.isNull ? nil : union
    }

    /// The design moved as one piece so its bounding box is centred on
    /// `center`, kept inside the frame.
    static func repositioned(_ composition: OverlayComposition, center: CustomPosition, canvasAspect: Double) -> OverlayComposition {
        let delta = shift(of: composition, center: center, canvasAspect: canvasAspect)
        let dx = delta.x, dy = delta.y
        guard dx != 0 || dy != 0 else { return composition }
        var result = composition
        result.texts = composition.texts.map { text in
            var item = text
            item.xFrac = (text.xFrac ?? 0.5) + dx
            item.yFrac = (text.yFrac ?? 0.2) + dy
            return item
        }
        result.images = composition.images.map { image in
            var item = image
            item.xFrac += dx
            item.yFrac += dy
            return item
        }
        return result
    }

    /// How much of the design shows through as a watermark by default.
    static let watermarkOpacity = 0.4

    /// The strength the watermark renders at for these options.
    static func effectiveWatermarkOpacity(options: WizardOptions) -> Double {
        let usesOverlay = options.watermarkOverlayTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let fallback = usesOverlay ? watermarkOpacity : BrandRenderer.logoWatermarkOpacity
        return min(1, max(0, options.watermarkOpacity ?? fallback))
    }

    /// The watermark as an overlay block over the whole video when the user
    /// chose a template for it; nil when the brand logo (or nothing) applies.
    static func watermarkBlock(options: WizardOptions, templates: [OverlayTemplate],
                               totalDuration: Double) -> OverlayBlockItem? {
        guard options.includeWatermark,
              let name = options.watermarkOverlayTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let template = templates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              !template.composition.isEmpty, totalDuration.isFinite, totalDuration >= minimumDuration else { return nil }
        var block = OverlayBlockItem()
        block.name = template.name
        block.composition = watermarkStyled(template.composition, opacity: effectiveWatermarkOpacity(options: options))
        block.exactPlacement = true
        block.startTime = 0
        block.duration = (totalDuration * 100).rounded() / 100
        return block
    }

    /// The watermark look: every item faded to `watermarkOpacity`, no
    /// background boxes, shadows or outlines, no entry or exit effects, and
    /// everything lasting the whole block.
    static func watermarkStyled(_ composition: OverlayComposition, opacity: Double = watermarkOpacity) -> OverlayComposition {
        var result = composition
        result.texts = composition.texts.map { text in
            var item = text
            item.opacity = min(item.opacity, opacity)
            item.boxOpacity = 0
            item.shadowOpacity = 0
            item.strokeWidthEm = 0
            item.transIn = "cut"
            item.transOut = "cut"
            item.startTime = 0
            item.unbounded = true
            return item
        }
        result.images = composition.images.map { image in
            var item = image
            item.opacity = min(item.opacity, opacity)
            item.transIn = "cut"
            item.transOut = "cut"
            item.startTime = 0
            item.unbounded = true
            return item
        }
        return result
    }

    /// The texts the AI Wizard may replace, in template order. These are
    /// the fields Express offers to override.
    static func dynamicTexts(in composition: OverlayComposition) -> [String] {
        dynamicTextItems(in: composition).map(\.text)
    }

    /// The replaceable text items themselves, in template order.
    static func dynamicTextItems(in composition: OverlayComposition) -> [TextOverlayItem] {
        composition.texts.filter(\.isDynamic)
    }

    /// The positions of the replaceable texts among all of the design's
    /// texts (what `OverlayEdits.texts` is indexed by).
    static func dynamicTextIndices(in composition: OverlayComposition) -> [Int] {
        composition.texts.indices.filter { composition.texts[$0].isDynamic }
    }

    /// A text's design box as canvas fractions (the defaults the renderer
    /// and `bounds` assume when a fraction is unset).
    static func designBox(of text: TextOverlayItem) -> CGRect {
        let w = text.wFrac ?? 0.6, h = text.hFrac ?? 0.1
        return CGRect(x: (text.xFrac ?? 0.5) - w / 2, y: (text.yFrac ?? 0.2) - h / 2, width: w, height: h)
    }

    /// An image's box as canvas fractions for `aspect` = height / width.
    static func designBox(of image: ImageOverlayItem, aspect: Double) -> CGRect {
        let w = image.wFrac, h = image.wFrac * max(0.01, aspect)
        return CGRect(x: image.xFrac - w / 2, y: image.yFrac - h / 2, width: w, height: h)
    }

    /// Apply the user's hand placements to the design's components by
    /// position; a missing or empty edit keeps the design. A placed text
    /// box locks its width so overflowing words wrap inside it; a placed
    /// image keeps its file's aspect.
    static func applyingEdits(in composition: OverlayComposition, with edits: OverlayEdits) -> OverlayComposition {
        guard !edits.isEmpty else { return composition }
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        var result = composition
        for (index, edit) in edits.texts.enumerated() where index < result.texts.count {
            if let alignment = edit.alignment, TextOverlayItem.alignmentChoices.contains(alignment) {
                result.texts[index].alignment = alignment
            }
            if let box = edit.box {
                let clamped = box.intersection(frame)
                guard clamped.width > 0, clamped.height > 0 else { continue }
                result.texts[index].xFrac = clamped.midX
                result.texts[index].yFrac = clamped.midY
                result.texts[index].wFrac = clamped.width
                result.texts[index].hFrac = clamped.height
                result.texts[index].lockedWidth = true
            }
        }
        for (index, edit) in edits.images.enumerated() where index < result.images.count {
            if let width = edit.width { result.images[index].wFrac = min(1, width) }
            if let center = edit.center {
                result.images[index].xFrac = min(1, max(0, center.x))
                result.images[index].yFrac = min(1, max(0, center.y))
            }
        }
        return result
    }

    /// Replace the replaceable texts in order; blank or missing entries keep
    /// the template's own text. Fixed texts are never touched.
    static func replacingDynamicTexts(in composition: OverlayComposition, with texts: [String]) -> OverlayComposition {
        var result = composition
        var index = 0
        for position in result.texts.indices where result.texts[position].isDynamic {
            defer { index += 1 }
            guard index < texts.count else { continue }
            let replacement = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !replacement.isEmpty { result.texts[position].text = replacement }
        }
        return result
    }

    /// One line for the Express summary and the wizard log.
    static func summary(options: WizardOptions) -> String? {
        guard let name = options.fixedOverlayTemplate, !name.isEmpty else { return nil }
        let start = options.fixedOverlayStart ?? 0
        let when = start > 0 ? " from \(Self.seconds(start))" : ""
        let length = options.fixedOverlayDuration.map { " for \(Self.seconds($0))" } ?? ""
        return "overlay \(name)\(when)\(length)"
    }

    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }
}
