import Foundation
import ImageIO
import Testing
@testable import Clip_Builder

/// Reruns the strike marker on a real fight and reports, for every strike it
/// misses, which gate rejected it. Off unless CLIPBUILDER_STRIKE_DIAG_DB names
/// a profile database copy whose video (CLIPBUILDER_STRIKE_DIAG_VIDEO) points
/// at a local file; the report goes to CLIPBUILDER_STRIKE_DIAG_REPORT.
@Suite("Strike mark diagnostic",
       .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_STRIKE_DIAG_DB"] != nil))
struct StrikeMarkDiagnosticTests {
    @Test("report why each missed strike has no mark", .timeLimit(.minutes(30)))
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let dbPath = try #require(environment["CLIPBUILDER_STRIKE_DIAG_DB"])
        let videoID = Int64(environment["CLIPBUILDER_STRIKE_DIAG_VIDEO"] ?? "") ?? 1
        let reportPath = environment["CLIPBUILDER_STRIKE_DIAG_REPORT"] ?? dbPath + ".strikes.txt"
        let maxDimension = Int(environment["CLIPBUILDER_STRIKE_DIAG_MAXDIM"] ?? "") ?? 960
        let database = try Database(path: URL(fileURLWithPath: dbPath))
        let video = try #require(try await database.fetchVideos().first { $0.id == videoID })
        let events = try await database.fetchFightEvents(videoID: videoID)
        let strikes = StrikeStatsSummary.deduplicatedStrikes(events).sorted { $0.time < $1.time }
        typealias Rules = StrikeHighlightRules
        var lines: [String] = []
        var tally: [String: Int] = [:]
        var cache: [Int: [Rules.Pose]] = [:]
        var aspect: CGFloat = 16.0 / 9
        func f(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
        for strike in strikes {
            let detail = StrikeDetail(strike.detail)
            let times = Rules.sampleTimes(around: strike.time, duration: video.duration).filter { $0 < video.duration }
            let missing = times.filter { cache[Int(($0 / Rules.step).rounded())] == nil }
            let stills = await ThumbnailService.jpegFrames(url: video.url, at: missing, maxDimension: CGFloat(maxDimension), tolerance: 0)
            for (time, jpeg) in zip(missing, stills) {
                guard let jpeg, let poses = await StrikeHighlightFinder.poses(jpeg) else { continue }
                cache[Int((time / Rules.step).rounded())] = poses
            }
            if let first = stills.compactMap({ $0 }).first,
               let source = CGImageSourceCreateWithData(first as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.height > 0 {
                aspect = CGFloat(image.width) / CGFloat(image.height)
            }
            let frames = times.compactMap { time in cache[Int((time / Rules.step).rounded())].map { (time: time, poses: $0) } }
            let track = Rules.track(frames: frames, time: strike.time, detail: detail, aspect: aspect)
            let window = frames.enumerated().filter { abs($0.element.time - strike.time) <= Rules.contactWindow + 1e-9 }
            var reason = "marked"
            var note = ""
            if track == nil {
                // Gate 1: two fighters in the frame.
                let fighterCounts = window.map { frame -> Int in
                    let poses = frame.element.poses
                    guard let tallest = poses.map(\.height).max(), tallest > 0 else { return 0 }
                    return Rules.contenders(poses.filter { $0.height >= tallest * Rules.comparableHeight }).count
                }
                let poseCounts = window.map { $0.element.poses.count }
                // Gate 2: a limb within reach, with the stored hints and without them.
                var bestStrict: CGFloat = .infinity, bestLoose: CGFloat = .infinity
                var bestApproach: CGFloat = -1, bestClosing: CGFloat = -1
                var anyStrict = false, anyNoHints = false
                for (index, frame) in window {
                    let previous = index > 0 && frame.time - frames[index - 1].time <= Rules.maxGap ? frames[index - 1].poses : nil
                    let strict = Rules.candidates(poses: frame.poses, technique: detail?.technique, limb: detail?.limb,
                                                  target: detail?.target, frameSide: detail?.frameSide, aspect: aspect)
                    if !strict.isEmpty { anyStrict = true }
                    for candidate in strict {
                        bestStrict = min(bestStrict, candidate.highlight.cost)
                        bestApproach = max(bestApproach, Rules.approach(candidate, previous: previous, aspect: aspect))
                        bestClosing = max(bestClosing, Rules.closing(candidate, previous: previous, aspect: aspect))
                    }
                    if !Rules.candidates(poses: frame.poses, technique: nil, aspect: aspect).isEmpty { anyNoHints = true }
                    for candidate in Rules.candidates(poses: frame.poses, technique: nil, aspect: aspect, maxCost: 5, maxReach: 5) {
                        bestLoose = min(bestLoose, candidate.highlight.cost)
                    }
                }
                if window.isEmpty || frames.count < times.count {
                    reason = "frames unreadable"
                } else if (fighterCounts.max() ?? 0) < 2 {
                    reason = "fewer than two fighters seen"
                } else if !anyStrict {
                    reason = anyNoHints ? "no limb in reach with the scorer's technique (another limb is)" : "no limb in reach"
                } else if bestApproach < Rules.minApproach {
                    reason = "limb in reach but not moving fast enough"
                } else if bestClosing < Rules.minClosing {
                    reason = "limb in reach but not closing on the target"
                } else {
                    reason = "approach and closing never pass on the same candidate"
                }
                note = " poses/frame=\(poseCounts) fighters/frame=\(fighterCounts) bestCost=\(bestStrict.isFinite ? f(bestStrict) : "-")"
                    + " nearestAnyLimb=\(bestLoose.isFinite ? f(bestLoose) : "-") bestApproach=\(f(bestApproach)) bestClosing=\(f(bestClosing))"
            }
            // Stills of the contact frame and the one before, with the limb and
            // landing spot drawn, for judging a mark by eye.
            if let track, let directory = environment["CLIPBUILDER_STRIKE_DIAG_STILLS"],
               let key = track.keyframes.min(by: { abs($0.time - track.contact) < abs($1.time - track.contact) }) {
                let shots = await ThumbnailService.jpegFrames(url: video.url, at: [max(0, track.contact - Rules.step), track.contact],
                                                              maxDimension: 1280, tolerance: 0)
                for (label, jpeg) in zip(["a-before", "b-contact"], shots) {
                    guard let jpeg, let drawn = Self.draw(key.highlight, on: jpeg) else { continue }
                    let name = String(format: "%06.2f-%@.jpg", strike.time, label)
                    try? drawn.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
            tally[reason, default: 0] += 1
            lines.append(String(format: "%6.2f", strike.time) + " \(strike.action) detail=\(strike.detail ?? "-") → \(reason)\(note)")
        }
        let summary = tally.sorted { $0.value > $1.value }.map { "\($0.value)  \($0.key)" }
        let report = (["\(strikes.count) strikes, aspect \(f(aspect)), frames at \(maxDimension) px", ""] + summary + [""] + lines).joined(separator: "\n")
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    private static func draw(_ highlight: StrikeHighlightRules.Highlight, on jpeg: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Top-left 0…1 points into CoreGraphics' bottom-left pixels.
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * width, y: (1 - p.y) * height) }
        context.setLineWidth(5)
        context.setStrokeColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 1))
        if let first = highlight.limb.first {
            context.move(to: point(first))
            for next in highlight.limb.dropFirst() { context.addLine(to: point(next)) }
            context.strokePath()
        }
        context.setStrokeColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
        let radius = highlight.radius * height
        let centre = point(highlight.target)
        context.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        guard let result = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, result, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
