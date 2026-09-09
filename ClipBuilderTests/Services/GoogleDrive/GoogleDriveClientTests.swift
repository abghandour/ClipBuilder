import Foundation
import Testing

@testable import Clip_Builder

@MainActor
struct GoogleDriveClientTests {
    @Test func assetReplacementUsesPatchAndVerifiesMD5() async throws {
        for wrongChecksum in [false, true] {
            let fixture = try AssetSyncFixture { request, _ in
                if request.httpMethod == "PATCH" {
                    return (Data(), 200, ["Location": "https://www.googleapis.com/upload/session"])
                }
                var file = AssetSyncFixture.file()
                if wrongChecksum { file.md5Checksum = "different" }
                return try AssetSyncFixture.response(file)
            }
            let file = try fixture.write("music/track.mp3")
            let checkpoint = fixture.directory.url.appendingPathComponent("upload.json")
            do {
                let result = try await fixture.client.upload(
                    file: file, folder: "music", checkpoint: checkpoint,
                    replacingID: "existing", verifyChecksum: true)
                #expect(!wrongChecksum)
                #expect(result.id == "file")
            } catch {
                #expect(wrongChecksum)
                #expect(error as? GoogleDriveError == .conflict)
            }
            let requests = await fixture.transport.requests
            let patch = try #require(requests.first(where: { $0.httpMethod == "PATCH" }))
            #expect(patch.url?.path == "/upload/drive/v3/files/existing")
            #expect(patch.url?.query?.contains("supportsAllDrives=true") == true)
            let metadata = try JSONSerialization.jsonObject(with: patch.httpBody!) as! [String: Any]
            #expect(metadata["parents"] == nil)
            #expect(metadata["trashed"] == nil)
        }
    }
}
