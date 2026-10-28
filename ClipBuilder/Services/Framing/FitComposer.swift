import Foundation
import CoreGraphics

/// Geometry uses oriented source fractions and top-left canvas pixels.
nonisolated struct FitSpec: Sendable {
    var sourceWindow = FreeCropRect()
    var sourceSize: CGSize
    var destination: CGRect
    var canvasSize: CGSize
    var fit: Framing.Fit = .fill
    var feather: Double = 0.08
    var blur: Double = 0.5
    var mask: ScreenCropArea?

    static func intersection(_ a: FreeCropRect, _ b: FreeCropRect) -> FreeCropRect {
        let overlap = CGRect(x: a.xFrac, y: a.yFrac, width: a.wFrac, height: a.hFrac)
            .intersection(CGRect(x: b.xFrac, y: b.yFrac, width: b.wFrac, height: b.hFrac))
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return b }
        return FreeCropRect(xFrac: overlap.minX, yFrac: overlap.minY, wFrac: overlap.width, hFrac: overlap.height)
    }

    var window: CGRect {
        let x = min(0.99, max(0, sourceWindow.xFrac))
        let y = min(0.99, max(0, sourceWindow.yFrac))
        return CGRect(x: x, y: y, width: max(0.01, min(1 - x, sourceWindow.wFrac)),
                      height: max(0.01, min(1 - y, sourceWindow.hFrac)))
    }

    var pixels: CGRect {
        CGRect(x: window.minX * sourceSize.width, y: window.minY * sourceSize.height,
               width: window.width * sourceSize.width, height: window.height * sourceSize.height)
    }

    /// Even dimensions match the YUV export; placement remains centred in the destination.
    var foreground: CGRect {
        let scale = min(destination.width / max(1, pixels.width), destination.height / max(1, pixels.height))
        let width = min(destination.width, CGFloat(max(2, Int((pixels.width * scale).rounded()) & ~1)))
        let height = min(destination.height, CGFloat(max(2, Int((pixels.height * scale).rounded()) & ~1)))
        return CGRect(x: destination.midX - width / 2, y: destination.midY - height / 2, width: width, height: height)
    }

    var featherFraction: Double { min(0.2, max(0, feather.isFinite ? feather : 0)) }
    var featherPixels: CGFloat { featherFraction * destination.width }
    var horizontalBars: Bool { foreground.height < destination.height - 1 }
    var verticalBars: Bool { foreground.width < destination.width - 1 }
    var blurRadius: Double {
        min(60, max(2, destination.width * (0.005 + 0.035 * min(1, max(0, blur.isFinite ? blur : 0)))))
    }

    init(sourceWindow: FreeCropRect = FreeCropRect(), sourceSize: CGSize, destination: CGRect,
         canvasSize: CGSize, fit: Framing.Fit = .fill, feather: Double = 0.08, blur: Double = 0.5,
         mask: ScreenCropArea? = nil) {
        self.sourceWindow = sourceWindow
        self.sourceSize = sourceSize
        self.destination = destination
        self.canvasSize = canvasSize
        self.fit = fit
        self.feather = feather
        self.blur = blur
        self.mask = mask
    }
}

