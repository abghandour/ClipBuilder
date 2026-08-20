import AVFoundation
import CoreImage
import ImageIO
import Vision

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
    private static func bufferRect(fromDisplay rect: CGRect,
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

        /// Slow, cinematic drift — interviews, posed footage.
        static let smooth = Tuning(analysisInterval: 0.15, keyframeInterval: 0.4,
                                   smoothing: 0.10, deadZoneWidth: 0.06,
                                   deadZoneZoom: 0.08, minCropHeightFraction: 0.6,
                                   padding: 1.4)
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
            case "smooth": return .smooth
            case "fast": return .fastAction
            default: return .balanced
            }
        }
    }

    private struct Target {
        var time: Double       // relative to the clip start
        var union: CGRect      // normalized, top-left origin
        var tracked: Bool      // false = no humans found this frame
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

    private func loadSource(_ url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CenterStageError(message: "The file has no video track.")
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let size = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        guard size.width > size.height else {
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
    func reframeClip(source: URL, start: Double, duration: Double,
                     focusRanges: [(start: Double, end: Double)] = [],
                     focusPortraits: [Data] = [],
                     avoidPortraits: [Data] = [],
                     hints: [(time: Double, crop: CGRect)] = [],
                     tuning: Tuning = .balanced,
                     log: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        let emit = log ?? { _ in }
        let info = try await loadSource(source)

        // Rotated sources (portrait-stored with a rotation flag) need Vision
        // told the display orientation, or people are hunted in sideways
        // frames and the boxes come back in the wrong coordinate space.
        let targets = try await trackPeople(asset: info.asset, track: info.track,
                                            start: start, duration: duration,
                                            focusRanges: focusRanges,
                                            focusPortraits: focusPortraits,
                                            avoidPortraits: avoidPortraits,
                                            orientation: Self.displayOrientation(of: info.preferredTransform),
                                            tuning: tuning)
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
                                   tuning: tuning, hints: hints)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("centerstage_\(UUID().uuidString).mp4")
        try await export(asset: info.asset, track: info.track, size: info.size,
                         preferredTransform: info.preferredTransform,
                         displayOrigin: info.displayOrigin,
                         start: start, duration: duration,
                         keyframes: keyframes, output: output)
        return output
    }

    /// Reframe `[start, start+duration]` using a precomputed camera path
    /// (clip-relative, normalized keyframes) — skips the tracking pass, so
    /// the render is just the hardware export.
    func reframeClip(source: URL, start: Double, duration: Double,
                     path: [CameraPathKeyframe],
                     log: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        guard path.count >= 2 else {
            throw CenterStageError(message: "The stored camera path is too short to render.")
        }
        let info = try await loadSource(source)
        let keyframes = path.map { keyframe in
            Keyframe(time: keyframe.t,
                     crop: CGRect(x: keyframe.x * info.size.width,
                                  y: keyframe.y * info.size.height,
                                  width: keyframe.w * info.size.width,
                                  height: keyframe.h * info.size.height))
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("centerstage_\(UUID().uuidString).mp4")
        try await export(asset: info.asset, track: info.track, size: info.size,
                         preferredTransform: info.preferredTransform,
                         displayOrigin: info.displayOrigin,
                         start: start, duration: duration,
                         keyframes: keyframes, output: output)
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
                    tuning: Tuning = .balanced) async throws
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
                                   tuning: tuning, hints: hints)
        let normalized = keyframes.map { keyframe in
            CameraPathKeyframe(t: keyframe.time,
                               x: keyframe.crop.minX / info.size.width,
                               y: keyframe.crop.minY / info.size.height,
                               w: keyframe.crop.width / info.size.width,
                               h: keyframe.crop.height / info.size.height)
        }
        return (normalized, trackedShare)
    }

    // MARK: - Stored-path helpers

    /// The camera's crop at `t`, linearly interpolated between the
    /// surrounding keyframes (clamped to the path's ends).
    nonisolated static func interpolated(_ keyframes: [CameraPathKeyframe],
                                         at t: Double) -> CameraPathKeyframe? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        guard t > first.t else { return first }
        guard t < last.t else { return last }
        for index in 1..<keyframes.count {
            let from = keyframes[index - 1], to = keyframes[index]
            guard t <= to.t else { continue }
            let span = to.t - from.t
            let fraction = span > 0 ? (t - from.t) / span : 1
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
        for keyframe in keyframes where keyframe.t > from && keyframe.t < from + duration {
            var shifted = keyframe
            shifted.t = keyframe.t - from
            result.append(shifted)
        }
        result.append(end)
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

    private func trackPeople(asset: AVURLAsset, track: AVAssetTrack,
                             start: Double, duration: Double,
                             focusRanges: [(start: Double, end: Double)],
                             focusPortraits: [Data] = [],
                             avoidPortraits: [Data] = [],
                             orientation: CGImagePropertyOrientation,
                             tuning: Tuning) async throws -> [Target] {
        // Identity focus: reference fingerprints from the user's person
        // markers. With positive references, only detections matching one of
        // them are framed; detections matching a NEGATIVE reference (an
        // ignored person — referee, staff) are dropped outright.
        let references = focusPortraits.compactMap { AppearanceSignature(jpeg: $0) }
        let negatives = avoidPortraits.compactMap { AppearanceSignature(jpeg: $0) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw CenterStageError(message: "Could not read the video for tracking.")
        }

        func inFocus(_ time: Double) -> Bool {
            focusRanges.isEmpty || focusRanges.contains { time >= $0.start && time <= $0.end }
        }

        var targets: [Target] = []
        var nextAnalysis = 0.0
        var lastUnion = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8)
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false

        while reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
            guard time >= nextAnalysis else { continue }
            nextAnalysis = time + tuning.analysisInterval
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

            guard inFocus(time) else {
                // Outside the picked people's ranges: ease toward full frame.
                targets.append(Target(time: time,
                                      union: CGRect(x: 0.05, y: 0.02, width: 0.9, height: 0.96),
                                      tracked: false, inFocus: false))
                continue
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            try? handler.perform([request])
            // With the orientation supplied, Vision reports boxes in upright
            // (display) space — bottom-left-origin normalized. Peripheral
            // detections (crowd, staff at distance) are dropped so the
            // camera frames the main subjects instead of everyone visible.
            let detections = Analyzer.primaryPeopleBoxes(
                (request.results ?? []).map { observation in
                    let box = observation.boundingBox
                    return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                })

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
                targets.append(Target(time: time, union: union, tracked: true))
            }
        }
        reader.cancelReading()
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
    nonisolated static func stillFrameCrop(source: URL, at time: Double,
                                           focusPortraits: [Data] = [],
                                           avoidPortraits: [Data] = [],
                                           tuning: Tuning = .balanced) async -> CGRect? {
        guard let data = await ThumbnailService.jpegFrame(url: source, at: time, maxDimension: 960),
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        try? VNImageRequestHandler(data: data).perform([request])
        var boxes = Analyzer.primaryPeopleBoxes((request.results ?? []).map { observation in
            let box = observation.boundingBox
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

    // MARK: - Camera path

    /// The 9:16 crop the camera wants for a people union (normalized,
    /// top-left) on a frame of `size` pixels: padded around the people,
    /// zoomed out when they spread, biased toward heads, clamped inside the
    /// frame. Returned in pixels.
    nonisolated static func desiredCrop(forUnion union: CGRect, size: CGSize,
                                        tuning: Tuning) -> CGRect {
        let aspect = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)
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
    nonisolated static func hintCrop(_ hint: CGRect, size: CGSize) -> CGRect {
        let aspect = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)
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
                            hints: [(time: Double, crop: CGRect)] = []) -> [Keyframe] {
        let aspect = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)   // 0.5625
        let pixelHints = hints
            .map { (time: $0.time, crop: Self.hintCrop($0.crop, size: size)) }
            .sorted { $0.time < $1.time }
        var hintIndex = 0

        // Dead-zone + exponential smoothing over the analysis cadence.
        // `pinned` entries (hints) survive keyframe downsampling verbatim.
        var current = Self.desiredCrop(forUnion: targets[0].union, size: size, tuning: tuning)
        var smoothed: [(time: Double, crop: CGRect, pinned: Bool)] = [(0, current, false)]
        let alpha = tuning.smoothing
        for target in targets {
            // Hints passed since the last target: snap exactly onto them.
            while hintIndex < pixelHints.count, pixelHints[hintIndex].time <= target.time {
                let hint = pixelHints[hintIndex]
                current = hint.crop
                smoothed.append((hint.time, current, true))
                hintIndex += 1
            }
            var desired = Self.desiredCrop(forUnion: target.union, size: size, tuning: tuning)
            if hintIndex < pixelHints.count {
                let hint = pixelHints[hintIndex]
                let lead = hint.time - target.time
                if lead <= 1.0 {
                    // Ease into the upcoming hint over its final second.
                    desired = Self.blend(desired, hint.crop, fraction: 1 - lead)
                }
            }
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
            smoothed.append((target.time, current, false))
        }
        // Hints at or beyond the last analyzed frame.
        while hintIndex < pixelHints.count {
            let hint = pixelHints[hintIndex]
            smoothed.append((min(hint.time, duration), hint.crop, true))
            hintIndex += 1
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
                        keyframes: [Keyframe], output: URL) async throws {
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
            let scale = Double(RenderEngine.outputWidth) / crop.width
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
        videoComposition.renderSize = CGSize(width: RenderEngine.outputWidth,
                                             height: RenderEngine.outputHeight)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw CenterStageError(message: "Could not create the export session.")
        }
        export.videoComposition = videoComposition
        export.outputURL = output
        export.outputFileType = .mp4
        try? FileManager.default.removeItem(at: output)
        await export.export()
        if let error = export.error {
            throw CenterStageError(message: "Export failed: \(error.localizedDescription)")
        }
        guard export.status == .completed else {
            throw CenterStageError(message: "Export did not complete (status \(export.status.rawValue)).")
        }
    }
}
