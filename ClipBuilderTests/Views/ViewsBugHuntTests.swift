import Foundation
import Testing
@testable import Clip_Builder

/// Regressions from the October 2026 views bug-hunt: the store and pure
/// helpers behind the fixed views.
@MainActor
@Suite("Views bug-hunt regressions", .serialized)
struct ViewsBugHuntTests {
    @Test("a speed change through updateClip(repack:) repacks a sequential track")
    func speedChangeRepacks() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        let first = Fixtures.timelineClip(sourceStart: 0, duration: 4, startTime: 0)
        let second = Fixtures.timelineClip(sourceStart: 4, duration: 4, startTime: 4)
        model.loadDocument(Fixtures.timelineDocument(clips: [first, second]))

        model.updateClip(first.uid, repack: true) { $0.speed = 2; $0.duration = 2 }
        #expect(model.clip(second.uid)?.startTime == 2)

        model.updateClip(first.uid, repack: true) { $0.speed = 0.5; $0.duration = 8 }
        #expect(model.clip(second.uid)?.startTime == 8)
    }

    @Test("plain updateClip still leaves the track layout alone")
    func plainUpdateDoesNotRepack() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        let first = Fixtures.timelineClip(sourceStart: 0, duration: 4, startTime: 0)
        let second = Fixtures.timelineClip(sourceStart: 4, duration: 4, startTime: 4)
        model.loadDocument(Fixtures.timelineDocument(clips: [first, second]))
        model.updateClip(first.uid) { $0.duration = 2 }
        #expect(model.clip(second.uid)?.startTime == 4)
    }

    @Test("expanded overlay-block items get the same ids on every expansion")
    func expandedOverlayIDsAreStable() {
        var block = OverlayBlockItem()
        block.startTime = 1
        block.duration = 3
        var text = TextOverlayItem()
        text.text = "Hello"
        text.endTime = 2
        var other = TextOverlayItem()
        other.text = "World"
        other.endTime = 2
        block.composition.texts = [text, other]
        var document = TimelineDocument()
        document.overlayBlocks = [block]

        let once = document.expandingOverlayBlocks().textOverlays.map(\.uid)
        let twice = document.expandingOverlayBlocks().textOverlays.map(\.uid)
        #expect(once.count == 2)
        #expect(once == twice)
        #expect(Set(once).count == 2)
        #expect(!once.contains(text.uid) && !once.contains(block.uid))
    }

    @Test("preview draws main clips, then their track's cutaways, then cover-all cutaways")
    func previewDrawOrderMatchesRenderer() {
        var main0 = Fixtures.timelineClip(duration: 10, track: 0)
        main0.videoFile = "main0"
        var main1 = Fixtures.timelineClip(duration: 10, track: 1)
        main1.videoFile = "main1"
        var cut0 = Fixtures.timelineClip(duration: 10, track: 0)
        cut0.role = .cutaway
        cut0.videoFile = "cut0"
        var coverAll = Fixtures.timelineClip(duration: 10, track: 2)
        coverAll.role = .cutaway
        coverAll.coverAllAreas = true
        coverAll.videoFile = "coverAll"

        let order = PreviewPane.drawOrder([coverAll, main1, cut0, main0], at: 1, areaCount: nil)
            .map(\.videoFile)
        #expect(order == ["main0", "cut0", "main1", "coverAll"])

        // One area: tracks 1 and 2 have none, but a cover-all cutaway needs none.
        let masked = PreviewPane.drawOrder([coverAll, main1, cut0, main0], at: 1, areaCount: 1)
            .map(\.videoFile)
        #expect(masked == ["main0", "cut0", "coverAll"])
        #expect(PreviewPane.coversAll(coverAll) && !PreviewPane.coversAll(cut0))
    }

    @Test("image metadata moves with a renamed file and with a moved folder")
    func imageMetadataMoves() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let images = AssetKind.images.rawValue
        try await database.upsertAssetMetadata(LibraryAssetMetadata(
            path: "/lib/a.jpg", kind: images, isBRoll: true, subjects: ["Fighter"], tags: ["crowd"],
            provider: "local", model: nil))
        try await database.upsertAssetMetadata(LibraryAssetMetadata(
            path: "/lib/folder/b.jpg", kind: images, isBRoll: false, subjects: [], tags: ["portrait"],
            provider: nil, model: nil))

        try await database.moveAssetMetadata(kind: .images, from: URL(fileURLWithPath: "/lib/a.jpg"),
                                             to: URL(fileURLWithPath: "/lib/renamed.jpg"))
        try await database.moveAssetMetadata(kind: .images, from: URL(fileURLWithPath: "/lib/folder"),
                                             to: URL(fileURLWithPath: "/lib/moved/folder"))

        let rows = try await database.fetchAssetMetadata(kind: images)
        #expect(Set(rows.map(\.path)) == ["/lib/renamed.jpg", "/lib/moved/folder/b.jpg"])
        let renamed = try #require(rows.first { $0.path == "/lib/renamed.jpg" })
        #expect(renamed.isBRoll && renamed.subjects == ["Fighter"] && renamed.tags == ["crowd"])
    }
}
