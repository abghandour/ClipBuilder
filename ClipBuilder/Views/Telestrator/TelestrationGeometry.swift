import CoreGraphics
import Foundation

// Pure geometry shared by the editor and painter; no view or actor dependencies.
extension TelestrationRules {
    /// `progress` is geometric progress, already eased by `state` when animated.
    /// All distances and directions use frame-height units (source x * aspect).
    static func paths(for figure: Telestration.Figure, progress: Double, aspect: CGFloat) -> [[CGPoint]] {
        guard aspect.isFinite, aspect > 0, progress.isFinite, progress > 0,
              figure.points.count >= 2 else { return [] }
        let amount = min(1, progress)
        let start = figure.points[0], end = figure.points[1]
        switch figure.kind {
        case .line:
            return [revealed(figure.points, progress: amount, aspect: aspect)]
        case .free, .arrow:
            let hasHead = figure.kind == .arrow || figure.head == true
            let stroke = revealed(figure.points, progress: hasHead ? min(1, amount / 0.8) : amount, aspect: aspect)
            guard hasHead, amount > 0.8, let tip = figure.points.last,
                  let previous = figure.points.dropLast().last(where: { distance($0, tip, aspect: aspect) > 0 }) else {
                return [stroke]
            }
            let length = distance(previous, tip, aspect: aspect)
            let dx = (tip.x - previous.x) * aspect / length, dy = (tip.y - previous.y) / length
            let size = min(figure.width * 5, length * 0.4) * CGFloat((amount - 0.8) / 0.2)
            let left = CGPoint(x: tip.x + (-dx - dy * 0.55) * size / aspect,
                               y: tip.y + (-dy + dx * 0.55) * size)
            let right = CGPoint(x: tip.x + (-dx + dy * 0.55) * size / aspect,
                                y: tip.y + (-dy - dx * 0.55) * size)
            // Do not clamp constructed branches: that skews their geometry at a
            // frame edge. The painter clips to the frame; stored points stay bounded.
            return [stroke, [tip, left], [tip, right]]
        case .oval:
            let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let rx = abs(end.x - start.x) / 2, ry = abs(end.y - start.y) / 2
            var points = (0..<96).map { index in
                let angle = CGFloat(index) * 2 * .pi / 96 - .pi / 2
                return CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
            }
            points.append(points[0])
            return [revealed(points, progress: amount, aspect: aspect)]
        case .rectangle:
            return [revealed(boxCorners(for: figure), progress: amount, aspect: aspect)]
        case .cross:
            let box = boxCorners(for: figure)
            var result = [revealed([box[0], box[2]], progress: min(1, amount * 2), aspect: aspect)]
            if amount > 0.5 {
                result.append(revealed([box[1], box[3]], progress: (amount - 0.5) * 2, aspect: aspect))
            }
            return result
        case .stamp:
            return [] // Scale and opacity, never a traced stroke.
        }
    }

    static func boxCorners(for figure: Telestration.Figure) -> [CGPoint] {
        guard figure.points.count >= 2 else { return [] }
        let a = figure.points[0], b = figure.points[1]
        let topLeft = CGPoint(x: min(a.x, b.x), y: min(a.y, b.y))
        return [topLeft, CGPoint(x: max(a.x, b.x), y: topLeft.y),
                CGPoint(x: max(a.x, b.x), y: max(a.y, b.y)),
                CGPoint(x: topLeft.x, y: max(a.y, b.y)), topLeft]
    }

    static func stampState(for figure: Telestration.Figure, progress: Double) -> (scale: CGFloat, opacity: CGFloat) {
        let amount = figure.kind == .stamp && progress.isFinite ? CGFloat(min(1, max(0, progress))) : 0
        return (0.6 + 0.4 * amount, amount)
    }

    private static func revealed(_ points: [CGPoint], progress: Double, aspect: CGFloat) -> [CGPoint] {
        guard let first = points.first, progress > 0 else { return [] }
        if progress >= 1 { return points }
        let lengths = zip(points, points.dropFirst()).map { distance($0.0, $0.1, aspect: aspect) }
        var remaining = lengths.reduce(0, +) * CGFloat(progress)
        var result = [first]
        for (index, length) in lengths.enumerated() {
            if length == 0 { continue }
            if remaining <= 0 { break }
            if remaining >= length {
                result.append(points[index + 1])
                remaining -= length
            } else {
                let a = points[index], b = points[index + 1], fraction = remaining / length
                result.append(CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction))
                break
            }
        }
        return result
    }

    /// The last figure is painted on top and wins an overlapping hit.
    static func figure(at point: CGPoint, in figures: [Telestration.Figure], aspect: CGFloat,
                       tolerance: CGFloat = 0.015) -> Int? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        return figures.indices.reversed().first { index in
            let figure = figures[index]
            if figure.kind == .stamp {
                let corners = boxCorners(for: figure)
                return corners.count == 5 && point.x >= corners[0].x && point.x <= corners[2].x
                    && point.y >= corners[0].y && point.y <= corners[2].y
            }
            return paths(for: figure, progress: 1, aspect: aspect).contains { points in
                zip(points, points.dropFirst()).contains {
                    segmentDistance(point, $0.0, $0.1, aspect: aspect) <= max(0, tolerance) + figure.width / 2
                }
            }
        }
    }

    /// Keep icon boxes square on screen, even when the drag reaches a frame edge.
    static func squareEnd(from start: CGPoint, to end: CGPoint, aspect: CGFloat) -> CGPoint {
        guard aspect.isFinite, aspect > 0 else { return start }
        let sx: CGFloat = end.x < start.x ? -1 : 1, sy: CGFloat = end.y < start.y ? -1 : 1
        let requested = max(abs(end.x - start.x) * aspect, abs(end.y - start.y))
        let availableX = (sx > 0 ? 1 - start.x : start.x) * aspect
        let availableY = sy > 0 ? 1 - start.y : start.y
        let side = min(requested, availableX, availableY)
        return CGPoint(x: start.x + sx * side / aspect, y: start.y + sy * side)
    }
}
