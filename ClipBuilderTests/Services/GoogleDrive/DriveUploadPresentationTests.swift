import Foundation
import Testing

@testable import Clip_Builder

@Suite("Drive upload presentation")
struct DriveUploadPresentationTests {
    @Test("a finished upload shows nothing; a running one shows its progress without actions")
    func runningAndComplete() {
        #expect(DriveUploadPresentation.state(status: .complete, message: "Complete", progress: 1, fileExists: true) == nil)
        let running = DriveUploadPresentation.state(status: .running, message: "Upload", progress: 0.42, fileExists: true)
        #expect(running?.primary == nil && running?.needsAttention == false)
        #expect(running?.text.contains("42%") == true)
        #expect(running?.symbol == "icloud.and.arrow.up")
    }

    @Test("a failed upload whose file is still there offers Resume with the Drive message")
    func failedWithFile() {
        let state = DriveUploadPresentation.state(status: .failed, message: "You appear to be offline.", progress: 0.3, fileExists: true)
        #expect(state?.symbol == "exclamationmark.icloud" && state?.needsAttention == true)
        #expect(state?.primary == .resume && state?.primaryTitle == "Resume upload")
        #expect(state?.text == "Upload failed — You appear to be offline.")
        #expect(state?.cancelTitle == "Cancel upload")
        let stopped = DriveUploadPresentation.state(status: .stopped, message: "", progress: 0, fileExists: true)
        #expect(stopped?.text == "Upload stopped" && stopped?.primary == .resume)
    }

    @Test("a failed upload whose file was renamed or moved offers Upload again instead of Resume")
    func failedWithoutFile() {
        for status in [DriveTransfer.Status.failed, .stopped] {
            let state = DriveUploadPresentation.state(status: status, message: "Google Drive couldn't finish that request.", progress: 0, fileExists: false)
            #expect(state?.primary == .uploadAgain && state?.primaryTitle == "Upload again")
            #expect(state?.text.contains("renamed or moved") == true)
            #expect(state?.needsAttention == true)
        }
    }

    @Test("waiting and reconnect states say what they are waiting for")
    func waitingAndReconnect() {
        let waiting = DriveUploadPresentation.state(status: .waiting, message: "Waiting", progress: 0, fileExists: true)
        #expect(waiting?.primary == nil && waiting?.needsAttention == false)
        let reconnect = DriveUploadPresentation.state(status: .reconnect, message: "", progress: 0.5, fileExists: true)
        #expect(reconnect?.primary == .resume && reconnect?.text.contains("sign in") == true)
    }

    @Test("a renamed source's pending upload follows the file; the running or complete ones keep their path")
    @MainActor func relinkFollowsRename() {
        let transfers = GoogleDriveTransfers(auth: GoogleDriveAuth(configuration: .init(clientID: "test", clientSecret: "test"), credentials: FakeDriveCredentials()))
        func media(_ path: String) -> DriveMedia { DriveMedia(kind: .source, recordID: 7, path: path) }
        var pending = DriveTransfer(profile: "p", projectName: "Home", operation: .upload, media: media("/in/old.mp4"), folder: "f")
        pending.status = .failed
        var done = pending
        done.id = UUID(); done.status = .complete
        var other = pending
        other.id = UUID(); other.media = DriveMedia(kind: .source, recordID: 8, path: "/in/other.mp4")
        transfers.jobs = [pending, done, other]
        transfers.relinkMedia(recordID: 7, kind: .source, to: "/in/new.mp4", profile: "p")
        #expect(transfers.jobs[0].media?.path == "/in/new.mp4")
        #expect(transfers.jobs[1].media?.path == "/in/old.mp4")
        #expect(transfers.jobs[2].media?.path == "/in/other.mp4")
    }
}
