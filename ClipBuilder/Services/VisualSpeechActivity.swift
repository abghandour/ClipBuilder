import AVFoundation
import CoreVideo
import Foundation
import Vision

/// How much each face slot's mouth region moves over time: a cheap "who is
/// talking" cue that works for any number of on-screen people. Frames are
/// decoded small and sampled at about eight per second; the mouth region of
/// each slot is the lower part of the face box Vision last found there,
/// refreshed every couple of seconds. The signal per bin is the mean
/// absolute luminance change inside that region between consecutive
/// sampled frames.
nonisolated enum VisualSpeechActivity {
    struct Activity: Sendable, Equatable {
        var binSeconds: Double
        /// activity[slot][bin], slots in tile order.
        var motion: [[Double]]
        /// Call recordings draw a colored border around the active speaker's
        /// tile: highlight[slot][bin] is how much of that slot's edge ring
        /// carries the highlight color (0…1); empty when no such border exists.
        var highlight: [[Double]] = []
        /// Diagnostics: the last face box used per slot (top-left fractions).
        var faceBoxes: [Int: CGRect] = [:]
        /// Diagnostics: ring hue shares per slot per bin (hue buckets).
        var ringShares: [[[Double]]] = []
        var bins: Int { motion.first?.count ?? 0 }
        func value(slot: Int, at time: Double) -> Double {
            guard motion.indices.contains(slot) else { return 0 }
            let bin = Int(time / binSeconds)
            return motion[slot].indices.contains(bin) ? motion[slot][bin] : 0
        }
    }

    static let targetFPS = 8.0
    static let binSeconds = 0.25
    static let faceRefreshSeconds = 2.0

    static func measure(url: URL, tiles: [PodcastTile], start: Double = 0, duration: Double,
                        log: (@Sendable (String) -> Void)? = nil) async throws -> Activity {
        let asset = try await DriveLocalAsset.make(url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return Activity(binSeconds: binSeconds, motion: tiles.map { _ in [] })
        }
        let naturalSize = try await track.load(.naturalSize)
        let nominalRate = Double(try await track.load(.nominalFrameRate))
        let transform = try await track.load(.preferredTransform)
        let orientation = displayOrientation(of: transform)
        let width = 640.0
        let scale = naturalSize.width > 0 ? min(1, width / abs(naturalSize.width)) : 1
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(2, Int((abs(naturalSize.width) * scale).rounded())),
            kCVPixelBufferHeightKey as String: max(2, Int((abs(naturalSize.height) * scale).rounded())),
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ScriptError.invalid("Could not read the video for speech activity.") }
        reader.add(output)
        guard reader.startReading() else { throw ScriptError.invalid("Could not read the video for speech activity.") }
        defer { reader.cancelReading() }

        let binCount = Int((duration / binSeconds).rounded(.up))
        var sums = tiles.map { _ in [Double](repeating: 0, count: binCount) }
        var counts = tiles.map { _ in [Int](repeating: 0, count: binCount) }
        // Edge-ring hue counts per slot per bin: rings[slot][bin][hueBucket].
        var rings = tiles.map { _ in [[Double]](repeating: [Double](repeating: 0, count: hueBuckets * 2), count: binCount) }
        var ringFrames = tiles.map { _ in [Int](repeating: 0, count: binCount) }
        var previous: [Int: [Float]] = [:]   // slot → last mouth patch
        var previousEyes: [Int: [Float]] = [:]   // slot → last eye patch (the shake reference)
        var faceBoxes: [Int: CGRect] = [:]   // slot → face box, top-left fractions
        var nextFaces = -1.0
        var nextSample = 0.0
        let step = nominalRate > 0 ? max(1.0 / nominalRate, 1.0 / targetFPS) : 1.0 / targetFPS
        let faceRequest = DetectFaceRectanglesRequest(.revision3)
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
            guard time + 1e-6 >= nextSample else { continue }
            nextSample = time + step
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if time >= nextFaces {
                nextFaces = time + faceRefreshSeconds
                let permit = try await MediaWorkScheduler.current.acquire(.vision)
                let timing = PerfSignpost.begin("Vision", metadata: "speech activity faces")
                let faces = (try? await faceRequest.perform(on: pixelBuffer, orientation: orientation)) ?? []
                PerfSignpost.end(timing)
                withExtendedLifetime(permit) {}
                // The largest face in a slot this refresh is its person; a
                // box from an earlier refresh never outranks it, so the
                // mouth region follows someone who leans back or away.
                var largest: [Int: CGRect] = [:]
                for face in faces {
                    let rect = face.boundingBox.cgRect
                    let box = CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
                    if let slot = tiles.first(where: { $0.contains(x: box.midX, y: box.midY) })?.index {
                        if let known = largest[slot], known.width * known.height >= box.width * box.height { continue }
                        largest[slot] = box
                    }
                }
                for (slot, box) in largest { faceBoxes[slot] = box }
            }
            let bin = min(binCount - 1, max(0, Int(time / binSeconds)))
            for (slot, tile) in tiles.enumerated() {
                let histogram = ringHues(pixelBuffer, tile: tile)
                for h in 0..<(hueBuckets * 2) { rings[slot][bin][h] += histogram[h] }
                ringFrames[slot][bin] += 1
            }
            for tile in tiles {
                guard let face = faceBoxes[tile.index] else { continue }
                let mouth = CGRect(x: face.minX + face.width * 0.2, y: face.minY + face.height * 0.55,
                                   width: face.width * 0.6, height: face.height * 0.4)
                // The eyes move with the head and the camera but not with
                // speech: their motion is the reference the mouth must beat.
                let eyes = CGRect(x: face.minX + face.width * 0.15, y: face.minY + face.height * 0.15,
                                  width: face.width * 0.7, height: face.height * 0.3)
                guard let patch = luminancePatch(pixelBuffer, region: mouth),
                      let eyePatch = luminancePatch(pixelBuffer, region: eyes) else { continue }
                if let last = previous[tile.index], last.count == patch.count,
                   let lastEyes = previousEyes[tile.index], lastEyes.count == eyePatch.count {
                    var diff = 0.0, reference = 0.0
                    for i in patch.indices { diff += Double(abs(patch[i] - last[i])) }
                    for i in eyePatch.indices { reference += Double(abs(eyePatch[i] - lastEyes[i])) }
                    sums[tile.index][bin] += max(0, diff / Double(patch.count) - reference / Double(eyePatch.count))
                    counts[tile.index][bin] += 1
                }
                previous[tile.index] = patch
                previousEyes[tile.index] = eyePatch
            }
        }
        // A decode failure part-way must not pass off the empty bins after
        // it as a quiet picture.
        if reader.status == .failed {
            throw reader.error ?? ScriptError.invalid("Could not read the video for speech activity.")
        }
        let motion = tiles.indices.map { slot in
            (0..<binCount).map { counts[slot][$0] > 0 ? sums[slot][$0] / Double(counts[slot][$0]) : 0 }
        }
        let highlight = highlightShares(rings: rings, frames: ringFrames)
        log?("Speech activity: \(tiles.count) slot(s), \(binCount) bins of \(binSeconds) s"
             + (highlight.isEmpty ? "" : ", active-speaker border found"))
        let ringShares = tiles.indices.map { slot in
            (0..<binCount).map { b in rings[slot][b].map { $0 / Double(max(1, ringFrames[slot][b])) } }
        }
        return Activity(binSeconds: binSeconds, motion: motion, highlight: highlight, faceBoxes: faceBoxes,
                        ringShares: ringShares)
    }

    static let hueBuckets = 12

    /// Per hue bucket, how strongly a thin line of that color runs along
    /// the tile's edge: the second-best of the four edge bands by the
    /// fraction of a row or column that is the hue, kept only when few rows
    /// share it (a border, not a shirt). Two passes over saturation: strict
    /// (buckets 0..<12) to learn which hue is the highlight, relaxed
    /// (12..<24) to follow it where it blends into a bright background.
    /// Resolution independent, so thresholds hold at any decode size.
    static func ringHues(_ buffer: CVPixelBuffer, tile: PodcastTile) -> [Double] {
        var scores = [Double](repeating: 0, count: hueBuckets * 2)
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return scores }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return scores }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let x0 = max(0, Int(tile.x * Double(width))), x1 = min(width, Int((tile.x + tile.w) * Double(width)))
        let y0 = max(0, Int(tile.y * Double(height))), y1 = min(height, Int((tile.y + tile.h) * Double(height)))
        guard x1 - x0 > 8, y1 - y0 > 8 else { return scores }
        // The border sits inside the cell past the gutter and the title bar:
        // scan a band 20% of the cell inward from each edge, edge included,
        // so a border hugging the cell boundary still belongs to its cell.
        let bandX = max(2, Int(Double(x1 - x0) * 0.2)), bandY = max(2, Int(Double(y1 - y0) * 0.2))
        let insetX = 0, insetY = 0
        /// (bucket, strict): the hue bucket of a colored pixel and whether
        /// it passes the strict saturation test.
        func hueBucket(_ x: Int, _ y: Int) -> (Int, Bool)? {
            let p = pixels + y * rowBytes + x * 4
            let b = Double(p[0]) / 255, g = Double(p[1]) / 255, r = Double(p[2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            guard saturation > 0.2, maxC > 0.3 else { return nil }
            let delta = maxC - minC
            var hue: Double
            if maxC == r { hue = (g - b) / delta }
            else if maxC == g { hue = 2 + (b - r) / delta }
            else { hue = 4 + (r - g) / delta }
            hue = hue < 0 ? hue + 6 : hue
            return (min(hueBuckets - 1, Int(hue / 6 * Double(hueBuckets))), saturation > 0.45 && maxC > 0.35)
        }
        // Each edge band separately: a highlight is a rectangle, so a lit
        // cell carries the hue on several edges, while a neighbor sharing a
        // boundary line sees it on one edge only.
        func scanRow(_ y: Int) -> [Double] {
            var counts = [Double](repeating: 0, count: hueBuckets * 2); var n = 0.0
            for x in stride(from: x0, to: x1, by: 2) {
                n += 1
                if let (h, strict) = hueBucket(x, y) { counts[hueBuckets + h] += 1; if strict { counts[h] += 1 } }
            }
            return counts.map { $0 / max(1, n) }
        }
        func scanColumn(_ x: Int) -> [Double] {
            var counts = [Double](repeating: 0, count: hueBuckets * 2); var n = 0.0
            for y in stride(from: y0, to: y1, by: 2) {
                n += 1
                if let (h, strict) = hueBucket(x, y) { counts[hueBuckets + h] += 1; if strict { counts[h] += 1 } }
            }
            return counts.map { $0 / max(1, n) }
        }
        let edges: [[[Double]]] = [
            ((y0 + insetY)..<min(y1, y0 + insetY + bandY)).map(scanRow),
            (max(y0, y1 - insetY - bandY)..<(y1 - insetY)).map(scanRow),
            ((x0 + insetX)..<min(x1, x0 + insetX + bandX)).map(scanColumn),
            (max(x0, x1 - insetX - bandX)..<(x1 - insetX)).map(scanColumn),
        ]
        for h in 0..<(hueBuckets * 2) {
            var edgeScores: [Double] = []
            for lines in edges where !lines.isEmpty {
                let values = lines.map { $0[h] }
                let peak = values.max() ?? 0
                // Thin: few lines of the band carry half the peak or more.
                let thick = values.count { $0 >= peak / 2 }
                edgeScores.append(peak > 0 && Double(thick) <= max(2, Double(lines.count) * 0.15) ? peak : 0)
            }
            let sorted = edgeScores.sorted(by: >)
            scores[h] = sorted.count >= 2 ? sorted[1] : 0
        }
        return scores
    }

    /// The highlight color is the hue that lights exactly one tile's ring at
    /// a time in enough frames. Each tile's own typical share of a hue (a
    /// green wall, an orange poster) is subtracted first, so only the
    /// excess counts, and a real highlight must visit at least two tiles.
    /// The result is 1 for the lit slot in each bin where one slot clearly
    /// carries the hue, else 0. Empty when no hue behaves like a border.
    static func highlightShares(rings: [[[Double]]], frames: [[Int]]) -> [[Double]] {
        guard let bins = rings.first?.count, bins > 0, rings.count >= 2 else { return [] }
        let slots = rings.count
        // shares[slot][bin][hue] (strict 0..<12, relaxed 12..<24), then the
        // per-slot per-hue baseline. A low percentile, not the median: a
        // tile lit most of the time must still show its unlit level.
        let shares: [[[Double]]] = (0..<slots).map { slot in
            (0..<bins).map { b in rings[slot][b].map { $0 / Double(max(1, frames[slot][b])) } }
        }
        let baseline: [[Double]] = (0..<slots).map { slot in
            (0..<(hueBuckets * 2)).map { h in
                let values = (0..<bins).filter { frames[slot][$0] > 0 }.map { shares[slot][$0][h] }.sorted()
                return values.isEmpty ? 0 : values[values.count / 6]
            }
        }
        func litSlot(_ b: Int, _ h: Int) -> Int? {
            let excess = (0..<slots).map { max(0, shares[$0][b][h] - baseline[$0][h]) }
            guard let top = excess.indices.max(by: { excess[$0] < excess[$1] }) else { return nil }
            let second = excess.enumerated().filter { $0.offset != top }.map(\.element).max() ?? 0
            // A lit tile has a clear line of the hue that the others lack.
            return excess[top] >= 0.15 && excess[top] >= 2.5 * max(second, 0.03) ? top : nil
        }
        var single = [Int](repeating: 0, count: hueBuckets)
        var movers = [Set<Int>](repeating: [], count: hueBuckets)
        var seen = 0
        for b in 0..<bins where (frames.first?[b] ?? 0) > 0 {
            seen += 1
            for h in 0..<hueBuckets {
                if let slot = litSlot(b, h) { single[h] += 1; movers[h].insert(slot) }
            }
        }
        guard seen > 0,
              let hue = single.indices.filter({ movers[$0].count >= 2 }).max(by: { single[$0] < single[$1] }),
              Double(single[hue]) / Double(seen) > 0.2 else { return [] }
        lastHighlightHue = hue
        // Decide with the relaxed pass of the learned hue: a border over a
        // bright wall keeps its hue but loses saturation. A one-bin blip
        // between two agreeing neighbors takes their value.
        let relaxed = hueBuckets + hue
        var lit: [Int?] = (0..<bins).map { litSlot($0, relaxed) }
        for b in 1..<max(1, bins - 1) where lit[b - 1] == lit[b + 1] && lit[b] != lit[b - 1] { lit[b] = lit[b - 1] }
        return (0..<slots).map { slot in (0..<bins).map { lit[$0] == slot ? 1.0 : 0.0 } }
    }

    /// Diagnostics: the hue bucket the last measurement treated as the border.
    nonisolated(unsafe) static var lastHighlightHue: Int?

    /// How a stored frame must be turned to display upright.
    static func displayOrientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }

    /// The region's luminance downsampled to a small fixed grid, so frames
    /// compare cell by cell regardless of the decoded size.
    static func luminancePatch(_ buffer: CVPixelBuffer, region: CGRect, grid: Int = 12) -> [Float]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = max(0, min(width - 1, Int(region.minX * Double(width))))
        let y0 = max(0, min(height - 1, Int(region.minY * Double(height))))
        let x1 = max(x0 + 1, min(width, Int(region.maxX * Double(width))))
        let y1 = max(y0 + 1, min(height, Int(region.maxY * Double(height))))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var patch = [Float](repeating: 0, count: grid * grid)
        for gy in 0..<grid {
            let ys = y0 + (y1 - y0) * gy / grid, ye = max(ys + 1, y0 + (y1 - y0) * (gy + 1) / grid)
            for gx in 0..<grid {
                let xs = x0 + (x1 - x0) * gx / grid, xe = max(xs + 1, x0 + (x1 - x0) * (gx + 1) / grid)
                var total = 0, n = 0
                for y in ys..<min(y1, ye) {
                    let row = pixels + y * stride
                    for x in xs..<min(x1, xe) {
                        let p = row + x * 4
                        total += Int(p[0]) + Int(p[1]) * 2 + Int(p[2])   // BGRA weighted luma
                        n += 1
                    }
                }
                patch[gy * grid + gx] = n > 0 ? Float(total) / Float(n * 4) : 0
            }
        }
        return patch
    }
}
