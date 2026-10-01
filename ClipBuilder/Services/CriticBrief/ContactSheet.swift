import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ContactSheet {
    static let tileWidth = 350
    static let height = 384

    static func times(duration: Double) -> [Double] {
        let end = max(0, duration - 0.4)
        return [min(0.3, end), min(1.8, end), max(0, duration / 2), end]
    }

    /// Fixed slots, including failed decodes, preserve the timestamp labels.
    static func image(frames: [Data?]) throws -> CGImage {
        guard let context = CGContext(data: nil, width: tileWidth * 4, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw AIError.unusableResponse("Could not allocate a critic contact sheet.")
        }
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Double(tileWidth * 4), height: Double(height)))
        for slot in 0..<4 {
            guard slot < frames.count, let data = frames[slot],
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let scale = min(Double(tileWidth) / Double(frame.width), Double(height) / Double(frame.height))
            let width = Double(frame.width) * scale
            let tall = Double(frame.height) * scale
            context.draw(frame, in: CGRect(x: Double(slot * tileWidth) + (Double(tileWidth) - width) / 2,
                y: (Double(height) - tall) / 2, width: width, height: tall))
        }
        guard let image = context.makeImage() else { throw AIError.unusableResponse("Could not make a critic contact sheet.") }
        return image
    }

    static func jpeg(frames: [Data?]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AIError.unusableResponse("Could not encode a critic contact sheet.")
        }
        CGImageDestinationAddImage(destination, try image(frames: frames),
            [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AIError.unusableResponse("Could not finish a critic contact sheet.") }
        return data as Data
    }

    @concurrent
    static func build(url: URL, duration: Double) async throws -> Data {
        let frames = await ThumbnailService.jpegFrames(url: url, at: times(duration: duration), maxDimension: 384, quality: 0.6)
        try Task.checkCancellation()
        return try jpeg(frames: frames)
    }
}
