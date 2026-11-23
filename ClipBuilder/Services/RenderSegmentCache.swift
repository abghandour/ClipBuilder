import CryptoKit
import Foundation

/// Completed segment artifacts shared by exact previews and final renders.
/// Actor isolation keeps restore/touch/eviction atomic within this process.
actor RenderSegmentCache {
    static let shared = RenderSegmentCache()
    /// Bumped whenever the filter graph changes shape: v3 added B-roll
    /// (draw order, cover-all framing, alpha dissolves, the audio mix).
    // v5 preserves original transcript timing through framing intermediates.
    // v6 uses half-open caption windows at page boundaries.
    // v7 folds Express burn-ins/mute and feed paths into the segment graph.
    // v8 preserves muted AAC, validates saved paths, and grades the whole composite.
    nonisolated static let rendererVersion = "multitrack-segment-v16-vip-paths"
    private let root: URL?
    private let byteLimit: Int64
    private var continuousPaths: [String: Task<CenterStageContinuity.Outcome, Error>] = [:]
    private var continuousFailures: [String: CenterStageContinuity.Outcome] = [:]
    private var continuousFailureOrder: [String] = []
    private func rememberFailure(_ outcome: CenterStageContinuity.Outcome, key: String) {
        guard !Task.isCancelled else { return }
        if continuousFailures[key] == nil {
            if continuousFailureOrder.count == 256 {
                continuousFailures.removeValue(forKey: continuousFailureOrder.removeFirst())
            }
            continuousFailureOrder.append(key)
        }
        continuousFailures[key] = outcome
    }

    /// Renders waiting on each shared analysis, and how many of them were cancelled.
    private var continuousWaiters: [Task<CenterStageContinuity.Outcome, Error>: (waiting: Int, cancelled: Int)] = [:]

    /// The shared analysis outlives one cancelled waiter, but stops once
    /// nobody is left to use it. A cancelled producer throws and caches nothing.
    private func waiterCancelled(_ pending: Task<CenterStageContinuity.Outcome, Error>) {
        guard var count = continuousWaiters[pending] else { return }
        count.cancelled += 1
        continuousWaiters[pending] = count
        if count.cancelled >= count.waiting {
            pending.cancel()
            // A render starting now must not join the analysis that was just stopped.
            for (key, task) in continuousPaths where task == pending { continuousPaths[key] = nil }
            CenterStageContinuity.unionCancellationObserver?()
        }
    }

    private func awaitContinuous(_ pending: Task<CenterStageContinuity.Outcome, Error>)
        async throws -> CenterStageContinuity.Outcome {
        continuousWaiters[pending, default: (0, 0)].waiting += 1
        // Counts are per task and only ever cancel that task, so a late
        // cancellation notice cannot reach a newer analysis of the same key.
        defer {
            if var count = continuousWaiters[pending] {
                count.waiting -= 1
                continuousWaiters[pending] = count.waiting <= 0 ? nil : count
            }
        }
        return try await withTaskCancellationHandler {
            try await pending.value
        } onCancel: {
            Task { await self.waiterCancelled(pending) }
        }
    }

    /// Unstructured tasks inherit render settings/test evidence, but not a
    /// waiter's cancellation. Publish before awaiting so concurrent previews
    /// and exports cannot both miss the same union. The producer owns caching.
    func continuousPath(key: String, cacheEnabled: Bool,
                        produce: @escaping @Sendable () async throws -> CenterStageContinuity.Outcome)
        async throws -> (outcome: CenterStageContinuity.Outcome, reused: Bool) {
        try Task.checkCancellation()
        CenterStageContinuity.unionRequestObserver?()
        if let pending = continuousPaths[key] {
            let outcome = try await awaitContinuous(pending)
            try Task.checkCancellation()
            return (outcome, true)
        }
        if cacheEnabled, let failed = continuousFailures[key] { return (failed, true) }
        if cacheEnabled, let cached = readJSON(CenterStageContinuity.Outcome.self, key: key), cached.path != nil {
            return (cached, true)
        }
        let pending = Task {
            let outcome = try await produce()
            try Task.checkCancellation()
            if cacheEnabled, outcome.cacheable != false {
                // "Nobody to follow" cannot always be told from a tracker that
                // failed quietly, so a failure is remembered for this launch
                // only; a path is kept on disk.
                if outcome.path == nil { self.rememberFailure(outcome, key: key) } else { self.storeJSON(outcome, key: key) }
            }
            return outcome
        }
        continuousPaths[key] = pending
        defer { if continuousPaths[key] == pending { continuousPaths[key] = nil } }
        let outcome = try await awaitContinuous(pending)
        try Task.checkCancellation()
        return (outcome, false)
    }

    init(directory: URL? = nil, byteLimit: Int64 = 2 * 1024 * 1024 * 1024) {
        root = directory
        self.byteLimit = byteLimit
    }

    nonisolated static func key<Value: Encodable>(_ value: Value, version: String = rendererVersion) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: Data(version.utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }

    private var directory: URL {
        root ?? SettingsStore.cacheDirectory.appendingPathComponent("render-segments", isDirectory: true)
    }

    func restore(key: String, to destination: URL) -> Bool {
        guard !Task.isCancelled else { return false }
        let source = directory.appendingPathComponent(key + ".mp4")
        do {
            // Copy avoids sharing a mutable inode with a later render retry.
            try FileManager.default.copyItem(at: source, to: destination)
            // The touch keeps LRU order; a hit adds no bytes, so eviction
            // waits for the next publish instead of scanning the whole
            // directory on every one of a render's dozens of hits.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: source.path)
            return true
        } catch { return false }
    }

    func readJSON<Value: Decodable & Sendable>(_ type: Value.Type, key: String) -> Value? {
        guard !Task.isCancelled else { return nil }
        let url = directory.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(type, from: data) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return value
    }

    func storeJSON<Value: Encodable & Sendable>(_ value: Value, key: String) {
        guard !Task.isCancelled, let data = try? JSONEncoder().encode(value) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Task.checkCancellation()
            try data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
            evict(in: directory)
        } catch { /* Evidence cache is optional. */ }
    }

    func readJSONRecords<Value: Decodable & Sendable>(_ type: Value.Type, prefix: String) -> [Value] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(type, from: data)
            }
    }

    nonisolated struct Entry: Sendable {
        var key: String
        var source: URL
    }

    func store(key: String, from source: URL) {
        store([Entry(key: key, source: source)])
    }

    /// Publish a batch without actor suspension; roll back newly added entries
    /// if cancellation arrives during copying. Readers never see partial files.
    func store(_ entries: [Entry]) {
        guard !Task.isCancelled else { return }
        let directory = directory
        var added: [URL] = []
        defer {
            if Task.isCancelled {
                for url in added { try? FileManager.default.removeItem(at: url) }
            }
        }
        for entry in entries {
            guard !Task.isCancelled else { return }
            let destination = directory.appendingPathComponent(entry.key + ".mp4")
            let pending = directory.appendingPathComponent(".pending-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: pending) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    let values = try FileManager.default.attributesOfItem(atPath: entry.source.path)
                    guard ((values[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { continue }
                    try FileManager.default.copyItem(at: entry.source, to: pending)
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: pending, to: destination)
                    added.append(destination)
                }
                try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            } catch { /* Cache failure must not fail a completed render. */ }
        }
        if !Task.isCancelled { evict(in: directory) }
    }

    private func evict(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        let entries = files.filter { ["mp4", "json"].contains($0.pathExtension) }.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = values[.size] as? NSNumber else { return nil }
            return (url, size.int64Value, values[.modificationDate] as? Date ?? .distantPast)
        }.sorted { $0.2 == $1.2 ? $0.0.path < $1.0.path : $0.2 < $1.2 }
        var bytes = entries.reduce(Int64(0)) { $0 + $1.1 }
        for entry in entries where bytes > byteLimit {
            do {
                try FileManager.default.removeItem(at: entry.0)
                bytes -= entry.1
            } catch { continue }
        }
    }
}

