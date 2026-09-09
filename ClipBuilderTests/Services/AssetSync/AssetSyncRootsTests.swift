import Foundation
import Testing

@testable import Clip_Builder

struct AssetSyncRootsTests {
    @Test func isolatedAndContained() throws {
        let temp = try TempDirectory()
        let roots = AssetSyncRoots(base: temp.url)
        #expect(!roots.usesSharedCatalog)
        #expect(
            try roots.url(for: "music/nested/a.mp3")
                == temp.url.appendingPathComponent("music/nested/a.mp3").resolvingSymlinksInPath())
        #expect(throws: GoogleDriveError.self) { try roots.url(for: "music/../a.mp3") }
        try FileManager.default.createDirectory(at: roots[.music], withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: roots[.music].appendingPathComponent("escape"), withDestinationURL: temp.url)
        #expect(throws: GoogleDriveError.self) { try roots.url(for: "music/escape/a.mp3") }
    }
}
