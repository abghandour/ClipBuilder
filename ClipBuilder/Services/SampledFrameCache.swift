import Foundation
import CoreGraphics
import Vision

/// A run owns this cache; TaskLocal lets the later framing pass reuse the
/// exact portrait-fit samples, and the people detected in them, without
/// retaining evidence between runs.
actor SampledFrameCache {
    @TaskLocal static var current: SampledFrameCache?
    /// `CLIPBUILDER_FRAMING_MODE=legacy` runs Vision for every caller and
    /// samples every scene, as before, for same-binary measurement.
    nonisolated static var legacyEvidence: Bool {
        ProcessInfo.processInfo.environment["CLIPBUILDER_FRAMING_MODE"] == "legacy"
    }
    private struct Key: Hashable {
        var path: String
        var time: Double
        var dimension: CGFloat
    }
    private struct DetectionKey: Hashable {
        var frame: Key
        var detector: String
    }
    private static let humanDetector = "human-rectangles-rev2-full-body"
    private var frames: [Key: Data] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private let byteLimit = 64 * 1024 * 1024
    private var detections: [DetectionKey: [CGRect]] = [:]
    private var detectionOrder: [DetectionKey] = []
    private let detectionLimit = 4096
    /// Vision requests actually performed by this cache.
    private(set) var visionRequests = 0

    /// Normalized human rectangles (Vision's bottom-left origin) at `times`,
    /// detected once per frame per run: portrait fit and the framing pass
    /// ask for the same three moments at the same size. nil marks a frame
    /// that could not be extracted; an empty array a frame with nobody
    /// detected or a failed request. Throws only for cancellation.
    func humanBoxes(url: URL, at times: [Double], maxDimension: CGFloat) async throws -> [[CGRect]?] {
        try Task.checkCancellation()
        let path = url.resolvingSymlinksInPath().path
        let keys = times.map {
            DetectionKey(frame: Key(path: path, time: $0, dimension: maxDimension), detector: Self.humanDetector)
        }
        var result: [[CGRect]?] = keys.map { Self.legacyEvidence ? nil : detections[$0] }
        let missing = result.indices.filter { result[$0] == nil }
        guard !missing.isEmpty else { return result }
        let extracted = await jpegFrames(url: url, at: missing.map { times[$0] }, maxDimension: maxDimension)
        try Task.checkCancellation()
        for (index, data) in zip(missing, extracted) {
            guard let data else { continue }
            var request = DetectHumanRectanglesRequest(.revision2)
            request.upperBodyOnly = false
            let permit = try await MediaWorkScheduler.current.acquire(.vision)
            defer { withExtendedLifetime(permit) {} }
            try Task.checkCancellation()
            let timing = PerfSignpost.begin("Vision", metadata: "humanBoxes")
            visionRequests += 1
            let boxes = ((try? await request.perform(on: data)) ?? []).map { $0.boundingBox.cgRect }
            PerfSignpost.end(timing)
            result[index] = boxes
            if !Self.legacyEvidence { remember(keys[index], boxes) }
        }
        return result
    }

    private func remember(_ key: DetectionKey, _ boxes: [CGRect]) {
        guard detections[key] == nil else { return }
        while detections.count >= detectionLimit, let oldest = detectionOrder.first {
            detectionOrder.removeFirst()
            detections.removeValue(forKey: oldest)
        }
        detections[key] = boxes
        detectionOrder.append(key)
    }

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
