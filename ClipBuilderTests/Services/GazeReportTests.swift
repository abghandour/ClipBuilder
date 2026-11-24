import Foundation
import Testing
@testable import Clip_Builder

struct GazeReportTests {
    private func row(_ start: Double, _ end: Double, _ kind: GazeMeter.Span.Kind,
                     tile: Int = 0, version: Int = GazeMeter.meterVersion) -> GazeSpanRecord {
        .init(videoID: 1, tile: tile, personKey: nil, start: start, end: end, kind: kind, meterVersion: version)
    }

    @Test func textClipsDurationsAndUsesSourceRange() {
        let report = GazeReport.summary([row(8, 12.1, .down), row(15, 16.4, .aside), row(30, 32, .turned)],
                                        range: 10...19.2, separateFeeds: false)
        #expect(abs(report.share - 3.5 / 9.2) < 1e-9)
        #expect(report.line(clipNumber: 2) == "Gaze: looks away 38% of clip 2 (down 2.1 s, aside 1.4 s)")
    }

    @Test func thresholdAndEmptyRanges() {
        let rows = [row(0, 1, .turned)]
        #expect(GazeReport.summary(rows, range: 0...3, separateFeeds: false).line(clipNumber: 1)
                == "Gaze: looks away 33% of clip 1 (turned 1.0 s)")
        #expect(GazeReport.summary(rows, range: 0...3.01, separateFeeds: false).line(clipNumber: 1) == nil)
        #expect(GazeReport.summary(rows, range: 1...1, separateFeeds: false).share == 0)
        #expect(GazeReport.summary([], range: 0...10, separateFeeds: true).line(clipNumber: 1) == nil)
    }

    @Test func selectsWorstTileInsteadOfAddingFeeds() {
        let rows = [row(0, 2, .down), row(2, 6, .aside, tile: 1), row(0, 10, .turned, tile: 2, version: 0)]
        let multiple = GazeReport.summary(rows, range: 0...10, separateFeeds: true)
        #expect(multiple.tile == 1)
        #expect(multiple.share == 0.4)
        #expect(multiple.line(clipNumber: 3) == "Gaze: looks away 40% of clip 3 (aside 4.0 s)")
        let single = GazeReport.summary(rows, range: 0...10, separateFeeds: false)
        #expect(single.share == 0.2)
        #expect(single.line(clipNumber: 3) == nil)
    }

    @Test func overlappingRowsDoNotDoubleCount() {
        let report = GazeReport.summary([row(0, 3, .down), row(1, 4, .down)], range: 0...10, separateFeeds: false)
        #expect(report.share == 0.4)
        #expect(report.seconds[.down] == 4)
    }
}
