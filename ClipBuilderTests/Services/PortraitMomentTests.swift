import Testing
@testable import Clip_Builder

@Suite("Portrait moment")
struct PortraitMomentTests {
    @Test func candidatesStartAtTheMomentAndFanOutInsideTheVideo() {
        let times = PortraitMoment.candidateTimes(around: 1, duration: 4)
        #expect(times.first == 1)
        #expect(times[1...2] == [0.5, 1.5])
        #expect(times.allSatisfy { $0 >= 0 && $0 <= 3.9 })
        // 1 - 1.5 and 1 - 2 both clamp to 0; the clamp is kept once.
        #expect(times.filter { $0 == 0 }.count == 1)
        #expect(times.contains(3.9) && !times.contains(5))
    }

    @Test func candidatesRespectTheOnScreenRanges() {
        let times = PortraitMoment.candidateTimes(around: 10, duration: 100, ranges: [9...11, 13...14])
        #expect(times == [10, 9.5, 10.5, 9, 11, 13, 14])
    }

    @Test func driftWidensTheBoxWithDistanceAndStaysInFrame() {
        let marker = PersonMarker(id: 1, videoID: 1, atTime: 20, x: 0.1, y: 0.2, width: 0.2, height: 0.5)
        let same = PortraitMoment.drifted(marker, by: 0)
        #expect(same.x == 0.1 && same.width == 0.2)
        let two = PortraitMoment.drifted(marker, by: 2)
        #expect(abs(two.x - 0.08) < 1e-9 && abs(two.width - 0.24) < 1e-9)
        #expect(abs(two.y - 0.15) < 1e-9 && abs(two.height - 0.6) < 1e-9)
        let edge = PortraitMoment.drifted(PersonMarker(id: 1, videoID: 1, atTime: 0, x: 0, y: 0.8, width: 0.3, height: 0.2), by: 6)
        #expect(edge.x == 0 && edge.y + edge.height <= 1 + 1e-9 && edge.x + edge.width <= 1 + 1e-9)
    }
}
