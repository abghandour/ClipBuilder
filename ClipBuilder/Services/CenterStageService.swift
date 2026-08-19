import AVFoundation
import CoreImage
import Vision

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

    // MARK: - Entry point

    /// Reframe `[start, start+duration]` of a widescreen source into a 9:16
    /// clip at `output`. The camera frames the union of all detected people;
    /// `focusRanges` (clip-relative) optionally mark when the people the user
    /// picked are on screen — outside those ranges the camera eases back to
    /// the full frame instead of chasing whoever happens to be visible.
    func reframeClip(source: URL, start: Double, duration: Double,
                     focusRanges: [(start: Double, end: Double)] = [],
                     tuning: Tuning = .balanced,
                     log: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        let emit = log ?? { _ in }
        let asset = AVURLAsset(url: source)
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

        // Rotated sources (portrait-stored with a rotation flag) need Vision
        // told the display orientation, or people are hunted in sideways
        // frames and the boxes come back in the wrong coordinate space.
        let targets = try await trackPeople(asset: asset, track: track,
                                            start: start, duration: duration,
                                            focusRanges: focusRanges,
                                            orientation: Self.displayOrientation(of: preferredTransform),
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

        let keyframes = cameraPath(from: targets, size: size, duration: duration, tuning: tuning)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("centerstage_\(UUID().uuidString).mp4")
        try await export(asset: asset, track: track, size: size,
                         preferredTransform: preferredTransform,
                         displayOrigin: displayRect.origin,
                         start: start, duration: duration,
                         keyframes: keyframes, output: output)
        return output
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
                             orientation: CGImagePropertyOrientation,
                             tuning: Tuning) async throws -> [Target] {
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
            // (display) space — bottom-left-origin normalized.
            let detections: [CGRect] = (request.results ?? []).map { observation in
                let box = observation.boundingBox
                return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            }

            if detections.isEmpty {
                // Nobody found: the camera holds its last framing.
                targets.append(Target(time: time, union: lastUnion, tracked: false))
            } else {
                let union = detections.dropFirst().reduce(detections[0]) { $0.union($1) }
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

    // MARK: - Camera path

    /// Smoothed pan/zoom: each raw target becomes a desired 9:16 crop (padded
    /// around the people, zooming out when they spread apart), then a
    /// dead-zone plus exponential smoothing turns jittery tracking into a
    /// camera-operator move. Downsampled to keyframes for the transform ramps.
    private func cameraPath(from targets: [Target], size: CGSize, duration: Double,
                            tuning: Tuning) -> [Keyframe] {
        let aspect = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)   // 0.5625

        func desiredCrop(for union: CGRect) -> CGRect {
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

        // Dead-zone + exponential smoothing over the analysis cadence.
        var current = desiredCrop(for: targets[0].union)
        var smoothed: [(time: Double, crop: CGRect)] = [(0, current)]
        let alpha = tuning.smoothing
        for target in targets {
            let desired = desiredCrop(for: target.union)
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
            smoothed.append((target.time, current))
        }

        // Downsample to ramp keyframes.
        var keyframes: [Keyframe] = []
        var nextKeyframe = 0.0
        for entry in smoothed {
            if entry.time >= nextKeyframe {
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
