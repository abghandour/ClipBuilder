import Foundation

nonisolated struct AssetSyncJournal: Codable, Equatable, Sendable {
    struct Fingerprint: Codable, Equatable, Sendable {
        var size: Int64
        var modifiedDate: Date
        var md5: String
        var driveID: String?
    }
    var homeID: String
    var kindFolderIDs: [String: String] = [:]
    var lastRefresh: Date?
    var summary: String?
    var md5Cache: [String: Fingerprint] = [:]

    static func decode(_ json: String?, homeID: String) -> Self {
        guard let json, let saved = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
            saved.homeID == homeID
        else { return Self(homeID: homeID) }
        return saved
    }

    static func load(database: Database, homeID: String) async throws -> Self {
        decode(try await database.driveSetting("assetSyncJournal"), homeID: homeID)
    }

    func save(database: Database) async throws {
        let data = try JSONEncoder().encode(self)
        try await database.setDriveSetting("assetSyncJournal", value: String(decoding: data, as: UTF8.self))
    }

    mutating func checksum(
        path: String, entry: AssetSyncEntry, url: URL,
        hash: (URL) throws -> String = ContentHashForDrive.md5
    ) throws -> String {
        if let cached = md5Cache[path], cached.size == entry.size, cached.modifiedDate == entry.modifiedDate {
            return cached.md5
        }
        let md5 = try hash(url)
        md5Cache[path] = Fingerprint(size: entry.size, modifiedDate: entry.modifiedDate, md5: md5)
        return md5
    }
}
