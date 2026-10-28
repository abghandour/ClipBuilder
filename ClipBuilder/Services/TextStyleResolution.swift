import Foundation

/// Explicit adapters keep old wire fields readable without materializing overrides.
nonisolated extension CaptionWordDecor {
    var legacyDecor: TextDecor {
        TextDecor(weight: weight, italic: italic, underline: underline, strikethrough: strikethrough,
                  letterSpacing: letterSpacing, strokeOn: strokeWidth.map { $0 > 0 }, strokeWidth: strokeWidth,
                  shadowOn: shadow, bgOn: bgOn, bgColor: bgColor,
                  bgOpacity: bgColor == nil ? 0.25 : 1, bgRadius: bgRadius)
    }
}

nonisolated extension CaptionStyle {
    var legacyDecor: TextDecor {
        TextDecor(color: color, weight: resolvedWeight, casing: resolvedUppercase ? "upper" : "asWritten",
                  letterSpacing: resolvedLetterSpacing,
                  strokeOn: !bgOn && resolvedStrokeWidth > 0, strokeWidth: resolvedStrokeWidth,
                  shadowOn: resolvedShadow, bgOn: bgOn, bgColor: bgColor, bgOpacity: 0.7,
                  bgRadius: resolvedPageRadius, alignment: alignment)
    }

    var hasTextDecor: Bool {
        decor != nil || text?.decor != nil || highlightDecor?.decor != nil || emphasisDecor?.decor != nil
    }

    /// The page box is distinct from each word state's box.
    var pageDecor: TextDecor {
        let box = text?.decor?.boxFields ?? TextDecor()
        return box.merged(over: decor ?? TextDecor()).resolved(over: legacyDecor)
    }

    func resolvedTextDecor(for state: WordState) -> TextDecor {
        let old = resolvedDecor(for: state)
        var legacy = old.legacyDecor.merged(over: legacyDecor)
        legacy.bgOn = old.resolvedBackground
        legacy.bgColor = old.bgColor
        legacy.bgOpacity = old.bgColor == nil ? 0.25 : 1
        legacy.bgRadius = old.resolvedRadius
        legacy.strokeOn = !bgOn && old.resolvedStrokeWidth > 0
        if state == .highlight && resolvedHighlight == "color" { legacy.color = resolvedHighlightColor }
        if state == .emphasis && ["color", "both"].contains(resolvedEmphasis) { legacy.color = resolvedEmphasisColor }
        var base = decor ?? TextDecor()
        // The surface box is painted once, not once per word.
        base.bgOn = nil; base.bgColor = nil; base.bgOpacity = nil; base.bgRadius = nil
        base.borderOn = nil
        base = (text?.decor ?? TextDecor()).merged(over: base).merged(over: legacy)
        let stateDecor: TextDecor?
        switch state {
        case .text: stateDecor = text?.decor
        case .highlight: stateDecor = highlightDecor?.decor
        case .emphasis: stateDecor = emphasisDecor?.decor
        }
        var result = (stateDecor ?? TextDecor()).resolved(over: base)
        // Modern Text backgrounds belong to the whole caption/line; the
        // active and emphasis states can still request individual word chips.
        if text?.decor?.bgOn != nil || text?.decor?.borderOn != nil {
            if state == .text || stateDecor?.bgOn == nil {
                result.bgOn = state == .highlight && resolvedHighlight == "box"
            }
            if state == .text || stateDecor?.borderOn == nil { result.borderOn = false }
        }
        return result
    }

    func applyingSharedStyle(_ styles: [NamedTextStyle]) -> Self {
        guard let shared = styles.first(where: { $0.id.uuidString == sharedStyleID }) else { return self }
        var result = self
        result.decor = (decor ?? TextDecor()).merged(over: shared.decor)
        if let family = shared.fontFamily { result.font = fontOverride ?? family }
        return result
    }
}

nonisolated extension TagLineStyle {
    var legacyDecor: TextDecor {
        TextDecor(color: color, weight: bold ? "bold" : "regular", italic: italic, underline: underline,
                  strikethrough: resolvedStrikethrough, casing: uppercase ? "upper" : "asWritten", size: scale,
                  bgOn: resolvedBackground, bgColor: resolvedBackgroundColor, bgOpacity: resolvedBackgroundOpacity,
                  bgRadius: resolvedCornerRadius, bgPaddingX: 0.18, bgPaddingY: 0.18,
                  underlineColor: underlineColor, underlineThickness: underlineThickness)
    }

    func resolvedTextDecor(over tag: TextDecor? = nil) -> TextDecor {
        (decor ?? TextDecor()).resolved(over: (tag ?? TextDecor()).merged(over: legacyDecor))
    }
}

