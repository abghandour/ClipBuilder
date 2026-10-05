import Foundation
import Testing

@testable import Clip_Builder

struct PlaybackSpeedTests {
    @Test func labels() {
        #expect([0.25, 0.5, 1, 1.25, 1.75, 3].map(PlaybackSpeed.label) == ["0.25×", "0.5×", "1×", "1.25×", "1.75×", "3×"])
    }

    @Test func nearestSnapsToAQuarterStopInRange() {
        #expect(PlaybackSpeed.nearest(1.6) == 1.5)
        #expect(PlaybackSpeed.nearest(1.3) == 1.25)
        #expect(PlaybackSpeed.nearest(10) == 3)
        #expect(PlaybackSpeed.nearest(0.05) == 0.25)
        #expect(PlaybackSpeed.nearest(0) == 1)
        #expect(PlaybackSpeed.nearest(.nan) == 1)
    }

    @Test func rememberedChoice() throws {
        let name = "PlaybackSpeedTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PlaybackSpeed.stored(defaults) == 1)
        PlaybackSpeed.store(1.75, defaults)
        #expect(PlaybackSpeed.stored(defaults) == 1.75)
    }
}
