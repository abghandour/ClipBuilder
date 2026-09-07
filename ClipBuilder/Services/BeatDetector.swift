import Foundation

/// Music onset detection for beat-synced cuts: decodes a track to mono PCM
/// with ffmpeg and finds energy-flux peaks — the "hits" a viewer would nod
/// to. No FFT, no tempo model: for cut snapping, landing on any strong onset
/// is what reads as beat-synced.
actor BeatDetector {
    static let shared = BeatDetector()

    private var cache: [String: Task<[Double], Never>] = [:]

    /// Onset timestamps (seconds) for the track, cached per path for the
    /// session. Empty when the file can't be decoded or has no clear onsets.
    func onsets(in url: URL) async -> [Double] {
        let key = url.path
        if let existing = cache[key] { return await existing.value }
        let task = Task { await Self.detect(url: url) }
        cache[key] = task
        return await task.value
    }

    private static let sampleRate = 22050.0
    private static let hop = OnsetEnergyAccumulator.hop

    private static func detect(url: URL) async -> [Double] {
        let accumulator = OnsetEnergyAccumulator()
        guard let executable = try? FFmpeg.ffmpegURL(),
              let result = try? await ProcessRunner.run(
                executable: executable,
                arguments: ["-v", "error", "-i", url.path,
                            "-ac", "1", "-ar", String(Int(sampleRate)),
                            "-f", "f32le", "-"],
                timeout: 120, capture: .streamingStdout { accumulator.append($0) }),
              result.exitCode == 0 else { return [] }
        // Preserve the original 22.05 kHz decode (the podcast artifact is
        // 16 kHz): changing sample rate or PCM precision changes cut positions.
        let energies = accumulator.energies
        guard energies.count > 32 else { return [] }

        let window = 8
        var flux = [Double](repeating: 0, count: energies.count)
        for frame in window..<energies.count {
            let local = energies[(frame - window)..<frame].reduce(0, +) / Double(window)
            flux[frame] = max(0, energies[frame] - local)
        }

        let mean = flux.reduce(0, +) / Double(flux.count)
        let variance = flux.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(flux.count)
        let threshold = mean + 1.3 * variance.squareRoot()
        guard threshold > 0 else { return [] }

        let hopSeconds = Double(hop) / sampleRate
        let minGap = 0.25
        var onsets: [Double] = []
        for frame in 2..<(flux.count - 2) where flux[frame] > threshold {
            // Local maximum over ±2 frames, at least minGap after the last.
            guard flux[frame] >= flux[frame - 1], flux[frame] >= flux[frame - 2],
                  flux[frame] >= flux[frame + 1], flux[frame] >= flux[frame + 2] else { continue }
            let time = Double(frame) * hopSeconds
            if let last = onsets.last, time - last < minGap { continue }
            onsets.append(time)
        }
        return onsets
    }
}
