import Foundation
import Testing
@testable import Clip_Builder

struct KeptClipsPlaybackTests {
    private let clips = KeptClipsPlayback.clips(scenes: [
        Fixtures.scene(id: 1, start: 10, end: 14),
        Fixtures.scene(id: 2, start: 30, end: 36.5),
    ])

    @Test func scenesBecomeClipsWithTheirRanges() {
        #expect(clips.map(\.start) == [10, 30] && clips.map(\.end) == [14, 36.5])
        #expect(Set(clips.map(\.id)).count == 2)
        #expect(KeptClipsPlayback.totalDuration(clips) == 10.5)
        #expect(KeptClipsPlayback.totalDuration([]) == 0)
    }

    @Test func aClipStopsAtItsEndUnlessPlayAllGoesOn() {
        #expect(KeptClipsPlayback.step(time: 12, index: 0, clips: clips, playsAll: false) == .keepPlaying)
        #expect(KeptClipsPlayback.step(time: 14, index: 0, clips: clips, playsAll: false) == .stop)
        #expect(KeptClipsPlayback.step(time: 13.99, index: 0, clips: clips, playsAll: true) == .advance(to: 1))
        // The last clip ends the list; an index out of range stops.
        #expect(KeptClipsPlayback.step(time: 36.5, index: 1, clips: clips, playsAll: true) == .stop)
        #expect(KeptClipsPlayback.step(time: 0, index: 5, clips: clips, playsAll: true) == .stop)
    }
}
