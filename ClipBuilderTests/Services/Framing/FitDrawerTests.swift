import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Clip_Builder

/// Smooth, nonuniform RGB footage makes scale, orientation and seam errors visible
/// without letting different resampling kernels dominate the comparison.
nonisolated enum FitTestImage {
    static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileReadUnknown) }
        context.interpolationQuality = .high
        return context
    }

    static func source() throws -> CGImage {
        let width = 960, height = 540
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(65 + 70 * x / (width - 1))
                pixels[offset + 1] = UInt8(80 + 65 * y / (height - 1))
                pixels[offset + 2] = UInt8(90 + 50 * x / (width - 1))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw CocoaError(.fileReadUnknown)
        }
        return image
    }

    static func draw(_ source: CGImage, spec: FitSpec) throws -> CGImage {
        let context = try context(width: Int(spec.canvasSize.width), height: Int(spec.canvasSize.height))
        try FitDrawer.draw(source, spec: spec, in: context)
        guard let image = context.makeImage() else { throw CocoaError(.fileReadUnknown) }
        return image
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        // Normalize channel layout before reading PNGs or CoreImage output.
        let context = try context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw CocoaError(.fileReadUnknown) }
        let offset = y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(bytes[offset + $0]) }
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadUnknown) }
        return image
    }
}

@Suite("Framing fit preview pixels")
struct FitDrawerTests {
    @Test func blurredFillHasPictureInBothBandsAndSharpCentre() throws {
        let source = try FitTestImage.source()
        let spec = FitSpec(sourceSize: CGSize(width: source.width, height: source.height),
            destination: CGRect(x: 0, y: 0, width: 540, height: 960), canvasSize: CGSize(width: 540, height: 960),
            fit: .blurredFill, feather: 0.08)
        let actual = try FitTestImage.draw(source, spec: spec)
        for y in [20, 940] {
            let pixel = try FitTestImage.pixel(actual, x: 270, y: y)
            #expect(pixel.prefix(3).allSatisfy { $0 > 20 })
        }
        let reference = try FitTestImage.context(width: 540, height: 960)
        reference.draw(source, in: spec.foreground)
        let expected = try #require(reference.makeImage())
        for x in [100, 270, 440] {
            let a = try FitTestImage.pixel(actual, x: x, y: 480)
            let b = try FitTestImage.pixel(expected, x: x, y: 480)
            #expect(zip(a, b).allSatisfy { abs($0 - $1) <= 2 })
        }
    }

    @Test func featherChangesHardSeamIntoGradient() throws {
        let context = try FitTestImage.context(width: 960, height: 540)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        let source = try #require(context.makeImage())
        var spec = FitSpec(sourceSize: CGSize(width: 960, height: 540),
            destination: CGRect(x: 0, y: 0, width: 540, height: 960), canvasSize: CGSize(width: 540, height: 960),
            fit: .blurredFill, feather: 0)
        let hard = try FitTestImage.draw(source, spec: spec)
        spec.feather = 0.2
        let soft = try FitTestImage.draw(source, spec: spec)
        let edge = Int(spec.foreground.minY)
        let before = try FitTestImage.pixel(hard, x: 270, y: edge - 2)[0]
        let after = try FitTestImage.pixel(hard, x: 270, y: edge + 2)[0]
        #expect(after - before > 35)
        let low = try FitTestImage.pixel(soft, x: 270, y: edge + 2)[0]
        let middle = try FitTestImage.pixel(soft, x: 270, y: edge + 54)[0]
        let high = try FitTestImage.pixel(soft, x: 270, y: edge + 110)[0]
        #expect(abs(low - before) <= 4)
        #expect(middle > low + 15 && high > middle + 15)
        #expect(abs(high - after) <= 2)
    }
}
