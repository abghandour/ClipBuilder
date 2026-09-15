import CryptoKit
import Foundation

/// Completed detector scans of immutable exported files. Full content identity
/// allows a copied finishing-cache artifact to reuse its scan under a new name.
actor ReelDetectorCache {
  static let shared = ReelDetectorCache()
  private let root: URL?
  private let byteLimit: Int
  private let entryLimit: Int

  init(directory: URL? = nil, byteLimit: Int = 2 * 1024 * 1024, entryLimit: Int = 256) {
    root = directory
    self.byteLimit = byteLimit
    self.entryLimit = entryLimit
  }

  private var directory: URL {
    root ?? SettingsStore.cacheDirectory.appendingPathComponent("reel-detectors", isDirectory: true)
  }

  /// Bump when detector filters, thresholds or parsing change.
  @concurrent
  static func key(for url: URL, duration: Double, runtime: String,
                  version: String = "reel-detectors-v1") async throws -> String {
    struct Input: Encodable {
      var digest: String
      var duration: Double
      var runtime: String
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
    }
    try Task.checkCancellation()
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    return try RenderSegmentCache.key(Input(digest: digest, duration: duration, runtime: runtime), version: version)
  }

  func detectors(for url: URL, duration: Double, runtime: String,
                 load: @Sendable () async throws -> VideoDetectors) async throws -> VideoDetectors {
    try Task.checkCancellation()
    let directory = directory
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    var key = try? await Self.key(for: url, duration: duration, runtime: runtime)
    let hashed = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    if values?.fileSize != hashed?.fileSize || values?.contentModificationDate != hashed?.contentModificationDate {
      key = nil
    }
    try Task.checkCancellation()
    let destination = key.map { directory.appendingPathComponent($0 + ".json") }
    if let destination,
       let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
       size > 0, size <= byteLimit,
       let data = try? Data(contentsOf: destination),
       let cached = try? JSONDecoder().decode(VideoDetectors.self, from: data) {
      try Task.checkCancellation()
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
      evict(in: directory)
      PerfSignpost.event("ReelDetectorCacheHit")
      return cached
    }
    let result = try await load()
    try Task.checkCancellation()
    let after = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard let destination, let values, let after,
          values.fileSize == after.fileSize, values.contentModificationDate == after.contentModificationDate,
          let data = try? JSONEncoder().encode(result), data.count <= byteLimit else { return result }
    // Cache I/O is optional. Failed/cancelled scans never reach publication.
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Task.checkCancellation()
      try data.write(to: destination, options: .atomic)
      if Task.isCancelled { try? FileManager.default.removeItem(at: destination); throw CancellationError() }
      evict(in: directory)
    } catch is CancellationError { throw CancellationError() }
    catch { /* Preserve a successful scan when the cache cannot be written. */ }
    return result
  }

  private func evict(in directory: URL) {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
    let entries = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Int, Date)? in
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize else { return nil }
      return (url, size, values.contentModificationDate ?? .distantPast)
    }.sorted { $0.2 == $1.2 ? $0.0.path < $1.0.path : $0.2 < $1.2 }
    var bytes = entries.reduce(0) { $0 + $1.1 }
    var count = entries.count
    for entry in entries where bytes > byteLimit || count > entryLimit {
      do { try FileManager.default.removeItem(at: entry.0); bytes -= entry.1; count -= 1 }
      catch { continue }
    }
  }
}
