import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Opt-in media work. Frames, segmentation and bitmap tracing stay off the UI actor.
nonisolated enum StrikeHighlightContour {
    static let noOutline = "The limb's outline could not be found for this strike"

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    @concurrent
    static func find(url: URL, track: StrikeHighlightRules.Track) async throws -> StrikeHighlightRules.Track? {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(message: "This file has no video track.")
        }
        let rate = Double(try await source.load(.nominalFrameRate))
        let times = StrikeHighlightContourRules.frameTimes(start: track.start, end: track.end, frameRate: rate)
        var dense = track
        dense.keyframes = []
        dense.contourVersion = StrikeHighlightRules.contourVersion
        var lastContour: [CGPoint]?
        // A short batch bounds decoded JPEG memory, and permits Stop between frames.
        for start in stride(from: 0, to: times.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(times[start..<min(times.count, start + 4)])
            let stills = await ThumbnailService.jpegFrames(url: url, at: batch, maxDimension: 960, tolerance: 0)
            for (index, time) in batch.enumerated() {
                try Task.checkCancellation()
                guard var highlight = StrikeHighlightRules.sample(track, at: time)?.highlight else { continue }
                highlight.contour = nil
                if index < stills.count, let jpeg = stills[index] {
                    do {
                        let masks = try await personMasks(jpeg)
                        if let mask = StrikeHighlightContourRules.bestMask(masks, limb: highlight.limb) {
                            highlight.contour = StrikeHighlightContourRules.contour(mask: mask, highlight: highlight, aspect: track.aspect)
                                .map { StrikeHighlightContourRules.aligned($0, to: lastContour, aspect: track.aspect) }
                            if let contour = highlight.contour { lastContour = contour }
                        }
                    } catch {
                        try Task.checkCancellation()
                        // A missing mask is a plain frame, counted against the contact coverage gate.
                        ErrorLog.record("HD strike highlight frame", error.localizedDescription)
                    }
                }
                dense.keyframes.append(.init(time: time, highlight: highlight))
            }
        }
        try Task.checkCancellation()
        return StrikeHighlightContourRules.enoughContours(dense) ? dense : nil
    }

    private static func personMasks(_ jpeg: Data) async throws -> [StrikeHighlightContourRules.Bitmap] {
        let permit = try await MediaWorkScheduler.current.acquire(.vision)
        defer { withExtendedLifetime(permit) {} }
        // Confirmed in the installed Vision.swiftinterface: Result is InstanceMaskObservation?.
        // generateMask(for:) returns CVPixelBuffer (float32 confidence, one instance at a time).
        do {
            if let observation = try await GeneratePersonInstanceMaskRequest().perform(on: jpeg), !observation.allInstances.isEmpty {
                return try observation.allInstances.map { instance in
                    try bitmap(observation.generateMask(for: IndexSet(integer: instance)))
                }
            }
        } catch {
            try Task.checkCancellation()
            // Unsupported instance inference on this device can still use segmentation.
        }
        try Task.checkCancellation()
        let request = GeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormatType = kCVPixelFormatType_OneComponent8
        let observation = try await request.perform(on: jpeg)
        // cgImage is available on macOS 26; pixelBuffer is new in macOS 27.
        return [try bitmap(observation.cgImage)]
    }

    private static func bitmap(_ buffer: CVPixelBuffer) throws -> StrikeHighlightContourRules.Bitmap {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw Failure(message: "Could not read the person's mask.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message: "The person's mask was empty.") }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8 else {
            throw Failure(message: "The person's mask has an unsupported pixel format.")
        }
        var pixels = [Bool](repeating: false, count: width * height)
        // Image buffers are row-major, top first; only Vision point coordinates flip y.
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<width {
                pixels[y * width + x] = format == kCVPixelFormatType_OneComponent32Float
                    ? row.assumingMemoryBound(to: Float.self)[x] >= 0.5
                    : row.assumingMemoryBound(to: UInt8.self)[x] >= 128
            }
        }
        return .init(width: width, height: height, pixels: pixels)
    }

    private static func bitmap(_ image: CGImage) throws -> StrikeHighlightContourRules.Bitmap {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure(message: "Could not read the person's mask.") }
        return .init(width: width, height: height, pixels: bytes.map { $0 >= 128 })
    }

    /// Claim the same per-video work lane as marking/scoring. Save each finished
    /// strike separately, checking both the generation and the unchanged event row.
    @concurrent
    static func makeHD(video: VideoRecord, events: [FightEventRecord], database: Database,
                       isCurrent: @escaping @Sendable () async -> Bool,
                       didSave: @escaping @Sendable () async -> Void,
                       log: @escaping @Sendable (String) -> Void) async throws {
        let key = FightWorkCoordinator.Key(database: database, videoID: video.id)
        try await FightWorkCoordinator.shared.withClaim(key: key) {
            guard await isCurrent() else { return }
            let state = try await database.strikeHighlightMarkingState(videoID: video.id)
            let requested = events.filter { state.events.contains($0) && $0.videoID == video.id }
            var savedCount = 0, failures = 0
            // Each saved row is a separate opt-in target, including plain tracks
            // found on demand for rows merged by the original marking pass.
            for saved in state.saved.sorted(by: { $0.time < $1.time }) {
                try Task.checkCancellation()
                guard await isCurrent() else { return }
                guard let track = saved.track, !track.isHD,
                      let event = requested.first(where: {
                          $0.time == saved.time && $0.fighterKey == saved.fighterKey && StrikeStatsSummary.strikeFamily.contains($0.action)
                      }) else { continue }
                log("Finding HD outline at \(event.time.formatted(.number.precision(.fractionLength(2)))) s…")
                do {
                    guard let refined = try await find(url: video.url, track: track) else {
                        throw Failure(message: noOutline)
                    }
                    try Task.checkCancellation()
                    guard await isCurrent() else { return }
                    let record = StrikeHighlightRecord(videoID: video.id, time: event.time, fighterKey: event.fighterKey, track: refined)
                    guard try await database.saveStrikeHighlights(videoID: video.id, [record], generation: state.generation,
                                                                  expectedEvent: event) else {
                        throw Failure(message: "The action changed while its HD highlight was being made. Try again.")
                    }
                    savedCount += 1
                    await didSave()
                } catch {
                    try Task.checkCancellation()
                    guard await isCurrent() else { return }
                    failures += 1
                    ErrorLog.record("HD strike highlight", error.localizedDescription)
                    log("\(event.time.formatted(.number.precision(.fractionLength(2)))) s: \(error.localizedDescription)")
                }
            }
            log("HD saved for \(savedCount) strike(s).")
            if failures > 0 {
                throw Failure(message: "\(noOutline) (\(failures) failed; \(savedCount) saved). See the job log for details.")
            }
        }
    }
}
