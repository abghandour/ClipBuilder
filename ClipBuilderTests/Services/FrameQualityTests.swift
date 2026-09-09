import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Clip_Builder

struct FrameQualityTests {
    private func gradient(reverse: Bool, jpeg: Bool) throws -> Data {
        let width = 90, height = 80
        let bytes = (0..<(width * height)).map { index -> UInt8 in
            let value = UInt8((index % width) * 255 / (width - 1))
            return reverse ? 255 - value : value
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
    @Test func hashSurvivesEncoding() throws {
        let original = try #require(FrameQuality.differenceHash(gradient(reverse: false, jpeg: false)))
        let reencoded = try #require(FrameQuality.differenceHash(gradient(reverse: false, jpeg: true)))
        let different = try #require(FrameQuality.differenceHash(gradient(reverse: true, jpeg: true)))
        #expect((original ^ reencoded).nonzeroBitCount <= 2)
        #expect((original ^ different).nonzeroBitCount > 20)
    }
    @Test func conservativeFilter() {
        let metrics: [FrameQuality.Metrics] = [.init(luminance: 0, variance: 100), .init(luminance: 0.5, variance: 1)]
            + Array(repeating: .init(luminance: 0.5, variance: 100), count: 4)
        #expect(FrameQuality.survivingIndices(metrics) == [2, 3, 4, 5])
        #expect(FrameQuality.survivingIndices(Array(metrics.prefix(3))) == [0, 1, 2])
        let times = [0.0, 1, 2, 3, 4, 5]
        let filtered = FrameQuality.survivingIndices(metrics).map { times[$0] }
        let parsed = CoverFramePicker.parse(#"{"covers":[{"t":2,"why":"sharp"}]}"#, sampledTimes: filtered)
        #expect(parsed.first?.time == 2)
    }
}

extension FrameQualityTests {
    private func gray(_ value: (Int, Int) -> UInt8) throws -> Data {
        let side = 64
        let bytes = (0..<(side * side)).map { value($0 % side, $0 / side) }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: side, height: side, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
    @Test func metricsFromRealPixels() throws {
        let black = try #require(FrameQuality.metrics(gray { _, _ in 0 }))
        let flat = try #require(FrameQuality.metrics(gray { _, _ in 128 }))
        let checker = try #require(FrameQuality.metrics(gray { x, y in (x / 4 + y / 4) % 2 == 0 ? 30 : 220 }))
        #expect(black.luminance < 0.01 && black.variance == 0)
        #expect(abs(flat.luminance - 0.5) < 0.02 && flat.variance == 0)
        #expect(abs(checker.luminance - 0.5) < 0.1 && checker.variance > 100)
        #expect(FrameQuality.metrics(Data("not an image".utf8)) == nil)
        let all = [black, flat] + Array(repeating: checker, count: 4)
        #expect(FrameQuality.survivingIndices(all) == [2, 3, 4, 5])
    }
}
