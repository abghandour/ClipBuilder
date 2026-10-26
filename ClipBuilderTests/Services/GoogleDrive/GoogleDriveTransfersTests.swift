import Foundation
import Testing

@testable import Clip_Builder

@MainActor
struct GoogleDriveTransfersTests {
    @Test func assetOperationsRoundTripWithoutMediaIdentity() throws {
        let job = DriveTransfer(
            profile: "profile", projectName: "Asset library", operation: .upload,
            assetOperation: .assetUpload, assetPath: "music/a.mp3", groupID: UUID())
        let restored = try JSONDecoder().decode(DriveTransfer.self, from: JSONEncoder().encode(job))
        #expect(restored.assetOperation == .assetUpload)
        #expect(restored.groupID == job.groupID)
        #expect(restored.title == "music/a.mp3")
        #expect(restored.media == nil)
        let legacy = DriveTransfer(profile: "profile", projectName: "Project", operation: .download)
        let old = try JSONDecoder().decode(DriveTransfer.self, from: JSONEncoder().encode(legacy))
        #expect(!old.isAsset)
    }

    @Test func stopDuringReconnectEndsAssetWaiter() async throws {
        let fixture = try AssetSyncFixture { _, _ in throw GoogleDriveError.invalidResponse }
        await fixture.attach()
        let group = UUID()
        let task = Task {
            try await fixture.transfers.assetTransfer(
                profile: fixture.profile.profileName, group: group,
                path: "music/a.mp3", upload: true, size: 3
            ) { _ in throw GoogleDriveError.reconnect }
        }
        for _ in 0..<200 {
            if fixture.transfers.jobs.contains(where: { $0.status == .reconnect }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let job = try #require(fixture.transfers.jobs.first)
        fixture.transfers.stop(job.id)
        let result = await task.result
        if case .success = result { Issue.record("Reconnect waiter survived Stop") }
        #expect(fixture.transfers.jobs.first?.status == .stopped)
    }

    @Test func reattachWithChangedInputFolderUsesTheNewFolder() async throws {
        let fixture = try AssetSyncFixture { _, _ in throw GoogleDriveError.invalidResponse }
        await fixture.attach()
        let name = fixture.profile.profileName
        let original = try #require(fixture.transfers.mediaStore(profile: name))
        #expect(await original.inputFolder.standardizedFileURL == fixture.profile.sourceFolderURL.standardizedFileURL)

        await fixture.transfers.attach(profile: fixture.profile, database: fixture.database, client: fixture.client)
        #expect(fixture.transfers.mediaStore(profile: name) === original)

        var edited = fixture.profile
        edited.sourceFolder = fixture.directory.url.appendingPathComponent("moved-input").path
        await fixture.transfers.attach(profile: edited, database: fixture.database, client: fixture.client)
        let updated = try #require(fixture.transfers.mediaStore(profile: name))
        #expect(await updated.inputFolder.standardizedFileURL == edited.sourceFolderURL.standardizedFileURL)
    }

    @Test func disconnectLeavesCompletedJobsComplete() async throws {
        let fixture = try AssetSyncFixture { _, _ in throw GoogleDriveError.invalidResponse }
        await fixture.attach()
        let name = fixture.profile.profileName
        var done = DriveTransfer(profile: name, projectName: "Project", operation: .upload,
                                 media: DriveMedia(kind: .output, recordID: 1, path: "/tmp/done.mp4"), folder: "f")
        done.status = .complete
        var paused = DriveTransfer(profile: name, projectName: "Project", operation: .upload,
                                   media: DriveMedia(kind: .output, recordID: 2, path: "/tmp/paused.mp4"), folder: "f")
        paused.status = .reconnect
        fixture.transfers.jobs = [done, paused]
        fixture.transfers.disconnect(profile: name)
        #expect(fixture.transfers.jobs.first { $0.id == done.id }?.status == .complete)
        #expect(fixture.transfers.jobs.first { $0.id == paused.id }?.status == .stopped)
        // Resume never restarts a finished job.
        fixture.transfers.resume(done.id)
        #expect(fixture.transfers.jobs.first { $0.id == done.id }?.status == .complete)
    }
}
