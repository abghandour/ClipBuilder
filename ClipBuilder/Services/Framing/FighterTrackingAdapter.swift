import CoreGraphics
import Foundation

/// Fight identity selection is independent of podcast tiles and speaker turns.
nonisolated enum FighterTrackingAdapter {
    struct Body: Sendable {
        var box: CGRect
        var appearance: AppearanceSignature?
    }

    struct Selection: Sendable {
        var box: CGRect
        var matchedVIP: Bool
    }

    struct Tracker: Sendable {
        var portraits: [AppearanceSignature]
        var hasVIP: Bool
        private var wideUntil: Double? = nil
        private var previous: CGRect? = nil

        init(portraits: [AppearanceSignature], hasVIP: Bool) {
            self.portraits = portraits
            self.hasVIP = hasVIP
        }

        mutating func select(_ bodies: [Body], at time: Double) -> Selection {
            let largest = bodies.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }.prefix(2)
            let wide = largest.reduce(CGRect.null) { $0.union($1.box) }
            let fallback = wide.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : wide
            guard hasVIP else { return Selection(box: fallback, matchedVIP: false) }
            if let until = wideUntil, time < until { return Selection(box: fallback, matchedVIP: false) }
            let matches = bodies.compactMap { body -> (Body, Double)? in
                guard let signature = body.appearance,
                      let distance = portraits.map({ AppearanceSignature.distance($0, signature) }).min(), distance <= 0.85 else { return nil }
                return (body, distance)
            }.sorted { lhs, rhs in
                if abs(lhs.1 - rhs.1) > 0.01 { return lhs.1 < rhs.1 }
                guard let previous else { return lhs.0.box.minX < rhs.0.box.minX }
                return hypot(lhs.0.box.midX - previous.midX, lhs.0.box.midY - previous.midY)
                    < hypot(rhs.0.box.midX - previous.midX, rhs.0.box.midY - previous.midY)
            }
            if let match = matches.first {
                previous = match.0.box
                wideUntil = nil
                return Selection(box: match.0.box, matchedVIP: true)
            }
            if wideUntil == nil { wideUntil = time + 2 }
            return Selection(box: fallback, matchedVIP: false)
        }
    }

    /// A camera may widen beyond the canvas aspect to retain both fighters; Fit owns the bars.
    static func containing(camera: CGRect, subjects: [CGRect], region: FreeCropRect? = nil) -> CGRect {
        let window = subjects.reduce(camera) { $0.union($1) }
        let bounds = region.map(FocusFrame.rect) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = window.intersection(bounds)
        return clipped.isNull ? bounds : clipped
    }

    static func portraits(source: URL, roster: [VideoPersonRecord], duration: Double) async -> [Data] {
        let markers = roster.filter(\.isVIP).compactMap { person -> PersonMarker? in
            guard let box = person.portraitBox else { return nil }
            return PersonMarker(id: person.personID, videoID: person.videoID, atTime: person.portraitAt,
                x: box.x, y: box.y, width: box.w, height: box.h, personID: person.personID)
        }
        return await Analyzer.markerPortraits(url: source, markers: markers, duration: duration)
    }

    static func cameraPath(source: URL, start: Double, duration: Double, roster: [VideoPersonRecord],
                           region: FreeCropRect? = nil, pullBack: Double = 0, aspect: Double,
                           service: CenterStageService = CenterStageService()) async throws -> [CameraPathKeyframe] {
        let portraits = await Self.portraits(source: source, roster: roster, duration: start + duration)
        var tuning = CenterStageService.Tuning.fastAction
        tuning.minCropHeightFraction += (1 - tuning.minCropHeightFraction) * min(1, max(0, pullBack))
        let result = try await service.cameraPath(source: source, start: start, duration: duration,
            focusPortraits: portraits, tuning: tuning, aspect: aspect,
            fighterFocus: true, fighterHasVIP: roster.contains(where: \.isVIP), fighterRegion: region)
        return result.keyframes
    }

    /// Replay the same camera path as the multitrack graph, retaining wide action windows for Fit.
    static func replay(source: URL, start: Double, duration: Double, path: [CameraPathKeyframe],
                       plan: FramingPlan, output: URL) async throws {
        let area = ScreenCropArea(name: "Fight", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 1, y: 1), .init(x: 0, y: 1)])
        let filter = AreaFramer.pathFilter(keyframes: path, source: .zero, area: area, namespace: "fight", framingPlan: plan)
        try await FFmpeg.run(["-y", "-ss", String(start), "-t", String(duration), "-i", source.path,
            "-filter_complex", "[0:v]setpts=PTS-STARTPTS," + filter + "[vout]", "-map", "[vout]", "-map", "0:a?",
            "-t", String(duration)] + FFmpeg.encodeArgs + [output.path], timeout: 600)
    }

}
