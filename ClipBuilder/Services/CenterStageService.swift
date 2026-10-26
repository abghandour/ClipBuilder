import AVFoundation
import CoreImage
import ImageIO
import Vision
import Synchronization

/// Compact appearance fingerprint: a normalized 4×4×4 RGB histogram of a
/// person's box. Cheap enough to compute for every tracked frame, and
/// discriminative enough to tell the subjects apart from a referee or
/// staff by outfit — which is what identity-focused tracking needs.
nonisolated struct AppearanceSignature: Sendable {
    fileprivate static let bins = 4
    var histogram: [Double]   // sums to 1

    /// L1 distance ∈ [0, 2]; same outfit across frames stays well below 1.
    static func distance(_ a: AppearanceSignature, _ b: AppearanceSignature) -> Double {
        zip(a.histogram, b.histogram).reduce(0) { $0 + abs($1.0 - $1.1) }
    }

    /// From a JPEG crop (a person-marker portrait).
    init?(jpeg: Data) {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(cgImage: cg)
    }

    /// From a normalized top-left sub-rect of a display-oriented image.
    init?(cgImage: CGImage, normalizedRect rect: CGRect) {
        let pixels = CGRect(x: rect.minX * CGFloat(cgImage.width),
                            y: rect.minY * CGFloat(cgImage.height),
                            width: rect.width * CGFloat(cgImage.width),
                            height: rect.height * CGFloat(cgImage.height))
        guard let cropped = cgImage.cropping(to: pixels) else { return nil }
        self.init(cgImage: cropped)
    }

    init?(cgImage cg: CGImage) {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var counts = [Double](repeating: 0, count: Self.bins * Self.bins * Self.bins)
        var offset = 0
        for _ in 0..<(side * side) {
            let r = Int(pixels[offset]) * Self.bins / 256
            let g = Int(pixels[offset + 1]) * Self.bins / 256
            let b = Int(pixels[offset + 2]) * Self.bins / 256
            counts[(r * Self.bins + g) * Self.bins + b] += 1
            offset += 4
        }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        histogram = counts.map { $0 / total }
    }

    /// From a detected box on the tracker's raw BGRA frame. `displayRect`
    /// is top-left-origin normalized in upright display space; it's mapped
    /// back into the buffer's storage orientation before sampling.
    init?(pixelBuffer: CVPixelBuffer, displayRect: CGRect,
          orientation: CGImagePropertyOrientation) {
        let rect = Self.bufferRect(fromDisplay: displayRect, orientation: orientation)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let x0 = max(0, Int(rect.minX * CGFloat(width)))
        let x1 = min(width, Int(rect.maxX * CGFloat(width)))
        let y0 = max(0, Int(rect.minY * CGFloat(height)))
        let y1 = min(height, Int(rect.maxY * CGFloat(height)))
        guard x1 > x0, y1 > y0 else { return nil }
        // A person box needs ~hundreds of samples, not every pixel.
        let strideX = max(1, (x1 - x0) / 24)
        let strideY = max(1, (y1 - y0) / 24)
        var counts = [Double](repeating: 0, count: Self.bins * Self.bins * Self.bins)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let p = y * bytesPerRow + x * 4
                let b = Int(pointer[p]) * Self.bins / 256
                let g = Int(pointer[p + 1]) * Self.bins / 256
                let r = Int(pointer[p + 2]) * Self.bins / 256
                counts[(r * Self.bins + g) * Self.bins + b] += 1
                x += strideX
            }
            y += strideY
        }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        histogram = counts.map { $0 / total }
    }

    /// Inverse of the display-orientation mapping, for normalized
    /// top-left-origin rects.
    fileprivate static func bufferRect(fromDisplay rect: CGRect,
                                   orientation: CGImagePropertyOrientation) -> CGRect {
        switch orientation {
        case .down:
            return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY,
                          width: rect.width, height: rect.height)
        case .right:
            return CGRect(x: rect.minY, y: 1 - rect.maxX,
                          width: rect.height, height: rect.width)
        case .left:
            return CGRect(x: 1 - rect.maxY, y: rect.minX,
                          width: rect.height, height: rect.width)
        default:
            return rect
        }
    }
}

