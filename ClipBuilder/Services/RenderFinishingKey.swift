import CryptoKit
import Foundation

/// Identity of the assembly and final overlay pass. Segment bytes include
/// captions, effects, source audio, crops and any other segment render input.
nonisolated struct RenderFinishingKey: Encodable, Sendable {
    struct Overlay: Encodable, Sendable {
        var pixels: String
        var start: Double
        var end: Double
        var transIn: String
        var transOut: String
    }

    var segments: [String]
    var transitions: [String?]
    var transitionDuration: Double
    var overlays: [Overlay]
    var settings: RenderSettings
    var encoder: [String]
    var segmentVersion = RenderSegmentCache.rendererVersion
    var maximumOverlap: Double? = nil

    /// Scratch inputs are immutable for this stage. Stream their complete
    /// contents off the main actor; first/last-block fingerprints would miss
    /// an edit in the middle of a segment or an overlay raster.
    @concurrent
    static func make(segments: [URL], transitions: [String?], transitionDuration: Double,
                     overlays: [MultitrackRenderer.TimedOverlayPNG], settings: RenderSettings,
                     encoder: [String], maximumOverlap: Double? = nil,
                     version: String = "multitrack-finishing-v1") async throws -> String {
        let timing = PerfSignpost.begin("FinishingCacheKey")
        defer { PerfSignpost.end(timing) }
        let input = try Self(
            segments: segments.map { try digest($0) }, transitions: transitions,
            transitionDuration: transitionDuration,
            overlays: overlays.map {
                try Overlay(pixels: digest($0.png), start: $0.startTime, end: $0.endTime,
                            transIn: $0.transIn, transOut: $0.transOut)
            }, settings: settings, encoder: encoder, maximumOverlap: maximumOverlap)
        try Task.checkCancellation()
        return try RenderSegmentCache.key(input, version: version)
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
