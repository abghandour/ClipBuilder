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
        block.composition = replacingDynamicTexts(in: template.composition, with: options.fixedOverlayTexts ?? [])
        block.exactPlacement = true
        block.startTime = (start * 100).rounded() / 100
        block.duration = (duration * 100).rounded() / 100
        return block
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
        composition.texts.filter(\.isDynamic).map(\.text)
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
