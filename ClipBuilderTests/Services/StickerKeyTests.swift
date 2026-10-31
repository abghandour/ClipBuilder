import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Clip_Builder

@Suite("Sticker key")
struct StickerKeyTests {
    private func canvas() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 25, y: 25, width: 50, height: 50))
        return try #require(context.makeImage())
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes[(y * image.width + x) * 4 + 3]
        }
    }

    @Test func greenBackgroundBecomesTransparentAndCircleStaysOpaque() throws {
        let keyed = StickerKey.keyed(try canvas(), color: (0, 1, 0))
        #expect(try alpha(keyed, x: 0, y: 0) == 0)
        #expect(try alpha(keyed, x: 50, y: 50) == 255)
        let trimmed = StickerKey.trimmedToContent(keyed)
        #expect((50...56).contains(trimmed.width))
        #expect((50...56).contains(trimmed.height))
        #expect(try alpha(trimmed, x: trimmed.width / 2, y: trimmed.height / 2) == 255)
    }

    @Test(arguments: [(1.0, 1.0, 0.0), (0.0, 1.0, 1.0), (1.0, 0.5, 0.0)])
    func neighbouringHuesStayOpaque(_ fill: (Double, Double, Double)) throws {
        let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
            bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.setFillColor(CGColor(red: fill.0, green: fill.1, blue: fill.2, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        let keyed = StickerKey.keyed(try #require(context.makeImage()), color: (0, 1, 0))
        #expect(try alpha(keyed, x: 2, y: 2) == 0)
        #expect(try alpha(keyed, x: 20, y: 20) == 255)
    }

    @Test func transparentCanvasKeepsValidDimensions() throws {
        let context = try #require(CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8,
            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let trimmed = StickerKey.trimmedToContent(image)
        #expect(trimmed.width == 20)
        #expect(trimmed.height == 30)
    }

    @Test func savedStickerSurvivesRawRemovalAndRetainsProvenance() throws {
        let directory = try TempDirectory(prefix: "StickerSave")
        let raw = directory.url.appendingPathComponent("raw.png")
        let destination = try #require(CGImageDestinationCreateWithURL(raw as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try canvas(), nil)
        #expect(CGImageDestinationFinalize(destination))
        let folder = directory.url.appendingPathComponent("Generated")
        let provenance = AIProvenance(provider: "gemini", task: AITask.imageGeneration.rawValue)
        let result = try ImageGeneration.save(raw: raw, mode: .sticker, prompt: "red circle", folder: folder, provenance: provenance)
        try FileManager.default.removeItem(at: raw)
        let image = try ImageGeneration.decode(Data(contentsOf: URL(fileURLWithPath: result.path)))
        #expect(image.width == result.width)
        #expect(try alpha(image, x: 0, y: 0) == 0)
        #expect(try alpha(image, x: image.width / 2, y: image.height / 2) == 255)
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: result.path).appendingPathExtension("json"))) as? [String: Any])
        #expect(record["prompt"] as? String == "red circle")
        #expect(record["outputPath"] as? String == result.path)
        #expect((record["provenance"] as? [String: Any])?["task"] as? String == "image_generation")
    }
}
