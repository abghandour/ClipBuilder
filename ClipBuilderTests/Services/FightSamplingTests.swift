import AppKit
import Foundation
import Testing

@testable import Clip_Builder

@Suite("Fight sampling")
struct FightSamplingTests {
    @Test("Incomplete extraction is unscored and preserves the window's previous events")
    func incompleteExtraction() {
        let times = FightSampling.timestamps(window: (0, 12))
        let partial = FightFrameSheets.Extraction(frames: [], requested: times, extracted: Set(times.prefix(4)))
        #expect(!partial.isComplete)
        #expect(FightSampling.extractionComplete(requested: times, extracted: Set(times)))
        let old = [1.0, 11.75, 12.0].enumerated().map {
            FightEventRecord(id: Int64($0.offset), videoID: 1, time: $0.element,
                             fighterKey: "a", action: "strike", points: 1)
        }
        let retained = FightSampling.retainedEvents(old, unscored: partial.isComplete ? [] : [(0, 12)])
        #expect(retained.map(\.time) == [1, 11.75])
    }

    @Test("Probe timestamps are scoring timestamps, so dense windows decode each still once")
    func reusableProbes() {
        // The fractional boundary also used to make the two grids disagree.
        let window: FightSampling.Range = (10.753, 22.753)
        let scoring = FightSampling.timestamps(window: window)
        let probes = FightSampling.probeTimes(window: window)
        let remaining = scoring.filter { !Set(probes).contains($0) }
        #expect(probes.count == 24 && remaining.count == 24)
        #expect(Set(probes + remaining) == Set(scoring))
        #expect(probes.count + remaining.count == 48)
    }

    private func body(_ minX: Double, _ maxX: Double, _ height: Double = 0.8) -> FightSampling.Body {
        FightSampling.Body(minX: minX, maxX: maxX, height: height)
    }

    @Test("The gap is measured in body heights between two fighter-sized bodies")
    func gap() throws {
        // 16:9 frame, bodies 0.8 tall and 0.45 of the width apart: 0.45 * 1.78 / 0.8 = 1.0.
        let apart = try #require(FightSampling.gap(bodies: [body(0.1, 0.25), body(0.7, 0.85)], aspect: 16.0 / 9))
        #expect(abs(apart - 1.0) < 0.01)
        #expect(FightSampling.gap(bodies: [body(0.3, 0.45), body(0.4, 0.55)], aspect: 16.0 / 9) == 0)
    }

    @Test("A frame that cannot confirm two separate fighters has no gap")
    func gapUnknown() {
        let aspect = 16.0 / 9
        #expect(FightSampling.gap(bodies: [], aspect: aspect) == nil)
        #expect(FightSampling.gap(bodies: [body(0.4, 0.55)], aspect: aspect) == nil)
        // One fighter and a small figure far behind: the small one is not a fighter.
        #expect(FightSampling.gap(bodies: [body(0.1, 0.25), body(0.8, 0.86, 0.4)], aspect: aspect) == nil)
        // Crowd only.
        #expect(FightSampling.gap(bodies: [body(0.1, 0.13, 0.15), body(0.8, 0.83, 0.15)], aspect: aspect) == nil)
        // A box wide enough to hold both fighters, with the referee far away.
        #expect(FightSampling.gap(bodies: [body(0.1, 0.5), body(0.8, 0.92)], aspect: aspect) == nil)
    }

