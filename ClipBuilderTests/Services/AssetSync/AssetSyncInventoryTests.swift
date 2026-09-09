import Foundation
import Testing

@testable import Clip_Builder

@MainActor
struct AssetSyncInventoryTests {
    @Test func synchronousWalkFiltersAndLazyHashes() throws {
        let fixture = try AssetSyncFixture { _, _ in throw GoogleDriveError.invalidResponse }
        try fixture.write("music/Album/a.mp3")
        let root = fixture.roots[.music]
        try Data().write(to: root.appendingPathComponent("foreign.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden.mp3"))
        let staging = root.appendingPathComponent(".import-test")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data().write(to: staging.appendingPathComponent("staged.mp3"))
        let local = try AssetSyncInventory.local(roots: fixture.roots)
        #expect(Set(local.keys) == ["music", "music/Album", "music/Album/a.mp3"])
        #expect(local["music/Album/a.mp3"]?.md5 == nil)
        var journal = AssetSyncJournal(homeID: "home")
        _ = try AssetSyncInventory.hashingMatches(local: local, remote: [:], roots: fixture.roots, journal: &journal)
        #expect(journal.md5Cache.isEmpty)
        let hashed = try AssetSyncInventory.hashingMatches(
            local: local,
            remote: ["music/Album/a.mp3": AssetSyncEntry(AssetSyncFixture.file())], roots: fixture.roots,
            journal: &journal)
        #expect(hashed["music/Album/a.mp3"]?.md5 == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test func paginatedDuplicatesAndRecursiveFolders() async throws {
        let fixture = try AssetSyncFixture { request, _ in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let q = query.first(where: { $0.name == "q" })?.value ?? ""
            let page = query.first(where: { $0.name == "pageToken" })?.value
            if q.contains("'home' in parents") {
                return try AssetSyncFixture.page([AssetSyncFixture.folder("music", "music")])
            }
            if q.contains("'music' in parents") {
                if page == nil {
                    var older = AssetSyncFixture.file(id: "old")
                    older.modifiedTime = "2020-01-01T00:00:00Z"
                    return try AssetSyncFixture.page([older, AssetSyncFixture.folder("album", "Album")], next: "next")
                }
                var googleDoc = AssetSyncFixture.file(id: "doc", name: "document.mp3")
                googleDoc.mimeType = "application/vnd.google-apps.document"
                return try AssetSyncFixture.page([
                    AssetSyncFixture.file(id: "new"), googleDoc,
                    AssetSyncFixture.file(name: ".hidden.mp3"), AssetSyncFixture.file(name: "bad.txt"),
                    AssetSyncFixture.folder("staging", ".import-x"),
                ])
            }
            if q.contains("'album' in parents") {
                return try AssetSyncFixture.page([AssetSyncFixture.file(name: "nested.mp3")])
            }
            throw GoogleDriveError.invalidResponse
        }
        let result = try await AssetSyncInventory.remote(client: fixture.client, homeID: "home")
        #expect(result.entries["music/track.mp3"]?.driveID == "new")
        #expect(result.entries["music/Album/nested.mp3"] != nil)
        #expect(result.reports.count == 1)
        #expect(result.entries.count == 4)
        let requests = await fixture.transport.requests
        #expect(!requests.contains(where: { $0.httpMethod == "DELETE" }))
        #expect(
            requests.filter { $0.url?.path == "/drive/v3/files" }.allSatisfy {
                !($0.url?.absoluteString.contains("video/") ?? false)
            })
    }
}
