import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

nonisolated struct TelestrationFigureKindsTests {
    private func box(_ kind: Telestration.Figure.Kind) -> Telestration.Figure {
        Telestration.Figure(kind: kind, points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.75)])
    }

    @Test func rectangleRevealsOneTwoAndFourSidesClockwise() {
        let figure = box(.rectangle) // Square on a 2:1 frame.
        let corners = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.25),
                       CGPoint(x: 0.5, y: 0.75), CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.25, y: 0.25)]
        #expect(TelestrationRules.paths(for: figure, progress: 0, aspect: 2).isEmpty)
        for (progress, count) in [(0.25, 2), (0.5, 3), (1.0, 5)] {
            #expect(TelestrationRules.paths(for: figure, progress: progress, aspect: 2) == [Array(corners.prefix(count))])
        }
        var reversed = figure
        reversed.points.reverse()
        #expect(TelestrationRules.paths(for: reversed, progress: 1, aspect: 2) == [corners])
    }

    @Test func crossHasTwoIndependentStrokes() {
        let figure = box(.cross)
        let first = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.75)]
        let second = [CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.25, y: 0.75)]
        #expect(TelestrationRules.paths(for: figure, progress: 0, aspect: 2).isEmpty)
        #expect(TelestrationRules.paths(for: figure, progress: 0.5, aspect: 2) == [first])
        #expect(TelestrationRules.paths(for: figure, progress: 1, aspect: 2) == [first, second])
        #expect(TelestrationRules.paths(for: figure, progress: 0.75, aspect: 2)
            == [first, [second[0], CGPoint(x: 0.375, y: 0.5)]])
    }

    @Test func arrowHeadsAreSymmetricAndOrientationIndependentOnWidescreen() throws {
        let rect = CGRect(x: 20, y: 30, width: 1600, height: 900)
        let aspect = rect.width / rect.height
        let arrow = Telestration.Figure(kind: .arrow, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.7, y: 0.7)])
        let paths = TelestrationRules.paths(for: arrow, progress: 1, aspect: aspect)
        #expect(paths.count == 3)
        let tip = TelestrationRules.placed(arrow.points[1], in: rect)
        let start = TelestrationRules.placed(arrow.points[0], in: rect)
        let left = TelestrationRules.placed(try #require(paths[1].last), in: rect)
        let right = TelestrationRules.placed(try #require(paths[2].last), in: rect)
        let shaft = CGVector(dx: tip.x - start.x, dy: tip.y - start.y)
        let a = CGVector(dx: left.x - tip.x, dy: left.y - tip.y)
        let b = CGVector(dx: right.x - tip.x, dy: right.y - tip.y)
        #expect(abs(hypot(a.dx, a.dy) - hypot(b.dx, b.dy)) < 0.000001)
        #expect(abs(a.dx * shaft.dx + a.dy * shaft.dy - b.dx * shaft.dx - b.dy * shaft.dy) < 0.000001)
        #expect(abs((a.dx + b.dx) * shaft.dy - (a.dy + b.dy) * shaft.dx) < 0.000001)
        #expect((a.dx * shaft.dy - a.dy * shaft.dx) * (b.dx * shaft.dy - b.dy * shaft.dx) < 0)
        var lengths: [CGFloat] = []
        for end in [CGPoint(x: 0.7, y: 0.2), CGPoint(x: 0.2, y: 0.7)] {
            let figure = Telestration.Figure(kind: .arrow, points: [arrow.points[0], end])
            let head = TelestrationRules.paths(for: figure, progress: 1, aspect: aspect)[1]
            lengths.append(TelestrationRules.distance(head[0], head[1], aspect: aspect) * rect.height)
        }
        #expect(abs(lengths[0] - lengths[1]) < 0.000001)
        #expect(abs(lengths[0] - hypot(a.dx, a.dy)) < 0.000001)
    }

    @Test func revealAndHitToleranceUseHeightUnits() throws {
        let figure = Telestration.Figure(kind: .free, points: [
            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.1), CGPoint(x: 0.3, y: 0.7)
        ])
        let end = try #require(TelestrationRules.paths(for: figure, progress: 0.5, aspect: 2).first?.last)
        #expect(abs(end.x - 0.3) < 0.000001 && abs(end.y - 0.2) < 0.000001)
        let horizontal = Telestration.Figure(kind: .line, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)])
        let vertical = Telestration.Figure(kind: .line, points: [CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.9)])
        for offset in [0.015, 0.03] {
            let h = TelestrationRules.figure(at: CGPoint(x: 0.5, y: 0.5 + offset), in: [horizontal], aspect: 2)
            let v = TelestrationRules.figure(at: CGPoint(x: 0.5 + offset / 2, y: 0.5), in: [vertical], aspect: 2)
            #expect(h == v)
            #expect((h != nil) == (offset < 0.02))
        }
    }

    @Test func freeHeadFollowsLastNonzeroSegmentAndOpensLast() {
        var figure = Telestration.Figure(kind: .free, points: [
            CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.6, y: 0.2), CGPoint(x: 0.6, y: 0.8)
        ], head: true)
        figure.points.append(CGPoint(x: 0.6, y: 0.8))
        #expect(TelestrationRules.paths(for: figure, progress: 0.8, aspect: 2) == [figure.points])
        let opening = TelestrationRules.paths(for: figure, progress: 0.9, aspect: 2)
        let full = TelestrationRules.paths(for: figure, progress: 1, aspect: 2)
        #expect(full.count == 3 && opening.count == 3)
        let tip = CGPoint(x: 0.6, y: 0.8)
        #expect(full[1][0] == tip && full[2][0] == tip)
        #expect(full[1][1].y < tip.y && full[2][1].y < tip.y)
        #expect(full[1][1].x < tip.x && full[2][1].x > tip.x)
        #expect(abs(TelestrationRules.distance(opening[1][1], tip, aspect: 2) * 2
            - TelestrationRules.distance(full[1][1], tip, aspect: 2)) < 0.000001)
        figure.head = nil
        #expect(TelestrationRules.paths(for: figure, progress: 1, aspect: 2).count == 1)
    }

    @Test func stampScalesAndFadesWithoutTracing() {
        let figure = box(.stamp)
        for (progress, scale) in [(0.0, 0.6), (0.5, 0.8), (1.0, 1.0)] {
            let state = TelestrationRules.stampState(for: figure, progress: progress)
            #expect(abs(state.scale - scale) < 0.000001)
            #expect(abs(Double(state.opacity) - progress) < 0.000001)
            #expect(TelestrationRules.paths(for: figure, progress: progress, aspect: 2).isEmpty)
        }
    }

    @Test func boxHitsRespectEmptyStrokesAndFilledStamps() {
        let rectangle = box(.rectangle)
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.375, y: 0.25), in: [rectangle], aspect: 2) == 0)
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.375, y: 0.5), in: [rectangle], aspect: 2) == nil)
        let stamp = box(.stamp)
        for point in [CGPoint(x: 0.375, y: 0.5), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.49, y: 0.74)] {
            #expect(TelestrationRules.figure(at: point, in: [stamp], aspect: 2) == 0)
        }
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.6, y: 0.5), in: [stamp], aspect: 2) == nil)
        let cross = box(.cross)
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.375, y: 0.5), in: [cross], aspect: 2) == 0)
        #expect(TelestrationRules.figure(at: CGPoint(x: 0.5, y: 0.5), in: [cross], aspect: 2) == nil)
    }

    @Test func squareStampDragStaysSquareAtFrameEdges() {
        let aspects: [CGFloat] = [16.0 / 9, 9.0 / 16]
        for aspect in aspects {
            let start = CGPoint(x: 0.4, y: 0.6)
            for target in [CGPoint(x: 1, y: 1), .zero, CGPoint(x: 0.7, y: 0.2)] {
                let end = TelestrationRules.squareEnd(from: start, to: target, aspect: aspect)
                #expect(abs(abs(end.x - start.x) * aspect - abs(end.y - start.y)) < 0.000001)
                #expect(end == TelestrationRules.clamped(end))
            }
        }
    }

    @Test func phaseOneLiteralDecodesEquallyAndOmitsNewNilKeys() throws {
        let json = #"{"time":3,"figures":[{"kind":"arrow","points":[[0.1,0.2],[0.8,0.7]],"color":"cyan","width":0.01}],"stay":2,"drawSpeed":0.5,"fade":0.3}"#
        let expected = Telestration(time: 3, figures: [Telestration.Figure(kind: .arrow,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)], color: .cyan)])
        let decoded = try JSONDecoder().decode(Telestration.self, from: Data(json.utf8))
        #expect(decoded == expected)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let figures = try #require(object["figures"] as? [[String: Any]])
        #expect(figures[0]["head"] == nil && figures[0]["style"] == nil && figures[0]["symbol"] == nil)
    }

    @Test func unknownAndUndecodableFiguresAreSkippedKeepingNeighbors() throws {
        let json = #"{"figures":[{"kind":"rectangle"},{"kind":"future"},null,7,{"points":"bad"},{"kind":"cross"},{}]}"#
        let drawing = try JSONDecoder().decode(Telestration.self, from: Data(json.utf8))
        #expect(drawing.figures.map(\.kind) == [.rectangle, .cross, .arrow])
    }

    @Test func unknownStyleAndSymbolFallBack() throws {
        let json = #"{"figures":[{"kind":"stamp","style":"future","symbol":"not.a.symbol"},{"kind":"stamp"}]}"#
        let drawing = try JSONDecoder().decode(Telestration.self, from: Data(json.utf8))
        #expect(drawing.figures[0].style == nil)
        #expect(drawing.figures[0].symbol == Telestration.Figure.symbols[0])
        #expect(drawing.figures[1].style == nil && drawing.figures[1].symbol == nil)
    }

    @Test func newKindsNormalizeMoveRoundTripAndRespectLimit() throws {
        var figures: [Telestration.Figure] = []
        for kind in [Telestration.Figure.Kind.rectangle, .cross, .stamp, .free] {
            var figure = box(kind)
            figure.head = true
            figure.style = .neon
            figure.symbol = "shield"
            figures.append(figure)
            #expect(figure.normalized == figure)
            let moved = TelestrationRules.moved(figure, by: CGSize(width: 1, height: -1))
            #expect(moved.points[1] == CGPoint(x: 1, y: 0.5))
            #expect(moved.head == true && moved.style == .neon && moved.symbol == "shield")
        }
        let drawing = Telestration(figures: figures + figures + figures + figures)
        #expect(drawing.figures.count == 12)
        #expect(try JSONDecoder().decode(Telestration.self, from: JSONEncoder().encode(drawing)) == drawing)
    }
}
