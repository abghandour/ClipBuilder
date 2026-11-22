import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

nonisolated struct TelestrationPainterTests {
    private let rect = CGRect(x: 50, y: 50, width: 400, height: 400)

    private func drawing(color: Telestration.Figure.Color = .yellow) -> Telestration {
        Telestration(figures: [Telestration.Figure(kind: .line,
            points: [CGPoint(x: 0.1, y: 0.25), CGPoint(x: 0.9, y: 0.25)], color: color, width: 0.016)])
    }

    private func pixels(_ draw: (CGContext) -> Void) throws -> [UInt8] {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
            bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
        context.clear(CGRect(x: 0, y: 0, width: 512, height: 512))
        context.setShouldAntialias(false)
        draw(context)
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 512 * 512 * 4))
    }

    private func pixel(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] {
        // Probe in the default CGContext's bottom-left coordinates; bitmap
        // storage starts with the top row.
        let start = ((511 - y) * 512 + x) * 4
        return Array(pixels[start..<(start + 4)])
    }

    @Test(arguments: Telestration.Figure.Color.allCases)
    func finishedLineUsesPaletteAndLeavesOtherPixelsAlone(_ color: Telestration.Figure.Color) throws {
        let pixels = try pixels { context in
            TelestrationPainter.draw(drawing(color: color), in: context, rect: rect, topLeftOrigin: false)
        }
        let rgb = color.components
        #expect(pixel(pixels, x: 250, y: 350) == [UInt8(rgb.red * 255), UInt8(rgb.green * 255), UInt8(rgb.blue * 255), 255])
        #expect(pixel(pixels, x: 250, y: 250) == [0, 0, 0, 0])
        #expect(pixel(pixels, x: 10, y: 350) == [0, 0, 0, 0])
    }

    @Test func zeroOpacityLeavesBitmapUntouched() throws {
        let drawing = drawing()
        let pixels = try pixels { context in
            TelestrationPainter.draw(drawing, at: drawing.duration, in: context, rect: rect, topLeftOrigin: false)
        }
        #expect(pixels.allSatisfy { $0 == 0 })
    }

    @Test func halfRevealedLinePaintsFirstQuarterOnly() throws {
        let drawing = drawing()
        // Invert the cubic ease-out to get geometric progress exactly 0.5.
        let elapsed = (1 - pow(0.5, 1.0 / 3)) * drawing.drawSpeed
        let pixels = try pixels { context in
            TelestrationPainter.draw(drawing, at: elapsed, in: context, rect: rect, topLeftOrigin: false)
        }
        #expect(pixel(pixels, x: 170, y: 350) == [255, 255, 0, 255])
        #expect(pixel(pixels, x: 330, y: 350) == [0, 0, 0, 0])
    }

    @Test func topLeftOriginAndInsetVideoRectAreRespected() throws {
        let pixels = try pixels { context in
            context.translateBy(x: 0, y: 512)
            context.scaleBy(x: 1, y: -1)
            TelestrationPainter.draw(drawing(), in: context, rect: rect, topLeftOrigin: true)
        }
        #expect(pixel(pixels, x: 250, y: 362) == [255, 255, 0, 255])
        #expect(pixel(pixels, x: 250, y: 150) == [0, 0, 0, 0])
    }

    @Test func outlineIsDarkAndWiderThanColorStroke() throws {
        // A frame far larger than the bitmap, so the band of outline beside
        // the colour is several pixels wide: stroke 32, outline 44.8, line at y 256.
        let large = CGRect(x: -744, y: -1244, width: 2000, height: 2000)
        let pixels = try pixels { context in
            TelestrationPainter.draw(drawing(), in: context, rect: large, topLeftOrigin: false)
        }
        #expect(pixel(pixels, x: 250, y: 256) == [255, 255, 0, 255])
        let outline = pixel(pixels, x: 250, y: 237)
        #expect(outline[0] == 0 && outline[1] == 0 && outline[2] == 0)
        #expect(outline[3] > 100 && outline[3] < 180)
        #expect(pixel(pixels, x: 250, y: 228) == [0, 0, 0, 0])
    }

    @Test func neonHasWhiteCoreColoredGlowAndTransparentDistance() throws {
        // Width 32, core 17.6; sample glow eight pixels beyond the colour stroke.
        let large = CGRect(x: -744, y: -1244, width: 2000, height: 2000)
        var drawing = drawing(color: .red)
        drawing.figures[0].style = .neon
        let pixels = try pixels { context in
            TelestrationPainter.draw(drawing, in: context, rect: large, topLeftOrigin: false)
        }
        #expect(pixel(pixels, x: 250, y: 256) == [255, 255, 255, 255])
        let glow = pixel(pixels, x: 250, y: 232)
        #expect(glow[0] > 0 && glow[1] == 0 && glow[2] == 0)
        #expect(glow[3] > 0 && glow[3] < 255)
        #expect(pixel(pixels, x: 250, y: 160) == [0, 0, 0, 0])
    }

    @Test(arguments: Telestration.Figure.symbols)
    func stampSymbolsExist(_ name: String) {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }

    @Test(arguments: [false, true])
    func asymmetricStampStaysUprightAndExactlyTinted(_ topLeftOrigin: Bool) throws {
        let figure = Telestration.Figure(kind: .stamp,
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)], color: .red,
            symbol: "exclamationmark.triangle")
        // Centred at 256 in either coordinate orientation.
        let frame = CGRect(x: 56, y: 56, width: 400, height: 400)
        let pixels = try pixels { context in
            if topLeftOrigin {
                context.translateBy(x: 0, y: 512)
                context.scaleBy(x: 1, y: -1)
            }
            TelestrationPainter.draw(Telestration(figures: [figure]), in: context, rect: frame,
                                     topLeftOrigin: topLeftOrigin)
        }
        // A triangle's lower rim is wider than its upper rim. Locate a solid
        // lower-right rim pixel to tolerate SF Symbol weight/raster changes,
        // then probe that SAME x in the upper half: it must be empty of red.
        let lowerX = try #require((270...325).last(where: { x in
            self.pixel(pixels, x: x, y: 221)[0] > 200
        }))
        let upperX = try #require((260...325).last(where: { x in
            self.pixel(pixels, x: x, y: 291)[0] > 200
        }))
        #expect(lowerX > upperX + 15)
        let lower = pixel(pixels, x: lowerX, y: 221)
        let upper = pixel(pixels, x: lowerX, y: 291)
        #expect(lower[0] > 200 && lower[1] == 0 && lower[2] == 0)
        #expect(upper[0] == 0 && upper[1] == 0 && upper[2] == 0)
        let fill = pixel(pixels, x: 155, y: 256)
        #expect(fill[0] == 0 && fill[1] == 0 && fill[2] == 0)
        #expect(fill[3] >= 88 && fill[3] <= 90)
        #expect(pixel(pixels, x: 100, y: 256) == [0, 0, 0, 0])
    }

    @Test func crossDoesNotPaintABridgeBetweenItsStrokes() throws {
        let figure = Telestration.Figure(kind: .cross,
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)])
        let pixels = try pixels { context in
            TelestrationPainter.draw(Telestration(figures: [figure]), in: context, rect: rect, topLeftOrigin: false)
        }
        #expect(pixel(pixels, x: 250, y: 250) == [255, 255, 0, 255])
        #expect(pixel(pixels, x: 370, y: 250) == [0, 0, 0, 0])
    }
}
