import Foundation
import Testing
@testable import Clip_Builder

@Suite("Hidden sources")
struct HiddenSourcesTests {
    @Test("Hidden rows leave the video lists but stay on record")
    func hiddenLeavesLists() async throws {
        let temp = try await TempDatabase()
        let first = try await temp.seedVideo()
        let url = temp.directory.url.appendingPathComponent("second.mp4")
        try Data("second".utf8).write(to: url)
        let second = try await temp.database.registerVideo(hash: UUID().uuidString, filename: "second.mp4", path: url.path,
                                                           duration: 10, width: 1920, height: 1080, wide: true)
        #expect(try await temp.database.fetchVideos().map(\.id).sorted() == [first, second].sorted())

        try await temp.database.setVideosHidden([second], true)
        #expect(try await temp.database.fetchVideos().map(\.id) == [first])
        // The row itself survives for teammates and sync.
        #expect(try await temp.database.video(id: second) != nil)

        try await temp.database.setVideosHidden([second], false)
        #expect(try await temp.database.fetchVideos().count == 2)
    }
}
