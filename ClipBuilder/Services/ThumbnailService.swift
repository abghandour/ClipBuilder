import Foundation
import AVFoundation
import AppKit
import CryptoKit

/// Generates and caches video thumbnails / analysis frames with
/// AVAssetImageGenerator. Thumbnails are cached as JPEG on disk under
/// `<data>/.cache/thumbs` keyed by (path, time, size).
actor ThumbnailService {
    private let cacheDirectory: URL

    init() {
        cacheDirectory = SettingsStore.cacheDirectory.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheKey(_ url: URL, time: Double, maxDimension: CGFloat) -> String {
        let digest = SHA256.hash(data: Data("\(url.path)|\(time)|\(Int(maxDimension))".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// JPEG thumbnail for a video at a given timestamp, disk-cached.
    func thumbnail(for url: URL, at time: Double, maxDimension: CGFloat = 480) async -> Data? {
        let cacheURL = cacheDirectory.appendingPathComponent(cacheKey(url, time: time, maxDimension: maxDimension))
        if let cached = try? Data(contentsOf: cacheURL) {
            return cached
        }
        guard let data = await Self.jpegFrame(url: url, at: time, maxDimension: maxDimension, quality: 0.7) else {
            return nil
        }
        try? data.write(to: cacheURL)
        return data
    }

    /// One JPEG frame, uncached — used by the analyzer's frame sampler.
    /// Quality ~0.85 approximates ffmpeg's `-q:v 4`.
    static func jpegFrame(url: URL, at time: Double,
                          maxDimension: CGFloat = 0, quality: CGFloat = 0.85) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        if maxDimension > 0 {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: cmTime).image {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        // AVFoundation cannot read some containers (MKV/WebM) — fall back to ffmpeg.
        return await FFmpeg.jpegFrame(of: url, at: time, maxDimension: maxDimension)
    }

    /// One frame with a VIP subject's colored box burned in — the analyzer's
    /// subject reference. The rect is frame fractions with a top-left origin.
    static func subjectReferenceJPEG(url: URL, at time: Double,
                                     rect: SubjectRect, colorIndex: Int) async -> Data? {
        guard let data = await jpegFrame(url: url, at: time),
              let cgImage = NSBitmapImageRep(data: data)?.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let entry = SubjectPalette.entry(colorIndex)
        context.setStrokeColor(CGColor(red: entry.red, green: entry.green, blue: entry.blue, alpha: 1))
        context.setLineWidth(max(3, CGFloat(width) * 0.006))
        // CG draws bottom-up, so the top-left-origin fractions flip in y.
        context.stroke(CGRect(x: rect.x * Double(width),
                              y: (1 - rect.y - rect.h) * Double(height),
                              width: rect.w * Double(width),
                              height: rect.h * Double(height)))
        guard let annotated = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: annotated)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Grayscale pixels for a frame, downscaled to `width` pixels across —
    /// feeds the auto-crop detail/motion scoring.
    static func grayscaleFrame(url: URL, at time: Double, width: Int) async -> (pixels: [UInt8], width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: 0)
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        var frame = try? await generator.image(at: cmTime).image
        if frame == nil, let jpeg = await FFmpeg.jpegFrame(of: url, at: time, maxDimension: CGFloat(width)) {
            frame = NSBitmapImageRep(data: jpeg)?.cgImage
        }
        guard let cgImage = frame else { return nil }

        let w = cgImage.width
        let h = cgImage.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: &pixels, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }
}
