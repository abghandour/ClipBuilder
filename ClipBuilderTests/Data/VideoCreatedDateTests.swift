import Foundation
import Testing

@testable import Clip_Builder

@Suite("Source creation dates")
struct VideoCreatedDateTests {
    @Test("Registration stores filesystem creation time as ISO 8601")
    func registration() async throws {
        let temp = try TempDatabase()
        let url = temp.directory.url.appendingPathComponent("video.mp4")
        try Data("video".utf8).write(to: url)
        let expected = try #require(url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        let id = try await temp.database.registerVideo(
            hash: "file", filename: "video.mp4", path: url.path, duration: 1, width: 1, height: 1, wide: false)
        let record = try #require(try await temp.database.video(id: id))
        #expect(record.createdAt == expected.ISO8601Format())
    }

    @Test("Registration falls back to media metadata, then discovery time")
    func fallbacks() async throws {
        let directory = try TempDirectory()
        let expected = Date(timeIntervalSince1970: 1_600_000_000)
        let dates = VideoCreationDates(filesystemDate: { _ in nil }, metadataDate: { _ in expected })
        let db = try Database(path: directory.url.appendingPathComponent("metadata.db"), creationDates: dates)
        let id = try await db.registerVideo(
            hash: "media", filename: "media.mp4", path: "/missing.mp4", duration: 1, width: 1, height: 1, wide: false)
        #expect(try await db.video(id: id)?.createdAt == expected.ISO8601Format())
        let noDates = VideoCreationDates(filesystemDate: { _ in nil }, metadataDate: { _ in nil })
        #expect(
            await noDates.resolve(path: "/missing.mp4", discoveredAt: "2020-09-13 12:26:40") == expected.ISO8601Format()
        )
        let fallbackPath = directory.url.appendingPathComponent("fallback.db")
        let fallbackDB = try Database(path: fallbackPath, creationDates: noDates)
        let raw = try SQLiteConnection(path: fallbackPath.path)
        try raw.execute(
            "INSERT INTO videos (hash, filename, path, discovered_at) VALUES ('fallback', 'gone.mp4', '/missing.mp4', '2020-09-13 12:26:40')"
        )
        let fallbackID = try await fallbackDB.registerVideo(
            hash: "fallback", filename: "gone.mp4", path: "/missing.mp4", duration: 1, width: 1, height: 1, wide: false)
        #expect(try await fallbackDB.video(id: fallbackID)?.createdAt == expected.ISO8601Format())
        let filesystemWins = VideoCreationDates(filesystemDate: { _ in expected }, metadataDate: { _ in Date() })
        #expect(await filesystemWins.resolve(path: "/missing.mp4", discoveredAt: nil) == expected.ISO8601Format())
    }

    @Test("Version 5 migrates exactly one column and lazily backfills without overwriting saved dates")
    func backfill() async throws {
        let temp = try TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        let url = temp.directory.url.appendingPathComponent("old.mp4")
        try Data("old".utf8).write(to: url)
        let fileDate = try #require(url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        try raw.execute("ALTER TABLE videos DROP COLUMN created_at")
        try raw.execute("PRAGMA user_version = 5")
        let before = try raw.columnNames(of: "videos")
        try raw.execute(
            "INSERT INTO videos (hash, filename, path, discovered_at) VALUES ('old', 'old.mp4', ?, '2020-09-13 12:26:40')",
            [.text(url.path)])
        try raw.execute(
            "INSERT INTO videos (hash, filename, path, discovered_at) VALUES ('gone', 'gone.mp4', '/missing.mp4', '2020-09-13 12:26:40')"
        )
        let db = try Database(path: temp.path)
        #expect(try raw.columnNames(of: "videos").subtracting(before) == ["created_at"])
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == Database.schemaVersion)
        let rows = try await db.fetchVideos()
        #expect(rows.first { $0.hash == "old" }?.createdAt == fileDate.ISO8601Format())
        #expect(rows.first { $0.hash == "gone" }?.createdAt == "2020-09-13T12:26:40Z")
        try FileManager.default.removeItem(at: url)
        let reopened = try Database(path: temp.path)
        #expect(try await reopened.fetchVideos() == rows)
    }
}
