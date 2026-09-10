import Foundation
import CryptoKit
import Testing
@testable import Clip_Builder

@Suite(.serialized) @MainActor
struct LearnedSyncTests {
    @Test func pendingDistillationRunsOnlyAfterFeedbackChanges() async throws {
        let temp = try TempDirectory()
        let path = temp.url.appendingPathComponent("profile.db")
        let database = try Database(path: path)
        var calls = 0
        let empty = try await LearnedSync.distillPending(database: database) { calls += 1 }
        #expect(!empty)
        let raw = try SQLiteConnection(path: path.path)
        try raw.execute("INSERT INTO wizard_preferences (chosen_rationale, rejected_rationale) VALUES ('Short hook', 'Slow hook')")
        let first = try await LearnedSync.distillPending(database: database) { calls += 1 }
        #expect(first)
        let unchanged = try await LearnedSync.distillPending(database: database) { calls += 1 }
        #expect(!unchanged)
        try raw.execute("UPDATE wizard_preferences SET chosen_rationale = 'Fast hook'")
        let edited = try await LearnedSync.distillPending(database: database) { calls += 1 }
        #expect(edited)
        #expect(calls == 2)
    }

    @Test func failedDistillationStillPublishesAndLeavesFingerprintUnrecorded() async throws {
        struct DistillFailed: Error {}
        let fixture = try AssetSyncFixture { _, _ in throw GoogleDriveError.offline }
        await fixture.attach()
        let raw = try SQLiteConnection(path: fixture.directory.url.appendingPathComponent("profile.db").path)
        try raw.execute("INSERT INTO wizard_preferences (chosen_rationale, rejected_rationale) VALUES ('Short hook', 'Slow hook')")
        var profile = fixture.profile
        profile.learnedSharing.deviceNickname = "Studio"
        var lines: [String] = []
        await #expect(throws: GoogleDriveError.self) {
            try await LearnedSync.run(executor: fixture.executor(), profile: profile, database: fixture.database,
                                      library: LearnedLibrary(root: fixture.directory.url), log: { lines.append($0) }) {
                throw DistillFailed()
            }
        }
        #expect(lines.contains { $0.contains("distillation skipped") })
        #expect(try await fixture.database.driveSetting("learnedDistilledFeedback") == nil)
    }

    @Test func ownReceiptReplacedAndFramesNested() async throws {
        var profile = BrandProfile(name: "Test")
        profile.learnedSharing.deviceNickname = "Studio"
        profile.tasteRubric = "Action"
        profile.tasteExemplarFrames = ["injected.jpg"]
        let build = try LearnedDocumentBuilder.build(profile: profile, readFrame: { _ in Data([0xff, 0xd8, 0xff, 0xd9]) })
        let own = build.document.contributor
        var peerProfile = BrandProfile(name: "Peer")
        peerProfile.learnedSharing.deviceNickname = "Studio"
        peerProfile.tasteRubric = "Peer action"
        peerProfile.tasteExemplarFrames = ["injected.jpg"]
        let peerBuild = try LearnedDocumentBuilder.build(profile: peerProfile,
            readFrame: { _ in Data([0xff, 0xd8, 0xff, 0xd9]) })
        let peerData = try JSONEncoder().encode(LearnedRedaction.apply(peerBuild.document, publishing: true))
        let peerFrameName = try #require(peerBuild.document.frameNames.first)
        let frameData = try #require(peerBuild.frames[peerFrameName])
        let peerFile = DriveFile(id: "peer-file", name: peerBuild.document.contributor + ".json", mimeType: "application/json",
            size: String(peerData.count), md5Checksum: Insecure.MD5.hash(data: peerData).map { String(format: "%02x", $0) }.joined())
        let peerFrame = DriveFile(id: "peer-frame", name: URL(fileURLWithPath: peerFrameName).lastPathComponent,
            mimeType: "image/jpeg", size: String(frameData.count),
            md5Checksum: Insecure.MD5.hash(data: frameData).map { String(format: "%02x", $0) }.joined())
        let fixture = try AssetSyncFixture { request, _ in
            if request.httpMethod == "PUT" {
                let body = try #require(request.httpBody)
                let md5 = Insecure.MD5.hash(data: body).map { String(format: "%02x", $0) }.joined()
                return try AssetSyncFixture.response(DriveFile(id: request.url?.lastPathComponent ?? "upload",
                    name: "uploaded", mimeType: "application/octet-stream", size: String(body.count), md5Checksum: md5))
            }
            if request.httpMethod == "PATCH" || request.httpMethod == "POST" {
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let name = try #require(object["name"] as? String)
                return (Data(), 200, ["Location": "https://www.googleapis.com/session/" + LearnedPreferences.stableID(name)])
            }
            if request.url?.path.hasSuffix("/peer-file") == true {
                if request.url?.query?.contains("alt=media") == true { return (peerData, 200, [:]) }
                return try AssetSyncFixture.response(peerFile)
            }
            if request.url?.path.hasSuffix("/peer-frame") == true {
                if request.url?.query?.contains("alt=media") == true { return (frameData, 200, [:]) }
                return try AssetSyncFixture.response(peerFrame)
            }
            let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "q" }?.value ?? ""
            if query.contains("'home'") { return try AssetSyncFixture.page([AssetSyncFixture.folder("learned", "learned")]) }
            if query.contains("'learned'") {
                return try AssetSyncFixture.page([AssetSyncFixture.folder("own", own),
                    DriveFile(id: "own-file", name: own + ".json", mimeType: "application/json"),
                    peerFile, AssetSyncFixture.folder("peer-folder", peerBuild.document.contributor)])
            }
            if query.contains("'own'") { return try AssetSyncFixture.page([AssetSyncFixture.folder("frames", "frames")]) }
            if query.contains("'peer-folder'") { return try AssetSyncFixture.page([AssetSyncFixture.folder("peer-frames", "frames")]) }
            if query.contains("'peer-frames'") { return try AssetSyncFixture.page([peerFrame]) }
            return try AssetSyncFixture.page([])
        }
        await fixture.attach()
        let key = "learnedReceipts." + LearnedPreferences.stableID("home|" + own)
        try await fixture.database.setDriveSetting(key, value: "{\"\(own).json\":\"own-file\"}")
        try await fixture.executor().publishLearned(build, database: fixture.database,
            library: LearnedLibrary(root: fixture.directory.url))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.url.appendingPathComponent(peerFrameName).path))
        #expect(LearnedLibrary(root: fixture.directory.url).documents().contains { $0.contributor == peerBuild.document.contributor })
        let requests = await fixture.transport.requests
        let patches = requests.filter { $0.httpMethod == "PATCH" }
        #expect(patches.count == 1)
        #expect(patches.first?.url?.path.hasSuffix("/own-file") == true)
        let framePosts = requests.filter { $0.httpMethod == "POST" && $0.url?.path.contains("/upload/") == true }
        let frameRequest = try #require(framePosts.first)
        let frameBody = try #require(frameRequest.httpBody)
        let frameObject = try #require(JSONSerialization.jsonObject(with: frameBody) as? [String: Any])
        #expect(frameObject["parents"] as? [String] == ["frames"])
        let frameName = try #require(build.document.frameNames.first)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.url.appendingPathComponent(frameName).path))
        #expect(AssetSyncFixture.stagingPaths(in: fixture.directory.url).isEmpty)
    }

    @Test func pullInstallsPeersWithoutNicknameOrUploads() async throws {
        var peerProfile = BrandProfile(name: "Peer")
        peerProfile.learnedSharing.deviceNickname = "Studio"
        peerProfile.tasteRubric = "Peer action"
        let peerBuild = try LearnedDocumentBuilder.build(profile: peerProfile, readFrame: { _ in Data() })
        let peerData = try JSONEncoder().encode(LearnedRedaction.apply(peerBuild.document, publishing: true))
        let peerFile = DriveFile(id: "peer-file", name: peerBuild.document.contributor + ".json", mimeType: "application/json",
            size: String(peerData.count), md5Checksum: Insecure.MD5.hash(data: peerData).map { String(format: "%02x", $0) }.joined())
        let fixture = try AssetSyncFixture { request, _ in
            if request.url?.path.hasSuffix("/peer-file") == true {
                if request.url?.query?.contains("alt=media") == true { return (peerData, 200, [:]) }
                return try AssetSyncFixture.response(peerFile)
            }
            let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "q" }?.value ?? ""
            if query.contains("'home'") { return try AssetSyncFixture.page([AssetSyncFixture.folder("learned", "learned")]) }
            if query.contains("'learned'") { return try AssetSyncFixture.page([peerFile]) }
            return try AssetSyncFixture.page([])
        }
        await fixture.attach()
        let local = BrandProfile(name: "Test")  // no device nickname
        try await LearnedSync.pull(executor: fixture.executor(), profile: local, library: LearnedLibrary(root: fixture.directory.url))
        #expect(LearnedLibrary(root: fixture.directory.url, profile: "Test").documents()
            .contains { $0.contributor == peerBuild.document.contributor })
        let requests = await fixture.transport.requests
        let writes = requests.filter { ["POST", "PATCH", "PUT"].contains($0.httpMethod) && $0.url?.path != "/token" }
        #expect(writes.isEmpty)
    }

    @Test func unownedSameNameNeverOverwritten() async throws {
        var profile = BrandProfile(name: "Test")
        profile.learnedSharing.deviceNickname = "Studio"
        let own = LearnedPreferences.contributor(profile: profile)
        let fixture = try AssetSyncFixture { request, _ in
            let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "q" }?.value ?? ""
            if query.contains("'home'") { return try AssetSyncFixture.page([AssetSyncFixture.folder("learned", "learned")]) }
            if query.contains("'learned'") { return try AssetSyncFixture.page([
                AssetSyncFixture.folder("own", own), DriveFile(id: "another-app", name: own + ".json", mimeType: "application/json")]) }
            if query.contains("'own'") { return try AssetSyncFixture.page([AssetSyncFixture.folder("frames", "frames")]) }
            return try AssetSyncFixture.page([])
        }
        await fixture.attach()
        let build = try LearnedDocumentBuilder.build(profile: profile)
        await #expect(throws: GoogleDriveError.self) {
            try await fixture.executor().publishLearned(build, database: fixture.database,
                library: LearnedLibrary(root: fixture.directory.url))
        }
        let requests = await fixture.transport.requests
        #expect(!requests.contains { $0.httpMethod == "PATCH" || $0.httpMethod == "PUT" })
    }
}
