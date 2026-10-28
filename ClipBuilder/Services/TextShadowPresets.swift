import Foundation

/// Code-owned shadow looks. Applying one writes only the shadow fields, so
/// the rest of the decoration (fill, stroke, box) stays as the user set it.
nonisolated enum TextShadowPresets {
    struct Preset: Hashable, Sendable, Identifiable {
        var id: String { name }
        let name: String
        let help: String
        let shadow: TextDecor
    }

    static let all: [Preset] = [
        Preset(name: "Soft drop", help: "A gentle blurred shadow just below the letters.",
               shadow: TextDecor(shadowOn: true, shadowColor: "#000000", shadowOpacity: 0.75, shadowX: 0, shadowY: -0.08, shadowBlur: 0.15, shadowStyle: "soft")),
        Preset(name: "Lifted", help: "A wider, softer shadow that floats the text off the footage.",
               shadow: TextDecor(shadowOn: true, shadowColor: "#000000", shadowOpacity: 0.6, shadowX: 0, shadowY: -0.18, shadowBlur: 0.45, shadowStyle: "soft")),
        Preset(name: "Glow", help: "A centred halo in the shadow colour with no offset.",
               shadow: TextDecor(shadowOn: true, shadowColor: "#ffffff", shadowOpacity: 0.9, shadowX: 0, shadowY: 0, shadowBlur: 0.35, shadowStyle: "soft")),
        Preset(name: "Hard offset", help: "One sharp copy of the letters down and to the right.",
               shadow: TextDecor(shadowOn: true, shadowColor: "#000000", shadowOpacity: 1, shadowX: 0.05, shadowY: -0.05, shadowBlur: 0, shadowStyle: "hard")),
        Preset(name: "Retro 3D", help: "Solid block letters: copies stacked from the offset back to the text.",
               shadow: TextDecor(shadowOn: true, shadowColor: "#1d1d1f", shadowOpacity: 1, shadowX: 0.06, shadowY: -0.06, shadowBlur: 0, shadowStyle: "extrude")),
        Preset(name: "Long shadow", help: "A deep extruded wedge, the flat-design poster look.",
               shadow: TextDecor(shadowOn: true, shadowColor: "#000000", shadowOpacity: 0.35, shadowX: 0.25, shadowY: -0.25, shadowBlur: 0, shadowStyle: "extrude")),
    ]

    static let shadowKeys: [WritableKeyPath<TextDecor, Double?>] = [\.shadowOpacity, \.shadowX, \.shadowY, \.shadowBlur]

    /// Copies the preset's shadow fields over `stored`; everything else is untouched.
    static func apply(_ preset: Preset, to stored: TextDecor?) -> TextDecor {
        var result = stored ?? TextDecor()
        result.shadowOn = preset.shadow.shadowOn
        result.shadowColor = preset.shadow.shadowColor
        result.shadowStyle = preset.shadow.shadowStyle
        for key in shadowKeys { result[keyPath: key] = preset.shadow[keyPath: key] }
        return result
    }

    /// The preset whose shadow fields the resolved decoration matches, if any.
    static func matching(_ decor: TextDecor) -> Preset? {
        let resolved = decor.resolved()
        return all.first { preset in
            let candidate = apply(preset, to: TextDecor()).resolved()
            return candidate.shadowOn == resolved.shadowOn && candidate.shadowColor?.lowercased() == resolved.shadowColor?.lowercased()
                && candidate.shadowStyle == resolved.shadowStyle
                && shadowKeys.allSatisfy { abs((candidate[keyPath: $0] ?? 0) - (resolved[keyPath: $0] ?? 0)) < 0.001 }
        }
    }
}
