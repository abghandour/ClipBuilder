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
}
