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

    var resolvedWeight: String { ["bold", "black"].contains(weight ?? "") ? weight! : "regular" }
    var resolvedStrokeWidth: Double { min(6, max(0, strokeWidth ?? 1)) }
    var resolvedLetterSpacing: Double { min(6, max(-2, letterSpacing ?? 0)) }
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
    }
}
