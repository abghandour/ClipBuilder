import Foundation

@testable import Clip_Builder

@MainActor
final class AssetSyncFixture {
    let directory: TempDirectory
    let database: Database
    let roots: AssetSyncRoots
    let transport: FakeDriveTransport
    let client: GoogleDriveClient
    let transfers: GoogleDriveTransfers
    let profile: BrandProfile

    init(handler: @escaping @Sendable (URLRequest, Int) throws -> (Data, Int, [String: String])) throws {
        directory = try TempDirectory(prefix: "AssetSync")
        database = try Database(path: directory.url.appendingPathComponent("profile.db"))
        roots = AssetSyncRoots(base: directory.url.appendingPathComponent("assets"))
        var profile = BrandProfile(name: "Asset sync test")
        profile.sourceFolder = directory.url.appendingPathComponent("input").path
        self.profile = profile
        transport = FakeDriveTransport { request, count in
            if request.url?.host == "oauth2.googleapis.com" {
                return (Data(#"{"access_token":"access","expires_in":3600}"#.utf8), 200, [:])
            }
            return try handler(request, count)
        }
        let credentials = FakeDriveCredentials()
        try credentials.write(
            JSONEncoder().encode(
                DriveCredential(
                    refreshToken: "refresh", issuedAt: Date(),
                    email: "assets@example.com")), profile: profile.profileName)
        let auth = GoogleDriveAuth(
            configuration: .init(clientID: "test", clientSecret: "test"),
            transport: transport, credentials: credentials)
        client = GoogleDriveClient(auth: auth, profile: profile.profileName, transport: transport)
        transfers = GoogleDriveTransfers(auth: auth)
    }

    func attach() async { await transfers.attach(profile: profile, database: database, client: client) }

    func executor(group: UUID = UUID(), fontsArrived: (() -> Void)? = nil) -> AssetSyncExecutor {
        AssetSyncExecutor(
            roots: roots, client: client, transfers: transfers, profile: profile.profileName,
            group: group, journal: AssetSyncJournal(homeID: "home"), fontsArrived: fontsArrived)
    }

    @discardableResult
    func write(_ path: String, text: String = "abc", date: Date = Date(timeIntervalSince1970: 100)) throws -> URL {
        let url = try roots.url(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    nonisolated static func file(id: String = "file", name: String = "track.mp3") -> DriveFile {
        DriveFile(
            id: id, name: name, mimeType: "application/octet-stream", size: "3",
            modifiedTime: "2026-09-09T12:34:56.123Z", md5Checksum: "900150983cd24fb0d6963f7d28e17f72", version: "1")
    }

    nonisolated static func response(_ file: DriveFile, status: Int = 200) throws -> (Data, Int, [String: String]) {
        (try JSONEncoder().encode(file), status, [:])
    }

    nonisolated static func folder(_ id: String, _ name: String) -> DriveFile {
        DriveFile(id: id, name: name, mimeType: "application/vnd.google-apps.folder")
    }

    nonisolated static func page(_ files: [DriveFile], next: String? = nil) throws -> (Data, Int, [String: String]) {
        var object: [String: Any] = [
            "files": try files.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        ]
        object["nextPageToken"] = next
        return (try JSONSerialization.data(withJSONObject: object), 200, [:])
    }

    nonisolated static func stagingPaths(in root: URL) -> [String] {
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walk?.compactMap { $0 as? URL } ?? []).filter { $0.lastPathComponent.hasPrefix(".import-") }.map(\.path)
    }
}
