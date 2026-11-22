import CoreGraphics
import Foundation

/// Bitmap and geometry rules for opt-in HD highlights. No Vision or media dependencies.
nonisolated enum StrikeHighlightContourRules {
    struct Bitmap: Equatable, Sendable {
        let width: Int
        let height: Int
        var pixels: [Bool]

        init(width: Int, height: Int, pixels: [Bool]) {
            precondition(width > 0 && height > 0 && pixels.count == width * height)
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        func contains(x: Int, y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && pixels[y * width + x]
        }

        func contains(_ point: CGPoint) -> Bool {
            guard point.x >= 0, point.x < 1, point.y >= 0, point.y < 1 else { return false }
            return contains(x: Int(point.x * CGFloat(width)), y: Int(point.y * CGFloat(height)))
        }
    }

    static func extendedLimb(_ limb: [CGPoint]) -> [CGPoint] {
        guard limb.count >= 2, let tip = limb.last else { return limb }
        let previous = limb[limb.count - 2]
        return limb + [CGPoint(x: tip.x + (tip.x - previous.x) * 0.6,
                               y: tip.y + (tip.y - previous.y) * 0.6)]
    }

    private static func nearest(_ point: CGPoint, on a: CGPoint, _ b: CGPoint, aspect: CGFloat) -> CGPoint {
        let dx = (b.x - a.x) * aspect, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((point.x - a.x) * aspect * dx + (point.y - a.y) * dy) / length)) : 0
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint, aspect: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }

    /// How wide the limb is, as shares of its own length from its first
    /// joint to its last: at the first joint, at the last, and over the
    /// hand or foot beyond it. A little over a real limb's half width, so
    /// the person's mask draws the edge and the area only keeps the other
    /// leg, the hips and the trunk out.
    static func widths(usesArm: Bool) -> (start: CGFloat, end: CGFloat, tip: CGFloat) {
        usesArm ? (0.10, 0.085, 0.12) : (0.14, 0.09, 0.10)
    }

    /// The share of the first segment left out at its start: a leg's first
    /// joint is the hip, inside the pelvis, where both legs meet.
    static func trim(usesArm: Bool) -> CGFloat { usesArm ? 0 : 0.25 }

    /// The line the area is built around: the limb without the part inside
    /// the trunk, carried on past the wrist or ankle.
    static func core(_ highlight: StrikeHighlightRules.Highlight) -> [CGPoint] {
        var line = extendedLimb(highlight.limb)
        guard line.count >= 2 else { return line }
        let share = trim(usesArm: highlight.usesArm)
        line[0] = CGPoint(x: line[0].x + (line[1].x - line[0].x) * share, y: line[0].y + (line[1].y - line[0].y) * share)
        return line
    }

    static func capsule(_ highlight: StrikeHighlightRules.Highlight, aspect: CGFloat, width: Int, height: Int) -> Bitmap {
        let line = core(highlight)
        var pixels = [Bool](repeating: false, count: width * height)
        guard line.count >= 3, aspect > 0, highlight.radius > 0 else { return Bitmap(width: width, height: height, pixels: pixels) }
        let limbLength = zip(highlight.limb, highlight.limb.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1, aspect: aspect) }
        let shares = widths(usesArm: highlight.usesArm)
        // A limb pointing at the camera is short in the picture and no thinner.
        let least = highlight.radius * 0.4
        let start = max(limbLength * shares.start, least), end = max(limbLength * shares.end, least)
        let tip = max(limbLength * shares.tip, least)
        let segments = Array(zip(line, line.dropFirst()))
        let lengths = segments.map { distance($0.0, $0.1, aspect: aspect) }
        // Everything before the last segment is limb; the last is the hand or foot.
        let jointed = max(lengths.dropLast().reduce(0, +), 0.000001)
        // Nothing farther from the line than the widest radius can be inside:
        // only the line's own box, grown by that much, is scanned.
        let reach = max(start, end, tip)
        let xs = line.map(\.x), ys = line.map(\.y)
        let left = max(0, Int((((xs.min() ?? 0) - reach / aspect) * CGFloat(width)).rounded(.down)))
        let right = min(width - 1, Int((((xs.max() ?? 0) + reach / aspect) * CGFloat(width)).rounded(.up)))
        let top = max(0, Int((((ys.min() ?? 0) - reach) * CGFloat(height)).rounded(.down)))
        let bottom = min(height - 1, Int((((ys.max() ?? 0) + reach) * CGFloat(height)).rounded(.up)))
        guard left <= right, top <= bottom else { return Bitmap(width: width, height: height, pixels: pixels) }
        for y in top...bottom {
            for x in left...right {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(width), y: (CGFloat(y) + 0.5) / CGFloat(height))
                var passed: CGFloat = 0
                for (index, segment) in segments.enumerated() {
                    let on = nearest(point, on: segment.0, segment.1, aspect: aspect)
                    let radius: CGFloat
                    if index == segments.count - 1 { radius = tip } else {
                        let along = (passed + distance(segment.0, on, aspect: aspect)) / jointed
                        radius = start + (end - start) * along
                    }
                    if distance(point, on, aspect: aspect) <= radius { pixels[y * width + x] = true; break }
                    passed += lengths[index]
                }
            }
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    /// The part of `bitmap` joined to the limb's own line. Another body
    /// part that falls inside the area without touching the limb is left out.
    static func region(_ bitmap: Bitmap, along line: [CGPoint]) -> Bitmap {
        var visited = [Bool](repeating: false, count: bitmap.pixels.count)
        var queue: [Int] = []
        for point in limbSamples(line) where bitmap.contains(point) {
            let index = Int(point.y * CGFloat(bitmap.height)) * bitmap.width + Int(point.x * CGFloat(bitmap.width))
            if !visited[index] { visited[index] = true; queue.append(index) }
        }
        guard !queue.isEmpty else { return largestRegion(bitmap) }
        var head = 0
        while head < queue.count {
            let index = queue[head], x = index % bitmap.width, y = index / bitmap.width
            head += 1
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where bitmap.contains(x: nx, y: ny) {
                let next = ny * bitmap.width + nx
                if !visited[next] { visited[next] = true; queue.append(next) }
            }
        }
        var result = bitmap
        result.pixels = visited
        // Seeds on two sides of a gap give two pieces: one outline needs one.
        return largestRegion(result)
    }

    /// Sample along every segment, not just the joints, to choose the attacker mask.
    static func limbSamples(_ limb: [CGPoint]) -> [CGPoint] {
        zip(limb, limb.dropFirst()).flatMap { a, b in
            (0...12).map { index in
                let t = CGFloat(index) / 12
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
    }

    static func bestMask(_ masks: [Bitmap], limb: [CGPoint]) -> Bitmap? {
        let samples = limbSamples(limb)
        return masks.enumerated().max { a, b in
            let left = samples.count { a.element.contains($0) }, right = samples.count { b.element.contains($0) }
            return left == right ? a.offset > b.offset : left < right
        }?.element
    }

    static func acceptableArea(region: Int, capsule: Int) -> Bool {
        capsule > 0 && Double(region) >= Double(capsule) * 0.15 && Double(region) <= Double(capsule) * 0.95
    }

    static func enoughContours(_ track: StrikeHighlightRules.Track) -> Bool {
        let frames = track.keyframes.filter { $0.time >= track.contact - 0.3 - 0.000001 && $0.time <= track.contact + 0.15 + 0.000001 }
        return !frames.isEmpty && Double(frames.count { $0.highlight.contour != nil }) >= Double(frames.count) * 0.6
    }

    /// Include endpoints to preserve the original track's fade and contact interval.
    static func frameTimes(start: Double, end: Double, frameRate: Double) -> [Double] {
        guard start.isFinite, end.isFinite, end >= start else { return [] }
        let rate = frameRate.isFinite && frameRate > 0 ? min(30, frameRate) : 30
        var times = [start]
        var index = floor(start * rate) + 1
        while index / rate < end - 0.000001 {
            times.append(index / rate)
            index += 1
        }
        if end > start + 0.000001 { times.append(end) }
        return times
    }

    static func largestRegion(_ bitmap: Bitmap) -> Bitmap {
        var visited = [Bool](repeating: false, count: bitmap.pixels.count)
        var largest: [Int] = []
        for seed in bitmap.pixels.indices where bitmap.pixels[seed] && !visited[seed] {
            var queue = [seed], head = 0
            visited[seed] = true
            while head < queue.count {
                let index = queue[head], x = index % bitmap.width, y = index / bitmap.width
                head += 1
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where bitmap.contains(x: nx, y: ny) {
                    let next = ny * bitmap.width + nx
                    if !visited[next] { visited[next] = true; queue.append(next) }
                }
            }
            if queue.count > largest.count { largest = queue }
        }
        var result = bitmap
        result.pixels = [Bool](repeating: false, count: bitmap.pixels.count)
        for index in largest { result.pixels[index] = true }
        return result
    }

    /// Trace exposed pixel edges clockwise (top-left coordinates). At a touching
    /// corner turn right first; keep the outside loop, discarding holes.
    static func boundary(_ bitmap: Bitmap) -> [CGPoint] {
        let stride = bitmap.width + 1
        var edges: [Int: [Int]] = [:]
        func edge(_ x: Int, _ y: Int, _ nx: Int, _ ny: Int) {
            edges[y * stride + x, default: []].append(ny * stride + nx)
        }
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.contains(x: x, y: y) {
                if !bitmap.contains(x: x, y: y - 1) { edge(x, y, x + 1, y) }
                if !bitmap.contains(x: x + 1, y: y) { edge(x + 1, y, x + 1, y + 1) }
                if !bitmap.contains(x: x, y: y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !bitmap.contains(x: x - 1, y: y) { edge(x, y + 1, x, y) }
            }
        }
        func point(_ index: Int) -> CGPoint {
            CGPoint(x: CGFloat(index % stride) / CGFloat(bitmap.width), y: CGFloat(index / stride) / CGFloat(bitmap.height))
        }
        func direction(_ a: Int, _ b: Int) -> Int {
            if b == a + 1 { return 0 }
            if b == a + stride { return 1 }
            if b == a - 1 { return 2 }
            return 3
        }
        var best: [CGPoint] = []
        while let start = edges.keys.min() {
            var loop: [CGPoint] = [], current = start, incoming = 0
            repeat {
                loop.append(point(current))
                guard let choices = edges[current], !choices.isEmpty else { break }
                let next = choices.min { a, b in
                    func priority(_ next: Int) -> Int {
                        let turn = (direction(current, next) - incoming + 4) % 4
                        return [1: 0, 0: 1, 3: 2, 2: 3][turn] ?? 4
                    }
                    return priority(a) < priority(b)
                }!
                edges[current]?.removeAll { $0 == next }
                if edges[current]?.isEmpty == true { edges.removeValue(forKey: current) }
                incoming = direction(current, next)
                current = next
            } while current != start
            if signedArea(loop) > signedArea(best) { best = loop }
        }
        // Exact collinear simplification retains concavities and thin fingers.
        return best.indices.compactMap { index in
            let a = best[(index + best.count - 1) % best.count], b = best[index], c = best[(index + 1) % best.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            return abs(cross) > 0.000000001 ? b : nil
        }
    }

    static func signedArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(0) { sum, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return sum + a.x * b.y - b.x * a.y
        } / 2
    }

    static func resample(_ polygon: [CGPoint], nearest joint: CGPoint, aspect: CGFloat) -> [CGPoint]? {
        guard polygon.count >= 3, aspect > 0, abs(signedArea(polygon)) > 0 else { return nil }
        let points = signedArea(polygon) > 0 ? polygon : Array(polygon.reversed())
        var first = points[0], edgeIndex = 0, closest = CGFloat.infinity
        for index in points.indices {
            let candidate = nearest(joint, on: points[index], points[(index + 1) % points.count], aspect: aspect)
            let separation = distance(joint, candidate, aspect: aspect)
            if separation < closest { closest = separation; first = candidate; edgeIndex = index }
        }
        let ordered = [first] + (1...points.count).map { points[(edgeIndex + $0) % points.count] } + [first]
        let lengths = zip(ordered, ordered.dropFirst()).map { distance($0, $1, aspect: aspect) }
        let perimeter = lengths.reduce(0, +)
        guard perimeter > 0 else { return nil }
        var segment = 0, passed: CGFloat = 0
        return (0..<StrikeHighlightRules.contourPoints).map { index in
            let at = perimeter * CGFloat(index) / CGFloat(StrikeHighlightRules.contourPoints)
            while segment < lengths.count - 1 && passed + lengths[segment] < at {
                passed += lengths[segment]; segment += 1
            }
            let t = lengths[segment] > 0 ? (at - passed) / lengths[segment] : 0
            let a = ordered[segment], b = ordered[segment + 1]
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// The same outline, started at the point that sits nearest where the
    /// previous frame's outline started. Each frame picks its own start
    /// (the point nearest the first joint), and on a rounded shape a small
    /// change of the mask can move that start to another edge: blended
    /// point by point with its neighbour, the outline would fold.
    static func aligned(_ contour: [CGPoint], to previous: [CGPoint]?, aspect: CGFloat) -> [CGPoint] {
        guard let previous, previous.count == contour.count, contour.count > 1 else { return contour }
        var best = 0, least = CGFloat.infinity
        for shift in contour.indices {
            var total: CGFloat = 0
            for index in contour.indices {
                let a = contour[(index + shift) % contour.count], b = previous[index]
                let dx = (a.x - b.x) * aspect, dy = a.y - b.y
                total += dx * dx + dy * dy
                if total >= least { break }
            }
            if total < least { least = total; best = shift }
        }
        return best == 0 ? contour : contour.indices.map { contour[($0 + best) % contour.count] }
    }

    static func contour(mask: Bitmap, highlight: StrikeHighlightRules.Highlight, aspect: CGFloat) -> [CGPoint]? {
        guard let joint = highlight.limb.first else { return nil }
        let capsule = capsule(highlight, aspect: aspect, width: mask.width, height: mask.height)
        let region = region(Bitmap(width: mask.width, height: mask.height,
                                   pixels: zip(mask.pixels, capsule.pixels).map { $0 && $1 }), along: core(highlight))
        guard acceptableArea(region: region.pixels.count { $0 }, capsule: capsule.pixels.count { $0 }) else { return nil }
        return resample(boundary(region), nearest: joint, aspect: aspect)
    }
}
