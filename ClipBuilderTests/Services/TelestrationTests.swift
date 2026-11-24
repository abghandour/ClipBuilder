import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

nonisolated struct TelestrationTests {
    private func line(_ y: CGFloat = 0.5) -> Telestration.Figure {
        Telestration.Figure(kind: .line, points: [CGPoint(x: 0.1, y: y), CGPoint(x: 0.9, y: y)])
    }

    @Test func figuresDrawInOrderAndEaseOut() throws {
        let drawing = Telestration(figures: [line(0.2), line(0.8)], drawSpeed: 1)
        #expect(TelestrationRules.state(of: drawing, at: -1).opacity == 0)
        #expect(TelestrationRules.state(of: drawing, at: 0).figures.isEmpty)
        let first = TelestrationRules.state(of: drawing, at: 0.5)
        #expect(first.figures.count == 1)
        #expect(try #require(first.figures.first).progress == 0.875)
        #expect(first.figures.first?.figure == drawing.figures[0])
        let boundary = TelestrationRules.state(of: drawing, at: 1)
        #expect(boundary.figures.count == 1)
        #expect(boundary.figures.first?.progress == 1)
        let second = TelestrationRules.state(of: drawing, at: 1.5)
        #expect(second.figures.map(\.progress) == [1, 0.875])
        #expect(second.figures.map(\.figure) == drawing.figures)
    }

    @Test func stayFadeAndDurationShareOneClock() {
        let drawing = Telestration(figures: [line(), line()], stay: 2, drawSpeed: 0.5, fade: 0.4)
        #expect(abs(drawing.duration - 3.4) < 0.000001)
        for time in [1.0, 2.0, 3.0] {
            let state = TelestrationRules.state(of: drawing, at: time)
            #expect(state.opacity == 1)
            #expect(state.figures.map(\.progress) == [1, 1])
        }
        #expect(abs(TelestrationRules.state(of: drawing, at: 3.2).opacity - 0.5) < 0.000001)
        #expect(TelestrationRules.state(of: drawing, at: drawing.duration).opacity == 0)
        #expect(TelestrationRules.state(of: drawing, at: 100).opacity == 0)
        let abrupt = Telestration(figures: [line()], fade: 0)
        #expect(TelestrationRules.state(of: abrupt, at: abrupt.duration).opacity == 0)
    }

    @Test func emptyDrawingHasNoVisibleState() {
        let drawing = Telestration()
        #expect(drawing.duration == 2.3)
        for time in [0.0, 0.5, 2.1, 3.0] {
            let state = TelestrationRules.state(of: drawing, at: time)
            #expect(state.figures.isEmpty)
            #expect(state.opacity == 0)
        }
    }

    @Test func lineRevealHasExactEndpoints() throws {
        let figure = line()
        #expect(TelestrationRules.paths(for: figure, progress: 0, aspect: 1).isEmpty)
        let halfway = try #require(TelestrationRules.paths(for: figure, progress: 0.5, aspect: 1).first)
        #expect(halfway.first == figure.points.first)
        #expect(try #require(halfway.last) == CGPoint(x: 0.5, y: 0.5))
        #expect(TelestrationRules.paths(for: figure, progress: 1, aspect: 1) == [figure.points])
    }

    @Test func freeRevealUsesLengthRatherThanPointCount() throws {
        let figure = Telestration.Figure(kind: .free, points: [
            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.1), CGPoint(x: 0.3, y: 0.7)
        ])
        #expect(TelestrationRules.paths(for: figure, progress: 0, aspect: 1).isEmpty)
        let halfway = try #require(TelestrationRules.paths(for: figure, progress: 0.5, aspect: 1).first)
        let end = try #require(halfway.last)
        #expect(abs(end.x - 0.3) < 0.000001)
        #expect(abs(end.y - 0.3) < 0.000001)
        #expect(halfway.count == 3)
        #expect(TelestrationRules.paths(for: figure, progress: 1, aspect: 1) == [figure.points])
    }

    @Test func arrowOpensItsHeadOnlyInFinalFifth() throws {
        var arrow = line()
        arrow.kind = .arrow
        #expect(TelestrationRules.paths(for: arrow, progress: 0, aspect: 1).isEmpty)
        #expect(TelestrationRules.paths(for: arrow, progress: 0.5, aspect: 1).first?.count == 2)
        #expect(TelestrationRules.paths(for: arrow, progress: 0.8, aspect: 1) == [arrow.points])
        let opening = TelestrationRules.paths(for: arrow, progress: 0.9, aspect: 1)
        let complete = TelestrationRules.paths(for: arrow, progress: 1, aspect: 1)
        #expect(opening.count == 3 && complete.count == 3)
        let tip = try #require(arrow.points.last)
        #expect(abs(TelestrationRules.distance(opening[1][1], tip, aspect: 1) * 2 - TelestrationRules.distance(complete[1][1], tip, aspect: 1)) < 0.000001)
        #expect(complete[1][1].y > tip.y && complete[2][1].y < tip.y)
        var thick = arrow
        thick.width = 0.016
        #expect(TelestrationRules.distance(TelestrationRules.paths(for: thick, progress: 1, aspect: 1)[1][1], tip, aspect: 1)
            > TelestrationRules.distance(complete[1][1], tip, aspect: 1))
    }

    @Test func ovalStartsAtTopAndClosesOnce() throws {
        let oval = Telestration.Figure(kind: .oval, points: [CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.2, y: 0.1)])
        #expect(TelestrationRules.paths(for: oval, progress: 0, aspect: 1).isEmpty)
        let full = try #require(TelestrationRules.paths(for: oval, progress: 1, aspect: 1).first)
        #expect(full.count >= 65)
        #expect(full.first == full.last)
        let top = try #require(full.first)
        #expect(abs(top.x - 0.5) < 0.000001 && abs(top.y - 0.1) < 0.000001)
        let half = try #require(TelestrationRules.paths(for: oval, progress: 0.5, aspect: 1).first?.last)
        #expect(abs(half.x - 0.5) < 0.000001 && abs(half.y - 0.9) < 0.000001)
        #expect(full.allSatisfy { $0.x >= 0.2 - 0.000001 && $0.x <= 0.8 + 0.000001 })
    }

    @Test func simplificationRemovesCollinearPoints() {
        let points = (0...100).map { CGPoint(x: Double($0) / 100, y: 0.4) }
        #expect(TelestrationRules.simplify(points) == [points[0], points[100]])
        let slightBend = [CGPoint.zero, CGPoint(x: 0.5, y: 0.001), CGPoint(x: 1, y: 0)]
        #expect(TelestrationRules.simplify(slightBend).count == 2)
        #expect(TelestrationRules.simplify([]).isEmpty)
    }

    @Test func simplificationCapsDensePathsAndPreservesEnds() {
        let points = (0...1000).map { CGPoint(x: Double($0) / 1000, y: $0.isMultiple(of: 2) ? 0.1 : 0.9) }
        let simplified = TelestrationRules.simplify(points)
        #expect(simplified.count == 200)
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
        let figure = Telestration.Figure(kind: .free, points: points)
        #expect(figure.points.count <= 200)
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let decoder = JSONDecoder()
        let empty = try decoder.decode(Telestration.self, from: Data("{}".utf8))
        #expect(empty == Telestration())
        let legacy = try decoder.decode(Telestration.self, from: Data(#"{"time":4,"figures":[{}]}"#.utf8))
        #expect(legacy.time == 4 && legacy.stay == 2 && legacy.drawSpeed == 0.5 && legacy.fade == 0.3)
        #expect(legacy.figures == [Telestration.Figure()])
        let nulls = try decoder.decode(Telestration.self, from: Data(#"{"figures":null,"stay":null,"fade":null}"#.utf8))
        #expect(nulls == Telestration())
    }

    @Test func decodingClampsRangesAndLimits() throws {
        let figure = #"{"kind":"line","points":[[-1,2],[0.8,0.9]],"width":5,"color":"red"}"#
        let json = "{\"time\":-3,\"stay\":999,\"drawSpeed\":0,\"fade\":-5,\"figures\":["
            + Array(repeating: figure, count: 14).joined(separator: ",") + "]}"
        let drawing = try JSONDecoder().decode(Telestration.self, from: Data(json.utf8))
        #expect(drawing.time == 0 && drawing.stay == Telestration.maximumStay && drawing.drawSpeed == 0.15 && drawing.fade == 0)
        #expect(drawing.figures.count == 12)
        #expect(drawing.figures[0].width == 0.016 && drawing.figures[0].color == .red)
        #expect(drawing.figures[0].points[0] == CGPoint(x: 0, y: 1))
        let low = try JSONDecoder().decode(Telestration.self, from: Data(#"{"stay":-1,"drawSpeed":99,"figures":[{"width":-1,"color":"unknown"}]}"#.utf8))
        #expect(low.stay == 0.5 && low.drawSpeed == 2)
        #expect(low.figures[0].width == 0.006 && low.figures[0].color == .yellow)
        #expect(try JSONDecoder().decode(Telestration.self, from: JSONEncoder().encode(drawing)) == drawing)
    }

    @Test func decodedFreePathIsSimplifiedAndCapped() throws {
        // Mutate after construction so this exercises decoding, not the member initializer.
        var figure = Telestration.Figure(kind: .free)
        figure.points = (0...600).map { CGPoint(x: Double($0) / 600, y: $0.isMultiple(of: 2) ? 0.1 : 0.9) }
        let decoded = try JSONDecoder().decode(Telestration.Figure.self, from: JSONEncoder().encode(figure))
        #expect(decoded.points.count <= 200)
        #expect(decoded.points.first == figure.points.first && decoded.points.last == figure.points.last)
    }

    @Test func hitTestingUsesStrokeAndTopmostOrder() {
        let figures = [line(), line()]
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.5, y: 0.51), in: figures, aspect: 1, tolerance: 0.02) == 1)
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.5, y: 0.55), in: figures, aspect: 1, tolerance: 0.01) == nil)
        let oval = Telestration.Figure(kind: .oval, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)])
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.5, y: 0.2), in: [oval], aspect: 1) == 0)
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.5, y: 0.5), in: [oval], aspect: 1) == nil)
    }

    @Test func movementClampsWholeFigureWithoutDistortingIt() {
        let original = line(0.3)
        let moved = TelestrationRules.moved(original, by: CGSize(width: 10, height: -10))
        #expect(abs(moved.points[0].x - 0.2) < 0.000001)
        #expect(moved.points[1] == CGPoint(x: 1, y: 0))
        #expect(abs(TelestrationRules.distance(moved.points[0], moved.points[1], aspect: 1) - 0.8) < 0.000001)
        let opposite = TelestrationRules.moved(original, by: CGSize(width: -10, height: 10))
        #expect(opposite.points[0] == CGPoint(x: 0, y: 1))
        #expect(moved.color == original.color && moved.width == original.width)
    }

    @Test func canvasMappingCropAndSourceTimeStayBounded() {
        let rect = TelestrationRules.videoRect(aspect: 2, in: CGSize(width: 600, height: 400))
        #expect(rect == CGRect(x: 0, y: 50, width: 600, height: 300))
        let point = CGPoint(x: 0.25, y: 0.75)
        #expect(TelestrationRules.sourcePoint(TelestrationRules.placed(point, in: rect), in: rect) == point)
        #expect(TelestrationRules.sourcePoint(CGPoint(x: -20, y: 900), in: rect) == CGPoint(x: 0, y: 1))
        #expect(TelestrationRules.cropRect(CGRect(x: 0.25, y: 0, width: 0.5, height: 1), in: rect)
            == CGRect(x: 150, y: 50, width: 300, height: 300))
        #expect(TelestrationRules.cropRect(nil, in: rect) == rect)
        #expect(TelestrationRules.sourceTime(-1, duration: 10) == 0)
        #expect(abs(TelestrationRules.sourceTime(10, duration: 10, frameRate: 25) - 9.96) < 0.000001)
        #expect(TelestrationRules.sourceTime(2, duration: 0) == 0)
        #expect(TelestrationRules.sourceTime(1, duration: 10, frameRate: 0) == 1)
    }
}
