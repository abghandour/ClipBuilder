import Foundation
import Testing

@testable import Clip_Builder

struct AssetSyncEntryTests {
    @Test func driveFractionalTimeAndChecksum() {
        let file = AssetSyncFixture.file()
        let entry = AssetSyncEntry(file)
        #expect(entry.size == 3)
        #expect(entry.driveID == "file")
        #expect(entry.md5 == file.md5Checksum)
        #expect(entry.modifiedDate != .distantPast)
        #expect(AssetSyncEntry.date("2026-09-09T12:34:56Z") != nil)
    }
}
