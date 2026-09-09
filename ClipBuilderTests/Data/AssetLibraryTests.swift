import Foundation
import Testing

@testable import Clip_Builder

struct AssetLibraryTests {
    @Test func syncMutatorsPreserveExactNamesAndRefuseUnexpectedOverwrite() throws {
        let temp = try TempDirectory()
        let folder = temp.url.appendingPathComponent("A & B")
        try AssetStore.createFolder(at: folder, syncKind: .music, invalidate: false)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        let destination = folder.appendingPathComponent("song.mp3")
        let staging = folder.appendingPathComponent(".import-staged")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: staging)
        let date = Date(timeIntervalSince1970: 1_000)
        #expect(throws: GoogleDriveError.self) {
            try AssetStore.installSyncedFile(
                staging, at: destination, modifiedDate: date,
                replacing: false, syncKind: .music, invalidate: false)
        }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        try AssetStore.installSyncedFile(
            staging, at: destination, modifiedDate: date,
            replacing: true, syncKind: .music, invalidate: false)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
    }
}
