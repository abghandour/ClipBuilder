import Foundation
import Testing
@testable import Clip_Builder

@Suite("Streaming onset energies")
struct OnsetEnergyAccumulatorTests {
    @Test("chunk boundaries preserve exact energies and discard incomplete windows")
    func chunkParity() {
        let samples: [Float] = (0..<(512 * 50 + 17)).map { (index: Int) -> Float in
            Float((index * 37) % 101 - 50) / 50
        }
        var bytes = Data()
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        let expected: [Double] = stride(from: 0, to: samples.count - 511, by: 512).map { (start: Int) -> Double in
            var sum = 0.0
            for index in start..<(start + 512) {
                let value = Double(samples[index])
                sum += value * value
            }
            return sum / 512
        }
        for chunkSize in [1, 3, 511, 2048, 65536] {
            let accumulator = OnsetEnergyAccumulator()
            for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                accumulator.append(bytes.subdata(in: start..<min(bytes.count, start + chunkSize)))
            }
            #expect(accumulator.energies == expected)
        }
    }
}
