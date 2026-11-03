import Foundation
import CoreVideo
import CoreMedia
import ImageIO
@preconcurrency import Vision

/// Measures the recording camera's motion frame to frame: Vision's
/// translational registration between consecutive decoded frames, limited
/// to the feed's region. Feed `trackPeople` every decoded frame; it decides
/// how many to compare (at most 30 per second).
nonisolated final class CameraMotionMeter {
    private let request: TrackTranslationalImageRegistrationRequest
    private let orientation: CGImagePropertyOrientation
    private let region: FreeCropRect
    private var lastTime: Double?
    private var lastPatch: [Float]?
    /// Recent frame-to-frame luminance differences, for the cut test.
    private var recentDifferences: [Float] = []
    /// Frames closer than this to the last compared one are skipped.
    static let minimumSpacing = 1.0 / 30 - 1e-4
    /// A frame whose mean luminance change (0–1) exceeds this and dwarfs the
    /// recent changes is a shot change in the source, not motion.
    static let cutDifference: Float = 0.12
    static let cutRatio: Float = 4

    init(orientation: CGImagePropertyOrientation, region: FreeCropRect? = nil) {
        request = TrackTranslationalImageRegistrationRequest()
        if let region {
            // Vision's region of interest has a lower-left origin.
            request.regionOfInterest = NormalizedRect(x: region.xFrac, y: 1 - region.yFrac - region.hFrac,
                                                      width: region.wFrac, height: region.hFrac)
        }
        self.orientation = orientation
        self.region = region ?? FreeCropRect()
    }

    /// The content shift since the previously compared frame, as fractions
    /// of the feed; nil for the first frame, a skipped frame, or a failure.
    /// Frames compared and frames whose registration failed (not counting the first).
    private(set) var compared = 0
    private(set) var failures = 0

    /// Whether `measure` would compare this frame; check before taking a Vision permit.
    func wants(_ time: Double) -> Bool {
        guard let lastTime else { return true }
        return time - lastTime >= Self.minimumSpacing
    }

    func measure(_ buffer: CVPixelBuffer, time: Double) async -> CameraMotionSample? {
        guard wants(time) else { return nil }
        let first = lastTime == nil
        lastTime = time
        let cut = detectCut(buffer)
        guard let observation = try? await request.perform(on: buffer, orientation: orientation) else {
            if !first { failures += 1 }
            return cut ? CameraMotionSample(time: time, dx: 0, dy: 0, cut: true) : nil
        }
        if first { return nil }
        compared += 1
        if cut { return CameraMotionSample(time: time, dx: 0, dy: 0, cut: true) }
        let transform = observation.alignmentTransform
        let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer))
        let upright = Self.uprightSize(width: width, height: height, orientation: orientation)
        // The transform aligns the new frame back onto the previous one, so
        // the content moved by the opposite amount; Vision's y axis points up.
        let dx = -transform.tx / max(1, upright.width * region.wFrac)
        let dy = transform.ty / max(1, upright.height * region.hFrac)
        guard dx.isFinite, dy.isFinite else { return nil }
        return CameraMotionSample(time: time, dx: dx, dy: dy)
    }

    /// Compares a coarse luminance grid of the feed with the previous frame.
    private func detectCut(_ buffer: CVPixelBuffer) -> Bool {
        let encoded = AppearanceSignature.bufferRect(fromDisplay: CGRect(x: region.xFrac, y: region.yFrac,
            width: region.wFrac, height: region.hFrac), orientation: orientation)
        guard let patch = VisualSpeechActivity.luminancePatch(buffer, region: encoded, grid: 16) else { return false }
        defer { lastPatch = patch }
        guard let previous = lastPatch, previous.count == patch.count else { return false }
        let difference = Self.meanDifference(patch, previous)
        defer {
            recentDifferences.append(difference)
            if recentDifferences.count > 15 { recentDifferences.removeFirst() }
        }
        guard difference > Self.cutDifference else { return false }
        let typical = recentDifferences.isEmpty ? 0 : recentDifferences.reduce(0, +) / Float(recentDifferences.count)
        return difference > typical * Self.cutRatio
    }

    static func meanDifference(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(a.count) / 255
    }

    static func uprightSize(width: Double, height: Double, orientation: CGImagePropertyOrientation) -> (width: Double, height: Double) {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: return (height, width)
        default: return (width, height)
        }
    }
}
