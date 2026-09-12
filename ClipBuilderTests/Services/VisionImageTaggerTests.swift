import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Testing
@testable import Clip_Builder

struct VisionImageTaggerTests {
    @Test func graphicFixture() async throws {
        let context = try #require(CGContext(data: nil, width: 512, height: 512,
            bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        for index in 0..<12 {
            context.textPosition = CGPoint(x: 12, y: 475 - index * 39)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "TRAINING CAMP ROUND 1", attributes: attributes))
            CTLineDraw(line, context)
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let signals = try await VisionImageTagger.inspect(data as Data)
        #expect(VisionImageTagger.localTag(signals) == "graphic")
    }
    @Test func conservativeRules() {
        #expect(VisionImageTagger.localTag(.init(labels: [:], faces: [], textArea: 0.3)) == "graphic")
        #expect(VisionImageTagger.localTag(.init(labels: ["crowd": 0.8], faces: [], textArea: 0)) == "crowd")
        let face = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let signals = VisionImageTagger.Signals(labels: ["crowd": 0.8], faces: [face], textArea: 0)
        #expect(VisionImageTagger.localTag(signals) == nil)
        #expect(VisionImageTagger.hints(signals).contains("crowd"))
    }
}
