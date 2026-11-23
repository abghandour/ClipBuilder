import Foundation
import CoreGraphics

/// Frames a source range INTO a screen-crop area: the tracking camera
/// follows the people at the area's aspect ratio (so the fighters fill the
/// area instead of a 9:16 window), the result is scaled into the area's
/// bounding box and placed on a black 1080×1920 canvas. The caller masks
/// the canvas with the area's polygon. When nobody is visible the window
/// is a static crop at the same aspect, centered on the known face or source.
nonisolated enum AreaFramer {
    // Output/tracking changes must bump MultitrackRenderer.framingVersion.
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
    /// `tracking` supplies the pre-drawing picture for analysis only.
    static func frame(source: URL, start: Double, duration: Double,
                      tracking: (source: URL, start: Double)? = nil,
                      area: ScreenCropArea,
                      framingPlan: FramingPlan? = nil,
                      pictureWindow: FreeCropRect? = nil,
                      focusPortraits: [Data] = [],
                      avoidPortraits: [Data] = [],
                      fallbackCenter: (x: Double, y: Double)? = nil,
                      detectFallbackFace: Bool = false,
                      tuning: CenterStageService.Tuning = .fastAction,
                      centerStage: CenterStageService,
                      scratch: URL,
                      onFallback: (@Sendable () -> Void)? = nil,
                      log: @escaping @Sendable (String) -> Void) async throws -> URL {
        if let plan = framingPlan, plan.isStatic {
            return try await frame(source: source, start: start, duration: duration, area: area,
                window: plan.sourceWindow ?? FreeCropRect(), framingPlan: plan, scratch: scratch)
        }
        let timing = PerfSignpost.begin("AreaFraming", metadata: "tracking")
        defer { PerfSignpost.end(timing) }
        let box = pixelBounds(of: area)
        let output = scratch.appendingPathComponent("area_\(UUID().uuidString).mp4")
        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        let place = "pad=\(w):\(h):\(Int(box.minX)):\(Int(box.minY)):color=black,setsar=1,fps=30,format=yuv420p[vout]"

        // Tracking camera at the area's aspect — a bbox-sized clip.
        var fitted: URL?
        do {
            fitted = try await centerStage.reframeClip(source: source, start: start, duration: duration,
                                                       tracking: tracking,
                                                       focusPortraits: focusPortraits,
                                                       avoidPortraits: avoidPortraits,
                                                       tuning: tuning, frame: box.size, pictureWindow: pictureWindow, log: log)
            log(String(format: "Area \"%@\": tracking camera at %.0f×%.0f", area.name, box.width, box.height))
        } catch {
            try Task.checkCancellation()
            onFallback?()
            log("Area \"\(area.name)\": \(error) — resolving a static fallback window")
        }
        defer { if let fitted { try? FileManager.default.removeItem(at: fitted) } }

        var arguments: [String] = ["-y"]
        let filter: String
        if let fitted {
            arguments += ["-i", fitted.path]
            filter = "[0:v]scale=\(Int(box.width)):\(Int(box.height)),\(place)"
        } else {
            let size = await FFmpeg.dimensions(of: source)
            var detectedFace: CGRect?
            if detectFallbackFace {
                for offset in [0.0, 1.0] where offset < duration {
                    detectedFace = try? await CenterStageService.faceCenter(source: tracking?.source ?? source,
                        at: (tracking?.start ?? start) + offset)
                    try Task.checkCancellation()
                    if detectedFace != nil { break }
                }
                log("Area \"\(area.name)\": static fallback uses \(detectedFace != nil ? "clip face detection" : fallbackCenter != nil ? "roster portrait" : "feed center")")
            }
            var window = fallbackWindow(aspect: box.width / box.height,
                                        sourceSize: CGSize(width: size.width, height: size.height),
                                        center: detectedFace.map { (x: $0.midX, y: $0.midY) } ?? fallbackCenter)
            if let face = detectedFace {
                let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                let crop = CGRect(x: window.xFrac * bounds.width, y: window.yFrac * bounds.height,
                                  width: window.wFrac * bounds.width, height: window.hFrac * bounds.height)
                let pixels = CGRect(x: face.minX * bounds.width, y: face.minY * bounds.height,
                                    width: face.width * bounds.width, height: face.height * bounds.height)
                let guarded = FaceGuard.contain(crop, faces: [pixels], bounds: bounds)
                window = FreeCropRect(xFrac: guarded.minX / bounds.width, yFrac: guarded.minY / bounds.height,
                                      wFrac: guarded.width / bounds.width, hFrac: guarded.height / bounds.height)
            }
            if let pictureWindow { window = FocusFrame.fitting(window, inside: pictureWindow) }
            arguments += ["-ss", String(format: "%.3f", max(0, start)),
                          "-t", String(format: "%.3f", duration), "-i", source.path]
            if let plan = framingPlan {
                // Fit sees the source window before the fallback aspect crop discards its bars.
                let foreground = plan.fit == .blurredFill ? plan.sourceWindow ?? FreeCropRect() : window
                var inputs: [URL] = []
                filter = try fitFilter(area: area, window: foreground,
                    sourceSize: CGSize(width: size.width, height: size.height), plan: plan, extraInputs: &inputs)
                for input in inputs { arguments += ["-threads", "1", "-loop", "1", "-i", input.path] }
            } else {
                filter = "[0:v]" + staticFilter(area: area, window: window) + "[vout]"
            }
        }
        arguments += ["-filter_complex", filter, "-map", "[vout]", "-map", "0:a?",
                      "-t", String(format: "%.3f", duration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        log("Decode/encode: place framed area on output canvas")
        try await FFmpeg.run(arguments, timeout: 600)
        return output
    }

    /// Largest window of `aspect` inside the source, centered on the face when known.
    /// The center and result are source-frame fractions; edge faces clamp the window.
    static func fallbackWindow(aspect: Double, sourceSize: CGSize,
                               center: (x: Double, y: Double)?) -> FreeCropRect {
        let sourceAspect = max(1, sourceSize.width) / max(1, sourceSize.height)
        let targetAspect = max(0.0001, aspect)
        let w = min(1, targetAspect / sourceAspect)
        let h = min(1, sourceAspect / targetAspect)
        let x = min(1 - w, max(0, (center?.x ?? 0.5) - w / 2))
        let y = min(1 - h, max(0, (center?.y ?? 0.5) - h / 2))
        return FreeCropRect(xFrac: x, yFrac: y, wFrac: w, hFrac: h)
    }

    /// Like `frame`, but the camera replays an explicit path (crop
    /// rectangles as fractions of the source at the area's aspect, seconds
    /// from `start`) instead of tracking.
    static func frame(source: URL, start: Double, duration: Double,
                      area: ScreenCropArea, path: [CameraPathKeyframe],
                      pictureWindow: FreeCropRect? = nil,
                      centerStage: CenterStageService,
                      scratch: URL,
                      log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let timing = PerfSignpost.begin("AreaFraming", metadata: "path")
        defer { PerfSignpost.end(timing) }
        let box = pixelBounds(of: area)
        let output = scratch.appendingPathComponent("area_\(UUID().uuidString).mp4")
        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        let fitted = try await centerStage.reframeClip(source: source, start: start, duration: duration,
                                                       path: path, frame: box.size, pictureWindow: pictureWindow, log: log)
        defer { try? FileManager.default.removeItem(at: fitted) }
        log(String(format: "Area \"%@\": camera path with %d keyframes at %.0f×%.0f", area.name, path.count,
                   box.width, box.height))
        let filter = "[0:v]scale=\(Int(box.width)):\(Int(box.height)),"
            + "pad=\(w):\(h):\(Int(box.minX)):\(Int(box.minY)):color=black,setsar=1,fps=30,format=yuv420p[vout]"
        var arguments: [String] = ["-y", "-i", fitted.path,
                                   "-filter_complex", filter, "-map", "[vout]", "-map", "0:a?",
                                   "-t", String(format: "%.3f", duration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        log("Decode/encode: place framed area on output canvas")
        try await FFmpeg.run(arguments, timeout: 600)
        return output
    }

    /// Like `frame`, but the window is fixed: `window` (fractions of the
    /// source frame, at the area's aspect) is cropped out, scaled into the
    /// area's bounding box, and placed on the black canvas. No tracking.
    static func frame(source: URL, start: Double, duration: Double,
                      area: ScreenCropArea, window: FreeCropRect,
                      framingPlan: FramingPlan? = nil, scratch: URL) async throws -> URL {
        let timing = PerfSignpost.begin("AreaFraming", metadata: "static")
        defer { PerfSignpost.end(timing) }
        let output = scratch.appendingPathComponent("area_\(UUID().uuidString).mp4")
        var inputs: [URL] = []
        let filter: String
        if let plan = framingPlan {
            let size = await FFmpeg.dimensions(of: source)
            filter = try fitFilter(area: area, window: window,
                sourceSize: CGSize(width: size.width, height: size.height), plan: plan, extraInputs: &inputs)
        } else {
            filter = "[0:v]" + staticFilter(area: area, window: window) + "[vout]"
        }
        var arguments: [String] = ["-y",
                                   "-ss", String(format: "%.3f", max(0, start)),
                                   "-t", String(format: "%.3f", duration), "-i", source.path]
        for input in inputs { arguments += ["-threads", "1", "-loop", "1", "-i", input.path] }
        arguments += ["-filter_complex", filter, "-map", "[vout]", "-map", "0:a?",
                                   "-t", String(format: "%.3f", duration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        try await FFmpeg.run(arguments, timeout: 600)
        return output
    }

    /// The source window is fitted before any aspect crop, preserving the background pixels.
    static func fitFilter(area: ScreenCropArea, window: FreeCropRect, sourceSize: CGSize,
                          plan: FramingPlan, extraInputs: inout [URL]) throws -> String {
        let spec = FitSpec(sourceWindow: window, sourceSize: sourceSize, destination: pixelBounds(of: area),
            canvasSize: CGSize(width: RenderEngine.outputWidth, height: RenderEngine.outputHeight),
            fit: plan.fit, feather: plan.feather, blur: plan.blur)
        return try FitComposer.graph(spec, inputLabel: "0:v", outputLabel: "fit_area", extraInputs: &extraInputs)
            + ";[fit_area]fps=30[vout]"
    }

    /// Shared by standalone framing and the fused segment graph. Preserve
    /// crop rounding and crop → scale → pad → fps → pixel format order.
    static func staticFilter(area: ScreenCropArea, window: FreeCropRect) -> String {
        let box = pixelBounds(of: area)
        let w = RenderEngine.outputWidth
        let h = RenderEngine.outputHeight
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        let x = clamp(window.xFrac), y = clamp(window.yFrac)
        let cw = max(0.01, min(window.wFrac, 1 - x))
        let ch = max(0.01, min(window.hFrac, 1 - y))
        // Even crop sizes keep yuv420p happy before the scale.
        return String(format: "crop='2*floor(iw*%.5f/2)':'2*floor(ih*%.5f/2)':'iw*%.5f':'ih*%.5f',",
                            cw, ch, x, y)
            + "scale=\(Int(box.width)):\(Int(box.height)),"
            + "pad=\(w):\(h):\(Int(box.minX)):\(Int(box.minY)):color=black,setsar=1,fps=30,format=yuv420p"
    }

    /// A path stays in source seconds until the segment applies playback speed.
    /// crop evaluates w/h only at configuration, so sendcmd evaluates the same
    /// piecewise-linear expressions on EVERY frame (T is sendcmd's clock).
    /// x/y are evaluated by crop itself on each frame. No intermediate video.
    static func pathFilter(keyframes: [CameraPathKeyframe], source: CGSize,
                           area: ScreenCropArea, namespace: String = "area", framingPlan: FramingPlan? = nil,
                           transformInterpolation: Bool = false,
                           continuityGrid: ContinuityCameraGrid? = nil,
                           preserveSourceTiming: Bool = false) -> String {
        var path = TrackedPictureBounds.clamped(keyframes).sorted { $0.t < $1.t }
        let box = pixelBounds(of: area)
        let grid = transformInterpolation
            ? continuityGrid ?? ContinuityCameraGrid.choose(path: path, source: source, box: box.size) : nil
        if grid == .crop { path = ContinuityCameraGrid.resampled(path) }
        guard let first = path.first else { return "null" }
        func expression(_ value: (CameraPathKeyframe) -> Double, clock: String) -> String {
            func number(_ x: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), x) }
            // A sum of clamped ramps avoids nesting hundreds of if() calls
            // (ffmpeg's expression parser has a finite recursion depth).
            var terms = [number(value(first))]
            for index in path.indices.dropLast() {
                let a = path[index], b = path[index + 1]
                guard value(b) != value(a) else { continue }
                if b.t == a.t || grid != .crop && CameraKeyframes.isCut(path, at: index + 1) {
                    terms.append("(\(number(value(b) - value(a))))*gte(\(clock),\(number(b.t)))")
                    continue
                }
                terms.append("(\(number(value(b) - value(a))))*clip((\(clock)-\(number(a.t)))/\(number(b.t - a.t)),0,1)")
            }
            // The evaluator also recurses down addition nodes. Keep the sum
            // balanced so a minute-long path cannot hit its recursion limit.
            func sum(_ range: Range<Int>) -> String {
                if range.count == 1 { return terms[range.lowerBound] }
                let middle = range.lowerBound + range.count / 2
                return "(" + sum(range.lowerBound..<middle) + "+" + sum(middle..<range.upperBound) + ")"
            }
            return sum(terms.indices)
        }
        if transformInterpolation && grid != .crop {
            // Scale and translation are affine ramps, as in the native export:
            // w = 1/S, x = U/S, y = V/S, with S=lerp(1/w), U=lerp(x/w), V=lerp(y/w).
            // Scale BEFORE cropping so rounding a small source crop cannot
            // change the zoom. Crop on a half-output-pixel grid, then downsample;
            // full chroma prevents 4:2:0 from rounding the translated origin.
            let scale = expression({ 1 / $0.w }, clock: "t")
            let x = expression({ $0.x / $0.w }, clock: "t")
            let y = expression({ $0.y / $0.w }, clock: "t")
            let multiplier = grid == .single ? 1 : 2
            let width = multiplier * Int(box.width), height = multiplier * Int(box.height)
            let aspect = source.height / source.width
            var filter = "format=yuv444p,scale=w='max(\(width),round(\(width)*(\(scale))))':"
                + "h='max(\(height),round(\(width)*\(aspect)*(\(scale))))':eval=frame,"
                + "crop=\(width):\(height):x='\(width)*(\(x))':y='\(width)*\(aspect)*(\(y))':exact=1,"
                + "scale=\(Int(box.width)):\(Int(box.height))"
            if box != CGRect(x: 0, y: 0, width: RenderEngine.outputWidth, height: RenderEngine.outputHeight) {
                filter += ",pad=\(RenderEngine.outputWidth):\(RenderEngine.outputHeight):\(Int(box.minX)):\(Int(box.minY)):color=black"
            }
            // The segment applies speed then fps exactly once, as for an
            // untracked split clip. Framing never resamples the source clock.
            return filter + ",setsar=1,format=yuv420p"
        }
        let w = expression({ $0.w }, clock: "T"), h = expression({ $0.h }, clock: "T")
        let x = expression({ $0.x }, clock: "t"), y = expression({ $0.y }, clock: "t")
        let target = "crop@\(namespace)"
        let zooms = path.contains { abs($0.w - first.w) > 1e-9 || abs($0.h - first.h) > 1e-9 }
        var filter = ""
        if zooms {
            // Two escaping layers: the filter parser, then sendcmd's parser.
            let cropWidth = "2*floor((\(w))*W/2)", cropHeight = "2*floor((\(h))*H/2)"
            let width = (grid == .crop ? "max(2,\(cropWidth))" : cropWidth).replacingOccurrences(of: ",", with: "\\\\,")
            let height = (grid == .crop ? "max(2,\(cropHeight))" : cropHeight).replacingOccurrences(of: ",", with: "\\\\,")
            filter += "sendcmd=c='0 [expr] \(target) w \(width), [expr] \(target) h \(height);',"
        }
        filter += "\(target)='max(2,2*floor(iw*\(first.w)/2))':'max(2,2*floor(ih*\(first.h)/2))':x='iw*(\(x))':y='ih*(\(y))',"
        // Scaling the source crop to the box is still necessary at Full Screen;
        // only the redundant canvas pad disappears there.
        if let plan = framingPlan, plan.recipe?.fighterFocus == true {
            let width = Int(box.width), height = Int(box.height)
            if plan.fit == .blurredFill {
                let fit = FitSpec(sourceSize: box.size, destination: box, canvasSize: box.size,
                    fit: plan.fit, feather: plan.feather, blur: plan.blur)
                let radius = max(0, min(fit.blurRadius, Double(min(width, height)) / 2 - 1))
                let ramp = max(0.001, min(0.2, max(0, plan.feather)) * Double(width))
                filter += "split[\(namespace)_bg][\(namespace)_fg];"
                filter += "[\(namespace)_bg]scale=\(width):\(height):force_original_aspect_ratio=increase:eval=frame,"
                    + "crop=\(width):\(height),format=gbrp,boxblur=\(radius):1,eq=brightness=-0.25[\(namespace)_back];"
                filter += "[\(namespace)_fg]scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2:eval=frame,format=rgba"
                if plan.feather > 0 {
                    let alpha = "255*min(if(lt(W,\(width)),min(1,min(X,W-1-X)/\(ramp)),1),if(lt(H,\(height)),min(1,min(Y,H-1-Y)/\(ramp)),1))"
                    filter += ",geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='\(alpha)'"
                }
                filter += "[\(namespace)_front];[\(namespace)_back][\(namespace)_front]overlay=(W-w)/2:(H-h)/2:shortest=1"
            } else {
                filter += "scale=\(width):\(height):force_original_aspect_ratio=increase:eval=frame,crop=\(width):\(height)"
            }
        } else { filter += "scale=\(Int(box.width)):\(Int(box.height))" }
        if box != CGRect(x: 0, y: 0, width: RenderEngine.outputWidth, height: RenderEngine.outputHeight) {
            filter += ",pad=\(RenderEngine.outputWidth):\(RenderEngine.outputHeight):\(Int(box.minX)):\(Int(box.minY)):color=black"
        }
        // Paused saved paths keep rectangle interpolation, but sampling belongs
        // to the segment after speed, just as it does for tracked run paths.
        return filter + (transformInterpolation || preserveSourceTiming ? ",setsar=1,format=yuv420p" : ",setsar=1,fps=30,format=yuv420p")
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
