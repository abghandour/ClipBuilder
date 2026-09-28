import Foundation
import Testing

@testable import Clip_Builder

@MainActor
struct DriveSubtreeWalkerTests {
    /// A fake tree: parent id -> children. The fixture answers list requests by
    /// reading the `'<id>' in parents` clause.
    private static func fixture(tree: [String: [DriveFile]], pageSize: Int = 100) throws -> AssetSyncFixture {
        try AssetSyncFixture { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let q = items.first { $0.name == "q" }?.value ?? ""
            let token = items.first { $0.name == "pageToken" }?.value
            guard let range = q.range(of: #"'([^']+)' in parents"#, options: .regularExpression) else {
                return try AssetSyncFixture.page([])
            }
            let parent = String(q[range].dropFirst().prefix { $0 != "'" })
            let children = tree[parent] ?? []
            let start = Int(token ?? "0") ?? 0
            let slice = Array(children.dropFirst(start).prefix(pageSize))
            let next = start + pageSize < children.count ? String(start + pageSize) : nil
            return try AssetSyncFixture.page(slice, next: next)
        }
    }
    private static func video(_ id: String, width: Int = 1920, height: Int = 1080) -> DriveFile {
        var file = DriveFile(id: id, name: "\(id).mp4", mimeType: "video/mp4")
        file.videoMediaMetadata = DriveVideoMetadata(width: width, height: height, durationMillis: "1000")
        return file
    }

    @Test func walksBreadthFirstWithPathsAndPaging() async throws {
        let fixture = try Self.fixture(tree: [
            "a": [AssetSyncFixture.folder("a1", "Inner"), Self.video("v1"), Self.video("v2")],
            "a1": [Self.video("v3")],
            "b": [],
        ], pageSize: 2)
        let seed = [AssetSyncFixture.folder("a", "Alpha"), Self.video("top"), AssetSyncFixture.folder("b", "Beta")]
        let result = try await DriveSubtreeWalker().walk(
            seed: seed, lister: fixture.client, videosOnly: true, driveID: nil)
        #expect(result.files.map(\.id) == ["top", "v1", "v2", "v3"])
        #expect(result.files.map(\.pathLabel) == ["", "Alpha", "Alpha", "Alpha / Inner"])
        #expect(result.files.map(\.topFolderID) == [nil, "a", "a", "a"])
        #expect(result.foldersScanned == 3)
        #expect(!result.truncated)
        let listRequests = await fixture.transport.requests.filter { $0.url?.path.hasSuffix("/files") == true }
        #expect(listRequests.count == 4)  // "a" needs two pages
    }

    /// The Recent listing returns a folder next to its own descendants.
    @Test func overlappingSeedsAreWalkedAndEmittedOnce() async throws {
        let fixture = try Self.fixture(tree: [
            "a": [AssetSyncFixture.folder("a1", "Inner"), Self.video("v1")],
            "a1": [Self.video("v2")],
        ])
        let seed = [Self.video("v2"), AssetSyncFixture.folder("a1", "Inner"), AssetSyncFixture.folder("a", "Alpha"),
                    Self.video("v1")]
        let result = try await DriveSubtreeWalker().walk(
            seed: seed, lister: fixture.client, videosOnly: true, driveID: nil)
        #expect(result.files.map(\.id) == ["v2", "v1"])
        #expect(result.files.map(\.pathLabel) == ["", ""])
        #expect(result.foldersScanned == 2)
        let listRequests = await fixture.transport.requests.filter { $0.url?.path.hasSuffix("/files") == true }
        #expect(listRequests.count == 2)
    }

    @Test func requestCapTruncates() async throws {
        let fixture = try Self.fixture(tree: [
            "a": [AssetSyncFixture.folder("a1", "One")], "a1": [AssetSyncFixture.folder("a2", "Two")],
            "a2": [Self.video("deep")],
        ])
        var walker = DriveSubtreeWalker()
        walker.maxRequests = 2
        let result = try await walker.walk(
            seed: [AssetSyncFixture.folder("a", "A")], lister: fixture.client, videosOnly: true, driveID: nil)
        #expect(result.truncated)
        #expect(result.files.isEmpty)
        #expect(result.foldersScanned == 2)
    }

    @Test func cachingListerHitsDriveOncePerFolderPage() async throws {
        let fixture = try Self.fixture(tree: ["a": [Self.video("v1")]])
        let cache = CachingDriveFolderLister(base: fixture.client)
        for _ in 0..<3 {
            _ = try await DriveSubtreeWalker().walk(
                seed: [AssetSyncFixture.folder("a", "A")], lister: cache, videosOnly: true, driveID: nil)
        }
        let listRequests = await fixture.transport.requests.filter { $0.url?.path.hasSuffix("/files") == true }
        #expect(listRequests.count == 1)
    }

    @Test func matchesByTopFolderCountsFilteredVideosOnly() {
        let files = [
            DriveFlatFile(file: Self.video("w1"), folderIDs: ["a"], folderNames: ["A"]),
            DriveFlatFile(file: Self.video("t1", width: 1080, height: 1920), folderIDs: ["a", "a1"], folderNames: ["A", "Inner"]),
            DriveFlatFile(file: Self.video("w2"), folderIDs: ["b", "b1"], folderNames: ["B", "Inner"]),
            DriveFlatFile(file: Self.video("direct"), folderIDs: [], folderNames: []),
        ]
        var filter = DriveBrowserFilter()
        filter.shape = .wide
        #expect(DriveSubtreeWalker.matchesByTopFolder(files, filter: filter) == ["a": 1, "b": 1])
        filter.shape = .tall
        #expect(DriveSubtreeWalker.matchesByTopFolder(files, filter: filter) == ["a": 1])
        filter.shape = .square
        #expect(DriveSubtreeWalker.matchesByTopFolder(files, filter: filter).isEmpty)
    }
}
