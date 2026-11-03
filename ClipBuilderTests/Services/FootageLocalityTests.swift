import Foundation
import Testing
@testable import Clip_Builder

/// Footage that is not on this Mac is listed only on Sources, and only when
/// a Drive copy can be downloaded.
struct FootageLocalityTests {
    private func temporaryFile() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("footage-locality-\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: url)
        return url.path
    }

    @Test func aDriveCopyIsPresentButNotLocalUntilDownloaded() throws {
        let missing = "/tmp/footage-locality-missing-\(UUID().uuidString).mp4"
        #expect(!FootageAvailability.refresh(path: missing, driveFileID: nil))
        #expect(!FootageAvailability.isPresent(path: missing) && !FootageAvailability.isLocal(path: missing))
        #expect(FootageAvailability.refresh(path: missing, driveFileID: "drive-1"))
        #expect(FootageAvailability.isPresent(path: missing), "a Drive copy can be fetched on demand")
        #expect(!FootageAvailability.isLocal(path: missing), "but it is not on this Mac")
        let local = try temporaryFile()
        defer { try? FileManager.default.removeItem(atPath: local) }
        #expect(FootageAvailability.refresh(path: local, driveFileID: nil))
        #expect(FootageAvailability.isLocal(path: local))
        #expect(!FootageAvailability.isLocal(path: nil) && !FootageAvailability.isLocal(path: "/.clipbuilder-unavailable/7"))
    }

    @Test func recordsSortIntoLocalDriveOnlyAndUnreachable() {
        var video = Fixtures.video(id: 1)
        video.locallyDownloaded = true
        #expect(video.isLocal && video.isReachable && !video.isDriveOnly)
        video.locallyDownloaded = false
        #expect(!video.isLocal && !video.isReachable, "neither here nor on Drive: nothing lists it")
        video.driveFileID = "drive-1"
        #expect(video.isDriveOnly && video.isReachable, "Sources lists it with a Download action")
        video.path = nil
        #expect(!video.isLocal)
    }
}
