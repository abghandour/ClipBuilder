import CoreGraphics

/// Alignment help while an element is dragged in the reel preview: a faint
/// grid with the centre lines, and a pull toward the lines worth aligning
/// to (the grid, the frame's centre and edges, and the other elements'
/// edges and centres). The grid is 6 cells across the short side and 12
/// along a long one, so it holds the halves, thirds, quarters and sixths.
nonisolated enum PreviewSnapRules {
    /// How close, in points, an edge or centre must come to a line to jump to it.
    static let threshold: CGFloat = 6

    struct Guide: Hashable, Sendable {
        /// A vertical line sits at an x; a horizontal one at a y.
        var vertical: Bool
        var position: CGFloat
        /// One of the frame's two centre lines.
        var centre = false
    }

    struct Result: Equatable, Sendable {
        var rect: CGRect
        /// The lines the element is aligned to right now.
        var guides: [Guide]
    }

    /// Which edges a drag moves; a move takes the whole box.
    struct Edges: Equatable, Sendable {
        var left = false, right = false, top = false, bottom = false
    }

    /// Cells across and down: a side at least half as long again as the
    /// other gets twice the cells, so they stay close to square.
    static func divisions(in frame: CGRect) -> (columns: Int, rows: Int) {
        (frame.width >= frame.height * 1.5 ? 12 : 6, frame.height >= frame.width * 1.5 ? 12 : 6)
    }

    /// The grid shown during a drag, with the two centre lines marked.
    static func grid(in frame: CGRect) -> [Guide] {
        guard frame.width > 0, frame.height > 0 else { return [] }
        let divisions = divisions(in: frame)
        return inner(frame.minX, frame.midX, frame.maxX, divisions.columns)
                .map { Guide(vertical: true, position: $0, centre: $0 == frame.midX) }
            + inner(frame.minY, frame.midY, frame.maxY, divisions.rows)
                .map { Guide(vertical: false, position: $0, centre: $0 == frame.midY) }
    }

    /// The grid lines between two edges; the middle one is exactly `centre`.
    private static func inner(_ lower: CGFloat, _ centre: CGFloat, _ upper: CGFloat, _ divisions: Int) -> [CGFloat] {
        (1..<divisions).map { $0 * 2 == divisions ? centre : lower + (upper - lower) * CGFloat($0) / CGFloat(divisions) }
    }

    /// `rect` moved onto the nearest lines, one per axis at most.
    static func moved(_ rect: CGRect, frame: CGRect, others: [CGRect] = [],
                      threshold: CGFloat = threshold) -> Result {
        var rect = rect
        var guides: [Guide] = []
        if let snap = nearest(anchors: [(rect.minX, false), (rect.midX, true), (rect.maxX, false)],
                              targets: targets(frame.minX, frame.midX, frame.maxX, divisions(in: frame).columns, others.flatMap { [$0.minX, $0.midX, $0.maxX] }),
                              centre: frame.midX, threshold: threshold) {
            rect.origin.x += snap.delta
            guides.append(Guide(vertical: true, position: snap.target, centre: snap.target == frame.midX))
        }
        if let snap = nearest(anchors: [(rect.minY, false), (rect.midY, true), (rect.maxY, false)],
                              targets: targets(frame.minY, frame.midY, frame.maxY, divisions(in: frame).rows, others.flatMap { [$0.minY, $0.midY, $0.maxY] }),
                              centre: frame.midY, threshold: threshold) {
            rect.origin.y += snap.delta
            guides.append(Guide(vertical: false, position: snap.target, centre: snap.target == frame.midY))
        }
        return Result(rect: rect, guides: guides)
    }

    /// `rect` with the edges being dragged pulled onto the nearest lines;
    /// the other edges stay where they are.
    static func resized(_ rect: CGRect, edges: Edges, frame: CGRect, others: [CGRect] = [],
                        minimum: CGSize = .zero, threshold: CGFloat = threshold) -> Result {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        var guides: [Guide] = []
        let xs = targets(frame.minX, frame.midX, frame.maxX, divisions(in: frame).columns, others.flatMap { [$0.minX, $0.midX, $0.maxX] })
        let ys = targets(frame.minY, frame.midY, frame.maxY, divisions(in: frame).rows, others.flatMap { [$0.minY, $0.midY, $0.maxY] })
        func pull(_ value: CGFloat, _ targets: [CGFloat], vertical: Bool, centre: CGFloat,
                  allowed: (CGFloat) -> Bool) -> CGFloat {
            guard let snap = nearest(anchors: [(value, false)], targets: targets, centre: centre, threshold: threshold),
                  allowed(snap.target) else { return value }
            guides.append(Guide(vertical: vertical, position: snap.target, centre: snap.target == centre))
            return snap.target
        }
        if edges.left { left = pull(left, xs, vertical: true, centre: frame.midX) { $0 <= right - minimum.width } }
        if edges.right { right = pull(right, xs, vertical: true, centre: frame.midX) { $0 >= left + minimum.width } }
        if edges.top { top = pull(top, ys, vertical: false, centre: frame.midY) { $0 <= bottom - minimum.height } }
        if edges.bottom { bottom = pull(bottom, ys, vertical: false, centre: frame.midY) { $0 >= top + minimum.height } }
        return Result(rect: CGRect(x: left, y: top, width: right - left, height: bottom - top), guides: guides)
    }

    private static func targets(_ lower: CGFloat, _ centre: CGFloat, _ upper: CGFloat, _ divisions: Int,
                                _ others: [CGFloat]) -> [CGFloat] {
        [lower] + inner(lower, centre, upper, divisions) + [upper] + others
    }

    /// The closest line to any anchor. The element's centre on the frame's
    /// centre line reaches half as far again and wins a tie: it is the
    /// alignment asked for most.
    private static func nearest(anchors: [(value: CGFloat, isCentre: Bool)], targets: [CGFloat], centre: CGFloat,
                                threshold: CGFloat) -> (delta: CGFloat, target: CGFloat)? {
        var best: (delta: CGFloat, target: CGFloat, score: CGFloat)?
        for anchor in anchors {
            for target in targets {
                let delta = target - anchor.value
                let favoured = anchor.isCentre && target == centre
                guard abs(delta) <= threshold * (favoured ? 1.5 : 1) else { continue }
                let score = abs(delta) / (favoured ? 1.5 : 1)
                if best == nil || score < best!.score { best = (delta, target, score) }
            }
        }
        return best.map { ($0.delta, $0.target) }
    }
}
