import CryptoKit
import Foundation

/// Completed segment artifacts shared by exact previews and final renders.
/// Actor isolation keeps restore/touch/eviction atomic within this process.
actor RenderSegmentCache {
    static let shared = RenderSegmentCache()
    nonisolated static let rendererVersion = "multitrack-segment-v1"
    private let root: URL?
    private let byteLimit: Int64

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
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: source.path)
            evict(in: directory)
            return true
        } catch { return false }
    }

    nonisolated struct Entry: Sendable {
        var key: String
        var source: URL
    }

    func store(key: String, from source: URL) {
        store([Entry(key: key, source: source)])
    }

    /// Called only after the entire render (including persistence) succeeded.
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
                    let values = try entry.source.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) > 0 else { continue }
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
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter { $0.pathExtension == "mp4" }.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
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
    var settings: RenderSettings
    var encoder: [String]
}
