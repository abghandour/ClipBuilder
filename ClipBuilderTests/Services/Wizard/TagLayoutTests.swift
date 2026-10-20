import Foundation
import CoreGraphics
import Testing
@testable import Clip_Builder

@Suite("Tag geometry")
struct TagLayoutTests {
    @Test func alignmentUnderlinesAndOutsideImagesContributeToBounds() {
        let image = TagImage(x: -0.5, y: 0.5, width: 0.5)
        let lines = [TagLayout.Line(size: CGSize(width: 100, height: 30), underlineThickness: 2),
                     TagLayout.Line(size: CGSize(width: 60, height: 20))]
        let layout = TagLayout.layout(lines: lines, padding: 10, gap: 5, alignment: "trailing",
            images: [image], aspects: [image.id: 2])
        #expect(layout.textBlock.size == CGSize(width: 120, height: 79))
        #expect(layout.origins == [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 49)])
        #expect(layout.underlines[0] == CGRect(x: 10, y: 42, width: 100, height: 2))
        #expect(layout.underlines[1] == nil)
        #expect(layout.images[image.id]?.size == CGSize(width: 60, height: 30))
        #expect(layout.bounds.minX == -90 && layout.bounds.maxX == 120)
    }

    @Test func missingImagesDoNotChangeBoundsAndCenterAlignsBothLines() {
        let layout = TagLayout.layout(lines: [.init(size: CGSize(width: 100, height: 30)),
            .init(size: CGSize(width: 60, height: 20))], padding: 10, gap: 5,
            alignment: "center", images: [TagImage(path: "/missing")], aspects: [:])
        #expect(layout.images.isEmpty && layout.bounds == layout.textBlock)
        #expect(layout.origins[1].x == 30)
    }
    @Test func lineChipsExpandTheBlockAndContainUnderlines() throws {
        for alignment in ["leading", "center", "trailing"] {
            let layout = TagLayout.layout(lines: [
                .init(size: CGSize(width: 100, height: 30), underlineThickness: 2, strikethrough: 3, chipPadding: 8),
                .init(size: CGSize(width: 60, height: 20), strikethrough: 1, chipPadding: 4),
            ], padding: 10, gap: 5, alignment: alignment, images: [], aspects: [:])
            #expect(layout.textBlock.size == CGSize(width: 136, height: 103))
            for index in 0..<2 {
                let chip = try #require(layout.chips[index])
                let strike = try #require(layout.strikethroughs[index])
                #expect(layout.textBlock.contains(chip) && chip.contains(strike))
                #expect(strike.minX == layout.origins[index].x)
                #expect(strike.height == (index == 0 ? 3 : 1))
            }
            let firstChip = try #require(layout.chips[0])
            let secondChip = try #require(layout.chips[1])
            let underline = try #require(layout.underlines[0])
            #expect(firstChip.contains(underline))
            #expect(firstChip.maxY + 5 == secondChip.minY)
            #expect(layout.bounds == layout.textBlock)
        }
    }

}
