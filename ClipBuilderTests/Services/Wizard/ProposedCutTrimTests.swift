import Testing
@testable import Clip_Builder

@Suite("Proposed cut trim")
struct ProposedCutTrimTests {
    private let scene = 100.0...200.0

    @Test func clampsBothSceneEdges() {
        #expect(ProposedCutTrim.clamp(start: 90, end: 110, scene: scene) == 100...110)
        #expect(ProposedCutTrim.clamp(start: 190, end: 210, scene: scene) == 190...200)
        #expect(ProposedCutTrim.clamp(start: 0, end: 300, scene: scene) == scene)
        #expect(ProposedCutTrim.clamp(start: 110, end: 120, scene: scene) == 110...120)
    }

    @Test func minimumSpanSurvivesOutOfBoundsAndReversedRanges() {
        #expect(ProposedCutTrim.clamp(start: 150, end: 150.1, scene: scene) == 150...150.5)
        #expect(ProposedCutTrim.clamp(start: 150, end: 140, scene: scene) == 150...150.5)
        #expect(ProposedCutTrim.clamp(start: 199.9, end: 200, scene: scene) == 199.5...200)
        #expect(ProposedCutTrim.clamp(start: 210, end: 220, scene: scene) == 199.5...200)
        #expect(ProposedCutTrim.clamp(start: 50, end: 60, scene: scene) == 100...100.5)
    }

    @Test func veryShortScenesStayInsideTheirBounds() {
        let short = 100.0...100.25
        #expect(ProposedCutTrim.clamp(start: 99, end: 101, scene: short) == short)
        #expect(ProposedCutTrim.clamp(start: 100.2, end: 100.2, scene: short) == short)
        #expect(ProposedCutTrim.clamp(start: 99, end: 101, scene: 100...100) == 100...100)
        #expect(ProposedCutTrim.window(for: short, scene: short).minimumSpan == 0.25)
    }

    @Test func windowsAtStartMiddleAndEndStayInTheScene() {
        let cases: [(ClosedRange<Double>, Double)] = [(100...110, 100), (145...155, 125), (190...200, 150)]
        for (range, expectedStart) in cases {
            let window = ProposedCutTrim.window(for: range, scene: scene)
            #expect(window.start == expectedStart)
            #expect(window.span == 50)
            #expect(window.start >= scene.lowerBound)
            #expect(window.end <= scene.upperBound)
            #expect(window.start <= range.lowerBound)
            #expect(window.end >= range.upperBound)
        }
    }

    @Test func shortSceneAndLongCutRemainFullyVisible() {
        let short = ProposedCutTrim.window(for: 104...106, scene: 100...110)
        #expect(short.start == 100)
        #expect(short.span == 10)
        let long = ProposedCutTrim.window(for: 200...500, scene: 100...600)
        #expect(long.start == 180)
        #expect(long.span == 340)
        #expect(long.rulerInterval == 10)
        #expect(short.rulerInterval == 5)
    }

    @Test func recentersWithinFivePercentOfEitherEdge() {
        let window = ProposedCutTrim.Window(start: 100, span: 100)
        #expect(!window.needsRecentering(106...194))
        #expect(window.needsRecentering(105...150))
        #expect(window.needsRecentering(150...195))
        #expect(window.needsRecentering(99...150))
        #expect(window.needsRecentering(150...201))
    }

    @Test func settingStartInsideBeforeAndAfterTheCut() {
        let range = 130.0...140.0
        #expect(ProposedCutTrim.settingStart(at: 135, in: range, scene: scene) == 135...140)
        #expect(ProposedCutTrim.settingStart(at: 120, in: range, scene: scene) == 120...140)
        #expect(ProposedCutTrim.settingStart(at: 150, in: range, scene: scene) == 150...150.5)
        #expect(ProposedCutTrim.settingStart(at: 140, in: range, scene: scene) == 140...140.5)
        #expect(ProposedCutTrim.settingStart(at: 90, in: range, scene: scene) == 100...140)
        #expect(ProposedCutTrim.settingStart(at: 210, in: range, scene: scene) == 199.5...200)
    }

    @Test func settingEndInsideBeforeAndAfterTheCut() {
        let range = 130.0...140.0
        #expect(ProposedCutTrim.settingEnd(at: 135, in: range, scene: scene) == 130...135)
        #expect(ProposedCutTrim.settingEnd(at: 120, in: range, scene: scene) == 119.5...120)
        #expect(ProposedCutTrim.settingEnd(at: 150, in: range, scene: scene) == 130...150)
        #expect(ProposedCutTrim.settingEnd(at: 130, in: range, scene: scene) == 129.5...130)
        #expect(ProposedCutTrim.settingEnd(at: 90, in: range, scene: scene) == 100...100.5)
        #expect(ProposedCutTrim.settingEnd(at: 210, in: range, scene: scene) == 130...200)
    }

    @Test func detectsChangesAtEitherEndWithoutFloatingPointNoise() {
        #expect(!ProposedCutTrim.differs(130...140, proposedStart: 130, proposedEnd: 140))
        #expect(!ProposedCutTrim.differs(130.0001...140.0001, proposedStart: 130, proposedEnd: 140))
        #expect(ProposedCutTrim.differs(131...140, proposedStart: 130, proposedEnd: 140))
        #expect(ProposedCutTrim.differs(130...139, proposedStart: 130, proposedEnd: 140))
    }

    @Test func playheadOnlyAppearsInsideTheWindow() {
        let window = ProposedCutTrim.Window(start: 100, span: 50)
        #expect(window.playheadX(at: 100, width: 500) == -1)
        #expect(window.playheadX(at: 125, width: 500) == 249)
        #expect(window.playheadX(at: 150, width: 500) == 499)
        #expect(window.playheadX(at: 99, width: 500) == nil)
        #expect(window.playheadX(at: 151, width: 500) == nil)
        #expect(ProposedCutTrim.Window(start: 100, span: 0).playheadX(at: 100, width: 500) == nil)
    }

    @Test func displaysTenthsWithMinuteRollover() {
        #expect(ProposedCutTrim.timecode(1419.72) == "23:39.7")
        #expect(ProposedCutTrim.timecode(1423.5) == "23:43.5")
        #expect(ProposedCutTrim.timecode(59.99) == "1:00.0")
        #expect(ProposedCutTrim.timecode(0) == "0:00.0")
        #expect(ProposedCutTrim.timecode(-1) == "0:00.0")
    }

    @Test func rangeDisplayCalculations() {
        #expect(ProposedCutTrim.range(start: 10, end: 9) == 10...10)
        #expect(ProposedCutTrim.range(start: 10, end: 12) == 10...12)
        #expect(ProposedCutTrim.duration(10...12) == 2)
        #expect(ProposedCutTrim.midpoint(10...12) == 11)
    }
}
