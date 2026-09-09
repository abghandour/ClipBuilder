import Foundation
import Testing

@testable import Clip_Builder

struct GoogleDriveModelsTests {
    @Test func legacyMetadataStillDecodesWithoutTrashField() throws {
        let legacy = Data(#"{"id":"file","name":"track.mp3","mimeType":"audio/mpeg","size":"3"}"#.utf8)
        let file = try JSONDecoder().decode(DriveFile.self, from: legacy)
        #expect(file.trashed == nil)
        #expect(file.byteCount == 3)
        let trashed = Data(
            #"{"id":"home","name":"Library","mimeType":"application/vnd.google-apps.folder","trashed":true}"#.utf8)
        let home = try JSONDecoder().decode(DriveFile.self, from: trashed)
        #expect(home.isFolder)
        #expect(home.trashed == true)
    }
}
