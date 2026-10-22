import Foundation
import Testing

@testable import Clip_Builder

@Suite("Automatic team source uploads")
struct AutoDriveUploadTests {
    @Test("Attachment, setting and connection gates explain why uploads are skipped")
    func gates() {
        let video = Fixtures.video()
        let detached = AutoDriveUpload.decide(videos: [video], attached: false, driveConnected: true, enabled: true)
        #expect(detached.candidates.isEmpty)
        #expect(detached.reason == .notAttached)
        let disabled = AutoDriveUpload.decide(videos: [video], attached: true, driveConnected: true, enabled: false)
        #expect(disabled.candidates.isEmpty)
        #expect(disabled.reason == .settingOff)
        let disconnected = AutoDriveUpload.decide(videos: [video], attached: true, driveConnected: false, enabled: true)
        #expect(disconnected.candidates.isEmpty)
        #expect(disconnected.reason == .driveNotConnected)
    }

    @Test("Only new local files without a Drive identity are candidates")
    func localCandidates() throws {
        let directory = try TempDirectory(prefix: "AutoDriveUpload")
        let url = directory.url.appendingPathComponent("local.mp4")
        try Data("fixture".utf8).write(to: url)
        var local = Fixtures.video()
        local.path = url.path
        var uploaded = Fixtures.video(id: 2)
        uploaded.path = url.path
        uploaded.driveFileID = "already-on-drive"
        var missing = Fixtures.video(id: 3)
        missing.path = directory.url.appendingPathComponent("missing.mp4").path
        var remote = Fixtures.video(id: 4)
        remote.path = nil
        var empty = Fixtures.video(id: 5)
        empty.path = ""
        let decision = AutoDriveUpload.decide(
            videos: [uploaded, missing, local, remote, empty], attached: true, driveConnected: true, enabled: true)
        #expect(decision.candidates == [local])
        #expect(decision.reason == nil)
        for videos in [[], [uploaded, missing, remote, empty]] {
            let skipped = AutoDriveUpload.decide(videos: videos, attached: true, driveConnected: true, enabled: true)
            #expect(skipped.candidates.isEmpty)
            #expect(skipped.reason == .nothingNew)
        }
    }

    @Test("Scan completion hands only newly discovered IDs to the policy")
    func newSinceScan() {
        let existing = Fixtures.video()
        var updated = existing
        updated.filename = "renamed.mp4"
        let added = Fixtures.video(id: 2)
        var driveDownload = Fixtures.video(id: 3)
        driveDownload.driveFileID = "downloaded"
        let fresh = AutoDriveUpload.newVideos(before: [existing], after: [updated, added, driveDownload])
        #expect(fresh == [added, driveDownload])
        let decision = AutoDriveUpload.decide(
            videos: fresh, attached: true, driveConnected: true, enabled: true, fileExists: { _ in true })
        #expect(decision.candidates == [added])
        #expect(AutoDriveUpload.newVideos(before: [added], after: [added]).isEmpty)
        #expect(AutoDriveUpload.newVideos(before: [existing], after: []).isEmpty)
    }
}