nonisolated extension TagStyle {
    var legacyDecor: TextDecor {
        TextDecor(bgOn: bgOn, bgColor: bgColor, bgOpacity: bgOpacity, bgRadius: cornerRadius,
                  bgPaddingX: 0.24, bgPaddingY: 0.24, alignment: alignment)
    }
    var boxDecor: TextDecor { (decor ?? TextDecor()).resolved(over: legacyDecor) }
    var lineDecor: TextDecor {
        var value = decor ?? TextDecor()
        value.bgOn = nil; value.bgColor = nil; value.bgOpacity = nil; value.bgRadius = nil
        value.borderOn = nil; value.bgPaddingX = nil; value.bgPaddingY = nil
        return value
    }
    func applyingSharedStyle(_ styles: [NamedTextStyle]) -> Self {
        guard let shared = styles.first(where: { $0.id.uuidString == sharedStyleID }) else { return self }
        var result = self
        result.decor = (decor ?? TextDecor()).merged(over: shared.decor)
        if let family = shared.fontFamily { result.name.font = name.fontOverride ?? family; result.description.font = description.fontOverride ?? family }
        return result
    }
}

nonisolated extension TextOverlayItem {
    var legacyDecor: TextDecor {
        TextDecor(color: fontcolor, weight: bold ? "bold" : "regular", italic: italic,
                  underline: resolvedUnderline, strikethrough: resolvedStrikethrough,
                  strokeOn: strokeColor != nil && strokeWidthEm > 0,
                  strokeWidth: strokeWidthEm * Double(fontsize) * 2, strokeColor: strokeColor, strokeOpacity: 1,
                  shadowOn: shadowOpacity > 0, shadowOpacity: shadowOpacity, shadowY: -0.05,
                  bgOn: boxOpacity > 0, bgColor: bgcolor ?? "#000000", bgOpacity: boxOpacity,
                  bgRadius: boxRadius ?? 4, bgPaddingX: 5 / Double(max(1, fontsize)),
                  bgPaddingY: 5 / Double(max(1, fontsize)), alignment: alignment == "left" ? "leading" : alignment == "right" ? "trailing" : "center")
    }
    var resolvedTextDecor: TextDecor { (decor ?? TextDecor()).resolved(over: legacyDecor) }
    func applyingSharedStyle(_ styles: [NamedTextStyle]) -> Self {
        var result = self
        if let shared = styles.first(where: { $0.id.uuidString == sharedStyleID }) {
            result.decor = (decor ?? TextDecor()).merged(over: shared.decor)
            if let family = shared.fontFamily { result.fontfamily = fontOverride ?? family }
        }
        result.tagStyle = tagStyle?.applyingSharedStyle(styles)
        return result
    }
}

nonisolated enum TextCasing {
    static func apply(_ text: String, casing: String?, firstWord: Bool = true) -> String {
        switch casing {
        case "upper": return text.uppercased()
        case "lower": return text.lowercased()
        case "title":
            let stops: Set<String> = ["a", "an", "and", "of", "the", "to"]
            var index = 0
            return text.components(separatedBy: " ").map { word in
                defer { if !word.isEmpty { index += 1 } }
                return !(firstWord && index == 0) && stops.contains(word.lowercased()) ? word.lowercased() : word.capitalized
            }.joined(separator: " ")
        default: return text
        }
    }
}

nonisolated extension TextOverlayItem {
    /// Project the layout-facing fields on a render copy, never the saved item.
    var textLayoutItem: Self {
        var result = self
        result.fontfamily = fontOverride ?? fontfamily
        guard decor != nil else { return result }
        let d = resolvedTextDecor
        result.fontfamily = fontOverride ?? fontfamily
        result.fontsize = max(1, Int(Double(fontsize) * (d.size ?? 1)))
        result.decor?.size = 1
        result.bold = d.weight == "bold" || d.weight == "black"
        result.italic = d.italic ?? false
        result.fontcolor = d.color ?? fontcolor
        result.bgcolor = d.bgColor
        result.boxOpacity = d.bgOn == true ? d.bgOpacity ?? 1 : 0
        result.alignment = d.alignment == "leading" ? "left" : d.alignment == "trailing" ? "right" : "center"
        // Casing after parsing keeps *highlight* delimiters meaningful.
        var first = true
        result.text = text.components(separatedBy: "\n").map { row in
            TextOverlayRenderer.parseMarkup(row).map { word in
                let cased = TextCasing.apply(word.text, casing: d.casing, firstWord: first)
                first = false
                return word.highlighted ? "*" + cased + "*" : cased
            }.joined(separator: " ")
        }.joined(separator: "\n")
        if design == "nameTag" { result.text = text }
        return result
    }
}

nonisolated extension TextDecor {
    var boxFields: TextDecor {
        TextDecor(bgOn: bgOn, bgColor: bgColor, bgOpacity: bgOpacity, bgRadius: bgRadius,
                  bgPaddingX: bgPaddingX, bgPaddingY: bgPaddingY, bgPerLine: bgPerLine,
                  borderOn: borderOn, borderWidth: borderWidth, borderColor: borderColor ?? color)
    }
}