/// All encode inputs, with source paths restored to their original identity
/// and raster URLs replaced by content digests before encoding this value.
nonisolated struct RenderSegmentKey: Encodable, Sendable {
    var start: Double
    var duration: Double
    var clips: [MultitrackRenderer.ResolvedClip]
    var captions: [MultitrackRenderer.CaptionOverlay]
    var overlays: [MultitrackRenderer.TimedOverlayPNG]
    var masks: [String: String]
    var fontFingerprints: [String]
    var captionStyle: CaptionStyle
    /// RenderSegmentCache.key encodes dictionary keys in sorted order.
    var speakerCaptionStyles: [String: CaptionStyle] = [:]
    var settings: RenderSettings
    var encoder: [String]
    var burnIns: [RenderEngine.ClipOverlay]?
    var burnInDuration: Double?
    var muteSource: Bool?
    var compositeEffect: EffectSpec?
    var lookAssets: [String: String]?
    /// Wizard brand layers drawn in their own stage, and whether below cutaways.
    var brandLayers: [MultitrackRenderer.CaptionOverlay]? = nil
    var brandUnderCutaways: Bool? = nil
    var lingering: [Telestration?]? = nil
    var screenStays: [TelestrationScreenStay.Mapping?]? = nil
    var stayTransitions: [Double?]? = nil
    var fixedStayFlash: Bool? = nil
    /// Speeds under 0.5 used to get audio clamped at 0.5; segments cached then must not be reused.
    var slowAudio: Bool? = nil
}
