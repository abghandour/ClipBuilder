import Foundation
import Testing

@testable import Clip_Builder

struct AssetSyncJournalTests {
    @Test func roundTripAndInvalidJournal() async throws {
        let temp = try TempDatabase()
        var journal = AssetSyncJournal(homeID: "home")
        journal.kindFolderIDs = ["music": "music-id"]
        journal.lastRefresh = Date(timeIntervalSince1970: 100)
        journal.summary = "1 uploaded"
        journal.md5Cache["music/a.mp3"] = .init(
            size: 3, modifiedDate: Date(timeIntervalSince1970: 50), md5: "abc", driveID: "id")
        try await journal.save(database: temp.database)
        #expect(try await AssetSyncJournal.load(database: temp.database, homeID: "home") == journal)
        #expect(try await AssetSyncJournal.load(database: temp.database, homeID: "other").md5Cache.isEmpty)
        try await temp.database.setDriveSetting("assetSyncJournal", value: "not JSON")
        #expect(try await AssetSyncJournal.load(database: temp.database, homeID: "home").md5Cache.isEmpty)
    }

    @Test func cacheUsesPathSizeAndMtime() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("a.mp3")
        try Data("abc".utf8).write(to: url)
        var journal = AssetSyncJournal(homeID: "home")
        var entry = AssetSyncEntry(size: 3, modifiedDate: Date(timeIntervalSince1970: 100))
        var calls = 0
        func hash(_ url: URL) throws -> String {
            calls += 1
            return try ContentHashForDrive.md5(url)
        }
        _ = try journal.checksum(path: "music/a.mp3", entry: entry, url: url, hash: hash)
        _ = try journal.checksum(path: "music/a.mp3", entry: entry, url: url, hash: hash)
        #expect(calls == 1)
        entry.modifiedDate.addTimeInterval(1)
        _ = try journal.checksum(path: "music/a.mp3", entry: entry, url: url, hash: hash)
        entry.size += 1
        _ = try journal.checksum(path: "music/a.mp3", entry: entry, url: url, hash: hash)
        _ = try journal.checksum(path: "music/b.mp3", entry: entry, url: url, hash: hash)
        #expect(calls == 4)
    }
}
