import Foundation
import CoreGraphics

/// A run owns this cache; TaskLocal lets the later framing pass reuse the
/// exact portrait-fit samples without retaining evidence between runs.
actor SampledFrameCache {
    @TaskLocal static var current: SampledFrameCache?
    private struct Key: Hashable {
        var path: String
        var time: Double
        var dimension: CGFloat
    }
    private var frames: [Key: Data] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private let byteLimit = 64 * 1024 * 1024

    func jpegFrames(url: URL, at times: [Double], maxDimension: CGFloat) async -> [Data?] {
        guard !Task.isCancelled else { return Array(repeating: nil, count: times.count) }
        let path = url.resolvingSymlinksInPath().path
        let keys = times.map { Key(path: path, time: $0, dimension: maxDimension) }
        let missing = keys.filter { frames[$0] == nil }
        let decoded = await ThumbnailService.jpegFrames(url: url, at: missing.map(\.time), maxDimension: maxDimension)
        guard !Task.isCancelled else { return Array(repeating: nil, count: times.count) }
        var result = frames
        for (key, data) in zip(missing, decoded) {
            guard let data else { continue }
            result[key] = data
            guard frames[key] == nil, data.count <= byteLimit else { continue }
            while bytes + data.count > byteLimit, let oldest = order.first {
                order.removeFirst()
                bytes -= frames.removeValue(forKey: oldest)?.count ?? 0
            }
            frames[key] = data
            bytes += data.count
            order.append(key)
        }
        return keys.map { result[$0] }
    }
}
