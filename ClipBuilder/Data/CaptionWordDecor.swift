import Foundation

/// Optional fields keep old profiles intact and allow state decorations to inherit.
nonisolated struct CaptionWordDecor: Codable, Sendable, Hashable {
    var decor: TextDecor?
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var size: Double?
    var bgOn: Bool?
    var bgColor: String?
    var bgRadius: Double?
    // Per-state typography; nil inherits the Text state (and, for Text, the
    // style's whole-caption fields from before states had their own).
    var weight: String?
    var strokeWidth: Double?
    var letterSpacing: Double?
    var shadow: Bool?
    /// Fit an emphasis page on one baseline, preserving the state size ratio.
    /// Nil uses historical wrapping; below this scale the page wraps normally.
    var fitLineMinimumScale: Double?
    /// Nil inherits the page's highlight hold; false ends at the word clock.
    var highlightHold: Bool?
    /// False keeps an emphasis word in its own colour while it is spoken;
    /// nil takes the spoken colour, as before.
    var takesHighlightColor: Bool?

    var resolvedFitLineMinimumScale: Double? {
        guard let value = fitLineMinimumScale, value.isFinite else { return nil }
        return min(1, max(0.25, value))
    }

    var resolvedWeight: String { ["bold", "black"].contains(weight ?? "") ? weight! : "regular" }
    var resolvedStrokeWidth: Double { min(6, max(0, strokeWidth ?? 1)) }
    var resolvedLetterSpacing: Double { min(TextDecor.letterSpacingRange.upperBound, max(TextDecor.letterSpacingRange.lowerBound, letterSpacing ?? 0)) }
    var resolvedShadow: Bool { shadow ?? false }

    var resolvedItalic: Bool { italic ?? false }
    var resolvedUnderline: Bool { underline ?? false }
    var resolvedStrikethrough: Bool { strikethrough ?? false }
    var resolvedBackground: Bool { bgOn ?? false }
    var resolvedRadius: Double { min(40, max(0, bgRadius ?? 6)) }

    // Synthesized Optional decoding uses decodeIfPresent for every field.
    enum CodingKeys: String, CodingKey {
        case decor = "decor"
        case italic, underline, strikethrough, size
        case bgOn = "bg_on"
        case bgColor = "bg_color"
        case bgRadius = "bg_radius"
        case weight
        case strokeWidth = "stroke_width"
        case letterSpacing = "letter_spacing"
        case shadow
        case fitLineMinimumScale = "fit_line_minimum_scale"
        case highlightHold = "highlight_hold"
        case takesHighlightColor = "takes_highlight_color"
    }
}
