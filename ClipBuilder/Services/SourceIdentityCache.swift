import Foundation

/// Metadata is a rescan shortcut, not deep verification. All disk access is
/// serialized; callers run on an actor or an explicit concurrent worker.
nonisolated final class SourceIdentityCache: @unchecked Sendable {
    private struct Entry: Codable {
        var size: Int
        var modified: Date
        var fingerprint: String
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var instances: [String: SourceIdentityCache] = [:]
    static var shared: SourceIdentityCache {
        let directory = SettingsStore.cacheDirectory.appendingPathComponent("source-evidence", isDirectory: true)
        return registryLock.withLock {
            if let cache = instances[directory.path] { return cache }
            let cache = SourceIdentityCache(directory: directory)
            instances[directory.path] = cache
            return cache
        }
    }

    let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry]?

    init(directory: URL) { self.directory = directory }

    func fingerprint(of url: URL, force: Bool = false,
                     hash: (URL) throws -> String = ContentHash.fingerprint) throws -> String {
        try lock.withLock {
            let index = directory.appendingPathComponent("identities-v1.json")
            if entries == nil {
                entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: index))) ?? [:]
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let values = try resolved.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if !force, let size = values.fileSize, let modified = values.contentModificationDate,
               let entry = entries?[resolved.path], entry.size == size, entry.modified == modified {
                return entry.fingerprint
            }
            let timing = PerfSignpost.begin("Fingerprint", metadata: resolved.lastPathComponent)
            defer { PerfSignpost.end(timing) }
            let fingerprint = try hash(resolved)
            // Don't record a file that changed while it was being read.
            let after = try URL(fileURLWithPath: resolved.path).resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let size = values.fileSize, let modified = values.contentModificationDate,
               after.fileSize == size, after.contentModificationDate == modified {
                entries?[resolved.path] = Entry(size: size, modified: modified, fingerprint: fingerprint)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(entries ?? [:]) { try? data.write(to: index, options: .atomic) }
            }
            return fingerprint
        }
    }

    func read<Value: Decodable>(_ type: Value.Type, fingerprint: String, version: String) -> Value? {
        lock.withLock {
            guard let data = try? Data(contentsOf: artifactURL(fingerprint: fingerprint, version: version)) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }

    func write<Value: Encodable>(_ value: Value, fingerprint: String, version: String) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: artifactURL(fingerprint: fingerprint, version: version), options: .atomic)
        }
    }

    private func artifactURL(fingerprint: String, version: String) -> URL {
        directory.appendingPathComponent("\(fingerprint).\(version).json")
    }
}