nonisolated enum FitComposer {
    /// Consumes one labelled video stream and produces a canvas-sized yuv420p stream.
    /// Labels may include brackets. Each call owns a unique internal namespace. Source
    /// windowing precedes the split: the background and foreground use the same timed
    /// pixels. Fill covers; blurred fill contains over a darkened, blurred cover copy.
    /// Feather affects only edges facing bars. Polygon masks use canvas coordinates.
    /// Appended PNGs must be bound as looped inputs, in order, starting at
    /// `inputOffset + extraInputs.count` (the count before this call). They are RGBA
    /// alpha masks; cache identity includes geometry, output size and feather.
    /// The caller owns stream timing and limits the output duration.
    static func graph(_ spec: FitSpec, inputLabel: String, outputLabel: String,
                      extraInputs: inout [URL], inputOffset: Int = 1) throws -> String {
        let prefix = "fit_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        func label(_ name: String) -> String { "[\(prefix)_\(name)]" }
        func stream(_ name: String) -> String { name.hasPrefix("[") ? name : "[\(name)]" }
        let width = max(2, Int(spec.destination.width)), height = max(2, Int(spec.destination.height))
        let canvasWidth = max(2, Int(spec.canvasSize.width)), canvasHeight = max(2, Int(spec.canvasSize.height))
        let crop = String(format: "crop=iw*%.9f:ih*%.9f:iw*%.9f:ih*%.9f,",
                          locale: Locale(identifier: "en_US_POSIX"), spec.window.width, spec.window.height, spec.window.minX, spec.window.minY)
        let window = spec.window == CGRect(x: 0, y: 0, width: 1, height: 1) ? "" : crop
        let cover = "scale=\(width):\(height):force_original_aspect_ratio=increase,crop=\(width):\(height),setsar=1"
        var filters: [String] = []
        if spec.fit == .fill || (!spec.horizontalBars && !spec.verticalBars) {
            filters.append("\(stream(inputLabel))\(window)\(cover)\(label("picture"))")
        } else {
            filters.append("\(stream(inputLabel))\(window)split=2\(label("bg_source"))\(label("fg_source"))")
            // Limit the box radius for tiny destinations; chroma uses RGB so it has the same size.
            let radius = min(spec.blurRadius, Double(min(width, height)) / 2 - 1)
            filters.append("\(label("bg_source"))\(cover),format=gbrp,boxblur=luma_radius=\(number(max(0, radius))):luma_power=1," +
                "colorchannelmixer=rr=0.75:gg=0.75:bb=0.75,format=rgba\(label("bg"))")
            let foreground = spec.foreground
            filters.append("\(label("fg_source"))scale=\(Int(foreground.width)):\(Int(foreground.height)),setsar=1,format=rgba\(label("fg"))")
            var foregroundLabel = label("fg")
            if spec.featherPixels > 0 {
                let maskIndex = inputOffset + extraInputs.count
                extraInputs.append(try ScreenCropStore.gradientMaskFile(spec: spec))
                filters.append("[\(maskIndex):v]format=rgba,alphaextract\(label("alpha"))")
                filters.append("\(foregroundLabel)\(label("alpha"))alphamerge\(label("feathered"))")
                foregroundLabel = label("feathered")
            }
            filters.append("\(label("bg"))\(foregroundLabel)overlay=x=\(Int(foreground.minX - spec.destination.minX)):" +
                "y=\(Int(foreground.minY - spec.destination.minY)):shortest=1:format=rgb\(label("picture"))")
        }
        filters.append("\(label("picture"))pad=\(canvasWidth):\(canvasHeight):\(Int(spec.destination.minX)):\(Int(spec.destination.minY)):color=black,setsar=1\(label("canvas"))")
        if let area = spec.mask {
            let maskIndex = inputOffset + extraInputs.count
            extraInputs.append(try ScreenCropStore.cachedMaskFile(for: area, width: canvasWidth, height: canvasHeight))
            filters.append("[\(maskIndex):v]format=gray\(label("polygon"))")
            filters.append("\(label("canvas"))format=rgba\(label("rgba"))")
            filters.append("\(label("rgba"))\(label("polygon"))alphamerge\(label("masked"))")
            filters.append("\(label("masked"))split=2\(label("masked_copy"))\(label("black_source"))")
            filters.append("\(label("black_source"))lutrgb=r=0:g=0:b=0:a=255\(label("black"))")
            filters.append("\(label("black"))\(label("masked_copy"))overlay=shortest=1,format=yuv420p\(stream(outputLabel))")
        } else {
            filters.append("\(label("canvas"))format=yuv420p\(stream(outputLabel))")
        }
        return filters.joined(separator: ";")
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

nonisolated extension FramingPlan {
    var fit: Framing.Fit {
        switch self {
        case .static(_, let fit, _, _), .tracked(_, _, let fit, _, _), .composed(_, _, let fit): fit
        }
    }
    var feather: Double {
        switch self {
        case .static(_, _, let value, _), .tracked(_, _, _, let value, _): value
        case .composed: 0.08
        }
    }
    var blur: Double {
        switch self {
        case .static(_, _, _, let value), .tracked(_, _, _, _, let value): value
        case .composed: 0.5
        }
    }
    var sourceWindow: FreeCropRect? {
        switch self {
        case .static(let window, _, _, _), .tracked(_, let window, _, _, _): window
        case .composed: nil
        }
    }
}
