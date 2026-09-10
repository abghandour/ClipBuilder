import Testing
@testable import Clip_Builder

struct LoupeCompanionTests {
    @Test func fullStripStepsBackOnlyWhileTheLoupeShows() {
        #expect(LoupeCompanionMetrics.stripHeight(44, loupeShown: true) == 33)
        #expect(LoupeCompanionMetrics.stripHeight(52, loupeShown: true) == 39)
        #expect(LoupeCompanionMetrics.stripHeight(44, loupeShown: false) == 44)
        #expect(LoupeCompanionMetrics.width(400, loupeShown: true) == 340)
        #expect(LoupeCompanionMetrics.width(400, loupeShown: false) == 400)
        // Centred: equal insets either side.
        #expect(LoupeCompanionMetrics.inset(400, loupeShown: true) == 30)
        #expect(LoupeCompanionMetrics.inset(400, loupeShown: false) == 0)
    }
    @Test func funnelEndpointsLandOnTheNarrowedStrip() {
        #expect(LoupeCompanionMetrics.x(fraction: 0, container: 400, loupeShown: true) == 30)
        #expect(LoupeCompanionMetrics.x(fraction: 1, container: 400, loupeShown: true) == 370)
        #expect(LoupeCompanionMetrics.x(fraction: 0.5, container: 400, loupeShown: true) == 200)
        #expect(LoupeCompanionMetrics.x(fraction: 2, container: 400, loupeShown: true) == 370)
        #expect(LoupeCompanionMetrics.x(fraction: 0.25, container: 400, loupeShown: false) == 100)
    }
}
