import Foundation
import Testing

@testable import Clip_Builder

/// In-memory credentials keep tests away from the user's Keychain.
nonisolated final class FakeDriveCredentials: DriveCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(profile: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[profile]
    }
    func write(_ data: Data?, profile: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[profile] = data
    }
}

actor FakeDriveTransport: DriveTransport {
    var requests: [URLRequest] = []
    let handler: @Sendable (URLRequest, Int) throws -> (Data, Int, [String: String])
    init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> (Data, Int, [String: String])) {
        self.handler = handler
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, status, headers) = try handler(request, requests.count)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        )
    }
}

nonisolated final class CountingDriveChecksum: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    func compute(_ url: URL) throws -> String {
        lock.lock()
        calls += 1
        lock.unlock()
        return try ContentHashForDrive.md5(url)
    }
}

@Suite("Google Drive")
struct GoogleDriveTests {
    private let profile = "Drive test"
    private func auth(_ transport: any DriveTransport, issued: Date = Date()) throws -> GoogleDriveAuth {
        let credentials = FakeDriveCredentials()
        try credentials.write(
            JSONEncoder().encode(DriveCredential(refreshToken: "refresh", issuedAt: issued, email: "test@example.com")),
            profile: profile)
        return GoogleDriveAuth(
            configuration: .init(clientID: "test", clientSecret: "test"), transport: transport, credentials: credentials
        )
    }
    nonisolated static var token: Data { Data(#"{"access_token":"access","expires_in":3600}"#.utf8) }

    @Test("PKCE follows RFC 7636 and form values cannot inject fields")
    func pkce() {
        #expect(
            GoogleDriveAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(String(decoding: GoogleDriveAuth.form(["code": "a+b&x=1"]), as: UTF8.self) == "code=a%2Bb%26x%3D1")
    }

    @Test("Refresh is cached and does not renew seven-day testing expiry")
    func refreshToken() async throws {
        let transport = FakeDriveTransport { _, _ in (Self.token, 200, [:]) }
        let issued = Date().addingTimeInterval(-3600)
        let auth = try auth(transport, issued: issued)
        #expect(try await auth.accessToken(profile: profile) == "access")
        #expect(try await auth.accessToken(profile: profile) == "access")
        #expect(await transport.requests.count == 1)
        #expect(try await auth.credential(profile: profile)?.issuedAt == issued)
        #expect(
            await auth.state(profile: profile, now: issued.addingTimeInterval(7 * 86400))
                == .reconnect(email: "test@example.com", expires: issued.addingTimeInterval(7 * 86400)))
    }

    @Test("Expired and revoked refresh tokens request reconnect")
    func expiredAndRevoked() async throws {
        let transport = FakeDriveTransport { _, _ in (Data(#"{"error":"invalid_grant"}"#.utf8), 400, [:]) }
        let expired = try auth(transport, issued: Date().addingTimeInterval(-8 * 86400))
        await #expect(throws: GoogleDriveError.reconnect) { try await expired.accessToken(profile: profile) }
        #expect(await transport.requests.isEmpty)
        let revoked = try auth(transport)
        await #expect(throws: GoogleDriveError.reconnect) { try await revoked.accessToken(profile: profile) }
        if case .reconnect = await revoked.state(profile: profile) {} else { Issue.record("Expected reconnect") }
        await #expect(throws: GoogleDriveError.reconnect) { try await revoked.accessToken(profile: profile) }
        #expect(await transport.requests.count == 1)
    }

    @Test("Empty configuration is visible and missing write scope requires reconnect")
    func configurationAndScopes() async throws {
        let transport = FakeDriveTransport { _, _ in
            (
                Data(
                    #"{"access_token":"access","expires_in":3600,"scope":"https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file"}"#
                        .utf8), 200, [:]
            )
        }
        let empty = GoogleDriveAuth(configuration: .init(clientID: "", clientSecret: ""), transport: transport)
        #expect(await empty.state(profile: profile) == .notConfigured)
        await #expect(throws: GoogleDriveError.notConfigured) { try await empty.accessToken(profile: profile) }
        let missing = try auth(transport)
        await #expect(throws: GoogleDriveError.reconnect) { try await missing.accessToken(profile: profile) }
    }

    @Test("Download registration reuses a local copy and preserves scenes")
    func registrationReuse() async throws {
        let temp = try TempDatabase()
        let url = temp.directory.url.appendingPathComponent("existing.mp4")
        try Data("video fixture".utf8).write(to: url)
        let id = try await temp.database.registerVideo(
            hash: ContentHash.fingerprint(of: url), filename: "existing.mp4", path: url.path, duration: 1, width: 10,
            height: 10, wide: false)
        let file = DriveFile(id: "remote", name: "existing.mp4", size: "13")
        try await temp.database.setDriveCopy(DriveMedia(kind: .source, recordID: id, path: url.path), file: file)
        let transport = FakeDriveTransport { _, _ in throw GoogleDriveError.offline }
        let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
        let media = DriveMediaStore(database: temp.database, client: client, inputFolder: temp.directory.url)
        #expect(try await media.download(file, projectID: nil) == url)
        #expect(await transport.requests.isEmpty)
        #expect(try await temp.database.fetchVideos().count == 1)
    }

    @Test("Off-load preserves scenes, and fetching restores the same path")
    func offloadAndRestore() async throws {
        let temp = try TempDatabase()
        let id = try await temp.seedVideo(sceneCount: 2)
        let video = try #require(try await temp.database.video(id: id))
        let bytes = Data("fixture".utf8)
        try bytes.write(to: video.url)
        let expectedChecksum = try ContentHashForDrive.md5(video.url)
        let file = DriveFile(id: "remote", name: "fixture.mp4", size: "7", md5Checksum: expectedChecksum, version: "1")
        try await temp.database.setDriveCopy(video.driveMedia, file: file)
        let data = try JSONEncoder().encode(file)
        let transport = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            if request.value(forHTTPHeaderField: "Range") != nil {
                return (bytes, 206, ["Content-Range": "bytes 0-6/7"])
            }
            return (data, 200, [:])
        }
        let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
        let checksum = CountingDriveChecksum()
        let media = DriveMediaStore(
            database: temp.database, client: client, inputFolder: temp.directory.url, checksumOf: checksum.compute)
        let registered = try #require(try await temp.database.video(id: id)).driveMedia
        let scenes = try await temp.database.fetchScenes()
        try await media.offload(registered)
        #expect(checksum.count == 1)
        let files = DriveTransferFiles(for: video.url)
        #expect(files.readIdentity()?.md5 == expectedChecksum)
        #expect(FileManager.default.fileExists(atPath: files.identity.path))
        #expect(
            !FileManager.default.fileExists(atPath: video.url.appendingPathExtension("drive-cache-identity.json").path))
        #expect(!FileManager.default.fileExists(atPath: video.path))
        #expect(try await temp.database.video(id: id)?.driveOffloaded == true)
        #expect(try await temp.database.fetchScenes() == scenes)
        #expect(try await media.ensure(registered) == video.url)
        #expect(try Data(contentsOf: video.url) == bytes)
        #expect(try await temp.database.video(id: id)?.driveOffloaded == false)
        #expect(try await temp.database.fetchScenes() == scenes)
    }

    @Test("Interrupted download resumes from its durable byte offset")
    func rangeResume() async throws {
        let temp = try TempDirectory()
        let destination = temp.url.appendingPathComponent("fixture.mp4")
        let file = DriveFile(id: "remote", name: "fixture.mp4", size: "6", version: "1")
        try Data("abc".utf8).write(to: destination.appendingPathExtension("drive-partial"))
        try Data("remote|1|6|".utf8).write(to: destination.appendingPathExtension("drive-download.json"))
        let data = try JSONEncoder().encode(file)
        let transport = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            if let range = request.value(forHTTPHeaderField: "Range") {
                #expect(range == "bytes=3-5")
                return (Data("def".utf8), 206, ["Content-Range": "bytes 3-5/6"])
            }
            return (data, 200, [:])
        }
        let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
        _ = try await client.download(id: file.id, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "abcdef")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("drive-partial").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("drive-download.json").path))
        let files = DriveTransferFiles(for: destination)
        #expect(FileManager.default.fileExists(atPath: files.directory.path))
    }

    @Test("Upload stores the returned id and link on an output")
    func uploadRegistration() async throws {
        let temp = try TempDatabase()
        let url = temp.directory.url.appendingPathComponent("output.mp4")
        try Data("fixture".utf8).write(to: url)
        let id = try await temp.database.insertGeneratedVideo(
            path: url.path, duration: 1, timelineJSON: "[]", wizardProvider: nil, wizardModel: nil)
        let file = DriveFile(
            id: "uploaded", name: "output.mp4", webViewLink: "https://drive.google.com/file/d/uploaded/view")
        let encoded = try JSONEncoder().encode(file)
        let transport = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            if request.httpMethod == "POST" {
                return (Data(), 200, ["Location": "https://www.googleapis.com/upload/session"])
            }
            #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-6/7")
            return (encoded, 200, [:])
        }
        let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
        let media = DriveMediaStore(database: temp.database, client: client, inputFolder: temp.directory.url)
        _ = try await media.upload(DriveMedia(kind: .output, recordID: id, path: url.path), folder: "folder")
        let result = try #require(try await temp.database.fetchGeneratedVideos().first)
        #expect(result.driveFileID == "uploaded")
        #expect(result.driveLink == file.webViewLink)
    }

    @Test("Drive errors distinguish quota, missing media, and missing scopes")
    func typedErrors() async throws {
        for (status, body, expected) in [
            (404, "", GoogleDriveError.notFound), (429, "", .quota),
            (403, "insufficientPermissions", .reconnect), (403, "insufficientFilePermissions", .forbidden),
            (503, "", .server(503)),
        ] {
            let transport = FakeDriveTransport { request, _ in
                if request.url?.path == "/token" { return (Self.token, 200, [:]) }
                return (Data(body.utf8), status, [:])
            }
            let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
            await #expect(throws: expected) { try await client.metadata(id: "missing") }
        }
    }
    @Test("Upload resumes by probing the server offset after a lost response")
    func uploadResume() async throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("upload.mp4")
        let checkpoint = temp.url.appendingPathComponent("session.json")
        try Data("abcdef".utf8).write(to: url)
        let file = DriveFile(id: "uploaded", name: "upload.mp4", size: "6")
        let encoded = try JSONEncoder().encode(file)
        let first = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            if request.httpMethod == "POST" {
                return (Data(), 200, ["Location": "https://www.googleapis.com/upload/session"])
            }
            throw GoogleDriveError.offline
        }
        let firstClient = GoogleDriveClient(auth: try auth(first), profile: profile, transport: first)
        await #expect(throws: GoogleDriveError.offline) {
            try await firstClient.upload(file: url, folder: "folder", checkpoint: checkpoint)
        }
        let second = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            #expect(request.httpMethod == "PUT")
            if request.value(forHTTPHeaderField: "Content-Range") == "bytes */6" {
                return (Data(), 308, ["Range": "bytes=0-2"])
            }
            #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 3-5/6")
            #expect(request.httpBody == Data("def".utf8))
            return (encoded, 200, [:])
        }
        let secondClient = GoogleDriveClient(auth: try auth(second), profile: profile, transport: second)
        #expect(try await secondClient.upload(file: url, folder: "folder", checkpoint: checkpoint).id == "uploaded")
    }

    @Test("A changed remote revision cannot be installed from mixed partial bytes")
    func changedRevision() async throws {
        let temp = try TempDirectory()
        let target = temp.url.appendingPathComponent("changed.mp4")
        let transport = FakeDriveTransport { request, count in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            if request.value(forHTTPHeaderField: "Range") != nil {
                return (Data("abc".utf8), 206, ["Content-Range": "bytes 0-2/3"])
            }
            let file = DriveFile(id: "remote", name: "changed.mp4", size: "3", version: count > 3 ? "2" : "1")
            return (try JSONEncoder().encode(file), 200, [:])
        }
        let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
        await #expect(throws: GoogleDriveError.conflict) { try await client.download(id: "remote", to: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("Media in use cannot be off-loaded")
    func mediaLease() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("playing.mp4")
        try Data("fixture".utf8).write(to: file)
        let lease = try await DriveMediaResolver.shared.acquire(file)
        await #expect(throws: GoogleDriveError.inUse) { try await DriveMediaResolver.shared.beginOffload(file.path) }
        withExtendedLifetime(lease) {}
    }

    @Test("Concurrent imports share one download and retain both project memberships")
    func concurrentImports() async throws {
        let temp = try TempDatabase()
        let firstProject = try await temp.database.createProject(profileName: profile, name: "First")
        let secondProject = try await temp.database.createProject(profileName: profile, name: "Second")
        let file = DriveFile(id: "concurrent", name: "fixture.mp4", size: "7", version: "1")
        let encoded = try JSONEncoder().encode(file)
        let transport = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            if request.value(forHTTPHeaderField: "Range") != nil {
                return (Data("fixture".utf8), 206, ["Content-Range": "bytes 0-6/7"])
            }
            return (encoded, 200, [:])
        }
        let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
        let media = DriveMediaStore(database: temp.database, client: client, inputFolder: temp.directory.url)
        async let first = media.download(file, projectID: firstProject)
        async let second = media.download(file, projectID: secondProject)
        let (firstURL, secondURL) = try await (first, second)
        #expect(firstURL == secondURL)
        let video = try #require(try await temp.database.driveSource(fileID: file.id))
        #expect(Set(try await temp.database.projectIDs(forVideo: video.id)) == Set([firstProject, secondProject]))
        #expect(await transport.requests.filter { $0.value(forHTTPHeaderField: "Range") != nil }.count == 1)
    }

    @Test("An off-loaded file cannot silently restore different media under existing scenes")
    func changedOffloadedCopy() async throws {
        let temp = try TempDatabase()
        let id = try await temp.seedVideo()
        let video = try #require(try await temp.database.video(id: id))
        try Data("fixture".utf8).write(to: video.url)
        let file = DriveFile(id: "remote", name: "fixture.mp4", size: "7", version: "1")
        try await temp.database.setDriveCopy(video.driveMedia, file: file)
        let encoded = try JSONEncoder().encode(file)
        let transport = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            if request.value(forHTTPHeaderField: "Range") != nil {
                return (Data("changed".utf8), 206, ["Content-Range": "bytes 0-6/7"])
            }
            return (encoded, 200, [:])
        }
        let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
        let media = DriveMediaStore(database: temp.database, client: client, inputFolder: temp.directory.url)
        let registered = try #require(try await temp.database.video(id: id)).driveMedia
        try await media.offload(registered)
        await #expect(throws: GoogleDriveError.conflict) { try await media.ensure(registered) }
        #expect(!FileManager.default.fileExists(atPath: video.path))
        #expect(try await temp.database.video(id: id)?.driveOffloaded == true)
        #expect(try await temp.database.fetchScenes().count == 1)
    }

    @Test("Missing ordinary local files retain their original consumer error behavior")
    func missingLocalPath() async throws {
        let temp = try TempDatabase()
        let id = try await temp.seedVideo()
        let video = try #require(try await temp.database.video(id: id))
        let resolver = DriveMediaResolver()
        await resolver.register(database: temp.database, profile: profile)
        let unknown = temp.directory.url.appendingPathComponent("missing.mp4")
        #expect(try await resolver.ensureLocal(unknown) == unknown)
        #expect(try await resolver.ensureLocal(video.url) == video.url)
        #expect(!FileManager.default.fileExists(atPath: unknown.path))
        #expect(!FileManager.default.fileExists(atPath: video.path))
    }

    @Test("Account mismatch names the required account and preserves the saved credentials")
    func mismatchedAccount() async throws {
        let scopes = GoogleDriveAuth.scopes.joined(separator: " ")
        let transport = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" {
                return (
                    try JSONSerialization.data(withJSONObject: [
                        "access_token": "new-access", "expires_in": 3600,
                        "refresh_token": "new-refresh", "scope": scopes,
                    ]), 200, [:]
                )
            }
            return (Data(#"{"email":"different@example.com"}"#.utf8), 200, [:])
        }
        let auth = try auth(transport)
        let before = try #require(try await auth.credential(profile: profile))
        let expected = GoogleDriveError.accountMismatch(expected: "test@example.com")
        await #expect(throws: expected) {
            try await auth.completeSignIn(
                code: "code", verifier: "verifier", redirectURI: "http://127.0.0.1/callback", profile: profile)
        }
        let after = try #require(try await auth.credential(profile: profile))
        #expect(after.refreshToken == before.refreshToken)
        #expect(after.issuedAt == before.issuedAt)
        #expect(after.email == before.email)
        #expect(expected.localizedDescription.contains("test@example.com"))
        #expect(expected.localizedDescription.contains("the account this profile uses"))
    }

    @Test("Downloads use 16 MiB ranges and retain interrupted bytes in hidden storage")
    func downloadRangeSize() async throws {
        let temp = try TempDirectory()
        let target = temp.url.appendingPathComponent("large.mp4")
        let chunk = 16 * 1024 * 1024
        let size = chunk + 1
        let file = DriveFile(id: "large", name: "large.mp4", size: String(size), version: "1")
        let data = try JSONEncoder().encode(file)
        let transport = FakeDriveTransport { request, _ in
            if request.url?.path == "/token" { return (Self.token, 200, [:]) }
            if let range = request.value(forHTTPHeaderField: "Range") {
                if range == "bytes=0-\(chunk - 1)" {
                    return (Data(repeating: 65, count: chunk), 206, ["Content-Range": "bytes 0-\(chunk - 1)/\(size)"])
                }
                #expect(range == "bytes=\(chunk)-\(chunk)")
                throw GoogleDriveError.offline
            }
            return (data, 200, [:])
        }
        let client = GoogleDriveClient(auth: try auth(transport), profile: profile, transport: transport)
        await #expect(throws: GoogleDriveError.offline) { try await client.download(id: file.id, to: target) }
        let files = DriveTransferFiles(for: target)
        #expect(try files.partial.resourceValues(forKeys: [.fileSizeKey]).fileSize == chunk)
        #expect(FileManager.default.fileExists(atPath: files.checkpoint.path))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == [".drive"])
        #expect(chunk % (256 * 1024) == 0)
    }

    @Test("Legacy restoration checkpoints migrate as a pair into path-keyed hidden storage")
    func hiddenSidecarMigration() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("source.mp4")
        let oldRestore = url.appendingPathExtension("drive-restoring")
        let identity = DriveCacheIdentity(size: 6, mtime: 123, md5: "checksum")
        try JSONEncoder().encode(identity).write(to: url.appendingPathExtension("drive-cache-identity.json"))
        try Data("restored".utf8).write(to: oldRestore)
        try Data("abc".utf8).write(to: oldRestore.appendingPathExtension("drive-partial"))
        try Data("checkpoint".utf8).write(to: oldRestore.appendingPathExtension("drive-download.json"))
        let files = DriveTransferFiles(for: url)
        try files.prepare()
        #expect(files.directory.lastPathComponent == ContentHashForDrive.key(url.standardizedFileURL.path))
        #expect(try Data(contentsOf: files.partial) == Data("abc".utf8))
        #expect(try Data(contentsOf: files.checkpoint) == Data("checkpoint".utf8))
        #expect(try Data(contentsOf: files.restoring) == Data("restored".utf8))
        #expect(files.readIdentity()?.md5 == identity.md5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == [".drive"])
        let other = DriveTransferFiles(for: temp.url.appendingPathComponent("other.mp4"))
        #expect(files.directory != other.directory)
        try files.prepare()
        #expect(try Data(contentsOf: files.partial) == Data("abc".utf8))
    }

    @Test("Stable thumbnails are created only for Drive records or identity sidecars")
    func thumbnailCacheScope() async throws {
        let temp = try TempDatabase()
        let id = try await temp.seedVideo()
        let video = try #require(try await temp.database.video(id: id))
        try Data("fixture".utf8).write(to: video.url)
        let resolver = DriveMediaResolver()
        await resolver.register(database: temp.database, profile: profile)
        let cache = temp.directory.url.appendingPathComponent("thumbs")
        let image = Data("cached JPEG".utf8)
        let thumbnails = ThumbnailService(
            cacheDirectory: cache, mediaResolver: resolver, frameLoader: { _, _, _ in image })
        #expect(await thumbnails.thumbnail(for: video.url, at: 0) == image)
        #expect(await thumbnails.thumbnail(for: video.url, at: 0) == image)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
        #expect(!FileManager.default.fileExists(atPath: DriveTransferFiles(for: video.url).directory.path))

        let file = DriveFile(id: "remote", name: "fixture.mp4")
        try await temp.database.setDriveCopy(video.driveMedia, file: file)
        #expect(await thumbnails.thumbnail(for: video.url, at: 0) == image)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 2)
        #expect(await thumbnails.thumbnail(for: video.url, at: 1) == image)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 4)

        // No registered DB in a new service: the legacy sidecar still identifies
        // this as Drive media, migrates, and serves the stable cached image.
        let identity = DriveCacheIdentity(size: 7, mtime: 123, md5: "checksum")
        try JSONEncoder().encode(identity).write(to: video.url.appendingPathExtension("drive-cache-identity.json"))
        try FileManager.default.removeItem(at: video.url)
        let restored = ThumbnailService(
            cacheDirectory: cache, mediaResolver: DriveMediaResolver(), frameLoader: { _, _, _ in nil })
        #expect(await restored.thumbnail(for: video.url, at: 0) == image)
        #expect(FileManager.default.fileExists(atPath: DriveTransferFiles(for: video.url).identity.path))
        #expect(
            !FileManager.default.fileExists(atPath: video.url.appendingPathExtension("drive-cache-identity.json").path))
        #expect(!FileManager.default.fileExists(atPath: video.path))
    }

}
