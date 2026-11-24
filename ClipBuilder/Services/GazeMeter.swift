import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Departures from the person's usual pose in a clip, not from the lens.
nonisolated enum GazeMeter {
    static let version = "1"

    struct Sample: Codable, Sendable, Equatable {
        var time: Double
        var yaw: Double
        var pitch: Double
        var pupilX: Double?
        var pupilY: Double?
        var faceWidth: Double
    }

    struct Span: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case down, aside, turned
        }
        var start: Double
        var end: Double
        var kind: Kind
    }

    struct Tuning: Sendable {
        var minimumSamples = 8
        var yawThreshold = 18.0
        var pitchThreshold = 14.0
        var downThreshold = 0.35
        var asideThreshold = 0.22
        var minimumFaceWidth = 120.0
        var minimumSpan = 0.6
    }

    enum MeasurementError: LocalizedError {
        case invalidRange, invalidRegion, timeBudgetExceeded

        var errorDescription: String? {
            switch self {
            case .invalidRange: "invalid range or sample rate"
            case .invalidRegion: "empty source region"
            case .timeBudgetExceeded: "time budget exceeded"
            }
        }
    }

    static func spans(_ samples: [Sample], tuning: Tuning = .init()) -> [Span] {
        let samples = samples.filter { $0.time.isFinite && $0.yaw.isFinite && $0.pitch.isFinite }
            .sorted { $0.time < $1.time }
        guard samples.count >= max(2, tuning.minimumSamples) else { return [] }
        let intervals = zip(samples, samples.dropFirst()).map { $1.time - $0.time }.filter { $0 > 0 }
        guard let interval = median(intervals), interval > 0,
              let yaw = median(samples.map(\.yaw)), let pitch = median(samples.map(\.pitch)) else { return [] }
        // A small face's noisy pupils must not shift the usable faces' baseline.
        let pupils = samples.filter { $0.faceWidth >= tuning.minimumFaceWidth }
        let pupilX = median(pupils.compactMap(\.pupilX))
        let pupilY = median(pupils.compactMap(\.pupilY))
        let kinds: [Span.Kind?] = samples.map { sample in
            if abs(sample.yaw - yaw) >= tuning.yawThreshold || abs(sample.pitch - pitch) >= tuning.pitchThreshold {
                return .turned
            }
            guard sample.faceWidth >= tuning.minimumFaceWidth else { return nil }
            if let value = sample.pupilY, let pupilY, value - pupilY <= -tuning.downThreshold { return .down }
            if let value = sample.pupilX, let pupilX, abs(value - pupilX) >= tuning.asideThreshold { return .aside }
            return nil
        }
        var result: [Span] = []
        var run: [Int] = []
        func finish() {
            guard let first = run.first, let last = run.last else { return }
            let end = samples[last].time + interval
            if end - samples[first].time + 1e-9 >= tuning.minimumSpan {
                // Stable tie break: pose, then down, then aside. Neutral gap
                // samples extend a span but do not vote for its kind.
                let priority: [Span.Kind] = [.turned, .down, .aside]
                let kind = priority.max { lhs, rhs in
                    run.count { kinds[$0] == lhs } < run.count { kinds[$0] == rhs }
                } ?? .turned
                result.append(Span(start: samples[first].time, end: end, kind: kind))
            }
            run.removeAll(keepingCapacity: true)
        }
        for index in samples.indices where kinds[index] != nil {
            if let last = run.last,
               index - last > 2 || samples[index].time - samples[last].time > 2 * interval + 1e-9 {
                finish()
            }
            run.append(index)
        }
        finish()
        return result
    }

    /// Union coverage, so overlapping spans never count a source second twice.
    static func share(_ spans: [Span], of range: ClosedRange<Double>) -> Double {
        let duration = range.upperBound - range.lowerBound
        guard duration.isFinite, duration > 0 else { return 0 }
        let clipped = spans.compactMap { span -> ClosedRange<Double>? in
            let start = max(range.lowerBound, span.start), end = min(range.upperBound, span.end)
            return start.isFinite && end.isFinite && end > start ? start...end : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var covered = 0.0, end = range.lowerBound
        for span in clipped {
            covered += max(0, span.upperBound - max(end, span.lowerBound))
            end = max(end, span.upperBound)
        }
        return min(1, max(0, covered / duration))
    }

    static func pupilOffset(eye: [CGPoint], pupil: [CGPoint]) -> CGPoint? {
        guard !eye.isEmpty, !pupil.isEmpty,
              (eye + pupil).allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let minX = eye.map(\.x).min(), let maxX = eye.map(\.x).max(),
              let minY = eye.map(\.y).min(), let maxY = eye.map(\.y).max(),
              maxX > minX, maxY > minY else { return nil }
        let x = pupil.map(\.x).reduce(0, +) / Double(pupil.count)
        let y = pupil.map(\.y).reduce(0, +) / Double(pupil.count)
        return CGPoint(x: 2 * (x - minX) / (maxX - minX) - 1,
                       y: 2 * (y - minY) / (maxY - minY) - 1)
    }

    private static func median(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    /// Source seconds, upright frames, and top-left fractional source regions.
    /// Explicit concurrency keeps decoding and Vision off the caller's actor.
    @concurrent static func measure(url: URL, range: ClosedRange<Double>,
                                    region: FreeCropRect? = nil, fps: Double = 5) async throws -> [Sample] {
        try Task.checkCancellation()
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound >= 0,
              fps.isFinite, fps > 0 else { throw MeasurementError.invalidRange }
        guard range.upperBound > range.lowerBound else { return [] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        let rectangles = DetectFaceRectanglesRequest(.revision3)
        var result: [Sample] = []
        var index = 0
        while true {
            try Task.checkCancellation()
            let time = range.lowerBound + Double(index) / fps
            guard time < range.upperBound else { break }
            index += 1
            let decoded = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
            try Task.checkCancellation()
            let image: CGImage
            if let region {
                guard [region.xFrac, region.yFrac, region.wFrac, region.hFrac].allSatisfy({ $0.isFinite }),
                      region.wFrac > 0, region.hFrac > 0 else { throw MeasurementError.invalidRegion }
                let bounds = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
                let rect = CGRect(x: region.xFrac * Double(decoded.width), y: region.yFrac * Double(decoded.height),
                                  width: region.wFrac * Double(decoded.width), height: region.hFrac * Double(decoded.height))
                    .intersection(bounds)
                guard !rect.isEmpty, let cropped = decoded.cropping(to: rect) else { throw MeasurementError.invalidRegion }
                image = cropped
            } else {
                image = decoded
            }
            let permit = try await MediaWorkScheduler.current.acquire(.vision)
            defer { withExtendedLifetime(permit) {} }
            let faces = try await rectangles.perform(on: image)
            try Task.checkCancellation()
            guard let face = faces.max(by: {
                let a = $0.boundingBox.cgRect, b = $1.boundingBox.cgRect
                return a.width * a.height < b.width * b.height
            }) else { continue }
            var landmarks = DetectFaceLandmarksRequest(.revision3)
            landmarks.inputFaceObservations = [face]
            let observations = try await landmarks.perform(on: image)
            try Task.checkCancellation()
            var offsets: [CGPoint] = []
            if let eyes = observations.first?.landmarks {
                if let left = pupilOffset(eye: eyes.leftEye.points.map { CGPoint(x: $0.x, y: $0.y) },
                                          pupil: eyes.leftPupil.points.map { CGPoint(x: $0.x, y: $0.y) }) { offsets.append(left) }
                if let right = pupilOffset(eye: eyes.rightEye.points.map { CGPoint(x: $0.x, y: $0.y) },
                                           pupil: eyes.rightPupil.points.map { CGPoint(x: $0.x, y: $0.y) }) { offsets.append(right) }
            }
            result.append(Sample(time: time, yaw: face.yaw.converted(to: .degrees).value,
                pitch: face.pitch.converted(to: .degrees).value,
                pupilX: offsets.isEmpty ? nil : offsets.map(\.x).reduce(0, +) / Double(offsets.count),
                pupilY: offsets.isEmpty ? nil : offsets.map(\.y).reduce(0, +) / Double(offsets.count),
                faceWidth: face.boundingBox.cgRect.width * Double(image.width)))
        }
        return result
    }
}
