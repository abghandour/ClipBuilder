import CoreGraphics
import Testing
@testable import Clip_Builder

nonisolated struct PreviewSnapRulesTests {
    private let frame = CGRect(x: 0, y: 0, width: 300, height: 600)

    @Test func aBoxNearTheCentreLinesJumpsOntoBoth() {
        let result = PreviewSnapRules.moved(CGRect(x: 104, y: 277, width: 100, height: 40), frame: frame)
        #expect(result.rect.midX == 150 && result.rect.midY == 300)
        #expect(Set(result.guides) == [.init(vertical: true, position: 150, centre: true),
                                       .init(vertical: false, position: 300, centre: true)])
    }

    @Test func aBoxFarFromEveryLineStaysPut() {
        let rect = CGRect(x: 12, y: 112, width: 20, height: 20)
        let result = PreviewSnapRules.moved(rect, frame: frame)
        #expect(result.rect == rect && result.guides.isEmpty)
    }

    @Test func edgesSnapToTheGridAndOtherElements() {
        // Left edge 3 pt from a grid line; top 4 pt under another element's bottom.
        let other = CGRect(x: 10, y: 50, width: 80, height: 30)
        let result = PreviewSnapRules.moved(CGRect(x: 103, y: 84, width: 41, height: 23), frame: frame, others: [other])
        #expect(result.rect.minX == 100 && result.rect.minY == 80)
        #expect(result.guides.allSatisfy { !$0.centre })
    }

    @Test func theCentreWinsOverACloserEdgeLine() {
        // Centre is 5 pt from the middle; the left edge is 4 pt from another element's edge.
        let other = CGRect(x: 109, y: 500, width: 20, height: 20)
        let result = PreviewSnapRules.moved(CGRect(x: 105, y: 400, width: 80, height: 20), frame: frame, others: [other])
        #expect(result.rect.midX == 150)
    }

    @Test func aResizePullsOnlyTheDraggedEdge() {
        let rect = CGRect(x: 40, y: 100, width: 107, height: 50)
        let result = PreviewSnapRules.resized(rect, edges: .init(right: true), frame: frame)
        #expect(result.rect == CGRect(x: 40, y: 100, width: 110, height: 50))
        #expect(result.guides == [.init(vertical: true, position: 150, centre: true)])
    }

    @Test func theGridIsSixCellsAcrossAndTwelveDownAPortraitFrame() {
        let grid = PreviewSnapRules.grid(in: frame)
        #expect(grid.filter(\.vertical).map(\.position) == [50, 100, 150, 200, 250])
        #expect(grid.filter { !$0.vertical }.map(\.position) == Array(stride(from: CGFloat(50), through: 550, by: 50)))
        #expect(grid.filter(\.centre).map(\.position) == [150, 300])
        let wide = PreviewSnapRules.divisions(in: CGRect(x: 0, y: 0, width: 640, height: 360))
        #expect(wide.columns == 12 && wide.rows == 6)
    }
}
