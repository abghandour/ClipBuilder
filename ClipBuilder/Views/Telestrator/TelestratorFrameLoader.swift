import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

nonisolated enum TelestratorFrameLoader {
    nonisolated struct Frame: Sendable {
        let image: CGImage
        let frameRate: Double
        let time: Double
    }

    // As in ThumbnailService: only cancellation crosses executors. The worker
    // owns and configures this non-Sendable generator before installing it.
    private nonisolated struct Cancellation: @unchecked Sendable {
        let generator: AVAssetImageGenerator
        func cancel() { generator.cancelAllCGImageGeneration() }
    }

    @concurrent
    static func load(url: URL, time: Double, duration: Double, range: ClosedRange<Double>? = nil,
                     lockTime: Bool = false) async throws -> Frame {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var rate = 30.0
        if let track = tracks.first {
            let nominal = try await track.load(.nominalFrameRate)
            if nominal.isFinite, nominal > 0 { rate = Double(nominal) }
        }
        // Builder holds own the exact source moment, including a frame closer
        // to EOF than the nominal frame interval. Never move their cut clock.
        var target = lockTime ? time : TelestrationRules.sourceTime(time, duration: duration, frameRate: rate)
        if let range { target = min(range.upperBound, max(range.lowerBound, target)) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let cancellation = Cancellation(generator: generator)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await generator.image(at: CMTime(seconds: target, preferredTimescale: 60000))
            try Task.checkCancellation()
            return Frame(image: result.image, frameRate: rate, time: target)
        } onCancel: {
            cancellation.cancel()
        }
    }
}
