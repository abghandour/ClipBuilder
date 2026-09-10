import Foundation
import Testing
@testable import Clip_Builder

@MainActor struct ClipInspectorCropTests {
    @Test func dragMovesTheWindowByItsShareOfTheRoom() {
        // 300 pt preview, 84 pt window: 216 pt of room.
        #expect(ClipInspector.cropFraction(anchor: 0.5, translation: 108, previewWidth: 300, windowWidth: 84) == 1)
        #expect(ClipInspector.cropFraction(anchor: 0.5, translation: -54, previewWidth: 300, windowWidth: 84) == 0.25)
        #expect(ClipInspector.cropFraction(anchor: 0, translation: -50, previewWidth: 300, windowWidth: 84) == 0)
        #expect(ClipInspector.cropFraction(anchor: 1, translation: 50, previewWidth: 300, windowWidth: 84) == 1)
        // No room (window fills the preview): centred, never NaN.
        #expect(ClipInspector.cropFraction(anchor: 0.2, translation: 10, previewWidth: 84, windowWidth: 84) == 0.5)
    }
    @Test func clickCentresTheWindow() {
        #expect(ClipInspector.cropFraction(centeredAt: 150, previewWidth: 300, windowWidth: 84) == 0.5)
        #expect(ClipInspector.cropFraction(centeredAt: 42, previewWidth: 300, windowWidth: 84) == 0)
        #expect(ClipInspector.cropFraction(centeredAt: 0, previewWidth: 300, windowWidth: 84) == 0)
        #expect(ClipInspector.cropFraction(centeredAt: 300, previewWidth: 300, windowWidth: 84) == 1)
    }
}