    @Test("With a third body in frame the closest pair decides")
    func gapClosestPair() throws {
        let gap = try #require(FightSampling.gap(bodies: [body(0.1, 0.25), body(0.3, 0.45), body(0.8, 0.92)],
                                                 aspect: 16.0 / 9))
        #expect(gap < FightSampling.farGap)
    }

    @Test("Distance is believed only when it holds for three seconds")
    func farRanges() {
        func probes(_ gaps: [Double?], from start: Double = 0) -> [(time: Double, gap: Double?)] {
            gaps.enumerated().map { (start + Double($0.offset) * 0.5, $0.element) }
        }
        // Two seconds apart: not enough.
        #expect(FightSampling.farRanges(probes: probes([1, 1, 1, 1, 0.1])).isEmpty)
        // Five seconds apart from 10 s, pulled in by the margin at both ends.
        let held = FightSampling.farRanges(probes: probes(Array(repeating: 1.2, count: 10) + [0.2], from: 10))
        #expect(held.count == 1)
        #expect(held.first?.start == 10.5 && held.first?.end == 14.5)
        // One unreadable frame in the middle breaks the run into two short ones.
        let broken: [Double?] = [1, 1, 1, 1, nil, 1, 1, 1, 1]
        #expect(FightSampling.farRanges(probes: probes(broken)).isEmpty)
        // A gap just under reach never counts.
        #expect(FightSampling.farRanges(probes: probes(Array(repeating: 0.6, count: 20))).isEmpty)
    }

    @Test("Stills are four a second, one a second while the fighters are apart")
    func timestamps() {
        let dense = FightSampling.timestamps(window: (10, 12))
        #expect(dense == [10, 10.25, 10.5, 10.75, 11, 11.25, 11.5, 11.75])
        let mixed = FightSampling.timestamps(window: (0, 6), far: [(1, 5)])
        #expect(mixed == [0, 0.25, 0.5, 0.75, 1, 2, 3, 4, 5, 5.25, 5.5, 5.75])
        #expect(FightSampling.timestamps(window: (3, 3.02)) == [3])
        #expect(FightSampling.sparseSeconds(window: (0, 6), far: [(1, 5), (5.5, 9)]) == 4.5)
    }

    @Test("Sheets hold four consecutive stills and say so in their label")
    func sheets() {
        let sheets = FightSampling.sheets(FightSampling.timestamps(window: (0, 2.25)))
        #expect(sheets.map(\.count) == [4, 4, 1])
        #expect(sheets[1] == [1, 1.25, 1.5, 1.75])
        #expect(FightSampling.label(sheets[1]).hasPrefix("1.00s, 1.25s, 1.50s, 1.75s — 4 consecutive stills"))
        #expect(FightSampling.label([2]) == "2.00s")
    }

    @Test("Windows stay inside one call's image budget")
    func windows() {
        let windows = FightSampling.windows([(0, 86), (100, 110), (200, 200)])
        #expect(windows.count == 9)
        #expect(windows.allSatisfy { $0.end - $0.start <= FightSampling.maxWindow + 0.001 })
        #expect(windows.first?.start == 0 && windows[7].end == 86 && windows[8].start == 100)
        let sheets = FightSampling.sheets(FightSampling.timestamps(window: (0, FightSampling.maxWindow)))
        #expect(sheets.count == 12)
    }

    @Test("A fight is scored end to end; recaps and very long files follow the action tags")
    func scoredRanges() {
        let tagged: [FightSampling.Range] = [(0.5, 14), (13, 15), (47, 57)]
        let whole = FightSampling.scoredRanges(actionRanges: tagged, type: .fight, duration: 86)
        #expect(whole.count == 1 && whole[0].start == 0 && whole[0].end == 86)
        #expect(FightSampling.scoredRanges(actionRanges: [], type: .fight, duration: 86).count == 1)
        let recap = FightSampling.scoredRanges(actionRanges: tagged, type: .recap, duration: 86)
        #expect(recap.count == 2 && recap[0].start == 0.5 && recap[0].end == 15 && recap[1].start == 47)
        let card = FightSampling.scoredRanges(actionRanges: tagged, type: .fight, duration: 4 * 3600)
        #expect(card.count == 2)
        #expect(FightSampling.scoredRanges(actionRanges: [], type: .recap, duration: 86).isEmpty)
    }

    @Test("A composed sheet is two stills across and as many rows as needed")
    func compose() throws {
        func still() throws -> Data {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
                                                    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            return try #require(rep.representation(using: .jpeg, properties: [:]))
        }
        func size(_ tiles: Int) throws -> [Int] {
            let jpeg = try #require(FightFrameSheets.compose(try (0..<tiles).map { (Double($0) * 0.25, try still()) }))
            let rep = try #require(NSBitmapImageRep(data: jpeg))
            return [rep.pixelsWide, rep.pixelsHigh]
        }
        #expect(try size(4) == [640, 360])
        #expect(try size(3) == [640, 360])
        #expect(try size(2) == [640, 180])
        #expect(try size(1) == [320, 180])
        #expect(FightFrameSheets.compose([]) == nil)
        #expect(FightFrameSheets.compose([(0, Data([1, 2, 3]))]) == nil)
        #expect(try FightFrameSheets.compose([(0, still()), (0.25, Data([1, 2, 3]))]) == nil)
    }
}
