import Foundation
import Testing
@testable import Clip_Builder

struct HashtagCandidatesTests {
    @Test func pinsAndCap() throws {
        #expect(HashtagCandidates.make(pins: ["#MMA"], tags: ["mma", "guard-pass"], people: ["Ana Silva"], limit: 3) == ["#MMA", "#GuardPass", "#AnaSilva"])
        #expect(HashtagCandidates.make(pins: [], tags: ["one", "two"], people: [], limit: 1) == ["#one"])
        let profile = try JSONDecoder().decode(BrandProfile.self, from: Data("{}".utf8))
        #expect(profile.hashtags.isEmpty)
    }
}
