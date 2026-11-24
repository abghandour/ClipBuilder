import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

struct GazeMeterTests {
    private func samples(count: Int = 20, yaw: Double = 0, pitch: Double = 0,
                         pupilX: Double? = 0, pupilY: Double? = 0, width: Double = 160) -> [GazeMeter.Sample] {
        (0..<count).map {
            .init(time: Double($0) / 5, yaw: yaw, pitch: pitch, pupilX: pupilX, pupilY: pupilY, faceWidth: width)
        }
    }

    @Test func baselineIsRelativeToThePerson() {
        var values = samples(yaw: 60, pitch: 25, pupilX: 0.4, pupilY: -0.5)
        #expect(GazeMeter.spans(values).isEmpty)
        for index in 8..<12 { values[index].yaw += 20 }
        let found = GazeMeter.spans(values)
        #expect(found.map(\.kind) == [.turned])
        // 2.4 is a sum of sample intervals: compare times with a tolerance.
        #expect(abs((found.first?.start ?? 0) - 1.6) < 1e-9 && abs((found.first?.end ?? 0) - 2.4) < 1e-9)
    }

    @Test(arguments: [-18.01, -18.0, -17.99, 17.99, 18.0, 18.01])
    func yawThreshold(departure: Double) {
        var values = samples()
        for index in 8..<12 { values[index].yaw = departure }
        let kinds = GazeMeter.spans(values).map(\.kind)
        #expect(kinds == (abs(departure) >= 18 ? [.turned] : []))
    }

    @Test(arguments: [-14.01, -14.0, -13.99, 13.99, 14.0, 14.01])
    func pitchThreshold(departure: Double) {
        var values = samples()
        for index in 8..<12 { values[index].pitch = departure }
        let kinds = GazeMeter.spans(values).map(\.kind)
        #expect(kinds == (abs(departure) >= 14 ? [.turned] : []))
    }

    @Test(arguments: [-0.351, -0.35, -0.349, 0.351])
    func downThreshold(departure: Double) {
        var values = samples()
        for index in 8..<12 { values[index].pupilY = departure }
        let kinds = GazeMeter.spans(values).map(\.kind)
        #expect(kinds == (departure <= -0.35 ? [.down] : []))
    }

    @Test(arguments: [-0.221, -0.22, -0.219, 0.219, 0.22, 0.221])
    func asideThreshold(departure: Double) {
        var values = samples()
        for index in 8..<12 { values[index].pupilX = departure }
        let kinds = GazeMeter.spans(values).map(\.kind)
        #expect(kinds == (abs(departure) >= 0.22 ? [.aside] : []))
    }

    @Test func pupilBaselinesAreRelative() {
        var values = samples(pupilX: -0.5, pupilY: 0.4)
        for index in 8..<12 { values[index].pupilY = 0.04 }
        #expect(GazeMeter.spans(values).map(\.kind) == [.down])
        for index in 8..<12 { values[index].pupilY = 0.4; values[index].pupilX = -0.27 }
        #expect(GazeMeter.spans(values).map(\.kind) == [.aside])
    }

    @Test(arguments: [119.99, 120.0, 120.01])
    func pupilFaceWidthThreshold(width: Double) {
        var values = samples(width: width)
        for index in 8..<12 { values[index].pupilY = -0.5; values[index].pupilX = 0.4 }
        #expect(GazeMeter.spans(values).map(\.kind) == (width >= 120 ? [.down] : []))
        for index in 8..<12 { values[index].yaw = 20 }
        #expect(GazeMeter.spans(values).map(\.kind) == [.turned])
    }

    @Test func smallFacesDoNotPollutePupilBaselines() {
        var values = samples(count: 30)
        for index in 0..<16 { values[index].faceWidth = 60; values[index].pupilY = -0.9 }
        for index in 20..<24 { values[index].pupilY = -0.4 }
        #expect(GazeMeter.spans(values).map(\.kind) == [.down])
    }

    @Test func missingPupilsDoNotInventGlances() {
        var values = samples(pupilX: nil, pupilY: nil)
        #expect(GazeMeter.spans(values).isEmpty)
        for index in 8..<12 { values[index].pitch = 15 }
        #expect(GazeMeter.spans(values).map(\.kind) == [.turned])
    }

    @Test func minimumSpanAndTuning() throws {
        var values = samples()
        for index in 8..<10 { values[index].yaw = 20 }
        #expect(GazeMeter.spans(values).isEmpty)
        values[10].yaw = 20
        let span = try #require(GazeMeter.spans(values).first)
        #expect(abs(span.end - span.start - 0.6) < 1e-9)
        var tuning = GazeMeter.Tuning()
        tuning.minimumSpan = 0.61
        #expect(GazeMeter.spans(values, tuning: tuning).isEmpty)
        tuning.minimumSpan = 0.4
        tuning.yawThreshold = 21
        #expect(GazeMeter.spans(values, tuning: tuning).isEmpty)
    }

    @Test func oneNeutralSampleIsBridged() throws {
        var values = samples()
        for index in [8, 9, 11, 12] { values[index].yaw = 20 }
        let spans = GazeMeter.spans(values)
        #expect(spans.count == 1)
        let span = try #require(spans.first)
        #expect(abs(span.start - 1.6) < 1e-9)
        #expect(abs(span.end - 2.6) < 1e-9)
    }

