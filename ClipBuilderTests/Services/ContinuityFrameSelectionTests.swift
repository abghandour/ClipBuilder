import Foundation
import Testing
@testable import Clip_Builder

@Suite("Containing hold frame")
struct ContinuityFrameSelectionTests {
    @Test(arguments: [24, 25, 30, 50, 60])
    func holdsUseContainingSample(rate: Int) throws {
        let times = (0..<(rate * 3)).map { Double($0) / Double(rate) }
        for time in [0.98, 0.999, 1.0, 1.955] {
            let index = try #require(ContinuityFrameSelection.containingFrame(times: times, time: time))
            let expected = Int(floor(time * Double(rate) + 1e-9))
            #expect(index == expected)
            let seek = try #require(Double(ContinuityFrameSelection.seek(times[index])))
            #expect(seek <= times[index] && times[index] - seek < 0.000001)
        }
    }

    @Test func variableTimestampsSelectTheContainingSample() {
        let times = [2.0, 2.04, 2.06, 2.13]
        #expect(ContinuityFrameSelection.containingFrame(times: times, time: 2.05) == 1)
        #expect(ContinuityFrameSelection.containingFrame(times: times, time: 2.06) == 2)
        #expect(ContinuityFrameSelection.containingFrame(times: times, time: .nan) == nil)
    }

    @Test(arguments: [24, 25, 30, 50, 60])
    func companionEndSelectsTheLastFrame(rate: Int) throws {
        let times = (0..<rate).map { Double($0) / Double(rate) }
        let frame = try #require(ContinuityFrameSelection.containingFrame(times: times, time: 1 - 0.001))
        #expect(frame == rate - 1)
    }
}
