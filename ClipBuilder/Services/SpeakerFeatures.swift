import Accelerate
import AVFoundation
import Foundation

/// Voice features for telling speakers apart, for any number of them:
/// MFCCs with deltas and pitch statistics pooled over short windows of
/// speech, from the 16 kHz mono audio the app already extracts. Clustering
/// groups windows into voices; the count is discovered, not assumed.
nonisolated enum SpeakerFeatures {
    static let sampleRate = 16_000.0
    static let frameLength = 400        // 25 ms
    static let hop = 160                // 10 ms
    static let melBands = 26
    static let coefficients = 13
    /// One feature vector per this many seconds of speech, stepping by half.
    static let windowSeconds = 1.0
    static let windowStep = 0.5

    struct Window: Sendable, Equatable {
        var start: Double
        var end: Double
        var vector: [Double]
    }

    /// Feature windows covering the given speech ranges of the audio file.
    static func windows(audioURL: URL, speech: [ClosedRange<Double>]) throws -> [Window] {
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        let scale = rate / sampleRate
        var result: [Window] = []
        let filterbank = melFilterbank()
        let dct = dctMatrix()
        var fft = FFTSetup(length: 512)
        for range in speech {
            var start = range.lowerBound
            while start + windowSeconds * 0.6 <= range.upperBound {
                let end = min(range.upperBound, start + windowSeconds)
                let frames = AVAudioFrameCount(((end - start) * rate).rounded())
                guard frames > AVAudioFrameCount(frameLength), let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
                file.framePosition = AVAudioFramePosition(start * rate)
                try file.read(into: buffer, frameCount: frames)
                if let vector = features(buffer, resampleScale: scale, filterbank: filterbank, dct: dct, fft: &fft) {
                    result.append(Window(start: start, end: end, vector: vector))
                }
                start += windowStep
            }
        }
        return result
    }

    /// Pooled MFCC + delta statistics and pitch statistics of one window.
    static func features(_ buffer: AVAudioPCMBuffer, resampleScale: Double = 1, filterbank: [[Float]]? = nil,
                         dct: [[Float]]? = nil, fft: inout FFTSetup) -> [Double]? {
        guard let channel = buffer.floatChannelData?.pointee else { return nil }
        let count = Int(buffer.frameLength)
        var samples = [Float](UnsafeBufferPointer(start: channel, count: count))
        if abs(resampleScale - 1) > 0.01 {
            // Nearest-sample decimation is enough for the 16 kHz features.
            let target = Int(Double(count) / resampleScale)
            samples = (0..<target).map { samples[min(count - 1, Int(Double($0) * resampleScale))] }
        }
        guard samples.count >= frameLength * 4 else { return nil }
        let bank = filterbank ?? melFilterbank()
        let cosines = dct ?? dctMatrix()
        var mfccs: [[Float]] = []
        var pitches: [Double] = []
        var energies: [Float] = []
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameLength, isHalfWindow: false)
        var frameStart = 0
        while frameStart + frameLength <= samples.count {
            let frame = Array(samples[frameStart..<(frameStart + frameLength)])
            let energy = vDSP.sumOfSquares(frame) / Float(frameLength)
            energies.append(energy)
            if energy > 1e-6 {
                let spectrum = fft.powerSpectrum(vDSP.multiply(frame, window))
                var logMel = [Float](repeating: 0, count: melBands)
                let bandEnergies = (0..<melBands).map { vDSP.dot(bank[$0], spectrum) }
                // A floor relative to the frame's loudest band keeps empty
                // bands from turning numeric noise into features.
                let floor = max(1e-8, (bandEnergies.max() ?? 0) * 1e-3)
                for band in 0..<melBands { logMel[band] = log(max(floor, bandEnergies[band])) }
                var mfcc = [Float](repeating: 0, count: coefficients)
                for c in 0..<coefficients { mfcc[c] = vDSP.dot(cosines[c], logMel) }
                mfccs.append(mfcc)
                if let f0 = pitch(frame) { pitches.append(f0) }
            }
            frameStart += hop
        }
        guard mfccs.count >= 8 else { return nil }
        // Cepstral mean subtraction per window keeps the channel out of the voice.
        let mean = (0..<coefficients).map { c in mfccs.reduce(0) { $0 + $1[c] } / Float(mfccs.count) }
        let centered = mfccs.map { frame in (0..<coefficients).map { frame[$0] - mean[$0] } }
        let deltas = centered.indices.map { i -> [Float] in
            let a = centered[max(0, i - 2)], b = centered[min(centered.count - 1, i + 2)]
            return (0..<coefficients).map { (b[$0] - a[$0]) / 4 }
        }
        func stats(_ rows: [[Float]]) -> [Double] {
            (0..<coefficients).flatMap { c -> [Double] in
                let values = rows.map { Double($0[c]) }
                let m = values.reduce(0, +) / Double(values.count)
                let v = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
                return [m, sqrt(v)]
            }
        }
        // Drop c0 (loudness) from the means; keep its spread as dynamics.
        var vector = stats(centered)
        vector[0] = 0
        vector += stats(deltas)
        let voiced = Double(pitches.count) / Double(max(1, mfccs.count))
        let logs = pitches.map { log($0) }
        let pitchMean = logs.isEmpty ? log(150.0) : logs.reduce(0, +) / Double(logs.count)
        let pitchSpread = logs.isEmpty ? 0 : sqrt(logs.reduce(0) { $0 + ($1 - pitchMean) * ($1 - pitchMean) } / Double(logs.count))
        // Pitch counts several times over: it separates voices the timbre
        // statistics blur.
        vector += [pitchMean * 4, pitchMean * 4, pitchSpread * 2, voiced * 2]
        return vector
    }

    /// Fundamental frequency of a voiced frame by normalized autocorrelation
    /// over 70–400 Hz; nil when the frame is not clearly periodic.
    static func pitch(_ frame: [Float]) -> Double? {
        let minLag = Int(sampleRate / 400), maxLag = Int(sampleRate / 70)
        guard frame.count > maxLag + 1 else { return nil }
        let energy = vDSP.sumOfSquares(frame)
        guard energy > 1e-6 else { return nil }
        var best = (lag: 0, value: 0.0)
        var lag = minLag
        while lag <= maxLag {
            let a = Array(frame[0..<(frame.count - lag)])
            let b = Array(frame[lag..<frame.count])
            let value = Double(vDSP.dot(a, b)) / Double(energy)
            if value > best.value { best = (lag, value) }
            lag += 1
        }
        guard best.value > 0.45, best.lag > 0 else { return nil }
        return sampleRate / Double(best.lag)
    }

    // MARK: - Filterbank and DCT

    static func melFilterbank(bins: Int = 257) -> [[Float]] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let low = mel(60), high = mel(sampleRate / 2)
        let points = (0...(melBands + 1)).map { hz(low + (high - low) * Double($0) / Double(melBands + 1)) }
        let binOf = points.map { Int(($0 / (sampleRate / 2)) * Double(bins - 1)) }
        return (0..<melBands).map { band in
            var filter = [Float](repeating: 0, count: bins)
            let left = binOf[band], center = binOf[band + 1], right = binOf[band + 2]
            for bin in left..<max(left + 1, center) { filter[bin] = Float(bin - left) / Float(max(1, center - left)) }
            for bin in center..<max(center + 1, right) { filter[bin] = Float(right - bin) / Float(max(1, right - center)) }
            return filter
        }
    }

    static func dctMatrix() -> [[Float]] {
        (0..<coefficients).map { c in
            (0..<melBands).map { m in Float(cos(Double.pi * Double(c) * (Double(m) + 0.5) / Double(melBands))) }
        }
    }

    /// A real FFT wrapper producing the one-sided power spectrum.
    struct FFTSetup {
        let length: Int
        private let setup: vDSP.FFT<DSPSplitComplex>
        init(length: Int) {
            self.length = length
            setup = vDSP.FFT(log2n: vDSP_Length(log2(Double(length))), radix: .radix2, ofType: DSPSplitComplex.self)!
        }
        func powerSpectrum(_ frame: [Float]) -> [Float] {
            var input = frame + [Float](repeating: 0, count: max(0, length - frame.count))
            let half = length / 2
            var real = [Float](repeating: 0, count: half)
            var imaginary = [Float](repeating: 0, count: half)
            var output = [Float](repeating: 0, count: half + 1)
            input.withUnsafeMutableBufferPointer { inputPointer in
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                        inputPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                        }
                        var forward = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                        setup.forward(input: split, output: &forward)
                        for bin in 0..<half {
                            output[bin] = forward.realp[bin] * forward.realp[bin] + forward.imagp[bin] * forward.imagp[bin]
                        }
                        // Nyquist sits in imagp[0] of the packed result.
                        output[half] = forward.imagp[0] * forward.imagp[0]
                        output[0] = forward.realp[0] * forward.realp[0]
                    }
                }
            }
            return output
        }
    }
}

