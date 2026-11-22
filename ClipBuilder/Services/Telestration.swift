import CoreGraphics
import Foundation

/// A drawing on a frozen source frame. Coordinates have a top-left origin.
nonisolated struct Telestration: Codable, Equatable, Sendable {
    static let maximumFigures = 12
    var time: Double
    var figures: [Figure]
    var stay: Double
    var drawSpeed: Double
    var fade: Double

    var duration: Double { Double(figures.count) * drawSpeed + stay + fade }

    init(time: Double = 0, figures: [Figure] = [], stay: Double = 2,
         drawSpeed: Double = 0.5, fade: Double = 0.3) {
        self.time = time.isFinite ? max(0, time) : 0
        self.figures = Array(figures.prefix(Self.maximumFigures)).map { $0.normalized }
        self.stay = stay.isFinite ? min(10, max(0.5, stay)) : 2
        self.drawSpeed = drawSpeed.isFinite ? min(2, max(0.15, drawSpeed)) : 0.5
        self.fade = fade.isFinite ? max(0, fade) : 0.3
    }

    private nonisolated enum CodingKeys: String, CodingKey { case time, figures, stay, drawSpeed, fade }

    private nonisolated struct DecodedFigure: Decodable {
        let value: Figure?
        init(from decoder: Decoder) throws { value = try? Figure(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(time: try values.decodeIfPresent(Double.self, forKey: .time) ?? 0,
                  figures: try values.decodeIfPresent([DecodedFigure].self, forKey: .figures)?.compactMap { $0.value } ?? [],
                  stay: try values.decodeIfPresent(Double.self, forKey: .stay) ?? 2,
                  drawSpeed: try values.decodeIfPresent(Double.self, forKey: .drawSpeed) ?? 0.5,
                  fade: try values.decodeIfPresent(Double.self, forKey: .fade) ?? 0.3)
    }

    nonisolated struct Figure: Codable, Equatable, Sendable {
        nonisolated enum Kind: String, Codable, CaseIterable, Sendable {
            case arrow, oval, line, free, rectangle, cross, stamp

            var label: String {
                switch self {
                case .arrow: "Arrow"
                case .oval: "Oval"
                case .line: "Line"
                case .free: "Free line"
                case .rectangle: "Rectangle"
                case .cross: "X"
                case .stamp: "Icon"
                }
            }
        }

        nonisolated enum Style: String, Codable, CaseIterable, Sendable { case flat, neon }

        nonisolated enum Color: String, Codable, CaseIterable, Sendable {
            case yellow, red, white, cyan, green

            var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
                switch self {
                case .yellow: (1, 1, 0)
                case .red: (1, 0, 0)
                case .white: (1, 1, 1)
                case .cyan: (0, 1, 1)
                case .green: (0, 1, 0)
                }
            }
        }

        static let widths: [CGFloat] = [0.006, 0.010, 0.016]
        static let symbols = ["brain", "eye", "exclamationmark.triangle", "bolt.fill",
                              "target", "shield", "figure.boxing", "arrow.triangle.2.circlepath"]
        var kind: Kind
        var points: [CGPoint]
        var color: Color
        var width: CGFloat
        var head: Bool?
        var style: Style?
        var symbol: String?

        init(kind: Kind = .arrow, points: [CGPoint] = [], color: Color = .yellow, width: CGFloat = 0.010,
             head: Bool? = nil, style: Style? = nil, symbol: String? = nil) {
            self.kind = kind
            let bounded = points.map(TelestrationRules.clamped)
            self.points = kind == .free ? TelestrationRules.simplify(bounded) : Array(bounded.prefix(2))
            self.color = color
            let finiteWidth = width.isFinite ? width : 0.010
            self.width = Self.widths.min(by: { abs($0 - finiteWidth) < abs($1 - finiteWidth) }) ?? 0.010
            self.head = head
            self.style = style
            self.symbol = symbol.map { Self.symbols.contains($0) ? $0 : Self.symbols[0] }
        }

        var normalized: Self {
            Self(kind: kind, points: points, color: color, width: width, head: head, style: style, symbol: symbol)
        }

        private nonisolated enum CodingKeys: String, CodingKey { case kind, points, color, width, head, style, symbol }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(kind: try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .arrow,
                      points: try values.decodeIfPresent([CGPoint].self, forKey: .points) ?? [],
                      color: Color(rawValue: try values.decodeIfPresent(String.self, forKey: .color) ?? "yellow") ?? .yellow,
                      width: try values.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0.010,
                      head: try values.decodeIfPresent(Bool.self, forKey: .head),
                      style: (try values.decodeIfPresent(String.self, forKey: .style)).flatMap(Style.init(rawValue:)),
                      symbol: try values.decodeIfPresent(String.self, forKey: .symbol))
        }
    }
}

