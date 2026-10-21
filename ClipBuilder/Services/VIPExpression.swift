import AVFoundation
import CoreVideo
import Foundation
import Vision

nonisolated enum VIPExpression {
    struct Track: Sendable {
        var tile: Int
        var samples: [(time: Double, score: Double)]
    }

    /// Decode only this source span, at most 640 px on either side. Keep one
    /// patch per VIP feed and about eight scores per second, never frame images.
    /// Decode failure is optional evidence: the caller uses even spacing.
    @concurrent
    static func measure(url: URL, tiles: [PodcastTile], roster: [VideoPersonRecord],
                        start: Double, duration: Double, cache: FeedPathCache = .shared,
                        log: @escaping @Sendable (String) -> Void = { _ in }) async -> [Track] {
        var vipTiles = VIPRecipePlanning.tiles(tiles, roster: roster)
        guard !vipTiles.isEmpty, start.isFinite, start >= 0, duration.isFinite, duration > 0 else { return [] }
        var cachedTracks: [Track] = []
        for tile in vipTiles {
            guard !Task.isCancelled else { return [] }
            let picture = tile.picture
            let region = CenterStageService.validRegion(FreeCropRect(xFrac: picture.x, yFrac: picture.y,
                wFrac: picture.w, hFrac: picture.h))
            if let cached = await cache.covering(source: url, region: region, start: start, duration: duration),
               !cached.path.samples.isEmpty {
                let samples = cached.path.samples.compactMap { sample -> (time: Double, score: Double)? in
                    let time = cached.identity.start + sample.time
                    guard time >= start, time < start + duration, let score = sample.expression else { return nil }
                    return (time, score)
                }
                cachedTracks.append(Track(tile: tile.index, samples: VIPExpressionScore.normalized(samples)))
            }
        }
        let cachedTiles = Set(cachedTracks.map(\.tile))
        vipTiles.removeAll { cachedTiles.contains($0.index) }
        if !cachedTracks.isEmpty { log("VIP expressions: cached feed face boxes and motion samples; feeds=\(cachedTracks.count); decode=0") }
        guard !vipTiles.isEmpty else { return cachedTracks }
        do {
            log("Decode: VIP expression motion for \(vipTiles.count) uncached feed(s)")
            let permit = try await MediaWorkScheduler.current.acquire(.decoding)
            defer { withExtendedLifetime(permit) {} }
            let asset = try await DriveLocalAsset.make(url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
            let size = try await track.load(.naturalSize)
            let rate = Double(try await track.load(.nominalFrameRate))
            let transform = try await track.load(.preferredTransform)
            let orientation = VisualSpeechActivity.displayOrientation(of: transform)
            let scale = min(1, 640 / max(1, abs(size.width), abs(size.height)))
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: max(2, Int((abs(size.width) * scale).rounded())),
                kCVPixelBufferHeightKey as String: max(2, Int((abs(size.height) * scale).rounded())),
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }
            defer { reader.cancelReading() }
            let step = rate > 0 ? max(1 / rate, 1 / VisualSpeechActivity.targetFPS) : 1 / VisualSpeechActivity.targetFPS
            var nextSample = start, nextFaces = start
            var previous: [Int: [Float]] = [:]
            var tracks = vipTiles.map { Track(tile: $0.index, samples: []) }
            var faces: [Int: CGRect] = [:]
            for tile in vipTiles {
                if let box = roster.first(where: { $0.key == tile.personKey })?.portraitBox {
                    faces[tile.index] = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
                }
            }
            let request = DetectFaceRectanglesRequest(.revision3)
            while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time >= start, time < start + duration else { continue }
                guard time + 1e-6 >= nextSample else { continue }
                nextSample = time + step
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                if time >= nextFaces {
                    nextFaces = time + VisualSpeechActivity.faceRefreshSeconds
                    let permit = try await MediaWorkScheduler.current.acquire(.vision)
                    let detected = (try? await request.perform(on: buffer, orientation: orientation)) ?? []
                    withExtendedLifetime(permit) {}
                    var largest: [Int: CGRect] = [:]
                    for face in detected {
                        let rect = face.boundingBox.cgRect
                        let box = CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
                        guard let tile = vipTiles.first(where: { $0.contains(x: box.midX, y: box.midY) }) else { continue }
                        if let old = largest[tile.index], old.width * old.height >= box.width * box.height { continue }
                        largest[tile.index] = box
                    }
                    for (tile, box) in largest {
                        // Moving the sampling rectangle is not expressive motion.
                        if faces[tile] != box { previous[tile] = nil }
                        faces[tile] = box
                    }
                }
                for (index, tile) in vipTiles.enumerated() {
                    let face = faces[tile.index]
                    let region = face.map {
                        CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height * 0.6)
                    } ?? CGRect(x: tile.x + tile.w / 3, y: tile.y + tile.h / 3, width: tile.w / 3, height: tile.h / 3)
                    // Vision/roster boxes are upright; the reader's pixels are encoded orientation.
                    let encoded: CGRect
                    switch orientation {
                    case .right:
                        encoded = CGRect(x: region.minY, y: 1 - region.maxX, width: region.height, height: region.width)
                    case .left:
                        encoded = CGRect(x: 1 - region.maxY, y: region.minX, width: region.height, height: region.width)
                    case .down:
                        encoded = CGRect(x: 1 - region.maxX, y: 1 - region.maxY, width: region.width, height: region.height)
                    default: encoded = region
                    }
                    guard let patch = VisualSpeechActivity.luminancePatch(buffer, region: encoded) else { continue }
                    if let last = previous[tile.index] {
                        tracks[index].samples.append((time, VIPExpressionScore.change(patch, from: last)))
                    }
                    previous[tile.index] = patch
                }
            }
            guard reader.status == .completed, !Task.isCancelled else { return [] }
            return cachedTracks + tracks.map { Track(tile: $0.tile, samples: VIPExpressionScore.normalized($0.samples)) }
        } catch {
            return Task.isCancelled ? [] : cachedTracks
        }
    }

    static func peaks(_ track: Track, minimumGap: Double = 4) -> [Double] {
        VIPExpressionScore.peaks(track.samples, minimumGap: minimumGap)
    }

    /// Preserve score priority across feeds before passing the schedule's
    /// compact (time, tile) inputs. Ties are deterministic.
    static func rankedPeaks(_ tracks: [Track]) -> [(time: Double, tile: Int)] {
        let candidates = tracks.flatMap { track in
            let times = Set(peaks(track))
            return track.samples.filter { times.contains($0.time) }.map {
                (time: $0.time, tile: track.tile, score: $0.score)
            }
        }
        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.time == $1.time ? $0.tile < $1.tile : $0.time < $1.time
        }.map { (time: $0.time, tile: $0.tile) }
    }
}
