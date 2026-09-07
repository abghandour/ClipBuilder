import Foundation

/// Consumes arbitrary pipe chunks while preserving the original 512-sample
/// windows and summation order. Retains energies, never the full PCM track.
nonisolated final class OnsetEnergyAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var sum = 0.0
    private var samplesInHop = 0
    private var values: [Double] = []
    static let hop = 512

    func append(_ chunk: Data) {
        lock.withLock {
            pending.append(chunk)
            let count = pending.count / 4
            pending.withUnsafeBytes { raw in
                for index in 0..<count {
                    let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
                    let value = Double(Float(bitPattern: bits))
                    sum += value * value
                    samplesInHop += 1
                    if samplesInHop == Self.hop {
                        values.append(sum / Double(Self.hop))
                        samplesInHop = 0
                        sum = 0
                    }
                }
            }
            pending = Data(pending.suffix(pending.count % 4))
        }
    }

    var energies: [Double] { lock.withLock { values } }
}
