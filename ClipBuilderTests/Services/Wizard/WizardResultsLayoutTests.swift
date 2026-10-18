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

    @Test func oneCardFillsTheSheetAndKeepsThePortraitShape() {
        let grid = WizardResultsLayout.grid(count: 1, available: CGSize(width: 900, height: 900))
        #expect(grid.columns == 1 && grid.columnWidth == 868)
        #expect(grid.playerMaxHeight == 608) // 900 minus the card chrome and padding.
        // Height-bound: a 9:16 player is as tall as the sheet allows.
        let portrait = WizardResultsLayout.playerSize(in: grid, aspect: 9 / 16)
        #expect(portrait.height == 608 && portrait.width == 342)
        // The card wraps the picture rather than spanning the column.
        #expect(WizardResultsLayout.cardWidth(in: grid, playerWidth: portrait.width) == 366)
        // Width-bound: a landscape player spans the column.
        let landscape = WizardResultsLayout.playerSize(in: grid, aspect: 16 / 9)
        #expect(landscape.width == 842 && landscape.height == 474)
        #expect(WizardResultsLayout.cardWidth(in: grid, playerWidth: landscape.width) == 866)
    }

    @Test func severalCardsShareColumnsAndShrinkTogether() {
        let grid = WizardResultsLayout.grid(count: 3, available: CGSize(width: 1100, height: 700))
        #expect(grid.columns == 3 && grid.columnWidth == 345)
        let player = WizardResultsLayout.playerSize(in: grid, aspect: 9 / 16)
        // Short sheet: the player shrinks to its height cap and the card to the minimum.
        #expect(player.height == 408 && player.width == 229)
        #expect(WizardResultsLayout.cardWidth(in: grid, playerWidth: player.width) == 320)
        // Too narrow for three: two columns, the third card wraps.
        #expect(WizardResultsLayout.grid(count: 3, available: CGSize(width: 700, height: 700)).columns == 2)
        // Narrower than one card still yields one full-width card and a sane player.
        let tiny = WizardResultsLayout.grid(count: 1, available: CGSize(width: 200, height: 200))
        #expect(tiny.columns == 1 && tiny.columnWidth == 320 && tiny.playerMaxHeight == 180)
        let bad = WizardResultsLayout.playerSize(in: tiny, aspect: .nan)
        #expect(bad.height == 180 && bad.width == 101)
    }
}
