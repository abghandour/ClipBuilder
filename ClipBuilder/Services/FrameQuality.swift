import Foundation
import CoreGraphics
import ImageIO

nonisolated enum FrameQuality {
    struct Metrics: Sendable {
        var luminance: Double
        var variance: Double
    }
    static func grayscale(_ data: Data, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? pixels : nil
    }
    static func metrics(_ data: Data) -> Metrics? {
        let side = 64
        guard let pixels = grayscale(data, width: side, height: side) else { return nil }
        var values: [Double] = []
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                values.append(Double(Int(pixels[i - 1]) + Int(pixels[i + 1]) + Int(pixels[i - side]) + Int(pixels[i + side]) - 4 * Int(pixels[i])))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return Metrics(luminance: pixels.reduce(0) { $0 + Double($1) } / Double(pixels.count) / 255, variance: variance)
    }
    static func survivingIndices(_ metrics: [Metrics]) -> [Int] {
        guard !metrics.isEmpty else { return [] }
        let sorted = metrics.map(\.variance).sorted()
        let median = sorted[sorted.count / 2]
        let surviving = metrics.indices.filter { metrics[$0].luminance >= 0.08 && metrics[$0].luminance <= 0.95 && metrics[$0].variance >= median * 0.25 }
        return surviving.count >= 4 ? surviving : Array(metrics.indices)
    }
    static func differenceHash(_ data: Data) -> UInt64? {
        guard let pixels = grayscale(data, width: 9, height: 8) else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 where pixels[y * 9 + x] > pixels[y * 9 + x + 1] {
                hash |= UInt64(1) << (y * 8 + x)
            }
        }
        return hash
    }
}
