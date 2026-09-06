import Foundation
import Testing

@testable import Clip_Builder

nonisolated final class UploadTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    func now() -> Double { lock.withLock { time } }
    func set(_ value: Double) { lock.withLock { time = value } }
}

/// Hold actual chunk PUTs open to measure queue behavior without network timing.
actor HeldUploadTransport: DriveTransport {
    private var serial = 0
    private var pending: [(URLRequest, CheckedContinuation<Void, Error>)] = []
    private(set) var peak = 0
    var inFlight: Int { pending.count }

    func release(error: GoogleDriveError? = nil) {
        guard !pending.isEmpty else { return }
        let (_, continuation) = pending.removeFirst()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        var headers: [String: String] = [:]
        let body: Data
        if url.path == "/token" {
            body = GoogleDriveTests.token
        } else if request.httpMethod == "POST" {
            serial += 1
            headers["Location"] = "https://www.googleapis.com/session/\(serial)"
            body = Data()
        } else {
            try await withCheckedThrowingContinuation { continuation in
                pending.append((request, continuation))
                peak = max(peak, pending.count)
            }
            body = try JSONEncoder().encode(DriveFile(id: url.lastPathComponent, name: "uploaded.mp4", size: "3"))
        }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

@Suite("Sources Drive upload")
@MainActor
struct SourcesDriveUploadTests {
    @Test("Selection skips sources that already have a Drive copy")
    func selectionFilter() {
        let local = DriveMedia(kind: .source, recordID: 1, path: "/local.mp4")
        let remote = DriveMedia(kind: .source, recordID: 2, path: "/remote.mp4", fileID: "drive")
        #expect(GoogleDriveTransfers.uploadCandidates([remote, local]) == [local])
        #expect(GoogleDriveTransfers.uploadCandidates([remote]).isEmpty)
        #expect(GoogleDriveTransfers.uploadCandidates([]).isEmpty)
    }

    @Test("Progress permits at most four updates per second and clocks are independent per job")
    func progressThrottle() async {
        let clock = UploadTestClock()
        let first = DriveProgressThrottle(now: { clock.now() })
        let second = DriveProgressThrottle(now: { clock.now() })
        var updates = 0
        for tick in 0..<1000 {
            clock.set(Double(tick) / 1000)
            if await first.acceptsUpdate() { updates += 1 }
        }
        #expect(updates == 4)
        #expect(await second.acceptsUpdate())
        clock.set(1)
        #expect(await first.acceptsUpdate())
    }

    @Test("Only two uploads run; failure frees a slot; completion saves Drive identity and refreshes UI")
    func uploadQueue() async throws { try await runQueue(failure: .offline) }

    @Test("Reconnect pauses release their slot so other uploads continue")
    func reconnectQueue() async throws { try await runQueue(failure: .reconnect) }

    private func runQueue(failure: GoogleDriveError) async throws {
        let temp = try TempDatabase()
        let profile = BrandProfile(name: "Queue test")
        let credentials = FakeDriveCredentials()
        try credentials.write(
            JSONEncoder().encode(DriveCredential(refreshToken: "test", issuedAt: Date(), email: "test@example.com")),
            profile: profile.profileName)
        let transport = HeldUploadTransport()
        let auth = GoogleDriveAuth(
            configuration: .init(clientID: "test", clientSecret: "test"), transport: transport, credentials: credentials
        )
        let client = GoogleDriveClient(auth: auth, profile: profile.profileName, transport: transport)
        let transfers = GoogleDriveTransfers(auth: auth)
        await transfers.attach(profile: profile, database: temp.database, client: client)
        var media: [DriveMedia] = []
        for index in 0..<4 {
            let url = temp.directory.url.appendingPathComponent("\(index).mp4")
            try Data("abc".utf8).write(to: url)
            let id = try await temp.database.registerVideo(
                hash: "\(index)", filename: url.lastPathComponent, path: url.path, duration: 1, width: 1, height: 1,
                wide: false)
            media.append(DriveMedia(kind: .source, recordID: id, path: url.path))
        }
        transfers.enqueueUpload(
            media, folder: "folder", profile: profile.profileName, projectID: nil, projectName: "Project")
        try await wait { await transport.inFlight == 2 }
        #expect(transfers.jobs.filter { $0.status == .waiting }.count == 2)
        #expect(transfers.jobs.filter { $0.status == .running }.count == 2)
        let waiting = try #require(transfers.jobs.last?.id)
        transfers.stop(waiting)
        #expect(transfers.jobs.last?.status == .stopped)
        transfers.resume(waiting)
        #expect(transfers.jobs.last?.status == .waiting)
        await transport.release(error: failure)
        try await wait {
            transfers.jobs.contains { $0.status == (failure == .reconnect ? .reconnect : .failed) }
                && transfers.jobs.filter { $0.status == .waiting }.count == 1
        }
        try await wait { await transport.inFlight == 2 }
        await transport.release()
        try await wait { transfers.jobs.filter { $0.status == .waiting }.isEmpty }
        try await wait { await transport.inFlight == 2 }
        await transport.release()
        await transport.release()
        try await wait { transfers.jobs.filter { $0.status == .complete }.count == 3 }
        #expect(await transport.peak == 2)
        #expect(transfers.revision == 3)
        for job in transfers.jobs where job.status == .complete {
            let video = try #require(try await temp.database.video(id: job.media!.recordID))
            #expect(video.driveFileID != nil)
            #expect(video.driveLink == "https://drive.google.com/file/d/\(video.driveFileID!)/view")
            #expect(job.progress == 1)
            #expect(job.totalBytes == 3)
        }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition(), "Timed out awaiting upload state")
    }
}
