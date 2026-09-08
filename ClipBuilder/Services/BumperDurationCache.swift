import AVFoundation
import Foundation

/// Metadata-only AVFoundation probes on an explicit worker actor. Replacing a
/// file at the same path invalidates its duration; failed probes may retry.
actor BumperDurationCache {
    static let shared = BumperDurationCache()
    private struct Entry {
        var modified: Date?
        var size: Int?
        var duration: Double
    }
    private var entries: [String: Entry] = [:]

    func duration(of url: URL) async -> Double? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            entries[url.path] = nil
            return nil
        }
        if let entry = entries[url.path], entry.modified == values.contentModificationDate,
           entry.size == values.fileSize { return entry.duration }
        guard let time = try? await AVURLAsset(url: url).load(.duration),
              time.seconds.isFinite, time.seconds > 0 else { return nil }
        entries[url.path] = Entry(modified: values.contentModificationDate, size: values.fileSize,
                                  duration: time.seconds)
        return time.seconds
    }
}
