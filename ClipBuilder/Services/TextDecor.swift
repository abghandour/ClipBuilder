import Foundation

/// Nil inherits; legacy payloads remain readable with synthesized decoding.
nonisolated struct TextDecor: Codable, Hashable, Sendable {
    var color: String?
    var gradientOn: Bool?
    var fillEndColor: String?
    var fillAngle: Double?
    var textOpacity: Double?
    var weight: String?
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var casing: String?
    var size: Double?
    var letterSpacing: Double?
    var lineHeight: Double?
    var strokeOn: Bool?
    var strokeWidth: Double?
    var strokeColor: String?
    var strokeOpacity: Double?
    var shadowOn: Bool?
    var shadowColor: String?
    var shadowOpacity: Double?
    var shadowX: Double?
    var shadowY: Double?
    var shadowBlur: Double?
    /// "soft" blurs, "hard" is one sharp copy, "extrude" stacks copies into a solid 3D wedge.
    var shadowStyle: String?
    var bgOn: Bool?
    var bgColor: String?
    var bgOpacity: Double?
    var bgRadius: Double?
    var bgPaddingX: Double?
    var bgPaddingY: Double?
    var bgPerLine: Bool?
    var borderOn: Bool?
    var borderWidth: Double?
    var borderColor: String?
    var alignment: String?
    var maxWidthFrac: Double?
    var underlineColor: String?
    var underlineThickness: Double?

    static let shadowStyles = ["soft", "hard", "extrude"]

    static let defaults = TextDecor(
        color: "#ffffff",
        fillAngle: 0,
        textOpacity: 1,
        weight: "regular",
        italic: false,
        underline: false,
        strikethrough: false,
        casing: "asWritten",
        size: 1,
        letterSpacing: 0,
        lineHeight: 1,
        strokeOn: false,
        strokeWidth: 1,
        strokeColor: "#000000",
        strokeOpacity: 0.86,
        shadowOn: false,
        shadowColor: "#000000",
        shadowOpacity: 0.75,
        shadowX: 0,
        shadowY: -0.08,
        shadowBlur: 0.15,
        shadowStyle: "soft",
        bgOn: false,
        bgColor: "#000000",
        bgOpacity: 1,
        bgRadius: 6,
        bgPaddingX: 0.125,
        bgPaddingY: 0.125,
        bgPerLine: false,
        borderOn: false,
        borderWidth: 2,
        alignment: "center")

    func merged(over base: TextDecor) -> TextDecor {
        var result = self
        result.color = color ?? base.color
        result.gradientOn = gradientOn ?? base.gradientOn
        result.fillEndColor = fillEndColor ?? base.fillEndColor
        result.fillAngle = fillAngle ?? base.fillAngle
        result.textOpacity = textOpacity ?? base.textOpacity
        result.weight = weight ?? base.weight
        result.italic = italic ?? base.italic
        result.underline = underline ?? base.underline
        result.strikethrough = strikethrough ?? base.strikethrough
        result.casing = casing ?? base.casing
        result.size = size ?? base.size
        result.letterSpacing = letterSpacing ?? base.letterSpacing
        result.lineHeight = lineHeight ?? base.lineHeight
        result.strokeOn = strokeOn ?? base.strokeOn
        result.strokeWidth = strokeWidth ?? base.strokeWidth
        result.strokeColor = strokeColor ?? base.strokeColor
        result.strokeOpacity = strokeOpacity ?? base.strokeOpacity
        result.shadowOn = shadowOn ?? base.shadowOn
        result.shadowColor = shadowColor ?? base.shadowColor
        result.shadowOpacity = shadowOpacity ?? base.shadowOpacity
        result.shadowX = shadowX ?? base.shadowX
        result.shadowY = shadowY ?? base.shadowY
        result.shadowBlur = shadowBlur ?? base.shadowBlur
        result.shadowStyle = shadowStyle ?? base.shadowStyle
        result.bgOn = bgOn ?? base.bgOn
        result.bgColor = bgColor ?? base.bgColor
        result.bgOpacity = bgOpacity ?? base.bgOpacity
        result.bgRadius = bgRadius ?? base.bgRadius
        result.bgPaddingX = bgPaddingX ?? base.bgPaddingX
        result.bgPaddingY = bgPaddingY ?? base.bgPaddingY
        result.bgPerLine = bgPerLine ?? base.bgPerLine
        result.borderOn = borderOn ?? base.borderOn
        result.borderWidth = borderWidth ?? base.borderWidth
        result.borderColor = borderColor ?? base.borderColor
        result.alignment = alignment ?? base.alignment
        result.maxWidthFrac = maxWidthFrac ?? base.maxWidthFrac
        result.underlineColor = underlineColor ?? base.underlineColor
        result.underlineThickness = underlineThickness ?? base.underlineThickness
        return result
    }

    func resolved(over base: TextDecor = .defaults) -> TextDecor {
        var value = merged(over: base).merged(over: .defaults)
        if let number = value.textOpacity { value.textOpacity = number.isFinite ? min(1, max(0, number)) : Self.defaults.textOpacity }
        if let number = value.strokeOpacity { value.strokeOpacity = number.isFinite ? min(1, max(0, number)) : Self.defaults.strokeOpacity }
        if let number = value.shadowOpacity { value.shadowOpacity = number.isFinite ? min(1, max(0, number)) : Self.defaults.shadowOpacity }
        if let number = value.bgOpacity { value.bgOpacity = number.isFinite ? min(1, max(0, number)) : Self.defaults.bgOpacity }
        if let number = value.strokeWidth { value.strokeWidth = number.isFinite ? min(6, max(0, number)) : Self.defaults.strokeWidth }
        if let number = value.borderWidth { value.borderWidth = number.isFinite ? min(6, max(0, number)) : Self.defaults.borderWidth }
        if let number = value.bgRadius { value.bgRadius = number.isFinite ? min(80, max(0, number)) : Self.defaults.bgRadius }
        if let number = value.bgPaddingX { value.bgPaddingX = number.isFinite ? min(3, max(0, number)) : Self.defaults.bgPaddingX }
        if let number = value.bgPaddingY { value.bgPaddingY = number.isFinite ? min(3, max(0, number)) : Self.defaults.bgPaddingY }
        if let number = value.shadowBlur { value.shadowBlur = number.isFinite ? min(3, max(0, number)) : Self.defaults.shadowBlur }
        if let number = value.shadowX { value.shadowX = number.isFinite ? min(3, max(-3, number)) : Self.defaults.shadowX }
        if let number = value.shadowY { value.shadowY = number.isFinite ? min(3, max(-3, number)) : Self.defaults.shadowY }
        if let number = value.size { value.size = number.isFinite ? min(4, max(0.1, number)) : Self.defaults.size }
        if let number = value.letterSpacing { value.letterSpacing = number.isFinite ? min(6, max(-2, number)) : Self.defaults.letterSpacing }
        if let number = value.lineHeight { value.lineHeight = number.isFinite ? min(2, max(0.8, number)) : Self.defaults.lineHeight }
        if let number = value.maxWidthFrac { value.maxWidthFrac = number.isFinite ? min(1, max(0.2, number)) : Self.defaults.maxWidthFrac }
        if value.gradientOn == false { value.fillEndColor = nil }
        if !TextDecor.shadowStyles.contains(value.shadowStyle ?? "") { value.shadowStyle = Self.defaults.shadowStyle }
        if let angle = value.fillAngle, !angle.isFinite { value.fillAngle = 0 }
        value.borderColor = value.borderColor ?? value.color
        return value
    }
}
