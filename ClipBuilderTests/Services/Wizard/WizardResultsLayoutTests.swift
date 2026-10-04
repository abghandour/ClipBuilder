import CoreGraphics
import Testing
@testable import Clip_Builder

struct WizardResultsLayoutTests {
    @Test func opensOneRowWhenAllCardsFit() {
        let size = WizardResultsLayout.idealSize(count: 3, cardSize: CGSize(width: 300, height: 680),
                                                screen: CGSize(width: 1920, height: 1080))
        #expect(size.width == 964)
        #expect(size.height == 812)
    }

    @Test func capsColumnsAndRowsToVisibleScreen() {
        let size = WizardResultsLayout.idealSize(count: 20, cardSize: CGSize(width: 300, height: 400),
                                                screen: CGSize(width: 1440, height: 1200))
        #expect(size.width == 1280) // Four columns.
        #expect(size.height == 948) // Two complete rows plus chrome.
        #expect(size.width <= 1440 * 0.92 && size.height <= 1200 * 0.90)
    }

    @Test func minimumAndShortScreensStillScrollVertically() {
        for count in [0, 1, 50] {
            let size = WizardResultsLayout.idealSize(count: count, cardSize: CGSize(width: 300, height: 680),
                                                    screen: CGSize(width: 600, height: 700))
            #expect(size.width == 520)
            #expect(size.height == 630)
        }
    }
}
