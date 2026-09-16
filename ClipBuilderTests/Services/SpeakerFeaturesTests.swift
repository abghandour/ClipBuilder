import AVFoundation
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Speaker features and clustering")
struct SpeakerFeaturesTests {
    /// A synthetic voice: a pulse train at the pitch through a crude formant
    /// filter, with a little noise, one second at 16 kHz.
    private func voice(pitch: Double, formant: Double, seed: UInt64) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let count = 16_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        var state = seed
        func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 2000
        }
        let period = 16_000 / pitch
        var y1: Float = 0, y2: Float = 0
        let r: Float = 0.97, theta = Float(2 * Double.pi * formant / 16_000)
        for i in 0..<count {
            let pulse: Float = Double(i).truncatingRemainder(dividingBy: period) < 1 ? 1 : 0
            let x = pulse + 0.0005 * noise()
            // Two-pole resonator around the formant.
            let y = x + 2 * r * cos(theta) * y1 - r * r * y2
            y2 = y1; y1 = y
            buffer.floatChannelData!.pointee[i] = y * 0.05
        }
        return buffer
    }

    @Test("two synthetic voices give two clusters that follow the voice, not the time")
    func separatesVoices() throws {
        var fft = SpeakerFeatures.FFTSetup(length: 512)
        var vectors: [[Double]] = []
        var truth: [Int] = []
        for i in 0..<12 {
            let low = i % 2 == 0
            let buffer = voice(pitch: low ? 110 : 190, formant: low ? 500 : 900, seed: UInt64(i + 1))
            let vector = try #require(SpeakerFeatures.features(buffer, fft: &fft))
            #expect(vector.count == 56 && vector.allSatisfy(\.isFinite))
            vectors.append(vector)
            truth.append(low ? 0 : 1)
        }
        let result = SpeakerClustering.cluster(vectors, minimum: 2, maximum: 4)
        let standardized = SpeakerClustering.standardize(vectors)
        let matrix = standardized.indices.map { a in
            standardized.indices.map { b in String(format: "%.2f", SpeakerClustering.distance(standardized[a], standardized[b]) / sqrt(Double(standardized[a].count))) }.joined(separator: " ")
        }.joined(separator: "\n")
        #expect(result.centroids.count == 2, "labels \(result.labels)\n\(matrix)")
        let agree = zip(result.labels, truth).count { $0 == $1 }
        #expect(agree == 12 || agree == 0, "labels \(result.labels)")
        // Pitch is measured near the truth.
        let low = voice(pitch: 110, formant: 500, seed: 3)
        let frame = Array(UnsafeBufferPointer(start: low.floatChannelData!.pointee, count: 400))
        withExtendedLifetime(low) {}
        let pitch = try #require(SpeakerFeatures.pitch(frame))
        #expect(abs(pitch - 110) < 6)
        // Posteriors are decisive for a member of each voice.
        let p = SpeakerClustering.posterior(result.vectors[0], centroids: result.centroids)
        #expect((p.max() ?? 0) > 0.8)
    }

    @Test("the power spectrum of a pure tone peaks at its bin")
    func spectrumPeak() {
        let fft = SpeakerFeatures.FFTSetup(length: 512)
        let tone = (0..<400).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 16_000)) }
        let spectrum = fft.powerSpectrum(tone)
        let peak = spectrum.indices.max { spectrum[$0] < spectrum[$1] } ?? 0
        // 1000 Hz at 16 kHz over 512 points is bin 32.
        #expect(abs(peak - 32) <= 1, "peak bin \(peak)")
    }
}