/// Groups feature windows into voices without a fixed count: average-linkage
/// merging of standardized vectors until the closest voices are farther apart
/// than a threshold, capped at a maximum when the layout says how many
/// people there are.
nonisolated enum SpeakerClustering {
    struct Result: Sendable, Equatable {
        /// Cluster index per window.
        var labels: [Int]
        /// Standardized centroids per cluster.
        var centroids: [[Double]]
        /// The standardized vectors the labels refer to.
        var vectors: [[Double]]
    }

    /// `maximum` bounds the number of voices; `minimum` (2 when several faces
    /// are on screen) keeps two similar voices apart; `threshold` is the
    /// average-linkage distance, in standard deviations per dimension, at
    /// which two voices are one.
    /// How vectors compare. Spectral averages are standardized per
    /// coordinate and compared by distance in standard deviations; neural
    /// embeddings are unit vectors compared by cosine, the space the model
    /// was trained to separate voices in (standardizing them amplifies
    /// their quiet coordinates and blurs the voices together).
    enum Geometry: Sendable {
        case standardized
        case cosine
    }

    /// Centroids whose cosine reaches this are one voice.
    static let mergeCosine = 0.45
    /// Softmax temperature over cosine: a 0.4 gap in cosine is about 55:1.
    static let cosineTemperature = 10.0

    static func cluster(_ windows: [[Double]], minimum: Int = 1, maximum: Int = 8, threshold: Double = 1.3,
                        geometry: Geometry = .standardized) -> Result {
        let vectors = geometry == .cosine ? windows.map(normalized) : standardize(windows)
        guard vectors.count > 1 else { return Result(labels: vectors.map { _ in 0 }, centroids: vectors.isEmpty ? [] : [vectors[0]], vectors: vectors) }
        let dimension = Double(vectors[0].count)
        let k = max(1, min(maximum, vectors.count / 3))
        // Farthest-first seeding from the most central vector, then Lloyd
        // iterations: balanced groups rather than one core plus outliers.
        let mean = (0..<vectors[0].count).map { i in vectors.reduce(0) { $0 + $1[i] } / Double(vectors.count) }
        var centroids = [vectors.min { distance($0, mean) < distance($1, mean) } ?? vectors[0]]
        while centroids.count < k {
            let next = vectors.max { a, b in
                (centroids.map { distance(a, $0) }.min() ?? 0) < (centroids.map { distance(b, $0) }.min() ?? 0)
            }
            guard let next else { break }
            centroids.append(next)
        }
        var labels = [Int](repeating: 0, count: vectors.count)
        for _ in 0..<25 {
            let next = vectors.map { v in centroids.indices.min { distance(v, centroids[$0]) < distance(v, centroids[$1]) } ?? 0 }
            if next == labels { break }
            labels = next
            for c in centroids.indices {
                let members = vectors.indices.filter { labels[$0] == c }
                guard !members.isEmpty else { continue }
                centroids[c] = (0..<vectors[0].count).map { i in members.reduce(0) { $0 + vectors[$1][i] } / Double(members.count) }
            }
        }
        // Two groups whose centers are no farther apart than their own
        // spread are one voice; merge down to the minimum the picture demands.
        var groups: [[Int]] = centroids.indices.map { c in vectors.indices.filter { labels[$0] == c } }
        groups.removeAll { $0.isEmpty }
        func centroid(_ members: [Int]) -> [Double] {
            (0..<vectors[0].count).map { i in members.reduce(0) { $0 + vectors[$1][i] } / Double(members.count) }
        }
        func radius(_ members: [Int], _ center: [Double]) -> Double {
            members.reduce(0) { $0 + distance(vectors[$1], center) } / Double(members.count) / dimension.squareRoot()
        }
        var centers = groups.map(centroid)
        while groups.count > max(1, minimum) {
            var best: (Int, Int, Double)?
            for a in 0..<groups.count {
                for b in (a + 1)..<groups.count {
                    // Centers closer than the threshold in per-dimension
                    // standard deviations are one voice; wide groups get
                    // a little more room.
                    let ratio: Double
                    switch geometry {
                    case .standardized:
                        let d = distance(centers[a], centers[b]) / dimension.squareRoot()
                        let spread = (radius(groups[a], centers[a]) + radius(groups[b], centers[b])) / 2
                        ratio = d / max(threshold, 1.2 * spread)
                    case .cosine:
                        ratio = (1 - cosine(centers[a], centers[b])) / (1 - mergeCosine)
                    }
                    if best == nil || ratio < best!.2 { best = (a, b, ratio) }
                }
            }
            guard let (a, b, ratio) = best, ratio <= 1 else { break }
            groups[a] += groups[b]; groups.remove(at: b)
            centers[a] = centroid(groups[a]); centers.remove(at: b)
        }
        let order = groups.indices.sorted { groups[$0].count > groups[$1].count }
        var final = [Int](repeating: 0, count: vectors.count)
        for (label, index) in order.enumerated() { for m in groups[index] { final[m] = label } }
        return Result(labels: final, centroids: order.map { centers[$0] }, vectors: vectors)
    }

    /// How much each voice explains a vector: softmax over negative squared
    /// distances to the centroids, in per-dimension units.
    static func posterior(_ vector: [Double], centroids: [[Double]],
                          geometry: Geometry = .standardized) -> [Double] {
        guard !centroids.isEmpty else { return [] }
        let dimension = Double(vector.count)
        let scores: [Double]
        switch geometry {
        case .standardized:
            scores = centroids.map { -pow(distance(vector, $0) / dimension.squareRoot(), 2) * 2 }
        case .cosine:
            scores = centroids.map { cosine(vector, $0) * cosineTemperature }
        }
        let peak = scores.max() ?? 0
        let weights = scores.map { exp($0 - peak) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / max(1e-12, total) }
    }

    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let norms = sqrt(a.reduce(0) { $0 + $1 * $1 }) * sqrt(b.reduce(0) { $0 + $1 * $1 })
        return norms > 1e-12 ? dot / norms : 0
    }

    static func normalized(_ vector: [Double]) -> [Double] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return norm > 1e-12 ? vector.map { $0 / norm } : vector
    }

    static func standardize(_ vectors: [[Double]]) -> [[Double]] {
        guard let first = vectors.first else { return [] }
        let n = Double(vectors.count)
        let means = first.indices.map { i in vectors.reduce(0) { $0 + $1[i] } / n }
        let spreads = first.indices.map { i in sqrt(vectors.reduce(0) { $0 + pow($1[i] - means[i], 2) } / n) }
        return vectors.map { v in v.indices.map { spreads[$0] > 1e-9 ? (v[$0] - means[$0]) / spreads[$0] : 0 } }
    }
}