nonisolated enum TelestrationRules {
    nonisolated struct FigureState: Equatable, Sendable {
        var figure: Telestration.Figure
        var progress: Double
    }

    nonisolated struct State: Equatable, Sendable {
        var figures: [FigureState]
        var opacity: Double
    }

    static func state(of drawing: Telestration, at elapsed: Double) -> State {
        guard elapsed.isFinite, elapsed >= 0, elapsed < drawing.duration, !drawing.figures.isEmpty else {
            return State(figures: [], opacity: 0)
        }
        let fadeStart = Double(drawing.figures.count) * drawing.drawSpeed + drawing.stay
        let opacity = elapsed <= fadeStart ? 1 : max(0, 1 - (elapsed - fadeStart) / max(drawing.fade, .leastNonzeroMagnitude))
        let figures = drawing.figures.enumerated().compactMap { index, figure -> FigureState? in
            let linear = min(1, max(0, (elapsed - Double(index) * drawing.drawSpeed) / drawing.drawSpeed))
            guard linear > 0 else { return nil }
            return FigureState(figure: figure, progress: 1 - pow(1 - linear, 3))
        }
        return State(figures: figures, opacity: opacity)
    }

    /// Iterative Douglas–Peucker avoids recursion for long freehand strokes.
    /// If still too dense, evenly subsample the simplified path, keeping both ends.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat = 0.002) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep: Set<Int> = [0, points.count - 1]
        var pending = [(0, points.count - 1)]
        while let (first, last) = pending.popLast() {
            guard last > first + 1 else { continue }
            var furthest = max(0, tolerance), split: Int?
            for index in (first + 1)..<last {
                let delta = segmentDistance(points[index], points[first], points[last], aspect: 1)
                if delta > furthest { furthest = delta; split = index }
            }
            if let split {
                keep.insert(split)
                pending.append((first, split))
                pending.append((split, last))
            }
        }
        let simplified = keep.sorted().map { points[$0] }
        guard simplified.count > 200 else { return simplified }
        return (0..<200).map { simplified[$0 * (simplified.count - 1) / 199] }
    }

    static func moved(_ figure: Telestration.Figure, by delta: CGSize) -> Telestration.Figure {
        guard !figure.points.isEmpty else { return figure }
        let xs = figure.points.map(\.x), ys = figure.points.map(\.y)
        let dx = min(1 - (xs.max() ?? 1), max(-(xs.min() ?? 0), delta.width.isFinite ? delta.width : 0))
        let dy = min(1 - (ys.max() ?? 1), max(-(ys.min() ?? 0), delta.height.isFinite ? delta.height : 0))
        var result = figure
        result.points = figure.points.map { clamped(CGPoint(x: $0.x + dx, y: $0.y + dy)) }
        return result
    }

    static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.isFinite ? min(1, max(0, point.x)) : 0,
                y: point.y.isFinite ? min(1, max(0, point.y)) : 0)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint, aspect: CGFloat) -> CGFloat {
        hypot((b.x - a.x) * aspect, b.y - a.y)
    }

    static func segmentDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint, aspect: CGFloat) -> CGFloat {
        let dx = (b.x - a.x) * aspect, dy = b.y - a.y, squared = dx * dx + dy * dy
        guard squared > 0 else { return distance(point, a, aspect: aspect) }
        let fraction = min(1, max(0, ((point.x - a.x) * aspect * dx + (point.y - a.y) * dy) / squared))
        return distance(point, CGPoint(x: a.x + fraction * dx / aspect, y: a.y + fraction * dy), aspect: aspect)
    }

    static func videoRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect.isFinite, aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, size.height * aspect), height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func sourcePoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return clamped(CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height))
    }

    static func translation(from start: CGPoint, to end: CGPoint) -> CGSize {
        CGSize(width: end.x - start.x, height: end.y - start.y)
    }

    static func placed(_ point: CGPoint, in rect: CGRect, topLeftOrigin: Bool = true) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width,
                y: topLeftOrigin ? rect.minY + point.y * rect.height : rect.maxY - point.y * rect.height)
    }

    static func cropRect(_ visible: CGRect?, in rect: CGRect) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let crop = (visible ?? unit).standardized.intersection(unit)
        guard !crop.isNull else { return .zero }
        return CGRect(x: rect.minX + crop.minX * rect.width, y: rect.minY + crop.minY * rect.height,
                      width: crop.width * rect.width, height: crop.height * rect.height)
    }

    /// Avoid requesting a frame at the exclusive end of an asset.
    static func sourceTime(_ time: Double, duration: Double, frameRate: Double = 30) -> Double {
        let rate = frameRate.isFinite && frameRate > 0 ? frameRate : 30
        let end = duration.isFinite ? max(0, duration - 1 / rate) : 0
        return min(end, max(0, time.isFinite ? time : 0))
    }
}
