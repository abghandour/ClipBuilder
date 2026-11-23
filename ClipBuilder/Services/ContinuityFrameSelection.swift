import AVFoundation
import Foundation

/// The source sample containing a hold's time, matching the drawing editor.
nonisolated enum ContinuityFrameSelection {
    nonisolated struct UnsupportedTiming: LocalizedError {
        var errorDescription: String? { "The containing hold frame could not be read" }
    }

    static func containingFrame(times: [Double], time: Double) -> Int? {
        guard time.isFinite else { return nil }
        // Match the editor's 60,000 Hz request clock, without millisecond
        // rounding across a source-frame boundary.
        let target = (max(0, time) * 60000).rounded() / 60000
        return times.lastIndex { $0 <= target + 1e-9 }
    }

    /// Seek just before a known timestamp, never rounded past it by ffmpeg's
    /// microsecond option parser. The preceding sample remains excluded.
    static func seek(_ time: Double) -> String {
        String(format: "%.6f", max(0, floor(time * 1_000_000 + 1e-7) / 1_000_000))
    }

    /// Read compressed presentation timestamps on the editor's asset clock.
    /// Holds alone use this lookup; moving clips retain ordinary graph sampling.
    @concurrent
    static func assetHoldTime(_ source: URL, time: Double) async throws -> Double {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw UnsupportedTiming() }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: max(0, time) + 1, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw UnsupportedTiming() }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? UnsupportedTiming() }
        defer { reader.cancelReading() }
        let target = (max(0, time) * 60000).rounded() / 60000
        var selected: Double?
        // Compressed samples can arrive in decode order (B frames). Check
        // presentation timestamps throughout the bounded reader range.
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts.isFinite, pts <= target + 1e-9, pts >= (selected ?? -.infinity) { selected = pts }
        }
        if reader.status == .failed { throw reader.error ?? UnsupportedTiming() }
        guard let selected else { throw UnsupportedTiming() }
        return selected
    }

}
