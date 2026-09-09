import Foundation
import Testing

@testable import Clip_Builder

@Suite(.serialized) @MainActor
struct AssetSyncExecutorTests {
    @Test func foldersBothWaysAndExactNames() async throws {
        let data = try DataFolderOverride()
        defer { _ = data }
        let fixture = try AssetSyncFixture { request, _ in
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                return try AssetSyncFixture.response(
                    AssetSyncFixture.folder(body["name"] as! String, body["name"] as! String))
            }
            return try AssetSyncFixture.page([])
        }
        await fixture.attach()
        let runner = fixture.executor()
        let plan = AssetSyncPlan(actions: [
            .init(operation: .createLocalFolder, path: "music", remote: .init(driveID: "music", isFolder: true)),
            .init(operation: .createLocalFolder, path: "music/A & B", remote: .init(driveID: "album", isFolder: true)),
            .init(operation: .createDriveFolder, path: "fonts"),
            .init(operation: .createDriveFolder, path: "fonts/Family"),
        ])
        try await runner.run(plan, remote: [:], database: fixture.database)
        #expect(FileManager.default.fileExists(atPath: fixture.roots[.music].appendingPathComponent("A & B").path))
        #expect(runner.journal.kindFolderIDs["fonts"] == "fonts")
        let requests = await fixture.transport.requests
        let posts = requests.filter { $0.httpMethod == "POST" && $0.url?.host == "www.googleapis.com" }
        #expect(posts.count == 2)
        let child = try JSONSerialization.jsonObject(with: posts[1].httpBody!) as! [String: Any]
        #expect(child["parents"] as? [String] == ["fonts"])
    }

    @Test func stagedDownloadAndDriveMtimeAndFonts() async throws {
        let fixture = try AssetSyncFixture { request, _ in
            if request.url?.query?.contains("alt=media") == true { return (Data("abc".utf8), 200, [:]) }
            return try AssetSyncFixture.response(AssetSyncFixture.file(name: "font.ttf"))
        }
        await fixture.attach()
        var registrations = 0
        let runner = fixture.executor(fontsArrived: { registrations += 1 })
        let remote = AssetSyncEntry(AssetSyncFixture.file(name: "font.ttf"))
        let plan = AssetSyncPlan(actions: [
            .init(operation: .createLocalFolder, path: "fonts"),
            .init(operation: .download, path: "fonts/font.ttf", remote: remote),
        ])
        try await runner.run(plan, remote: [:], database: fixture.database)
        let installed = try fixture.roots.url(for: "fonts/font.ttf")
        #expect(try Data(contentsOf: installed) == Data("abc".utf8))
        let date = try installed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(abs((date ?? .distantPast).timeIntervalSince(remote.modifiedDate)) < 0.001)
        #expect(registrations == 1)
        #expect(AssetSyncFixture.stagingPaths(in: fixture.directory.url).isEmpty)
        #expect(runner.journal.md5Cache["fonts/font.ttf"]?.driveID == "file")
        #expect(
            fixture.transfers.jobs.contains(where: { $0.assetOperation == .assetDownload && $0.status == .complete }))
        #expect(try await fixture.database.fetchVideos().isEmpty)
    }

    @Test func uploadReceiptAndReplaceForbiddenIsReport() async throws {
        for forbidden in [false, true] {
            let fixture = try AssetSyncFixture { request, _ in
                if request.httpMethod == "PATCH" {
                    return (Data(#"{"error":{"reason":"insufficientFilePermissions"}}"#.utf8), 403, [:])
                }
                if request.httpMethod == "POST" {
                    return (Data(), 200, ["Location": "https://www.googleapis.com/upload/session"])
                }
                return try AssetSyncFixture.response(AssetSyncFixture.file(), status: 201)
            }
            await fixture.attach()
            let source = try fixture.write("music/track.mp3")
            let local = try #require(AssetSyncInventory.local(roots: fixture.roots)["music/track.mp3"])
            let runner = fixture.executor()
            let plan = AssetSyncPlan(actions: [
                .init(
                    operation: forbidden ? .replaceInDrive : .upload,
                    path: "music/track.mp3", local: local,
                    remote: forbidden ? AssetSyncEntry(AssetSyncFixture.file()) : nil)
            ])
            try await runner.run(
                plan, remote: ["music": .init(driveID: "music", isFolder: true)], database: fixture.database)
            #expect(try Data(contentsOf: source) == Data("abc".utf8))
            if forbidden {
                #expect(runner.summary.contains("1 conflict"))
                #expect(!runner.summary.contains("errors"))
                #expect(
                    fixture.transfers.jobs.contains(where: {
                        $0.message.contains("cannot replace (not created by Clip Builder)")
                    }))
                #expect(!fixture.transfers.jobs.contains(where: { $0.status == .failed }))
            } else {
                #expect(runner.journal.md5Cache["music/track.mp3"]?.driveID == "file")
                #expect(
                    try await AssetSyncJournal.load(database: fixture.database, homeID: "home").md5Cache[
                        "music/track.mp3"]?.driveID == "file")
            }
            let requests = await fixture.transport.requests
            #expect(!requests.contains(where: { $0.httpMethod == "DELETE" }))
            for request in requests where request.httpMethod == "PATCH" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                #expect(body["parents"] == nil)
                #expect(body["trashed"] == nil)
                #expect(request.url?.path.hasSuffix("/files/file") == true)
            }
        }
    }

    @Test func stopCancelsRemainingActionsAndCleansStaging() async throws {
        let fixture = try AssetSyncFixture { request, _ in
            if request.url?.query?.contains("alt=media") == true { throw GoogleDriveError.offline }
            return try AssetSyncFixture.response(AssetSyncFixture.file())
        }
        await fixture.attach()
        let existing = try fixture.write("music/keep.mp3")
        let group = UUID()
        let runner = fixture.executor(group: group)
        let plan = AssetSyncPlan(actions: [
            .init(operation: .download, path: "music/track.mp3", remote: AssetSyncEntry(AssetSyncFixture.file())),
            .init(operation: .createLocalFolder, path: "fonts"),
        ])
        let task = Task { try await runner.run(plan, remote: [:], database: fixture.database) }
        fixture.transfers.beginAssetGroup(group) { task.cancel() }
        defer { fixture.transfers.endAssetGroup(group) }
        var active: DriveTransfer?
        for _ in 0..<200 {
            active = fixture.transfers.jobs.first(where: { $0.groupID == group && $0.status == .waiting })
            if active != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let active else {
            task.cancel()
            _ = await task.result
            Issue.record("Transfer did not enter offline wait")
            return
        }
        fixture.transfers.stop(active.id)
        let result = await task.result
        if case .success = result { Issue.record("Stopped plan completed") }
        #expect(AssetSyncFixture.stagingPaths(in: fixture.directory.url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.roots[.fonts].path))
        #expect(try Data(contentsOf: existing) == Data("abc".utf8))
    }

    @Test func replacesLocalAtomicallyAndPreservesDriveTime() async throws {
        let fixture = try AssetSyncFixture { request, _ in
            if request.url?.query?.contains("alt=media") == true { return (Data("abc".utf8), 200, [:]) }
            return try AssetSyncFixture.response(AssetSyncFixture.file())
        }
        await fixture.attach()
        let source = try fixture.write("music/track.mp3", text: "older")
        let local = try #require(AssetSyncInventory.local(roots: fixture.roots)["music/track.mp3"])
        let remote = AssetSyncEntry(AssetSyncFixture.file())
        let runner = fixture.executor()
        try await runner.run(
            AssetSyncPlan(actions: [
                .init(
                    operation: .replaceLocal,
                    path: "music/track.mp3", local: local, remote: remote)
            ]), remote: [:], database: fixture.database)
        #expect(try Data(contentsOf: source) == Data("abc".utf8))
        #expect(AssetSyncFixture.stagingPaths(in: fixture.directory.url).isEmpty)
        let date = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(abs((date ?? .distantPast).timeIntervalSince(remote.modifiedDate)) < 0.001)
    }
}
