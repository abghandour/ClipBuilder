import AVFoundation

/// A recording's audio as peak levels over a few seconds, for the boundary
/// waveforms in the range review column: one level per millisecond-scale
/// bin, folded to the view's width when drawn.
nonisolated struct AudioPeaks: Sendable, Equatable {
    /// The span the levels cover, in source seconds.
    var span: ClosedRange<Double>
    /// Absolute sample peaks (0...1 for full scale), evenly spaced over `span`.
    var levels: [Float]

    static let binsPerSecond = 1000.0

    var isEmpty: Bool { levels.isEmpty || span.upperBound <= span.lowerBound }

    func covers(_ window: ClosedRange<Double>) -> Bool {
        !isEmpty && span.lowerBound <= window.lowerBound + 1e-6 && span.upperBound >= window.upperBound - 1e-6
    }

    /// Peaks of mono `samples` taken at `sampleRate`, the first at `start`,
    /// one bin per `1 / binsPerSecond` seconds.
    static func binned(_ samples: [Float], sampleRate: Double, start: Double) -> AudioPeaks {
        guard sampleRate > 0, !samples.isEmpty else { return AudioPeaks(span: start...start, levels: []) }
        let perBin = max(1, Int((sampleRate / binsPerSecond).rounded()))
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / perBin + 1)
        var index = 0
        while index < samples.count {
            let upper = min(samples.count, index + perBin)
            var peak: Float = 0
            for i in index..<upper { peak = max(peak, abs(samples[i])) }
            levels.append(min(1, peak))
            index = upper
        }
        let duration = Double(levels.count * perBin) / sampleRate
        return AudioPeaks(span: start...(start + duration), levels: levels)
    }

    /// The window folded to `columns` levels (each the loudest bin it
    /// covers), scaled so the window's loudest column fills the height. A
    /// quiet window is scaled no more than a whisper's worth, so room noise
    /// does not look like speech.
    func columns(_ columns: Int, window: ClosedRange<Double>) -> [Float] {
        guard columns > 0, !isEmpty, window.upperBound > window.lowerBound else { return [] }
        let binSeconds = (span.upperBound - span.lowerBound) / Double(levels.count)
        let width = window.upperBound - window.lowerBound
        var result = [Float](repeating: 0, count: columns)
        for column in 0..<columns {
            let from = window.lowerBound + width * Double(column) / Double(columns)
            let to = window.lowerBound + width * Double(column + 1) / Double(columns)
            let first = Int(((from - span.lowerBound) / binSeconds).rounded(.down))
            let last = Int(((to - span.lowerBound) / binSeconds).rounded(.up))
            let lower = max(0, first), upper = min(levels.count, max(last, first + 1))
            guard lower < upper else { continue }
            var peak: Float = 0
            for i in lower..<upper { peak = max(peak, levels[i]) }
            result[column] = peak
        }
        let loudest = max(result.max() ?? 0, Self.quietFloor)
        return result.map { min(1, $0 / loudest) }
    }

    /// The loudest level a window is scaled up from (about -26 dBFS).
    static let quietFloor: Float = 0.05

    /// Where `time` sits across a view `width` wide showing `window`.
    static func x(for time: Double, in window: ClosedRange<Double>, width: Double) -> Double {
        let span = window.upperBound - window.lowerBound
        return span > 0 ? (time - window.lowerBound) / span * width : 0
    }

    /// The time under `x` across a view `width` wide showing `window`.
    static func time(forX x: Double, in window: ClosedRange<Double>, width: Double) -> Double {
        guard width > 0 else { return window.lowerBound }
        return window.lowerBound + min(max(x / width, 0), 1) * (window.upperBound - window.lowerBound)
    }

    /// The window of half-width `halfWidth` centred on `center`, kept inside
    /// the recording where it can be.
    static func window(center: Double, halfWidth: Double, limits: ClosedRange<Double>) -> ClosedRange<Double> {
        var lower = center - halfWidth, upper = center + halfWidth
        if limits.upperBound - limits.lowerBound >= halfWidth * 2 {
            if lower < limits.lowerBound { upper += limits.lowerBound - lower; lower = limits.lowerBound }
            if upper > limits.upperBound { lower -= upper - limits.upperBound; upper = limits.upperBound }
        }
        return lower...upper
    }

    /// The zoom steps, as the half-width of the window in seconds.
    static let zoomLevels: [Double] = [2, 1, 0.5, 0.25]
}

/// Reads and caches peaks. Decoding a few seconds of audio takes a few
/// milliseconds, off the main actor; the last chunks per file are kept so
/// dragging inside them never decodes again.
actor AudioPeaksReader {
    static let shared = AudioPeaksReader()

    private var cache: [(url: URL, peaks: AudioPeaks)] = []
    private static let cacheLimit = 12
    /// Seconds read on each side of the requested window, so nearby drags hit the cache.
    private static let margin = 3.0
    private static let sampleRate = 16_000.0

    func peaks(url: URL, window: ClosedRange<Double>) async throws -> AudioPeaks {
        if let hit = cache.last(where: { $0.url == url && $0.peaks.covers(window) }) { return hit.peaks }
        let start = max(0, window.lowerBound - Self.margin)
        let end = window.upperBound + Self.margin
        let peaks = try await Self.read(url: url, span: start...end)
        cache.append((url, peaks))
        if cache.count > Self.cacheLimit { cache.removeFirst(cache.count - Self.cacheLimit) }
        return peaks
    }

    private static func read(url: URL, span: ClosedRange<Double>) async throws -> AudioPeaks {
        let asset = try await DriveLocalAsset.make(url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return AudioPeaks(span: span.lowerBound...span.lowerBound, levels: []) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: span.lowerBound, preferredTimescale: 600),
                                       duration: CMTime(seconds: span.upperBound - span.lowerBound, preferredTimescale: 600))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }
        var samples: [Float] = []
        samples.reserveCapacity(Int((span.upperBound - span.lowerBound) * sampleRate))
        var first: Double?
        while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if first == nil { first = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= MemoryLayout<Float>.size else { continue }
            let count = length / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            chunk.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: bytes.baseAddress!)
            }
            samples += chunk
        }
        let start = first.map { $0.isFinite ? $0 : span.lowerBound } ?? span.lowerBound
        return AudioPeaks.binned(samples, sampleRate: sampleRate, start: start)
    }
}
