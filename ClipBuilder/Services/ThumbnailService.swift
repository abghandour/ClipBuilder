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
        // Size + mtime ride along so a file re-encoded in place gets a
        // fresh frame instead of the old cached one.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(mtime)|\(time)|\(Int(maxDimension))".utf8))
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
    @concurrent
    static func jpegFrame(url: URL, at time: Double,
                          maxDimension: CGFloat = 0, quality: CGFloat = 0.85) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        configure(generator, maxDimension: maxDimension)
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: cmTime).image {
            return jpegData(from: cgImage, quality: quality)
        }
        // AVFoundation cannot read some containers (MKV/WebM) — fall back to ffmpeg.
        return await FFmpeg.jpegFrame(of: url, at: time, maxDimension: maxDimension)
    }

    /// JPEG frames for many timestamps, preserving the input order. One asset and
    /// image generator service the whole request; individual AVFoundation misses
    /// fall back to ffmpeg without making successful frames wait for a new asset.
    ///
    /// Unlike `thumbnail(for:at:)`, this deliberately does not use the disk cache:
    /// analysis callers want a one-shot, consistently configured frame batch.
    @concurrent
    static func jpegFrames(url: URL, at timestamps: [Double],
                           maxDimension: CGFloat = 0, quality: CGFloat = 0.85) async -> [Data?] {
        guard !timestamps.isEmpty else { return [] }

        let requestedTimes = timestamps.map { CMTime(seconds: $0, preferredTimescale: 600) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        configure(generator, maxDimension: maxDimension)

        var frames = [Data?](repeating: nil, count: timestamps.count)
        var fulfilled = Set<Int>()
        for await result in generator.images(for: requestedTimes) {
            // The async API reports failures per result, so keep collecting the
            // other requested frames when a seek/decode error occurs.
            guard let index = requestedTimes.indices.first(where: {
                !fulfilled.contains($0) && CMTimeCompare(requestedTimes[$0], result.requestedTime) == 0
            }) else {
                continue
            }
            fulfilled.insert(index)
            guard let image = try? result.image else { continue }
            frames[index] = jpegData(from: image, quality: quality)
        }

        // AVFoundation does not support every source container. Only retry the
        // missing timestamps, preserving successful AVFoundation results.
        let missedIndices = frames.indices.filter { frames[$0] == nil }
        if !missedIndices.isEmpty {
            let fallbacks = (try? await BoundedConcurrency.map(missedIndices, limit: FFmpeg.jobLimit) { _, index in
                (index, await FFmpeg.jpegFrame(of: url, at: timestamps[index], maxDimension: maxDimension))
            }) ?? []
            for (index, frame) in fallbacks {
                frames[index] = frame
            }
        }
        return frames
    }

    private static func configure(_ generator: AVAssetImageGenerator, maxDimension: CGFloat) {
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        if maxDimension > 0 {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }


    /// Grayscale pixels for a frame, downscaled to `width` pixels across —
    /// feeds the auto-crop detail/motion scoring.
    @concurrent
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
