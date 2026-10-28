import Foundation

/// A resolved picture, including a layout snapshot independent of the layout library.
nonisolated enum FramingPlan: Codable, Hashable, Sendable {
    case `static`(window: FreeCropRect?, fit: Framing.Fit, feather: Double, blur: Double)
    case tracked(CropRecipe, region: FreeCropRect?, fit: Framing.Fit, feather: Double, blur: Double)
    case composed(layout: ScreenCropLayout, areas: [AreaSegment], fit: Framing.Fit)

    private enum Kind: String, Codable { case `static`, tracked, composed }
    private enum CodingKeys: String, CodingKey {
        case kind, window, recipe, region, fit, feather, blur, layout, areas
        case layoutName = "layout_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fit = try c.decodeIfPresent(Framing.Fit.self, forKey: .fit) ?? .fill
        switch try c.decode(Kind.self, forKey: .kind) {
        case .static:
            self = .static(window: try c.decodeIfPresent(FreeCropRect.self, forKey: .window), fit: fit,
                           feather: try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.08,
                           blur: try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0.5)
        case .tracked:
            self = .tracked(try c.decode(CropRecipe.self, forKey: .recipe),
                            region: try c.decodeIfPresent(FreeCropRect.self, forKey: .region), fit: fit,
                            feather: try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.08,
                            blur: try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0.5)
        case .composed:
            var layout = try c.decode(ScreenCropLayout.self, forKey: .layout)
            // ScreenCropLayout's file format deliberately omits its filename-based name.
            layout.name = try c.decode(String.self, forKey: .layoutName)
            self = .composed(layout: layout, areas: try c.decode([AreaSegment].self, forKey: .areas), fit: fit)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .static(window, fit, feather, blur):
            try c.encode(Kind.static, forKey: .kind)
            try c.encodeIfPresent(window, forKey: .window)
            try c.encode(fit, forKey: .fit)
            try c.encode(feather, forKey: .feather)
            try c.encode(blur, forKey: .blur)
        case let .tracked(recipe, region, fit, feather, blur):
            try c.encode(Kind.tracked, forKey: .kind)
            try c.encode(recipe, forKey: .recipe)
            try c.encodeIfPresent(region, forKey: .region)
            try c.encode(fit, forKey: .fit)
            try c.encode(feather, forKey: .feather)
            try c.encode(blur, forKey: .blur)
        case let .composed(layout, areas, fit):
            try c.encode(Kind.composed, forKey: .kind)
            try c.encode(layout, forKey: .layout)
            try c.encode(layout.name, forKey: .layoutName)
            try c.encode(areas, forKey: .areas)
            try c.encode(fit, forKey: .fit)
        }
    }
}

nonisolated extension FramingPlan {
    var isComposed: Bool { if case .composed = self { return true }; return false }

    func area(forTrack track: Int) -> ScreenCropArea? {
        guard case .composed(let layout, _, _) = self else { return nil }
        return layout.areas[safe: track]
    }
}
