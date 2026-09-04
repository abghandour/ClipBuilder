import Foundation
import CoreGraphics

/// Frames a source range INTO a screen-crop area: the tracking camera
/// follows the people at the area's aspect ratio (so the fighters fill the
/// area instead of a 9:16 window), the result is scaled into the area's
/// bounding box and placed on a black 1080×1920 canvas. The caller masks
/// the canvas with the area's polygon. When nobody is visible the window
/// is a static center crop at the same aspect.
nonisolated enum AreaFramer {
    /// The area's bounding box in output pixels, rounded to even sizes
    /// (encoders and `pad` want even dimensions).
    static func pixelBounds(of area: ScreenCropArea) -> CGRect {
        let box = area.bounds
        let width = Double(RenderEngine.outputWidth)
        let height = Double(RenderEngine.outputHeight)
        func even(_ value: Double) -> Int { max(2, Int(value.rounded()) & ~1) }
        let w = even(box.w * width)
        let h = even(box.h * height)
        let x = min(Int((box.x * width).rounded()) & ~1, RenderEngine.outputWidth - w)
        let y = min(Int((box.y * height).rounded()) & ~1, RenderEngine.outputHeight - h)
        return CGRect(x: max(0, x), y: max(0, y), width: w, height: h)
    }

    /// A 1080×1920 clip (audio kept) with `[start, start+duration]` of
    /// `source` framed into `area`'s bounding box, black elsewhere.
    static func frame(source: URL, start: Double, duration: Double,
                      area: ScreenCropArea,
                      focusPortraits: [Data] = [],
                      avoidPortraits: [Data] = [],
                      tuning: CenterStageService.Tuning = .fastAction,
                      centerStage: CenterStageService,
                      scratch: URL,
                      log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let box = pixelBounds(of: area)
        let output = scratch.appendingPathComponent("area_\(UUID().uuidString).mp4")
        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        let place = "pad=\(w):\(h):\(Int(box.minX)):\(Int(box.minY)):color=black,setsar=1,fps=30,format=yuv420p[vout]"

        // Tracking camera at the area's aspect — a bbox-sized clip.
        var fitted: URL?
        do {
            fitted = try await centerStage.reframeClip(source: source, start: start, duration: duration,
                                                       focusPortraits: focusPortraits,
                                                       avoidPortraits: avoidPortraits,
                                                       tuning: tuning, frame: box.size, log: log)
            log(String(format: "Area \"%@\": tracking camera at %.0f×%.0f", area.name, box.width, box.height))
        } catch {
            log("Area \"\(area.name)\": \(error) — using a static center window")
        }
        defer { if let fitted { try? FileManager.default.removeItem(at: fitted) } }

        var arguments: [String] = ["-y"]
        let filter: String
        if let fitted {
            arguments += ["-i", fitted.path]
            filter = "[0:v]scale=\(Int(box.width)):\(Int(box.height)),\(place)"
        } else {
            let aspect = box.width / box.height
            arguments += ["-ss", String(format: "%.3f", max(0, start)),
                          "-t", String(format: "%.3f", duration), "-i", source.path]
            // Largest window of the area's aspect that fits the source,
            // centered — crop's default x/y center it.
            filter = String(format: "[0:v]crop='if(gt(iw/ih,%.5f),ih*%.5f,iw)':'if(gt(iw/ih,%.5f),ih,iw/%.5f)',",
                            aspect, aspect, aspect, aspect)
                + "scale=\(Int(box.width)):\(Int(box.height)),\(place)"
        }
        arguments += ["-filter_complex", filter, "-map", "[vout]", "-map", "0:a?",
                      "-t", String(format: "%.3f", duration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        try await FFmpeg.run(arguments, timeout: 600)
        return output
    }

    /// Like `frame`, but the window is fixed: `window` (fractions of the
    /// source frame, at the area's aspect) is cropped out, scaled into the
    /// area's bounding box, and placed on the black canvas. No tracking.
    static func frame(source: URL, start: Double, duration: Double,
                      area: ScreenCropArea, window: FreeCropRect,
                      scratch: URL) async throws -> URL {
        let box = pixelBounds(of: area)
        let output = scratch.appendingPathComponent("area_\(UUID().uuidString).mp4")
        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        let x = clamp(window.xFrac), y = clamp(window.yFrac)
        let cw = max(0.01, min(window.wFrac, 1 - x))
        let ch = max(0.01, min(window.hFrac, 1 - y))
        // Even crop sizes keep yuv420p happy before the scale.
        let filter = String(format: "[0:v]crop='2*floor(iw*%.5f/2)':'2*floor(ih*%.5f/2)':'iw*%.5f':'ih*%.5f',",
                            cw, ch, x, y)
            + "scale=\(Int(box.width)):\(Int(box.height)),"
            + "pad=\(w):\(h):\(Int(box.minX)):\(Int(box.minY)):color=black,setsar=1,fps=30,format=yuv420p[vout]"
        var arguments: [String] = ["-y",
                                   "-ss", String(format: "%.3f", max(0, start)),
                                   "-t", String(format: "%.3f", duration), "-i", source.path,
                                   "-filter_complex", filter, "-map", "[vout]", "-map", "0:a?",
                                   "-t", String(format: "%.3f", duration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        try await FFmpeg.run(arguments, timeout: 600)
        return output
    }

    /// The largest window of the area's aspect that fits a source of
    /// `sourceSize`, centered — the starting point for a hand-placed window.
    static func defaultWindow(for area: ScreenCropArea, sourceSize: CGSize) -> FreeCropRect {
        let box = pixelBounds(of: area)
        let areaAspect = box.width / max(1, box.height)
        let sourceAspect = sourceSize.width / max(1, sourceSize.height)
        if sourceAspect > areaAspect {
            let w = areaAspect / sourceAspect
            return FreeCropRect(xFrac: (1 - w) / 2, yFrac: 0, wFrac: w, hFrac: 1)
        } else {
            let h = sourceAspect / areaAspect
            return FreeCropRect(xFrac: 0, yFrac: (1 - h) / 2, wFrac: 1, hFrac: h)
        }
    }
}
