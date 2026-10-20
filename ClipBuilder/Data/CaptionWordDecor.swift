import Foundation

/// Optional fields keep old profiles intact and allow state decorations to inherit.
nonisolated struct CaptionWordDecor: Codable, Sendable, Hashable {
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var size: Double?
    var bgOn: Bool?
    var bgColor: String?
    var bgRadius: Double?

    var resolvedItalic: Bool { italic ?? false }
    var resolvedUnderline: Bool { underline ?? false }
    var resolvedStrikethrough: Bool { strikethrough ?? false }
    var resolvedBackground: Bool { bgOn ?? false }
    var resolvedRadius: Double { min(40, max(0, bgRadius ?? 6)) }

    // Synthesized Optional decoding uses decodeIfPresent for every field.
    enum CodingKeys: String, CodingKey {
        case italic, underline, strikethrough, size
        case bgOn = "bg_on"
        case bgColor = "bg_color"
        case bgRadius = "bg_radius"
    }
}
