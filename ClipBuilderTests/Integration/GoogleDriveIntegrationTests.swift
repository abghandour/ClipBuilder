import Foundation
import Testing

@testable import Clip_Builder

@Suite(
    "Google Drive integration",
    .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_DRIVE_INTEGRATION"] == "1"))
struct GoogleDriveIntegrationTests {
    @Test("List, upload, download, off-load, fetch, and clean up a test fixture")
    func roundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let clientID = try #require(env["GOOGLE_OAUTH_CLIENT_ID"])
        let secret = try #require(env["GOOGLE_OAUTH_CLIENT_SECRET"])
        let refresh = try #require(env["GOOGLE_OAUTH_REFRESH_TOKEN"])
        let folder = try #require(env["GOOGLE_DRIVE_TEST_FOLDER_ID"])
        let fixturePath = try #require(env["GOOGLE_DRIVE_TEST_VIDEO"])
        let credentials = FakeDriveCredentials()
        try credentials.write(
            JSONEncoder().encode(DriveCredential(refreshToken: refresh, issuedAt: Date(), email: "integration")),
            profile: "integration")
        let auth = GoogleDriveAuth(
            configuration: .init(clientID: clientID, clientSecret: secret), credentials: credentials)
        let client = GoogleDriveClient(auth: auth, profile: "integration")
        let temp = try TempDatabase()
        let local = temp.directory.url.appendingPathComponent("drive-integration-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixturePath), to: local)
        let uploaded = try await client.upload(
            file: local, folder: folder, checkpoint: temp.directory.url.appendingPathComponent("upload.json"))
        do {
            let page = try await client.list(folder: folder, search: uploaded.name)
            #expect(page.files.contains { $0.id == uploaded.id })
            let media = DriveMediaStore(
                database: temp.database, client: client, inputFolder: temp.directory.url.appendingPathComponent("Input")
            )
            let downloaded = try await media.download(uploaded, projectID: nil)
            let video = try #require(try await temp.database.driveSource(fileID: uploaded.id))
            #expect(try ContentHashForDrive.md5(downloaded) == ContentHashForDrive.md5(local))
            try await media.offload(video.driveMedia)
            #expect(!FileManager.default.fileExists(atPath: downloaded.path))
            _ = try await media.ensure(video.driveMedia)
            #expect(try ContentHashForDrive.md5(downloaded) == ContentHashForDrive.md5(local))
        } catch {
            try? await deleteFixture(uploaded.id, auth: auth)
            throw error
        }
        try await deleteFixture(uploaded.id, auth: auth)
    }

    private func deleteFixture(_ id: String, auth: GoogleDriveAuth) async throws {
        // Only the id created by this test is deleted; the app has no delete UI.
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!)
        request.httpMethod = "DELETE"
        request.setValue(
            "Bearer \(try await auth.accessToken(profile: "integration"))", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSessionDriveTransport().send(request)
        #expect(response.statusCode == 204)
    }
}
