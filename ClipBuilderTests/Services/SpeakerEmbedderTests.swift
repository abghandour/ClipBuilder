import AVFoundation
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Speaker embeddings")
struct SpeakerEmbedderTests {
    /// A voiced-sounding signal: a pulse train at `pitch` Hz with a few
    /// formant-like resonances, 16 kHz, `seconds` long.
    private func voice(pitch: Double, seconds: Double, formants: [Double]) -> [Float] {
        let n = Int(16_000 * seconds)
        return (0..<n).map { i in
            let t = Double(i) / 16_000
            var sample = 0.0
            for harmonic in 1...30 {
                let f = pitch * Double(harmonic)
                let gain = formants.reduce(0.0) { $0 + 1 / (1 + pow((f - $1) / 120, 2)) }
                sample += gain * sin(2 * .pi * f * t) / Double(harmonic)
            }
            return Float(sample * 0.05)
        }
    }

    @Test("the bundled model loads and gives unit-length embeddings that keep a voice near itself")
    func embeds() throws {
        try #require(SpeakerEmbedder.isAvailable, "SpeakerEmbedding.mlmodelc missing from the app bundle")
        let low = voice(pitch: 110, seconds: 2, formants: [500, 1500, 2500])
        let lowAgain = voice(pitch: 112, seconds: 2, formants: [520, 1480, 2550])
        let high = voice(pitch: 240, seconds: 2, formants: [800, 1900, 3000])
        let a = try SpeakerEmbedder.embed(low)
        let b = try SpeakerEmbedder.embed(lowAgain)
        let c = try SpeakerEmbedder.embed(high)
        #expect(a.count == SpeakerEmbedder.dimension)
        #expect(abs(sqrt(a.reduce(0) { $0 + $1 * $1 }) - 1) < 1e-3)
        func cosine(_ x: [Double], _ y: [Double]) -> Double { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(cosine(a, a) > 0.999)
        #expect(cosine(a, b) > cosine(a, c))
    }

    @Test("windows follow the speech ranges at two seconds stepping by half, and skip stubs")
    func windows() throws {
        try #require(SpeakerEmbedder.isAvailable)
        let temp = try TempDirectory(prefix: "Embedder")
        let url = temp.url.appendingPathComponent("voice.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let samples = voice(pitch: 130, seconds: 6, formants: [600, 1600, 2600])
        // The writer flushes when it goes away; keep it in its own scope.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData!.pointee.update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
        let windows = try SpeakerEmbedder.windows(audioURL: url, speech: [0...5, 5.2...5.8])
        // 0–5 s: starts at 0, 0.5, … until a window reaches the end (start 3 → 5 s), so seven;
        // the 0.6 s stub yields none.
        #expect(windows.count == 7)
        #expect(windows.first?.start == 0 && windows.first?.end == 2)
        #expect(windows.last?.end == 5)
        #expect(windows.allSatisfy { $0.vector.count == SpeakerEmbedder.dimension })
    }
}
