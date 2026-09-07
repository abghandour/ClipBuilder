import Foundation
import AVFoundation
import AppKit
import CryptoKit

/// Generates and caches video thumbnails / analysis frames with
/// AVAssetImageGenerator. Thumbnails are cached as JPEG on disk under
/// `<data>/.cache/thumbs` keyed by (path, time, size).
actor ThumbnailService {
    private let cacheDirectory: URL
    private let mediaResolver: DriveMediaResolver
    private let frameLoader: @Sendable (URL, Double, CGFloat) async -> Data?

    private nonisolated struct RequestKey: Hashable, Sendable {
        let path: String
        let time: Double
        let maxDimension: CGFloat
    }
    private nonisolated struct Request: Sendable {
        let id: UUID
        let task: Task<Data?, Never>
        var consumers: Set<UUID>
    }
    private var inFlight: [RequestKey: Request] = [:]

    /// AVAssetImageGenerator is not Sendable. Configuration and generation
    /// stay on the worker; only its cancellation API crosses executors.
    private nonisolated struct GenerationCancellation: @unchecked Sendable {
        let generator: AVAssetImageGenerator
        func cancel() { generator.cancelAllCGImageGeneration() }
    }

    init(cacheDirectory: URL? = nil, mediaResolver: DriveMediaResolver = .shared,
         frameLoader: @escaping @Sendable (URL, Double, CGFloat) async -> Data? = { url, time, dimension in
             await ThumbnailService.jpegFrame(url: url, at: time, maxDimension: dimension, quality: 0.7)
         }) {
        self.cacheDirectory = cacheDirectory ?? SettingsStore.cacheDirectory.appendingPathComponent("thumbs", isDirectory: true)
        self.mediaResolver = mediaResolver
        self.frameLoader = frameLoader
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheKey(_ url: URL, time: Double, maxDimension: CGFloat) -> String {
        // Size + mtime ride along so a file re-encoded in place gets a
        // fresh frame instead of the old cached one.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let identity = DriveTransferFiles(for: url).readIdentity()
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? Int64(identity?.size ?? -1)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? identity?.mtime ?? -1
        let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(mtime)|\(time)|\(Int(maxDimension))".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// JPEG thumbnail for a video at a given timestamp, disk-cached.
    func thumbnail(for url: URL, at time: Double, maxDimension: CGFloat = 480) async -> Data? {
        let timing = PerfSignpost.begin("Thumbnail", metadata: url.lastPathComponent)
        defer { PerfSignpost.end(timing) }
        guard !Task.isCancelled else { return nil }
        let key = RequestKey(path: url.path, time: time, maxDimension: maxDimension)
        let consumer = UUID()
        let request: Request
        if var existing = inFlight[key] {
            PerfSignpost.event("ThumbnailCacheHit", metadata: "in flight")
            existing.consumers.insert(consumer)
            inFlight[key] = existing
            request = existing
        } else {
            let task = Task {
                await MediaWorkScheduler.$priority.withValue(.interactive) {
                    await self.loadThumbnail(for: url, at: time, maxDimension: maxDimension)
                }
            }
            request = Request(id: UUID(), task: task, consumers: [consumer])
            inFlight[key] = request
        }
        return await withTaskCancellationHandler {
            let data = await request.task.value
            releaseConsumer(consumer, key: key, requestID: request.id)
            return Task.isCancelled ? nil : data
        } onCancel: {
            PerfSignpost.event("ThumbnailCancel")
            Task { await self.releaseConsumer(consumer, key: key, requestID: request.id) }
        }
    }

    private func releaseConsumer(_ consumer: UUID, key: RequestKey, requestID: UUID) {
        guard var request = inFlight[key], request.id == requestID else { return }
        request.consumers.remove(consumer)
        if request.consumers.isEmpty {
            request.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
    }

    private func loadThumbnail(for url: URL, at time: Double, maxDimension: CGFloat) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let files = DriveTransferFiles(for: url)
        _ = files.readIdentity() // Migrate a pre-existing identity before looking up its cache.
        let hasIdentity = FileManager.default.fileExists(atPath: files.identity.path)
        let isDriveMedia = hasIdentity ? true : ((try? await mediaResolver.isDriveMedia(url)) ?? false)
        guard !Task.isCancelled else { return nil }
        let stable = cacheDirectory.appendingPathComponent(ContentHashForDrive.key("\(url.path)|\(time)|\(maxDimension)") + ".jpg")
        if isDriveMedia, !FileManager.default.fileExists(atPath: url.path), let cached = try? Data(contentsOf: stable) {
            PerfSignpost.event("ThumbnailCacheHit", metadata: "Drive offline")
            return cached
        }
        let cacheURL = cacheDirectory.appendingPathComponent(cacheKey(url, time: time, maxDimension: maxDimension))
        if let cached = try? Data(contentsOf: cacheURL) {
            PerfSignpost.event("ThumbnailCacheHit", metadata: "disk")
            if isDriveMedia { try? cached.write(to: stable) }
            return cached
        }
        guard !Task.isCancelled,
              let data = await frameLoader(url, time, maxDimension),
              !Task.isCancelled else {
            return nil
        }
        try? data.write(to: cacheURL)
        if isDriveMedia { try? data.write(to: stable) }
        return data
    }

    /// One JPEG frame, uncached — used by the analyzer's frame sampler.
    /// Quality ~0.85 approximates ffmpeg's `-q:v 4`.
    @concurrent
    static func jpegFrame(url: URL, at time: Double,
                          maxDimension: CGFloat = 0, quality: CGFloat = 0.85) async -> Data? {
        guard !Task.isCancelled, let asset = try? await DriveLocalAsset.make(url) else { return nil }
        defer { withExtendedLifetime(asset) {} }
        if let cgImage = await generatedFrame(asset: asset, at: time, maxDimension: maxDimension) {
            guard !Task.isCancelled else { return nil }
            return jpegData(from: cgImage, quality: quality)
        }
        guard !Task.isCancelled else { return nil }
        // Release the decode permit before the external-process fallback.
        return await FFmpeg.jpegFrame(of: url, at: time, maxDimension: maxDimension)
    }

    @concurrent
    private static func generatedFrame(asset: AVURLAsset, at time: Double, maxDimension: CGFloat,
                                       widthOnly: Bool = false) async -> CGImage? {
        guard let permit = try? await MediaWorkScheduler.shared.acquire(.decoding, priority: MediaWorkScheduler.priority)
        else { return nil }
        defer { withExtendedLifetime((asset, permit)) {} }
        guard !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        if widthOnly {
            // Retain the grayscale sampler's original seek tolerance and sizing.
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxDimension, height: 0)
        } else {
            configure(generator, maxDimension: maxDimension)
        }
        let cancellation = GenerationCancellation(generator: generator)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            return Task.isCancelled ? nil : image
        } onCancel: {
            cancellation.cancel()
        }
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
        let timing = PerfSignpost.begin("Frames", metadata: "count=\(timestamps.count) edge=\(maxDimension)")
        defer { PerfSignpost.end(timing) }
        guard !timestamps.isEmpty else { return [] }
        guard !Task.isCancelled else { return Array(repeating: nil, count: timestamps.count) }

        guard let asset = try? await DriveLocalAsset.make(url) else {
            return Array(repeating: nil, count: timestamps.count)
        }
        defer { withExtendedLifetime(asset) {} }
        var frames = await generatedFrames(asset: asset, at: timestamps, maxDimension: maxDimension, quality: quality)
        guard !Task.isCancelled else { return Array(repeating: nil, count: timestamps.count) }

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

    @concurrent
    private static func generatedFrames(asset: AVURLAsset, at timestamps: [Double],
                                        maxDimension: CGFloat, quality: CGFloat) async -> [Data?] {
        let requestedTimes = timestamps.map { CMTime(seconds: $0, preferredTimescale: 600) }
        guard let permit = try? await MediaWorkScheduler.shared.acquire(.decoding, priority: MediaWorkScheduler.priority)
        else { return Array(repeating: nil, count: timestamps.count) }
        defer { withExtendedLifetime((asset, permit)) {} }
        guard !Task.isCancelled else { return Array(repeating: nil, count: timestamps.count) }
        let generator = AVAssetImageGenerator(asset: asset)
        configure(generator, maxDimension: maxDimension)

        let cancellation = GenerationCancellation(generator: generator)
        return await withTaskCancellationHandler {
            var frames = [Data?](repeating: nil, count: timestamps.count)
            var fulfilled = Set<Int>()
            guard !Task.isCancelled else { return frames }
            for await result in generator.images(for: requestedTimes) {
                // Drain cancelled results too, retaining the asset/Drive lease
                // until the generator has finished the batch.
                guard !Task.isCancelled else { continue }
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

            return frames
        } onCancel: {
            cancellation.cancel()
        }
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
        guard !Task.isCancelled, let asset = try? await DriveLocalAsset.make(url) else { return nil }
        defer { withExtendedLifetime(asset) {} }
        var frame = await generatedFrame(asset: asset, at: time, maxDimension: CGFloat(width), widthOnly: true)
        if frame == nil, !Task.isCancelled,
           let jpeg = await FFmpeg.jpegFrame(of: url, at: time, maxDimension: CGFloat(width)) {
            frame = NSBitmapImageRep(data: jpeg)?.cgImage
        }
        guard !Task.isCancelled, let cgImage = frame else { return nil }

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
