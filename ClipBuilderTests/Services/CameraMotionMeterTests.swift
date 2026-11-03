import Testing
import CoreVideo
import CoreGraphics
@testable import Clip_Builder

/// Pins the sign convention of the Vision registration: content that moves
/// right and down between frames reports positive dx and dy.
struct CameraMotionMeterTests {
    private func frame(width: Int, height: Int, offset: (x: Int, y: Int), invert: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        // A textured pattern (hashed blobs) so the registration has features to lock onto.
        for y in 0..<height {
            for x in 0..<width {
                let sx = x - offset.x, sy = y - offset.y
                let cell = ((sx / 24) &* 73856093) ^ ((sy / 24) &* 19349663)
                var value = UInt8(truncatingIfNeeded: (cell >> 8) & 0xFF)
                if invert { value = 255 &- value }
                let p = base + y * stride + x * 4
                p[0] = value; p[1] = value &* 3; p[2] = value / 2; p[3] = 255
            }
        }
        return pixels
    }

    @Test func contentMovingRightAndDownReadsPositive() async throws {
        let meter = CameraMotionMeter(orientation: .up)
        let width = 640, height = 360
        #expect(await meter.measure(try frame(width: width, height: height, offset: (0, 0)), time: 0) == nil, "first frame has no reference")
        let sample = try #require(await meter.measure(try frame(width: width, height: height, offset: (12, 6)), time: 1.0 / 30))
        #expect(abs(sample.dx - 12.0 / Double(width)) < 4.0 / Double(width), "dx \(sample.dx)")
        #expect(abs(sample.dy - 6.0 / Double(height)) < 4.0 / Double(height), "dy \(sample.dy)")
        let back = try #require(await meter.measure(try frame(width: width, height: height, offset: (0, 0)), time: 2.0 / 30))
        #expect(back.dx < -8.0 / Double(width) && back.dy < -3.0 / Double(height))
    }

    @Test func aWhollyDifferentPictureReadsAsAShotChange() async throws {
        let meter = CameraMotionMeter(orientation: .up)
        for index in 0..<6 {
            let sample = await meter.measure(try frame(width: 320, height: 180, offset: (index, 0)), time: Double(index) / 30)
            #expect(sample?.cut != true, "a slow pan is not a cut")
        }
        // Inverting the pattern changes most of the picture at once.
        let other = try frame(width: 320, height: 180, offset: (0, 0), invert: true)
        let cut = try #require(await meter.measure(other, time: 6.0 / 30))
        #expect(cut.cut && cut.dx == 0 && cut.dy == 0)
    }

    @Test func framesCloserThanTheSpacingAreSkipped() async throws {
        let meter = CameraMotionMeter(orientation: .up)
        _ = await meter.measure(try frame(width: 320, height: 180, offset: (0, 0)), time: 0)
        #expect(await meter.measure(try frame(width: 320, height: 180, offset: (5, 0)), time: 0.01) == nil)
    }
}
