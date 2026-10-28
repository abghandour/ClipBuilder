import Foundation
import Testing
@testable import Clip_Builder

@Suite("Focus frame zoom slider")
struct FocusFrameZoomTests {
    private let portrait = FreeCropRect(xFrac: 0.34, yFrac: 0, wFrac: 0.32, hFrac: 1)

    @Test func fullSourceReadsOneAndLongerSideSetsTheZoom() {
        #expect(FocusFrameZoom.zoom(nil) == 1)
        #expect(FocusFrameZoom.zoom(portrait) == 1)
        #expect(abs(FocusFrameZoom.zoom(FreeCropRect(xFrac: 0.4, yFrac: 0.25, wFrac: 0.16, hFrac: 0.5)) - 2) < 1e-9)
        #expect(FocusFrameZoom.zoom(FreeCropRect(wFrac: 0.01, hFrac: 0.01)) == FocusFrameZoom.range.upperBound)
    }

    @Test func zoomingInKeepsTheCentreAndShape() throws {
        let frame = try #require(FocusFrameZoom.frame(zoom: 2, current: nil, base: portrait))
        #expect(abs(frame.wFrac - 0.16) < 1e-9 && abs(frame.hFrac - 0.5) < 1e-9)
        #expect(abs(frame.xFrac + frame.wFrac / 2 - 0.5) < 1e-9)
        #expect(abs(frame.yFrac + frame.hFrac / 2 - 0.5) < 1e-9)
        #expect(abs(FocusFrameZoom.zoom(frame) - 2) < 1e-9)
    }

    @Test func zoomingBackOutReturnsTheBaseAndStaysInsideTheSource() {
        let corner = FreeCropRect(xFrac: 0.84, yFrac: 0.5, wFrac: 0.16, hFrac: 0.5)
        let out = FocusFrameZoom.frame(zoom: 1, current: corner, base: portrait)
        #expect(abs((out?.xFrac ?? 0) - 0.68) < 1e-9 && out?.yFrac == 0)
        #expect(abs((out?.wFrac ?? 0) - 0.32) < 1e-9 && out?.hFrac == 1)
        #expect(FocusFrameZoom.frame(zoom: 1, current: FreeCropRect(xFrac: 0.42, yFrac: 0.25, wFrac: 0.16, hFrac: 0.5), base: portrait) == nil)
        #expect(FocusFrameZoom.frame(zoom: 1, current: nil, base: FreeCropRect()) == nil)
    }

    @Test func freeFramesScaleUniformlyAndRespectTheMinimumSide() throws {
        let band = FreeCropRect(xFrac: 0, yFrac: 0.3, wFrac: 1, hFrac: 0.1)
        let zoomed = try #require(FocusFrameZoom.frame(zoom: 4, current: band, base: FreeCropRect()))
        #expect(abs(zoomed.wFrac - 0.5) < 1e-9 && abs(zoomed.hFrac - FocusFrameZoom.minimumSide) < 1e-9)
        #expect(abs(zoomed.yFrac + zoomed.hFrac / 2 - 0.35) < 1e-9)
        #expect(FocusFrameZoom.frame(zoom: .nan, current: band, base: FreeCropRect()) == FreeCropRect(xFrac: 0, yFrac: 0.3, wFrac: 1, hFrac: 0.1))
    }
}
