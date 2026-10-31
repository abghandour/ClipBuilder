import CoreImage
import Foundation

nonisolated enum StickerKey {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// `tolerance` is on the doubled hue-distance scale (1 = 180°). Yellow and
    /// cyan sit 60° (0.33) from green, so the default keeps them opaque while
    /// still removing the background and its spill up to about 32°.
    static func keyed(_ image: CGImage, color: (r: Double, g: Double, b: Double),
                      tolerance: Double = 0.18) -> CGImage {
        let dimension = 32
        let target = hue(color.r, color.g, color.b)
        var cube = [Float]()
        cube.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let red = Double(r) / Double(dimension - 1)
                    let green = Double(g) / Double(dimension - 1)
                    let blue = Double(b) / Double(dimension - 1)
                    let chroma = max(red, green, blue) - min(red, green, blue)
                    let delta = abs(hue(red, green, blue) - target)
                    let distance = min(delta, 1 - delta) * 2
                    // Hue has no meaning for neutral pixels: preserve white, gray and black.
                    let alpha = chroma < 0.1 ? 1 : min(1, max(0, (distance - tolerance) / 0.05))
                    cube += [Float(red * alpha), Float(green * alpha), Float(blue * alpha), Float(alpha)]
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": dimension, "inputCubeData": data,
        ])
        return context.createCGImage(output, from: input.extent) ?? image
    }

    private static func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 0 else { return 0 }
        let value: Double
        if high == r { value = (g - b) / delta }
        else if high == g { value = (b - r) / delta + 2 }
        else { value = (r - g) / delta + 4 }
        return (value / 6 + 1).truncatingRemainder(dividingBy: 1)
    }

    static func trimmedToContent(_ image: CGImage, alphaThreshold: UInt8 = 8) -> CGImage {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bounds: CGRect? = pixels.withUnsafeMutableBytes { bytes in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = bytes.bindMemory(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where rgba[(y * width + x) * 4 + 3] > alphaThreshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            let marginX = max(1, Int(ceil(Double(maxX - minX + 1) * 0.02)))
            let marginY = max(1, Int(ceil(Double(maxY - minY + 1) * 0.02)))
            let left = max(0, minX - marginX), top = max(0, minY - marginY)
            return CGRect(x: left, y: top, width: min(width - 1, maxX + marginX) - left + 1,
                          height: min(height - 1, maxY + marginY) - top + 1)
        }
        guard let bounds else { return image }
        return image.cropping(to: bounds) ?? image
    }
}