/// "Center Stage" auto-reframe: renders a widescreen clip range as 9:16 by
/// tracking the people on screen with on-device Vision and driving a virtual
/// camera (pan + zoom, smoothed with a dead-zone) that keeps them centered.
/// Rendering uses AVFoundation transform ramps, so the pan/zoom is
/// hardware-accelerated and the clip's audio rides along untouched.
actor CenterStageService {
    struct CenterStageError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    /// Every knob of the virtual camera in one place — how often it looks,
    /// how eagerly it moves, and how tight it dares to zoom. Presets trade
    /// cinematic smoothness against keeping fast-moving subjects in frame.
    struct Tuning: Sendable {
        /// Analysis cadence: how often the tracker looks at a frame.
        var analysisInterval: Double
        /// Keyframe cadence for the exported camera path.
        var keyframeInterval: Double
        /// Exponential smoothing per analyzed frame (higher = snappier).
        var smoothing: Double
        /// Ignore target moves smaller than this fraction of the frame width.
        var deadZoneWidth: Double
        /// Ignore zoom changes smaller than this fraction of the crop height.
        var deadZoneZoom: Double
        /// The camera never zooms tighter than this fraction of frame height.
        var minCropHeightFraction: Double
        /// Horizontal breathing room around the people (1 = none).
        var padding: Double

        /// Normalize smoothing to elapsed time and sample the keyframe clock
        /// independently of detection cadence (used by conversation tracking).
        var timeBasedSmoothing = false

        /// Slow, cinematic drift — interviews, posed footage.
        static let smooth = Tuning(analysisInterval: 0.15, keyframeInterval: 0.4,
                                   smoothing: 0.10, deadZoneWidth: 0.06,
                                   deadZoneZoom: 0.08, minCropHeightFraction: 0.6,
                                   padding: 1.4)
        /// Calm, face-safe motion inside a podcast feed.
        static let conversation = Tuning(analysisInterval: 0.25, keyframeInterval: 0.3,
                                         smoothing: 0.12, deadZoneWidth: 0.05,
                                         deadZoneZoom: 0.08, minCropHeightFraction: 0.6,
                                         padding: 1.35, timeBasedSmoothing: true)
        /// The long-standing defaults.
        static let balanced = Tuning(analysisInterval: 0.1, keyframeInterval: 0.3,
                                     smoothing: 0.18, deadZoneWidth: 0.04,
                                     deadZoneZoom: 0.06, minCropHeightFraction: 0.55,
                                     padding: 1.35)
        /// Fast action (fights, sparring): looks twice as often, reacts hard,
        /// and zooms out further so quick movers stay inside the frame.
        static let fastAction = Tuning(analysisInterval: 0.05, keyframeInterval: 0.15,
                                       smoothing: 0.38, deadZoneWidth: 0.015,
                                       deadZoneZoom: 0.03, minCropHeightFraction: 0.72,
                                       padding: 1.5)

        static func named(_ name: String) -> Tuning {
            switch name {
            case "conversation": return .conversation
            case "smooth": return .smooth
            case "fast": return .fastAction
            default: return .balanced
            }
        }
    }

    private nonisolated struct Target {
        var time: Double       // relative to the clip start
        var union: CGRect      // normalized, top-left origin
        var tracked: Bool      // false = no matching people found this frame
        var faces: [CGRect] = [] // normalized, top-left; selected subjects only
        var inFocus = true     // false = outside the picked people's ranges
    }

    private struct Keyframe {
        var time: Double
        var crop: CGRect       // source pixels, top-left origin
    }

    /// Everything about a source the passes need: the asset, its video
    /// track, and the upright display geometry.
    private struct SourceInfo {
        var asset: AVURLAsset
        var track: AVAssetTrack
        var size: CGSize
        var preferredTransform: CGAffineTransform
        var displayOrigin: CGPoint
    }

    /// `requireWide` = the classic 9:16 reframe, which only makes sense on
    /// landscape footage; area framing (any target aspect) accepts anything.
    private func loadSource(_ url: URL, requireWide: Bool = true) async throws -> SourceInfo {
        let asset = try await DriveLocalAsset.make(url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CenterStageError(message: "The file has no video track.")
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let size = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        guard !requireWide || size.width > size.height else {
            throw CenterStageError(message: "Center Stage needs widescreen (landscape) footage.")
        }
        return SourceInfo(asset: asset, track: track, size: size,
                          preferredTransform: preferredTransform,
                          displayOrigin: displayRect.origin)
    }

    // MARK: - Entry points

    /// Reframe `[start, start+duration]` of a widescreen source into a 9:16
    /// clip at `output`. The camera frames the union of all detected people;
    /// `focusRanges` (clip-relative) optionally mark when the people the user
    /// picked are on screen — outside those ranges the camera eases back to
    /// the full frame instead of chasing whoever happens to be visible.
    /// `frame` is the output size (default 1080×1920): a screen-crop area's
    /// bounding box makes the camera track people at THAT aspect, so the
    /// footage fills the area instead of a 9:16 window.
    // Output/tracking changes must bump MultitrackRenderer.framingVersion.
    func reframeClip(source: URL, start: Double, duration: Double,
                     focusRanges: [(start: Double, end: Double)] = [],
                     focusPortraits: [Data] = [],
                     avoidPortraits: [Data] = [],
                     hints: [(time: Double, crop: CGRect)] = [],
                     tuning: Tuning = .balanced,
                     frame: CGSize? = nil,
                     log: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        let emit = log ?? { _ in }
        let renderSize = frame ?? Self.defaultRenderSize
        let info = try await loadSource(source, requireWide: frame == nil)

        // Rotated sources (portrait-stored with a rotation flag) need Vision
        // told the display orientation, or people are hunted in sideways
        // frames and the boxes come back in the wrong coordinate space.
        let targets = try await trackPeople(asset: info.asset, track: info.track,
                                            start: start, duration: duration,
                                            focusRanges: focusRanges,
                                            focusPortraits: focusPortraits,
                                            avoidPortraits: avoidPortraits,
                                            orientation: Self.displayOrientation(of: info.preferredTransform),
                                            tuning: tuning, log: emit)
        let analyzed = targets.filter(\.inFocus)
        let trackedShare = analyzed.isEmpty ? 0
            : Double(analyzed.filter(\.tracked).count) / Double(analyzed.count)
        emit(String(format: "Center Stage: people visible in %.0f%% of the clip", trackedShare * 100))
        // Nobody to track means the camera would chase a stale default box —
        // bail so the caller's fallback (static auto-crop) handles the clip.
        guard trackedShare >= 0.1 else {
            throw CenterStageError(message: String(
                format: "people visible in only %.0f%% of the clip", trackedShare * 100))
        }

        let keyframes = cameraPath(from: targets, size: info.size, duration: duration,
                                   tuning: tuning, hints: hints,
                                   aspect: renderSize.width / renderSize.height)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("centerstage_\(UUID().uuidString).mp4")
        log?("Encode: Center Stage camera path export")
        try await export(asset: info.asset, track: info.track, size: info.size,
                         preferredTransform: info.preferredTransform,
                         displayOrigin: info.displayOrigin,
                         start: start, duration: duration,
                         keyframes: keyframes, renderSize: renderSize, output: output)
        return output
    }

    static var defaultRenderSize: CGSize {
        CGSize(width: RenderEngine.outputWidth, height: RenderEngine.outputHeight)
    }

    /// Reframe `[start, start+duration]` using a precomputed camera path
    /// (clip-relative, normalized keyframes) — skips the tracking pass, so
    /// the render is just the hardware export.
    func reframeClip(source: URL, start: Double, duration: Double,
                     path: [CameraPathKeyframe],
                     frame: CGSize? = nil,
                     log: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        guard path.count >= 2 else {
            throw CenterStageError(message: "The stored camera path is too short to render.")
        }
        let info = try await loadSource(source, requireWide: frame == nil)
        let keyframes = path.map { keyframe in
            Keyframe(time: keyframe.t,
                     crop: CGRect(x: keyframe.x * info.size.width,
                                  y: keyframe.y * info.size.height,
                                  width: keyframe.w * info.size.width,
                                  height: keyframe.h * info.size.height))
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("centerstage_\(UUID().uuidString).mp4")
        log?("Encode: Center Stage camera path export")
        try await export(asset: info.asset, track: info.track, size: info.size,
                         preferredTransform: info.preferredTransform,
                         displayOrigin: info.displayOrigin,
                         start: start, duration: duration,
                         keyframes: keyframes, renderSize: frame ?? Self.defaultRenderSize, output: output)
        return output
    }

    /// Pass 1 only: track people over `[start, start+duration]` and return
    /// the smoothed camera path as normalized keyframes (crop rect as
    /// fractions of the source frame, top-left origin, times relative to
    /// `start`), plus how much of the range had people visible. No render.
    func cameraPath(source: URL, start: Double, duration: Double,
                    focusPortraits: [Data] = [],
                    avoidPortraits: [Data] = [],
                    hints: [(time: Double, crop: CGRect)] = [],
                    tuning: Tuning = .balanced,
                    aspect: Double = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)) async throws
        -> (keyframes: [CameraPathKeyframe], trackedShare: Double) {
        let info = try await loadSource(source)
        let targets = try await trackPeople(asset: info.asset, track: info.track,
                                            start: start, duration: duration,
                                            focusRanges: [],
                                            focusPortraits: focusPortraits,
                                            avoidPortraits: avoidPortraits,
                                            orientation: Self.displayOrientation(of: info.preferredTransform),
                                            tuning: tuning)
        let trackedShare = targets.isEmpty ? 0
            : Double(targets.filter(\.tracked).count) / Double(targets.count)
        let keyframes = cameraPath(from: targets, size: info.size, duration: duration,
                                   tuning: tuning, hints: hints, aspect: aspect)
        let normalized = keyframes.map { keyframe in
            CameraPathKeyframe(t: keyframe.time,
                               x: keyframe.crop.minX / info.size.width,
                               y: keyframe.crop.minY / info.size.height,
                               w: keyframe.crop.width / info.size.width,
                               h: keyframe.crop.height / info.size.height)
        }
        return (normalized, trackedShare)
    }

    /// Track a feed directly from decoded source buffers. Vision and FaceGuard
    /// see only its picture; the returned path/face boxes use full-frame fractions.
    func cameraPath(source: URL, start: Double, duration: Double, region: FreeCropRect,
                    tuning: Tuning = .conversation, aspect: Double,
                    fallbackCenter: AreaFocus? = nil,
                    log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> FeedCameraPath {
        let info = try await loadSource(source, requireWide: false)
        let region = Self.validRegion(region)
        let samples = Mutex<[FeedPathSample]>([])
        let targets: [Target]
        var reusable = true
        do {
            targets = try await trackPeople(asset: info.asset, track: info.track,
                start: start, duration: duration, focusRanges: [],
                orientation: Self.displayOrientation(of: info.preferredTransform), tuning: tuning,
                region: region, evidence: { sample in samples.withLock { $0.append(sample) } }, log: log)
        } catch {
            try Task.checkCancellation()
            reusable = false
            targets = []
            log("Feed tracking failed (\(error)); resolving a face-safe constant crop")
            for offset in [0.0, 1.0] where offset < duration {
                log("Decode: feed fallback face at \(start + offset)s")
                if let face = try? await Self.faceCenter(source: source, at: start + offset, region: region) {
                    samples.withLock { $0.append(FeedPathSample(time: offset, faces: [face], expression: nil)) }
                    break
                }
                try Task.checkCancellation()
            }
        }
        let focus = fallbackCenter.map { AreaFocus(x: ($0.x - region.xFrac) / region.wFrac,
                                                  y: ($0.y - region.yFrac) / region.hFrac) }
        let focused = Self.focusedTargets(targets, focus: focus)
        let share = Double(focused.filter(\.tracked).count) / Double(max(1, focused.count))
        let size = CGSize(width: info.size.width * region.wFrac, height: info.size.height * region.hFrac)
        let evidence = samples.withLock { $0 }
        let local: [CameraPathKeyframe]
        if share >= 0.1 {
            local = cameraPath(from: focused, size: size, duration: duration, tuning: tuning, aspect: aspect).map {
                CameraPathKeyframe(t: $0.time, x: $0.crop.minX / size.width, y: $0.crop.minY / size.height,
                    w: $0.crop.width / size.width, h: $0.crop.height / size.height)
            }
        } else {
            // The same decoded face evidence drives the VIP static fallback.
            let faces = evidence.flatMap(\.faces)
            let face = fallbackCenter.flatMap { focus in
                faces.min { Self.focusDistance($0, focus) < Self.focusDistance($1, focus) }
            } ?? faces.first
            let center = face.map { (x: ($0.midX - region.xFrac) / region.wFrac,
                                    y: ($0.midY - region.yFrac) / region.hFrac) }
                ?? fallbackCenter.map { (x: ($0.x - region.xFrac) / region.wFrac,
                                         y: ($0.y - region.yFrac) / region.hFrac) }
            let window = AreaFramer.fallbackWindow(aspect: aspect, sourceSize: size, center: center)
            var crop = CGRect(x: window.xFrac * size.width, y: window.yFrac * size.height,
                width: window.wFrac * size.width, height: window.hFrac * size.height)
            if let face {
                let pixels = CGRect(x: (face.minX - region.xFrac) * info.size.width,
                    y: (face.minY - region.yFrac) * info.size.height,
                    width: face.width * info.size.width, height: face.height * info.size.height)
                crop = FaceGuard.contain(crop, faces: [pixels], bounds: CGRect(origin: .zero, size: size))
            }
            local = [0, duration].map { CameraPathKeyframe(t: $0, x: crop.minX / size.width,
                y: crop.minY / size.height, w: crop.width / size.width, h: crop.height / size.height) }
            log("Feed tracking: static fallback uses \(face != nil ? "clip face detection" : fallbackCenter != nil ? "roster portrait" : "feed center")")
        }
        log(String(format: "feed %.0f%%×%.0f%% at (%.0f%%, %.0f%%) tracked in place",
            region.wFrac * 100, region.hFrac * 100, region.xFrac * 100, region.yFrac * 100))
        return FeedCameraPath(keyframes: local.map {
            CameraPathKeyframe(t: $0.t, x: region.xFrac + $0.x * region.wFrac,
                y: region.yFrac + $0.y * region.hFrac, w: $0.w * region.wFrac, h: $0.h * region.hFrac)
        }, samples: evidence, trackedShare: share, sourceSize: info.size, usedFallback: share < 0.1, reusable: reusable)
    }

    private nonisolated static func focusDistance(_ face: CGRect, _ focus: AreaFocus) -> Double {
        pow(face.midX - focus.x, 2) + pow(face.midY - focus.y, 2)
    }

    /// A full-frame feed may contain both speakers. Each cell follows only the
    /// face nearest its roster focus; a missing face holds the last target.
    private nonisolated static func focusedTargets(_ targets: [Target], focus: AreaFocus?) -> [Target] {
        guard let focus else { return targets }
        var previous = CGRect(x: focus.x - 0.1, y: focus.y - 0.1, width: 0.2, height: 0.3)
        return targets.map { target in
            guard let face = target.faces.min(by: { focusDistance($0, focus) < focusDistance($1, focus) }) else {
                return Target(time: target.time, union: previous, tracked: false)
            }
            previous = bodyEstimate(fromFace: face)
            return Target(time: target.time, union: previous, tracked: true, faces: [face])
        }
    }

    nonisolated static func validRegion(_ region: FreeCropRect) -> FreeCropRect {
        let x = min(0.99, max(0, region.xFrac)), y = min(0.99, max(0, region.yFrac))
        return FreeCropRect(xFrac: x, yFrac: y, wFrac: min(1 - x, max(0.01, region.wFrac)),
                            hFrac: min(1 - y, max(0.01, region.hFrac)))
    }

    #if DEBUG
    /// Deterministic detection fixtures exercise the production smoothing/FaceGuard
    /// path independently of Vision model availability or detector revisions.
    func pathForDetectionFixture(_ samples: [FeedPathSample], size: CGSize, duration: Double,
                                 tuning: Tuning, aspect: Double, focus: AreaFocus? = nil) -> [CameraPathKeyframe] {
        let targets = samples.compactMap { sample -> Target? in
            let bodies = sample.faces.map { Self.bodyEstimate(fromFace: $0) }
            guard let first = bodies.first else { return nil }
            return Target(time: sample.time, union: bodies.dropFirst().reduce(first) { $0.union($1) },
                          tracked: true, faces: sample.faces)
        }
        guard !targets.isEmpty else { return [] }
        return cameraPath(from: Self.focusedTargets(targets, focus: focus), size: size, duration: duration, tuning: tuning, aspect: aspect).map {
            CameraPathKeyframe(t: $0.time, x: $0.crop.minX / size.width, y: $0.crop.minY / size.height,
                              w: $0.crop.width / size.width, h: $0.crop.height / size.height)
        }
    }
    #endif

    // MARK: - Stored-path helpers

    /// Whether a stored path's crop shape fits the current canvas. Keyframes
    /// are normalized to the source frame, so the crop's pixel aspect is
    /// only known once the source size is: compare against `sourceSize`
    /// when given, else assume the common 16:9 source. A path framed for
    /// another canvas must be re-tracked, not replayed — replaying it
    /// scales the wrong-shaped crop across the frame.
    nonisolated static func pathMatchesCanvas(_ path: [CameraPathKeyframe],
                                              sourceSize: CGSize? = nil,
                                              canvasAspect: Double = Double(RenderEngine.outputWidth)
                                                  / Double(RenderEngine.outputHeight)) -> Bool {
        guard !path.isEmpty, canvasAspect > 0 else { return false }
        let source = sourceSize ?? CGSize(width: 16, height: 9)
        return path.allSatisfy { frame in
            guard frame.w > 0, frame.h > 0 else { return false }
            let cropAspect = (frame.w * source.width) / (frame.h * source.height)
            return abs(cropAspect - canvasAspect) / canvasAspect < 0.03
        }
    }

    /// The camera's crop at `t`, linearly interpolated between the
    /// surrounding keyframes (clamped to the path's ends).
    nonisolated static func interpolated(_ keyframes: [CameraPathKeyframe],
                                         at t: Double) -> CameraPathKeyframe? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        guard t >= first.t else { return first }
        guard t < last.t else { return last }
        for index in 1..<keyframes.count {
            let from = keyframes[index - 1], to = keyframes[index]
            // Right-continuous at a cut, including a clamped t=0 cut, so
            // slicing at the boundary cannot turn the jump into a ramp.
            guard t < to.t else { continue }
            let span = to.t - from.t
            // Recipe hold keys mark a jump at `to.t`, never a short ramp.
            let fraction = CameraKeyframes.isCut(keyframes, at: index) ? 0 : (span > 0 ? (t - from.t) / span : 1)
            return CameraPathKeyframe(t: t,
                                      x: from.x + (to.x - from.x) * fraction,
                                      y: from.y + (to.y - from.y) * fraction,
                                      w: from.w + (to.w - from.w) * fraction,
                                      h: from.h + (to.h - from.h) * fraction)
        }
        return last
    }

    /// Slice `[from, from+duration]` out of a scene's path and rebase the
    /// times to the slice start — how a trimmed wizard clip reuses the path
    /// recorded for its whole scene.
    nonisolated static func slice(_ keyframes: [CameraPathKeyframe], from: Double,
                                  duration: Double) -> [CameraPathKeyframe] {
        guard var start = interpolated(keyframes, at: from),
              var end = interpolated(keyframes, at: from + duration) else { return [] }
        start.t = 0
        end.t = duration
        var result = [start]
        for (index, keyframe) in keyframes.enumerated() where keyframe.t > from && keyframe.t <= from + duration {
            var shifted = keyframe
            shifted.t = keyframe.t - from
            if CameraKeyframes.isCut(keyframes, at: index), shifted.t < CameraKeyframes.cutGap {
                // Trimming inside the hold gap must not shorten it into a ramp.
                // An equal-time hold preserves the cut when there is no room
                // for the usual full-gap key before the boundary.
                var hold = result[result.count - 1]
                hold.t = shifted.t
                result.append(hold)
            }
            result.append(shifted)
        }
        if result[result.count - 1].t < duration { result.append(end) }
        return result
    }

    /// How a stored frame must be turned to display upright, from the
    /// track's preferred transform — the orientation Vision needs to detect
    /// people in rotated (e.g. portrait-stored landscape) footage.
    private static func displayOrientation(of transform: CGAffineTransform)
        -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    // MARK: - Pass 1: people tracking

    /// Expand an upright, top-left normalized face into head-and-shoulders
    /// framing, clipping the estimate at the image edges.
    nonisolated static func bodyEstimate(fromFace face: CGRect) -> CGRect {
        let width = face.width * 2.6
        let estimate = CGRect(x: face.midX - width / 2,
                              y: face.minY - face.height * 0.35,
                              width: width, height: face.height * 3.2)
        return estimate.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func trackPeople(asset: AVURLAsset, track: AVAssetTrack,
                             start: Double, duration: Double,
                             focusRanges: [(start: Double, end: Double)],
                             focusPortraits: [Data] = [],
                             avoidPortraits: [Data] = [],
                             orientation: CGImagePropertyOrientation,
                             tuning: Tuning,
                             region: FreeCropRect? = nil,
                             evidence: (@Sendable (FeedPathSample) -> Void)? = nil,
                             log: @Sendable (String) -> Void = { print($0) }) async throws -> [Target] {
        let decodePermit = try await MediaWorkScheduler.current.acquire(.decoding)
        defer { withExtendedLifetime(decodePermit) {} }
        try Task.checkCancellation()
        // Identity focus: reference fingerprints from the user's person
        // markers. With positive references, only detections matching one of
        // them are framed; detections matching a NEGATIVE reference (an
        // ignored person — referee, staff) are dropped outright.
        let references = focusPortraits.compactMap { AppearanceSignature(jpeg: $0) }
        let negatives = avoidPortraits.compactMap { AppearanceSignature(jpeg: $0) }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(transform)
        let longestEdge = max(abs(displaySize.width) * (region?.wFrac ?? 1), abs(displaySize.height) * (region?.hFrac ?? 1))
        let scale = longestEdge > 0 ? min(1, 960 / longestEdge) : 1
        // AVAssetReaderOutput.h permits CV width/height scaling for 32BGRA;
        // its high-bit-depth scaling restriction does not apply to this output.
        func makeReader(scaled: Bool) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           duration: CMTime(seconds: duration, preferredTimescale: 600))
            var settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            if scaled {
                // Buffers stay in encoded orientation; Vision applies the transform.
                settings[kCVPixelBufferWidthKey as String] = max(1, Int((abs(naturalSize.width) * scale).rounded()))
                settings[kCVPixelBufferHeightKey as String] = max(1, Int((abs(naturalSize.height) * scale).rounded()))
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw CenterStageError(message: "Could not configure the video for tracking.")
            }
            reader.add(output)
            guard reader.startReading() else {
                reader.cancelReading()
                throw CenterStageError(message: "Could not read the video for tracking.")
            }
            return (reader, output)
        }
        log("Decode: source buffers for Center Stage tracking\(region == nil ? "" : " and feed expression evidence")")
        let reader: AVAssetReader
        let readerOutput: AVAssetReaderTrackOutput
        do {
            (reader, readerOutput) = try makeReader(scaled: scale < 1)
        } catch {
            try Task.checkCancellation()
            log("Decode: retry full-resolution buffers for Center Stage tracking")
            (reader, readerOutput) = try makeReader(scaled: false)
        }
        defer { reader.cancelReading() }

        func inFocus(_ time: Double) -> Bool {
            focusRanges.isEmpty || focusRanges.contains { time >= $0.start && time <= $0.end }
        }

        var targets: [Target] = []
        var nextAnalysis = 0.0
        var lastUnion = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8)
        var request = DetectHumanRectanglesRequest(.revision2)
        request.upperBodyOnly = false
        let faceRequest = DetectFaceRectanglesRequest(.revision3)
        var analyzedSamples = 0
        var faceSamples = 0

        let imageContext = CIContext(options: [.cacheIntermediates: false])
        var lastFaces: [CGRect] = []
        var previousPatch: [Float]?
        var previousFace: CGRect?
        var nextExpressionFace = 0.0
        var nextEvidence = 0.0
        func recordEvidence(_ buffer: CVPixelBuffer, time: Double) {
            guard let region, let evidence, time + 1e-6 >= nextEvidence else { return }
            nextEvidence = time + 1 / VisualSpeechActivity.targetFPS
            let fullFaces = lastFaces.map {
                CGRect(x: region.xFrac + $0.minX * region.wFrac, y: region.yFrac + $0.minY * region.hFrac,
                    width: $0.width * region.wFrac, height: $0.height * region.hFrac)
            }
            // Match the scorer's face-refresh cadence. More frequent tracker
            // observations must not reset its motion patch on every detection.
            if time >= nextExpressionFace {
                nextExpressionFace = time + VisualSpeechActivity.faceRefreshSeconds
                if let face = fullFaces.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    if face != previousFace { previousPatch = nil }
                    previousFace = face
                }
            }
            let patchRegion = previousFace.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height * 0.6) }
                ?? CGRect(x: region.xFrac + region.wFrac / 3, y: region.yFrac + region.hFrac / 3,
                          width: region.wFrac / 3, height: region.hFrac / 3)
            let encoded = AppearanceSignature.bufferRect(fromDisplay: patchRegion, orientation: orientation)
            let patch = VisualSpeechActivity.luminancePatch(buffer, region: encoded)
            let score = patch.flatMap { current in previousPatch.map { VIPExpressionScore.change(current, from: $0) } }
            evidence(FeedPathSample(time: time, faces: fullFaces, expression: score))
            previousPatch = patch
        }

        while reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard time + 1e-6 >= nextAnalysis else {
                recordEvidence(pixelBuffer, time: time)
                continue
            }
            nextAnalysis = region == nil ? time + tuning.analysisInterval : nextAnalysis + tuning.analysisInterval

            guard inFocus(time) else {
                // Outside the picked people's ranges: ease toward full frame.
                targets.append(Target(time: time,
                                      union: CGRect(x: 0.05, y: 0.02, width: 0.9, height: 0.96),
                                      tracked: false, inFocus: false))
                continue
            }

            analyzedSamples += 1
            var boxes: [CGRect]
            var usedFaces = false
            var faceBoxes: [CGRect] = []
            do {
                let visionPermit = try await MediaWorkScheduler.current.acquire(.vision)
                defer { withExtendedLifetime(visionPermit) {} }
                try Task.checkCancellation()
                let timing = PerfSignpost.begin("Vision", metadata: "tracking")
                defer { PerfSignpost.end(timing) }
                let observations: [HumanObservation]
                let faces: [FaceObservation]
                if let region {
                    let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
                    let extent = upright.extent
                    let rect = CGRect(x: extent.minX + region.xFrac * extent.width,
                        y: extent.minY + (1 - region.yFrac - region.hFrac) * extent.height,
                        width: region.wFrac * extent.width, height: region.hFrac * extent.height).integral.intersection(extent)
                    guard let image = imageContext.createCGImage(upright.cropped(to: rect), from: rect) else {
                        throw CenterStageError(message: "Could not crop the decoded feed buffer.")
                    }
                    observations = (try? await request.perform(on: image)) ?? []
                    faces = (try? await faceRequest.perform(on: image)) ?? []
                } else {
                    observations = (try? await request.perform(on: pixelBuffer, orientation: orientation)) ?? []
                    faces = (try? await faceRequest.perform(on: pixelBuffer, orientation: orientation)) ?? []
                }
                try Task.checkCancellation()
                // Detections are local to the upright feed, with a top-left origin.
                faceBoxes = faces.map {
                    let box = $0.boundingBox.cgRect
                    return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                }
                if observations.isEmpty {
                    boxes = faceBoxes.map { Self.bodyEstimate(fromFace: $0) }
                    usedFaces = !faceBoxes.isEmpty
                } else {
                    boxes = observations.map { observation in
                        let box = observation.boundingBox.cgRect
                        return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                    }
                }
                try Task.checkCancellation()
            }
            lastFaces = faceBoxes
            recordEvidence(pixelBuffer, time: time)
            // Peripheral detections (crowd, staff at distance) are dropped so the
            // camera frames the main subjects instead of everyone visible.
            let detections = Analyzer.primaryPeopleBoxes(boxes)

            var focused = detections
            if (!references.isEmpty || !negatives.isEmpty) && !detections.isEmpty {
                let signatures = detections.map {
                    AppearanceSignature(pixelBuffer: pixelBuffer, displayRect: $0,
                                        orientation: orientation)
                }
                var indices = Array(detections.indices)
                if !negatives.isEmpty {
                    indices = indices.filter { index in
                        guard let signature = signatures[index] else { return true }
                        return !negatives.contains {
                            AppearanceSignature.distance($0, signature) <= 0.85
                        }
                    }
                }
                if !references.isEmpty {
                    let chosen = Self.chooseMatches(signatures: indices.map { signatures[$0] },
                                                    references: references)
                    indices = chosen.sorted().map { indices[$0] }
                }
                focused = indices.map { detections[$0] }
            }
            if focused.isEmpty {
                // Nobody (matching) found: the camera holds its last framing.
                targets.append(Target(time: time, union: lastUnion, tracked: false))
            } else {
                let union = focused.dropFirst().reduce(focused[0]) { $0.union($1) }
                lastUnion = union
                let selectedFaces = faceBoxes.filter { face in
                    focused.contains { $0.contains(CGPoint(x: face.midX, y: face.midY)) }
                }
                targets.append(Target(time: time, union: union, tracked: true, faces: selectedFaces))
                if usedFaces { faceSamples += 1 }
            }
        }
        reader.cancelReading()
        log("Center Stage: \(faceSamples) of \(analyzedSamples) samples framed from faces")
        guard !targets.isEmpty else {
            throw CenterStageError(message: "No frames could be analyzed for tracking.")
        }
        return targets
    }

    /// Greedy identity match: each reference claims its nearest detection
    /// (by appearance distance), loosely thresholded so a missing subject
    /// doesn't pull in whoever else is on screen.
    private static func chooseMatches(signatures: [AppearanceSignature?],
                                      references: [AppearanceSignature]) -> Set<Int> {
        var chosen = Set<Int>()
        for reference in references {
            var bestIndex = -1
            var bestDistance = Double.infinity
            for (index, signature) in signatures.enumerated() {
                guard let signature else { continue }
                let distance = AppearanceSignature.distance(reference, signature)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            if bestIndex >= 0, bestDistance <= 1.1 {
                chosen.insert(bestIndex)
            }
        }
        return chosen
    }

    /// The crop the tracker would pick for ONE still frame — the notes
    /// panel's live suggestion rectangle. Same detection, peripheral-people
    /// filter, and identity focus as the real pass. Normalized top-left
    /// display coordinates; nil when nobody is detected.
    @concurrent
    nonisolated static func stillFrameCrop(source: URL, at time: Double,
                                           focusPortraits: [Data] = [],
                                           avoidPortraits: [Data] = [],
                                           tuning: Tuning = .balanced) async -> CGRect? {
        let data = await MediaWorkScheduler.$priority.withValue(.interactive) {
            await ThumbnailService.jpegFrame(url: source, at: time, maxDimension: 960)
        }
        guard let data,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        var request = DetectHumanRectanglesRequest(.revision2)
        request.upperBodyOnly = false
        let observations: [HumanObservation]
        do {
            let permit = try await MediaWorkScheduler.current.acquire(.vision, priority: .interactive)
            defer { withExtendedLifetime(permit) {} }
            try Task.checkCancellation()
            observations = (try? await request.perform(on: data)) ?? []
        } catch { return nil }
        var boxes = Analyzer.primaryPeopleBoxes(observations.map { observation in
            let box = observation.boundingBox.cgRect
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        })
        guard !boxes.isEmpty else { return nil }
        let references = focusPortraits.compactMap { AppearanceSignature(jpeg: $0) }
        let negatives = avoidPortraits.compactMap { AppearanceSignature(jpeg: $0) }
        if !references.isEmpty || !negatives.isEmpty {
            let signatures = boxes.map { AppearanceSignature(cgImage: cg, normalizedRect: $0) }
            var indices = Array(boxes.indices)
            if !negatives.isEmpty {
                indices = indices.filter { index in
                    guard let signature = signatures[index] else { return true }
                    return !negatives.contains {
                        AppearanceSignature.distance($0, signature) <= 0.85
                    }
                }
            }
            if !references.isEmpty {
                let chosen = chooseMatches(signatures: indices.map { signatures[$0] },
                                           references: references)
                if !chosen.isEmpty { indices = chosen.sorted().map { indices[$0] } }
            }
            guard !indices.isEmpty else { return nil }
            boxes = indices.map { boxes[$0] }
        }
        let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        let size = CGSize(width: cg.width, height: cg.height)
        let crop = desiredCrop(forUnion: union, size: size, tuning: tuning)
        return CGRect(x: crop.minX / size.width, y: crop.minY / size.height,
                      width: crop.width / size.width, height: crop.height / size.height)
    }

    /// One fresh face observation on the feed, in normalized top-left coordinates.
    /// Kept off the main actor; callers may retry at a later clip timestamp.
    @concurrent
    static func faceCenter(source: URL, at time: Double, region: FreeCropRect? = nil) async throws -> CGRect? {
        try await faces(source: source, at: time, region: region).max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Every face on the frame (or on `region` of it), in normalized
    /// top-left coordinates of the full frame.
    @concurrent
    static func faces(source: URL, at time: Double, region: FreeCropRect? = nil) async throws -> [CGRect] {
        let image = try await faceFrame(source: source, at: time)
        return try await faces(in: image, region: region)
    }

    /// The frame `faces(source:)` detects on, so a caller looking at several
    /// regions of one moment decodes it once.
    @concurrent
    static func faceFrame(source: URL, at time: Double) async throws -> CGImage {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let decodePermit = try await MediaWorkScheduler.current.acquire(.decoding)
        defer { withExtendedLifetime(decodePermit) {} }
        return try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
    }

    /// The largest face on `region` of a frame from `faceFrame`.
    @concurrent
    static func faceCenter(in image: CGImage, region: FreeCropRect? = nil) async throws -> CGRect? {
        try await faces(in: image, region: region).max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Every face on a frame from `faceFrame` (or on `region` of it).
    @concurrent
    static func faces(in image: CGImage, region: FreeCropRect? = nil) async throws -> [CGRect] {
        let visionPermit = try await MediaWorkScheduler.current.acquire(.vision)
        defer { withExtendedLifetime(visionPermit) {} }
        try Task.checkCancellation()
        let detectionImage: CGImage
        if let region {
            let rect = CGRect(x: region.xFrac * Double(image.width), y: region.yFrac * Double(image.height),
                width: region.wFrac * Double(image.width), height: region.hFrac * Double(image.height)).integral
            guard let crop = image.cropping(to: rect) else { return [] }
            detectionImage = crop
        } else { detectionImage = image }
        let faces = try await DetectFaceRectanglesRequest(.revision3).perform(on: detectionImage)
        try Task.checkCancellation()
        let region = region ?? FreeCropRect(xFrac: 0, yFrac: 0, wFrac: 1, hFrac: 1)
        return faces.map {
            let box = $0.boundingBox.cgRect
            return CGRect(x: region.xFrac + box.minX * region.wFrac,
                y: region.yFrac + (1 - box.maxY) * region.hFrac,
                width: box.width * region.wFrac, height: box.height * region.hFrac)
        }
    }

    // MARK: - Camera path

    /// The 9:16 crop the camera wants for a people union (normalized,
    /// top-left) on a frame of `size` pixels: padded around the people,
    /// zoomed out when they spread, biased toward heads, clamped inside the
    /// frame. Returned in pixels.
    nonisolated static func desiredCrop(forUnion union: CGRect, size: CGSize,
                                        tuning: Tuning,
                                        aspect: Double = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)) -> CGRect {
        let unionPixels = CGRect(x: union.minX * size.width,
                                 y: union.minY * size.height,
                                 width: union.width * size.width,
                                 height: union.height * size.height)
        // Padding: breathing room around the person(s).
        let neededWidth = unionPixels.width * tuning.padding
        let neededHeight = unionPixels.height * 1.12
        var cropHeight = max(neededHeight, neededWidth / aspect,
                             size.height * tuning.minCropHeightFraction)
        cropHeight = min(cropHeight, size.height)
        // A wide target aspect on a narrow source: the width is the limit.
        if cropHeight * aspect > size.width { cropHeight = size.width / aspect }
        let cropWidth = cropHeight * aspect
        // Center on the union, biased toward the upper body/head.
        let centerX = unionPixels.midX
        let centerY = unionPixels.minY + unionPixels.height * 0.42
        var crop = CGRect(x: centerX - cropWidth / 2, y: centerY - cropHeight / 2,
                          width: cropWidth, height: cropHeight)
        crop.origin.x = min(max(0, crop.origin.x), size.width - cropWidth)
        crop.origin.y = min(max(0, crop.origin.y), size.height - cropHeight)
        return crop
    }

    /// A user hint rect (normalized, top-left) as a legal pixel crop:
    /// 9:16 aspect re-derived from its height and clamped into the frame.
    nonisolated static func hintCrop(_ hint: CGRect, size: CGSize,
                                     aspect: Double = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)) -> CGRect {
        var height = min(hint.height * size.height, size.height)
        var width = height * aspect
        if width > size.width {
            width = size.width
            height = width / aspect
        }
        var crop = CGRect(x: hint.midX * size.width - width / 2,
                          y: hint.midY * size.height - height / 2,
                          width: width, height: height)
        crop.origin.x = min(max(0, crop.origin.x), size.width - width)
        crop.origin.y = min(max(0, crop.origin.y), size.height - height)
        return crop
    }

    private static func blend(_ a: CGRect, _ b: CGRect, fraction: Double) -> CGRect {
        let f = CGFloat(min(max(0, fraction), 1))
        return CGRect(x: a.minX + (b.minX - a.minX) * f,
                      y: a.minY + (b.minY - a.minY) * f,
                      width: a.width + (b.width - a.width) * f,
                      height: a.height + (b.height - a.height) * f)
    }

    /// Smoothed pan/zoom: each raw target becomes a desired 9:16 crop (padded
    /// around the people, zooming out when they spread apart), then a
    /// dead-zone plus exponential smoothing turns jittery tracking into a
    /// camera-operator move. User hints are hard: the camera eases toward a
    /// hint through the second before its timestamp, snaps exactly onto it,
    /// then tracking resumes. Downsampled to keyframes for the ramps.
    private func cameraPath(from targets: [Target], size: CGSize, duration: Double,
                            tuning: Tuning,
                            hints: [(time: Double, crop: CGRect)] = [],
                            aspect: Double = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)) -> [Keyframe] {
        let pixelHints = hints
            .map { (time: $0.time, crop: Self.hintCrop($0.crop, size: size, aspect: aspect)) }
            .sorted { $0.time < $1.time }
        var hintIndex = 0

        // Dead-zone + exponential smoothing over the analysis cadence.
        // `pinned` entries (hints) survive keyframe downsampling verbatim.
        var current = Self.desiredCrop(forUnion: targets[0].union, size: size, tuning: tuning,
                                       aspect: aspect)
        let bounds = CGRect(origin: .zero, size: size)
        func faces(_ target: Target) -> [CGRect] {
            guard target.inFocus else { return [] }
            return target.faces.map {
                CGRect(x: $0.minX * size.width, y: $0.minY * size.height,
                       width: $0.width * size.width, height: $0.height * size.height)
            }
        }
        current = FaceGuard.contain(current, faces: faces(targets[0]), bounds: bounds)
        var smoothed: [(time: Double, crop: CGRect, pinned: Bool)] = [(0, current, false)]
        var previousTime = 0.0
        for target in targets {
            let elapsed = max(0, target.time - previousTime)
            let alpha = tuning.timeBasedSmoothing
                ? 1 - pow(1 - tuning.smoothing, elapsed / 0.1) : tuning.smoothing
            previousTime = target.time
            // Hints passed since the last target: snap exactly onto them.
            while hintIndex < pixelHints.count, pixelHints[hintIndex].time <= target.time {
                let hint = pixelHints[hintIndex]
                current = hint.crop
                smoothed.append((hint.time, current, true))
                hintIndex += 1
            }
            var desired = Self.desiredCrop(forUnion: target.union, size: size, tuning: tuning,
                                           aspect: aspect)
            if hintIndex < pixelHints.count {
                let hint = pixelHints[hintIndex]
                let lead = hint.time - target.time
                if lead <= 1.0 {
                    // Ease into the upcoming hint over its final second.
                    desired = Self.blend(desired, hint.crop, fraction: 1 - lead)
                }
            }
            desired = FaceGuard.contain(desired, faces: faces(target), bounds: bounds)
            let deadZoneX = size.width * tuning.deadZoneWidth
            let deadZoneScale = current.height * tuning.deadZoneZoom
            let moveX = abs(desired.midX - current.midX) > deadZoneX
            let zoom = abs(desired.height - current.height) > deadZoneScale
            if moveX || zoom {
                current = CGRect(x: current.minX + (desired.minX - current.minX) * alpha,
                                 y: current.minY + (desired.minY - current.minY) * alpha,
                                 width: current.width + (desired.width - current.width) * alpha,
                                 height: current.height + (desired.height - current.height) * alpha)
                // Re-normalize the aspect after independent lerp.
                current.size.width = current.height * aspect
                current.origin.x = min(max(0, current.origin.x), size.width - current.width)
                current.origin.y = min(max(0, current.origin.y), size.height - current.height)
            }
            let guarded = FaceGuard.contain(current, faces: faces(target), bounds: bounds)
            let corrected = guarded != current
            current = guarded
            // Safety corrections must survive keyframe downsampling.
            smoothed.append((target.time, current, corrected))
        }
        // Hints at or beyond the last analyzed frame.
        while hintIndex < pixelHints.count {
            let hint = pixelHints[hintIndex]
            smoothed.append((min(hint.time, duration), hint.crop, true))
            hintIndex += 1
        }

        if tuning.timeBasedSmoothing {
            // Preserve the 0.3 s camera cadence even when detections arrive at
            // 0.25 s. Sampling at the next detection would silently become 0.5 s.
            var times = Set(smoothed.filter(\.pinned).map(\.time))
            times.formUnion(stride(from: 0, through: duration, by: tuning.keyframeInterval))
            times.insert(duration)
            var cursor = 0
            return times.sorted().map { time in
                while cursor + 1 < smoothed.count && smoothed[cursor + 1].time <= time { cursor += 1 }
                let from = smoothed[cursor]
                guard cursor + 1 < smoothed.count else { return Keyframe(time: time, crop: from.crop) }
                let to = smoothed[cursor + 1]
                let fraction = to.time > from.time ? min(1, max(0, (time - from.time) / (to.time - from.time))) : 1
                return Keyframe(time: time, crop: Self.blend(from.crop, to.crop, fraction: fraction))
            }
        }

        // Downsample to ramp keyframes; pinned hint entries always survive.
        var keyframes: [Keyframe] = []
        var nextKeyframe = 0.0
        for entry in smoothed {
            if entry.pinned || entry.time >= nextKeyframe {
                keyframes.append(Keyframe(time: entry.time, crop: entry.crop))
                nextKeyframe = entry.time + tuning.keyframeInterval
            }
        }
        if let last = smoothed.last, keyframes.last?.time ?? 0 < last.time {
            keyframes.append(Keyframe(time: last.time, crop: last.crop))
        }
        if keyframes.count == 1 {
            keyframes.append(Keyframe(time: max(duration, keyframes[0].time + 0.1),
                                      crop: keyframes[0].crop))
        }
        return keyframes
    }

    // MARK: - Pass 2: export

    private func export(asset: AVURLAsset, track: AVAssetTrack, size: CGSize,
                        preferredTransform: CGAffineTransform,
                        displayOrigin: CGPoint,
                        start: Double, duration: Double,
                        keyframes: [Keyframe],
                        renderSize: CGSize = CenterStageService.defaultRenderSize,
                        output: URL) async throws {
        // Composition tracks need not retain the original AVURLAsset object
        // that owns a Drive lease. Keep it alive through queueing and export.
        defer { withExtendedLifetime(asset) {} }
        let timing = PerfSignpost.begin("FramingExport", metadata: "CenterStage")
        defer { PerfSignpost.end(timing) }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: duration, preferredTimescale: 600))
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CenterStageError(message: "Could not build the output composition.")
        }
        try videoTrack.insertTimeRange(range, of: track, at: .zero)
        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        }

        // Crop rect → transform placing that region across the 1080×1920
        // canvas. A rotation-flagged source maps into negative coordinates
        // (e.g. a bare -90° matrix puts everything at y = -height…0), so the
        // display origin must be shifted out first — without it the whole
        // frame lands off-canvas and the export renders black.
        func transform(for crop: CGRect) -> CGAffineTransform {
            let scale = renderSize.width / crop.width
            return preferredTransform
                .concatenating(CGAffineTransform(translationX: -displayOrigin.x, y: -displayOrigin.y))
                .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        for index in 0..<(keyframes.count - 1) {
            let from = keyframes[index]
            let to = keyframes[index + 1]
            guard to.time > from.time else { continue }
            layerInstruction.setTransformRamp(
                fromStart: transform(for: from.crop),
                toEnd: transform(for: to.crop),
                timeRange: CMTimeRange(start: CMTime(seconds: from.time, preferredTimescale: 600),
                                       end: CMTime(seconds: to.time, preferredTimescale: 600)))
        }
        if let last = keyframes.last {
            layerInstruction.setTransform(transform(for: last.crop),
                                          at: CMTime(seconds: last.time, preferredTimescale: 600))
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw CenterStageError(message: "Could not create the export session.")
        }
        export.videoComposition = videoComposition
        try await MediaExport.run(export, to: output)
    }
}
