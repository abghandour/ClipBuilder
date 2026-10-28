import Foundation
import Testing
@testable import Clip_Builder

struct OverlayStageBackdropTests {
    @Test func frameOnlyForAChosenVideo() {
        var backdrop = OverlayStageBackdrop(mode: .black, colorHex: "#ff0000", videoPath: "/tmp/a.mp4", time: 12)
        #expect(backdrop.frame == nil)
        backdrop.mode = .color
        #expect(backdrop.frame == nil)
        backdrop.mode = .video
        #expect(backdrop.frame == OverlayStageBackdrop.Frame(url: URL(fileURLWithPath: "/tmp/a.mp4"), time: 12))
        backdrop.time = -3
        #expect(backdrop.frame?.time == 0)
        backdrop.videoPath = ""
        #expect(backdrop.frame == nil)
    }

    @Test func modesHaveLabelsAndRoundTrip() {
        for mode in OverlayStageBackdrop.Mode.allCases {
            #expect(!mode.label.isEmpty)
            #expect(OverlayStageBackdrop.Mode(rawValue: mode.rawValue) == mode)
        }
    }
}
