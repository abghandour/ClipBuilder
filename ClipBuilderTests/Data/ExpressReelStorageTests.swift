import Foundation
import Testing
@testable import Clip_Builder

@Suite("Express reel storage")
struct ExpressReelStorageTests {
    @Test func reelRoundTripsInOrderPerProjectAndVideo() async throws {
        let temp = try await TempDatabase()
        let db = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 2)
        let a = try await db.createProject(profileName: "Test", name: "A", videoIDs: [videoID])
        let b = try await db.createProject(profileName: "Test", name: "B", videoIDs: [videoID])
        let sceneID = try await db.fetchScenes(videoID: videoID).first?.id
        let items = [
            MiniReelItem(kind: .highlights, itemID: 41, position: 0, sceneID: sceneID, start: 1.5, end: 9.25, title: "Hook"),
            MiniReelItem(kind: .qa, itemID: 3, position: 1, sceneID: sceneID, start: 10, end: 20, title: "Why?"),
            MiniReelItem(kind: .transcript, itemID: 7, position: 2, sceneID: nil, start: 30, end: 40, title: "Passage 1"),
        ]
        try await db.replaceExpressReelItems(projectID: a, videoID: videoID, items: items)
        try await db.replaceExpressReelItems(projectID: b, videoID: videoID, items: [items[2]])
        #expect(try await db.fetchExpressReelItems(projectID: a, videoID: videoID) == items)
        #expect(try await db.fetchExpressReelItems(projectID: b, videoID: videoID).map(\.itemID) == [7])
        // A rewrite replaces the list and renumbers from the array order.
        try await db.replaceExpressReelItems(projectID: a, videoID: videoID, items: [items[2], items[0]])
        let after = try await db.fetchExpressReelItems(projectID: a, videoID: videoID)
        #expect(after.map(\.itemID) == [7, 41] && after.map(\.position) == [0, 1])
        #expect(try await db.fetchExpressReelItems(projectID: b, videoID: videoID).count == 1, "the other project's reel is untouched")
    }
}