    @Test func twoNeutralSamplesSplitSpans() {
        var values = samples()
        for index in [6, 7, 8, 11, 12, 13] { values[index].yaw = 20 }
        let spans = GazeMeter.spans(values)
        #expect(spans.count == 2)
        #expect(spans.map(\.start) == [1.2, 2.2])
        #expect(spans.allSatisfy { abs($0.end - $0.start - 0.6) < 1e-9 })
    }

    @Test func missingFaceFramesRespectTheSameGapLimit() {
        var values = samples()
        for index in 6..<14 { values[index].yaw = 20 }
        #expect(GazeMeter.spans(values.enumerated().filter { $0.offset != 9 }.map(\.element)).count == 1)
        #expect(GazeMeter.spans(values.enumerated().filter { ![9, 10].contains($0.offset) }.map(\.element)).count == 2)
    }

    @Test func majorityKindAndSamplePrecedence() {
        var values = samples(count: 30)
        for index in 10..<16 { values[index].pupilX = 0.3 }
        for index in 10..<13 { values[index].pupilY = -0.5 }
        values[15].yaw = 20
        values[15].pupilY = -0.5
        #expect(GazeMeter.spans(values).map(\.kind) == [.down])
        for index in 10..<16 { values[index].yaw = 20 }
        #expect(GazeMeter.spans(values).map(\.kind) == [.turned])
    }

    @Test func fewerThanEightSamples() {
        var values = samples(count: 8)
        for index in 0..<3 { values[index].yaw = 20 }
        #expect(GazeMeter.spans(Array(values.prefix(7))).isEmpty)
        #expect(GazeMeter.spans(values).count == 1)
        #expect(GazeMeter.spans([]).isEmpty)
        var tuning = GazeMeter.Tuning()
        tuning.minimumSamples = 9
        #expect(GazeMeter.spans(values, tuning: tuning).isEmpty)
    }

    @Test func shareClipsAndUnionsSpans() {
        let spans: [GazeMeter.Span] = [
            .init(start: -2, end: 2, kind: .down), .init(start: 1, end: 4, kind: .turned),
            .init(start: 8, end: 12, kind: .aside), .init(start: 20, end: 22, kind: .down),
        ]
        #expect(abs(GazeMeter.share(spans, of: 0...10) - 0.6) < 1e-9)
        #expect(GazeMeter.share(spans, of: 1...2) == 1)
        #expect(GazeMeter.share(spans, of: 4...8) == 0)
        #expect(GazeMeter.share(spans, of: 2...2) == 0)
        #expect(GazeMeter.share([], of: 0...10) == 0)
    }

    @Test func pupilOffsetCentreAndEdges() {
        let eye = [CGPoint(x: 2, y: 4), CGPoint(x: 6, y: 4), CGPoint(x: 6, y: 6), CGPoint(x: 2, y: 6)]
        #expect(GazeMeter.pupilOffset(eye: eye, pupil: [CGPoint(x: 3, y: 5), CGPoint(x: 5, y: 5)]) == .zero)
        #expect(GazeMeter.pupilOffset(eye: eye, pupil: [CGPoint(x: 2, y: 4)]) == CGPoint(x: -1, y: -1))
        #expect(GazeMeter.pupilOffset(eye: eye, pupil: [CGPoint(x: 6, y: 6)]) == CGPoint(x: 1, y: 1))
    }

    @Test func pupilOffsetEmptyAndDegenerate() {
        #expect(GazeMeter.pupilOffset(eye: [], pupil: [.zero]) == nil)
        #expect(GazeMeter.pupilOffset(eye: [.zero, CGPoint(x: 1, y: 1)], pupil: []) == nil)
        #expect(GazeMeter.pupilOffset(eye: [.zero], pupil: [.zero]) == nil)
        #expect(GazeMeter.pupilOffset(eye: [.zero, CGPoint(x: 0, y: 1)], pupil: [.zero]) == nil)
        #expect(GazeMeter.pupilOffset(eye: [.zero, CGPoint(x: 1, y: 0)], pupil: [.zero]) == nil)
    }

    @Test func rollingBaselineFollowsSlowDriftButKeepsATurn() throws {
        var values = samples(count: 601)
        for index in values.indices { values[index].yaw = values[index].time / 3 }
        #expect(GazeMeter.spans(values).isEmpty)
        for index in 300..<305 { values[index].yaw += 20 }
        let found = GazeMeter.spans(values)
        #expect(found.count == 1)
        let span = try #require(found.first)
        #expect(span.kind == .turned)
        #expect(abs(span.start - 60) < 1e-9)
        #expect(abs(span.end - 61) < 1e-9)
    }

    @Test func baselineWindowIsTunableAndShortInputsStayWhole() {
        let short = samples()
        var tuning = GazeMeter.Tuning()
        tuning.baselineWindow = 300
        #expect(GazeMeter.spans(short) == GazeMeter.spans(short, tuning: tuning))
        var drift = samples(count: 601)
        for index in drift.indices { drift[index].yaw = drift[index].time / 3 }
        #expect(!GazeMeter.spans(drift, tuning: tuning).isEmpty)
        #expect(GazeMeter.spans(drift).isEmpty)
    }

}
