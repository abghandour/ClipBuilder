import Foundation

/// Shared by media consumers, including background tasks from previous projects.
/// Looks up stable local paths in the owning database; never uses active UI ids.
actor DriveMediaResolver {
    static let shared = DriveMediaResolver()
    private var uses: [String: Int] = [:]
    private var removing: Set<String> = []
    private var databases: [(database: Database, profile: String)] = []

    func register(database: Database, profile: String) {
        databases.removeAll { $0.database.path == database.path }
        databases.append((database, profile))
    }

    @discardableResult
    func ensureLocal(_ url: URL) async throws -> URL {
        guard url.isFileURL else { return url }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        for entry in databases {
            if let media = try await entry.database.driveMedia(path: url.path) {
                return try await GoogleDriveTransfers.shared.fetch(media, profile: entry.profile)
            }
        }
        return url
    }

    func isDriveMedia(_ url: URL) async throws -> Bool {
        for entry in databases {
            if try await entry.database.driveMedia(path: url.path) != nil { return true }
        }
        return false
    }

    func acquire(_ url: URL) async throws -> DriveMediaLease {
        try Task.checkCancellation()
        guard !removing.contains(url.path) else { throw GoogleDriveError.inUse }
        uses[url.path, default: 0] += 1
        do {
            try await ensureLocal(url)
            try Task.checkCancellation()
            return DriveMediaLease(path: url.path)
        } catch {
            release(url.path)
            throw error
        }
    }

    func release(_ path: String) {
        uses[path] = max(0, uses[path, default: 0] - 1)
        if uses[path] == 0 { uses[path] = nil }
    }

    func beginOffload(_ path: String) throws {
        guard uses[path, default: 0] == 0, !removing.contains(path) else { throw GoogleDriveError.inUse }
        removing.insert(path)
    }

    func endOffload(_ path: String) { removing.remove(path) }

    /// Called before ffmpeg/ffprobe launch, covering render, audio extraction,
    /// analysis, export and all their specialized filter paths.
    func prepareInputs(_ arguments: [String], probe: Bool = false) async throws -> [DriveMediaLease] {
        var leases: [DriveMediaLease] = []
        for (index, argument) in arguments.enumerated() where argument == "-i" && index + 1 < arguments.count {
            let path = arguments[index + 1]
            if path.hasPrefix("/") { leases.append(try await acquire(URL(fileURLWithPath: path))) }
        }
        if probe, let path = arguments.last, path.hasPrefix("/") {
            leases.append(try await acquire(URL(fileURLWithPath: path)))
        }
        return leases
    }
}
