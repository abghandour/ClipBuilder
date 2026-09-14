import Foundation
import Testing
@testable import Clip_Builder

/// Right-click menus on the Sound and Overlay lanes add at the pointer's
/// time; on an item they replace it in place or remove it.
@MainActor
@Suite("Timeline lane menus", .serialized)
struct TimelineLaneMenuTests {
    @Test("the lane click locator maps the hovered x to a snapped time when no window is attached")
    func locatorFallsBackToHover() {
        let locator = LaneClickLocator()
        locator.hoverX = 190
        #expect(locator.time(pointsPerSecond: 60) == BuilderTimelineModel.snap(190.0 / 60))
        locator.hoverX = -40
        #expect(locator.time(pointsPerSecond: 60) == 0)
    }

    @Test("music and overlays added from a lane menu land at the clicked time, not the playhead")
    func addsAtClickedTime() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10)]))
        model.playhead = 1
        model.addSound(name: "bed.m4a", at: 4)
        let sound = try #require(model.document.soundTrack.first)
        #expect(sound.startTime == 4 && sound.name == "bed.m4a")
        model.addOverlayBlock(name: "Lower Third", composition: LowerThirdOverlay.composition(
            name: "A", role: "B", logoPath: nil), at: 6.5)
        let block = try #require(model.document.overlayBlocks.first)
        #expect(block.startTime == 6.5 && block.name == "Lower Third")
    }

    @Test("replacing keeps an item's place and length and only swaps what it shows")
    func replaceKeepsPlacement() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10)]))
        model.addSound(name: "one.m4a", at: 2, duration: 5)
        let sound = try #require(model.document.soundTrack.first)
        model.updateSound(sound.uid) { $0.name = "two.m4a" }
        let swapped = try #require(model.document.soundTrack.first)
        #expect(swapped.name == "two.m4a" && swapped.startTime == 2 && swapped.duration == 5 && swapped.uid == sound.uid)

        model.addOverlayBlock(name: "Lower Third", composition: LowerThirdOverlay.composition(
            name: "A", role: "B", logoPath: nil), at: 3)
        let block = try #require(model.document.overlayBlocks.first)
        let replacement = LowerThirdOverlay.composition(name: "C", role: "D", logoPath: nil)
        model.updateOverlayBlock(block.uid) { $0.name = "Lower Third — C"; $0.composition = replacement }
        let replaced = try #require(model.document.overlayBlocks.first)
        #expect(replaced.name == "Lower Third — C" && replaced.composition == replacement)
        #expect(replaced.startTime == block.startTime && replaced.duration == block.duration && replaced.uid == block.uid)

        model.removeOverlayBlock(block.uid)
        model.removeSound(sound.uid)
        #expect(model.document.overlayBlocks.isEmpty && model.document.soundTrack.isEmpty)
    }
}
