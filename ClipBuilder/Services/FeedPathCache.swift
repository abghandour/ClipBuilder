import CoreGraphics
import Foundation

/// Small evidence records, never media files. Coordinates and times are relative
/// to the full upright source and the requested span respectively.
nonisolated struct FeedPathSample: Codable, Sendable {
    var time: Double
    var faces: [CGRect]
    var expression: Double?
}

nonisolated struct FeedCameraPath: Codable, Sendable {
    var keyframes: [CameraPathKeyframe]
    var samples: [FeedPathSample]
    var trackedShare: Double
    var sourceSize: CGSize
    var usedFallback: Bool
    var reusable: Bool?
}

/// One canonical key shared by render, preview and VIP scoring. Aspect and
/// fallback focus are included because they change the actual camera path.
actor FeedPathCache {
    static let shared = FeedPathCache()
    private let cache: RenderSegmentCache
    init(cache: RenderSegmentCache = .shared) { self.cache = cache }

    nonisolated struct Identity: Codable, Sendable, Equatable {
        var fingerprint: String
        var region: FreeCropRect
        var start: Double
        var duration: Double
        var tuning: String
        var version: String
        var aspect: Double
        var focus: AreaFocus?
    }
    nonisolated struct Record: Codable, Sendable {
        var identity: Identity
        var path: FeedCameraPath
    }

    nonisolated static func identity(source: URL, region: FreeCropRect, start: Double,
                                    duration: Double, tuning: String = "conversation",
                                    aspect: Double, focus: AreaFocus? = nil) throws -> Identity {
        Identity(fingerprint: try SourceIdentityCache.shared.fingerprint(of: source),
            region: region, start: start, duration: duration, tuning: tuning,
            version: MultitrackRenderer.framingVersion, aspect: aspect, focus: focus)
    }

    func read(_ identity: Identity) async -> FeedCameraPath? {
        guard let key = try? RenderSegmentCache.key(identity) else { return nil }
        return await cache.readJSON(Record.self, key: "feed-" + key)?.path
    }

    func store(_ path: FeedCameraPath, identity: Identity) async {
        guard !Task.isCancelled, path.reusable != false, let key = try? RenderSegmentCache.key(identity) else { return }
        await cache.storeJSON(Record(identity: identity, path: path), key: "feed-" + key)
    }

    /// Preview/scoring can consume an enclosing span; never borrow another feed,
    /// camera preset, source revision or canvas aspect. Prefer the tightest span.
    func covering(source: URL, region: FreeCropRect, start: Double, duration: Double,
                  tuning: String = "conversation", aspect: Double? = nil, focus: AreaFocus? = nil) async -> Record? {
        guard let fingerprint = try? SourceIdentityCache.shared.fingerprint(of: source) else { return nil }
        let records = await cache.readJSONRecords(Record.self, prefix: "feed-")
        return records.filter {
            let key = $0.identity
            return key.fingerprint == fingerprint && key.region == region
                && key.start <= start + 1e-6 && key.start + key.duration >= start + duration - 1e-6
                && key.tuning == tuning && key.version == MultitrackRenderer.framingVersion
                && (aspect.map { abs(key.aspect - $0) < 1e-6 } ?? true)
                && (aspect == nil || key.focus == focus)
        }.min { $0.identity.duration < $1.identity.duration }
    }
}
