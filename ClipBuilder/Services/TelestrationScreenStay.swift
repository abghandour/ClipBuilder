import CoreGraphics
import Foundation

/// Geometry only. Windows use source fractions; destinations use top-left
/// canvas pixels. No part of this evidence is saved in a timeline document.
nonisolated enum TelestrationScreenStay {
    static let fallbackMessage = "Drawing: stay follows the picture (framing not supported for a fixed stay)"

    nonisolated struct Frame: Codable, Equatable, Sendable {
        var window: FreeCropRect
        var picture: CGRect
        var area: CGRect
    }

    nonisolated struct Mapping: Codable, Equatable, Sendable {
        var frame: Frame
        var outputSize: CGSize
        var outputOrigin: CGPoint

        var picture: CGRect { frame.picture.offsetBy(dx: -outputOrigin.x, dy: -outputOrigin.y) }
        var painterRect: CGRect? { TelestrationScreenStay.painterRect(window: frame.window, picture: picture) }
    }

    static func painterRect(window: FreeCropRect, picture: CGRect) -> CGRect? {
        guard [window.xFrac, window.yFrac, window.wFrac, window.hFrac].allSatisfy(\.isFinite),
              window.wFrac > 0, window.hFrac > 0, picture.width > 0, picture.height > 0 else { return nil }
        return CGRect(x: picture.minX - window.xFrac / window.wFrac * picture.width,
                      y: picture.minY - window.yFrac / window.hFrac * picture.height,
                      width: picture.width / window.wFrac, height: picture.height / window.hFrac)
    }

    static func supported(_ clip: MultitrackRenderer.ResolvedClip) -> Bool {
        // A resolved run is one crop-and-scale per picture, even when its
        // originating recipe composes several pictures.
        let runPicture = clip.continuityTransform != nil && clip.cameraPath != nil
            && CenterStageContinuity.prepassArea(clip) != nil
        let resolvedArea = (clip.areaWindow != nil && (clip.fitArea != nil || clip.areaPathArea != nil))
            || (clip.cameraPath != nil && clip.areaPathSource != nil && clip.areaPathArea != nil)
        guard clip.framingPlan?.fit != .blurredFill,
              (clip.framingPlan?.isComposed != true || runPicture || resolvedArea),
              (clip.freeCrops?.count ?? 0) <= 1 else { return false }
        if clip.staticAreaFilter != nil, clip.areaWindow == nil, clip.areaPathSource == nil { return false }
        if !runPicture && !resolvedArea, let recipe = clip.framingPlan?.recipe,
           recipe.centerStage != true, recipe.fighterFocus != true { return false }
        return true
    }

    /// The rectangle occupied by the framed stream, and the area it fills.
    /// Area filters produce padded canvases; a free crop produces only its tile.
    static func surface(_ clip: MultitrackRenderer.ResolvedClip, canvas: CGSize) -> (area: CGRect, stream: CGRect)? {
        guard supported(clip) else { return nil }
        let full = CGRect(origin: .zero, size: canvas)
        if let crop = clip.freeCrops?.first {
            guard valid(crop.src) else { return nil }
            let d = crop.dst
            guard d.wFrac > 0, d.hFrac > 0, d.xFrac >= 0, d.yFrac >= 0,
                  d.xFrac + d.wFrac <= 1, d.yFrac + d.hFrac <= 1 else { return nil }
            let box = CGRect(x: (d.xFrac * canvas.width).rounded(), y: (d.yFrac * canvas.height).rounded(),
                width: max(2, (d.wFrac * canvas.width).rounded()), height: max(2, (d.hFrac * canvas.height).rounded()))
            return (box, box)
        }
        if let area = clip.areaPathArea ?? clip.fitArea ?? ScreenCropStore.area(reference: clip.screenCrop)
            ?? (clip.continuityTransform != nil ? CenterStageContinuity.prepassArea(clip) : nil) {
            return (AreaFramer.pixelBounds(of: area), full)
        }
        if clip.centerStage || clip.cameraPath != nil || clip.framingPlan != nil || clip.fillCanvas
            || clip.staticAreaFilter != nil || !clip.wide || clip.effectiveCropXFrac != nil { return (full, full) }
        let height = max(2, Int(canvas.height) / 3)
        let y = clip.effectivePosition == "center" ? height : clip.effectivePosition == "bottom" ? height * 2 : 0
        let box = CGRect(x: 0, y: y, width: Int(canvas.width), height: height)
        return (box, box)
    }

    /// Called after the hold prepass: a tracking hold must have the actual
    /// frozen path and area, never an estimated window from the next camera.
    static func frame(for hold: MultitrackRenderer.ResolvedClip, source: CGSize, canvas: CGSize) -> Frame? {
        guard hold.hold, source.width > 0, source.height > 0,
              let surface = surface(hold, canvas: canvas) else { return nil }
        if let crop = hold.freeCrops?.first {
            let window = pixelWindow(crop.src, source: source)
            let sx = surface.area.width / (window.wFrac * source.width)
            let sy = surface.area.height / (window.hFrac * source.height)
            guard abs(sx - sy) / max(sx, sy) <= 0.01 else { return nil }
            return Frame(window: window, picture: surface.area, area: surface.area)
        }
        if let path = hold.cameraPath, let first = path.first, hold.areaPathArea != nil {
            guard path.allSatisfy({ abs($0.x - first.x) < 1e-9 && abs($0.y - first.y) < 1e-9
                && abs($0.w - first.w) < 1e-9 && abs($0.h - first.h) < 1e-9 }) else { return nil }
            guard valid(.init(xFrac: first.x, yFrac: first.y, wFrac: first.w, hFrac: first.h)) else { return nil }
            var window = pixelWindow(.init(xFrac: first.x, yFrac: first.y, wFrac: first.w, hFrac: first.h),
                source: source, floorSize: true)
            if hold.continuityTransform == true && hold.continuityGrid != .crop {
                let grid = hold.continuityGrid == .single ? 1.0 : 2.0
                let width = grid * surface.area.width, height = grid * surface.area.height
                let aspect = source.height / source.width
                let scaledWidth = max(width, (width / first.w).rounded())
                let scaledHeight = max(height, (width * aspect / first.w).rounded())
                let x = max(0, min(scaledWidth - width, (width * first.x / first.w).rounded()))
                let y = max(0, min(scaledHeight - height, (width * aspect * first.y / first.w).rounded()))
                window = .init(xFrac: x / scaledWidth, yFrac: y / scaledHeight,
                    wFrac: width / scaledWidth, hFrac: height / scaledHeight)
            }
            if hold.framingPlan?.recipe?.fighterFocus == true { window = cover(window, source: source, destination: surface.area.size) }
            return Frame(window: window, picture: surface.area, area: surface.area)
        }
        // An unresolved camera or opaque filter is not a known crop.
        guard hold.cameraPath == nil, !hold.centerStage || hold.areaWindow != nil else { return nil }
        let window = FitSpec.intersection(hold.areaWindow ?? hold.framingPlan?.sourceWindow ?? FreeCropRect(),
                                         hold.contentWindow ?? FreeCropRect())
        guard valid(window) else { return nil }
        if hold.framingPlan != nil {
            guard hold.framingPlan?.isStatic == true || (hold.areaWindow != nil && hold.fitArea != nil) else { return nil }
            return Frame(window: cover(pixelWindow(window, source: source), source: source, destination: surface.area.size),
                         picture: surface.area, area: surface.area)
        }
        if hold.staticAreaFilter != nil {
            guard let window = hold.areaWindow else { return nil }
            return Frame(window: pixelWindow(window, source: source, floorSize: true), picture: surface.area, area: surface.area)
        }
        // A named area without a resolved filter would need tracking.
        guard hold.screenCrop == nil else { return nil }
        var shown = pixelWindow(window, source: source)
        if hold.fillCanvas { shown = cover(shown, source: source, destination: surface.area.size) }
        if hold.wide, let fraction = hold.effectiveCropXFrac {
            let width = min(shown.wFrac, shown.hFrac * source.height * canvas.width / canvas.height / source.width)
            shown.xFrac += (shown.wFrac - width) * min(1, max(0, fraction))
            shown.wFrac = width
            shown = pixelWindow(shown, source: source)
        }
        let size = CGSize(width: shown.wFrac * source.width, height: shown.hFrac * source.height)
        let scale = min(surface.area.width / size.width, surface.area.height / size.height)
        let picture = CGRect(x: surface.area.midX - (size.width * scale).rounded() / 2,
                             y: surface.area.midY - (size.height * scale).rounded() / 2,
                             width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        return Frame(window: shown, picture: picture, area: surface.area)
    }

    static func mapping(hold: Frame, following: MultitrackRenderer.ResolvedClip, canvas: CGSize) -> Mapping? {
        guard let surface = surface(following, canvas: canvas), surface.area == hold.area else { return nil }
        return Mapping(frame: hold, outputSize: surface.stream.size, outputOrigin: surface.stream.origin)
    }

    private static func valid(_ window: FreeCropRect) -> Bool {
        [window.xFrac, window.yFrac, window.wFrac, window.hFrac].allSatisfy(\.isFinite)
            && window.xFrac >= 0 && window.yFrac >= 0 && window.wFrac > 0 && window.hFrac > 0
            && window.xFrac + window.wFrac <= 1.000001 && window.yFrac + window.hFrac <= 1.000001
    }

    private static func pixelWindow(_ window: FreeCropRect, source: CGSize, floorSize: Bool = false) -> FreeCropRect {
        func even(_ value: Double) -> Double { floor((floorSize ? floor(value) : value.rounded()) / 2) * 2 }
        func origin(_ value: Double) -> Double { floor(value.rounded() / 2) * 2 }
        let w = max(2, even(window.wFrac * source.width)), h = max(2, even(window.hFrac * source.height))
        let x = max(0, min(source.width - w, origin(window.xFrac * source.width)))
        let y = max(0, min(source.height - h, origin(window.yFrac * source.height)))
        return .init(xFrac: x / source.width, yFrac: y / source.height, wFrac: w / source.width, hFrac: h / source.height)
    }

    private static func cover(_ window: FreeCropRect, source: CGSize, destination: CGSize) -> FreeCropRect {
        let width = window.wFrac * source.width, height = window.hFrac * source.height
        let scale = max(destination.width / width, destination.height / height)
        let w = destination.width / scale / source.width, h = destination.height / scale / source.height
        return .init(xFrac: window.xFrac + (window.wFrac - w) / 2,
                     yFrac: window.yFrac + (window.hFrac - h) / 2, wFrac: w, hFrac: h)
    }
}
