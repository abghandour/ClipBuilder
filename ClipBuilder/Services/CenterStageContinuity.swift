import CoreGraphics
import Foundation

/// Bound the whole-picture affine intermediate, independently of source
/// resolution. A normal 4K picture at 2x is 33,177,600 pixels, below this cap.
nonisolated enum ContinuityCameraGrid: String, Sendable {
    case double, single, crop

    static let pixelBudget = 67_108_864.0
    static let maximumScaleRatio = 1.1

    static func choose(path: [CameraPathKeyframe], source: CGSize, box: CGSize) -> Self {
        let path = TrackedPictureBounds.clamped(path)
        guard let width = path.map(\.w).min(), source.width > 0, source.height > 0 else { return .crop }
        for (level, grid) in [(Self.double, 2.0), (.single, 1.0)] {
            let w = max(grid * box.width, (grid * box.width / width).rounded())
            let h = max(grid * box.height, (grid * box.width * source.height / source.width / width).rounded())
            if w * h <= pixelBudget { return level }
        }
        return .crop
    }

    /// Sample uniformly in log(scale), at most a 10% scale ratio per step.
    /// For r <= 1.1, linear width vs harmonic width differs by at most
    /// (r - 1)^2 / (4r) = 0.228%. Camera aspect is constant on a framing path.
    /// Cuts become duplicate-time knots so dense samples cannot invent cuts.
    static func resampled(_ path: [CameraPathKeyframe]) -> [CameraPathKeyframe] {
        guard let first = path.first else { return [] }
        var result = [first]
        for index in path.indices.dropFirst() {
            let a = path[index - 1], b = path[index]
            if CameraKeyframes.isCut(path, at: index) {
                var held = a
                held.t = b.t
                result.append(held)
            } else if b.t > a.t, a.w > 0, b.w > 0 {
                let logRatio = log(a.w / b.w)
                let steps = max(1, Int(ceil(abs(logRatio) / log(maximumScaleRatio))))
                for step in 1..<steps {
                    let scale = exp(logRatio * Double(step) / Double(steps))
                    let fraction = (scale - 1) / (a.w / b.w - 1)
                    result.append(CenterStageContinuity.transformValue(a, b, fraction: fraction,
                        time: a.t + fraction * (b.t - a.t)))
                }
            }
            result.append(b)
        }
        return result
    }

    /// Keep existing 2x identities byte-for-byte; only degraded routes differ.
    var cacheSuffix: String {
        switch self {
        case .double: ""
        case .single: "-grid-1x-v1"
        case .crop: "-grid-crop-ratio1.1-v1"
        }
    }
}

/// A run uses source seconds. Pause length and playback speed never enter
/// its tracking identity; each member converts the result onto its own clock.
nonisolated enum CenterStageContinuity {
    static let tolerance = 1.0 / 60 + 1e-9

    /// Deterministic tracking evidence for decoded-pixel renderer tests.
    @TaskLocal static var trackingOverride: (@Sendable (URL, Double, Double) async throws -> FeedCameraPath)?
    @TaskLocal static var unionRequestObserver: (@Sendable () -> Void)?
    @TaskLocal static var unionCancellationObserver: (@Sendable () -> Void)?

    nonisolated struct Member: Codable, Sendable {
        var id: UUID
        var sourceStart: Double
        var sourceEnd: Double
    }

    nonisolated struct Run: Codable, Sendable {
        var template: MultitrackRenderer.ResolvedClip
        var members: [Member]
        var start: Double
        var end: Double
        var pieces: [MultitrackRenderer.ResolvedClip]? = nil

        /// Membership after tracking has changed render-only framing fields.
        func containsSourcePiece(_ clip: MultitrackRenderer.ResolvedClip) -> Bool {
            clip.sourcePath == template.sourcePath && clip.track == template.track
                && members.contains { $0.id == clip.continuityClipID
                    && clip.sourceStart >= $0.sourceStart - tolerance
                    && sourceEnd(clip) <= $0.sourceEnd + tolerance }
        }

        func contains(_ clip: MultitrackRenderer.ResolvedClip) -> Bool {
            guard clip.sourcePath == template.sourcePath, clip.track == template.track,
                  sameInputs(clip, template) else { return false }
            return members.contains { $0.id == clip.continuityClipID
                && clip.sourceStart >= $0.sourceStart - tolerance
                && sourceEnd(clip) <= $0.sourceEnd + tolerance }
        }
    }

    nonisolated struct Identity: Codable, Sendable {
        var version = "center-stage-continuity-v3-vip-paths"
        var fingerprint: String
        var start: Double
        var duration: Double
        var area: ScreenCropArea
        var region: FreeCropRect?
        var focus: AreaFocus?
        var plan: FramingPlan?
        var content: FreeCropRect?
        var tuning: String
        var aspect: Double
        var portraits: [Data]?
    }

    static func sourceEnd(_ clip: MultitrackRenderer.ResolvedClip) -> Double {
        clip.sourceStart + (clip.hold ? 0 : clip.duration * clip.speed)
    }

    static func eligible(_ clip: MultitrackRenderer.ResolvedClip, ignoringStoredPaths: Bool = false) -> Bool {
        (clip.centerStage || clip.areaRegion != nil || tracksArea(clip)) && (ignoringStoredPaths || clip.cameraPath == nil)
            && !clip.bumper && clip.role != .cutaway && clip.framingPlan?.isStatic != true
            && clip.areaWindow == nil && clip.staticAreaFilter == nil
            && clip.duration > 0 && clip.sourceStart.isFinite && clip.speed.isFinite && clip.speed > 0
    }

    /// The layout pass also tracks recipes without Center Stage or a feed region.
    static func tracksArea(_ clip: MultitrackRenderer.ResolvedClip) -> Bool {
        prepassArea(clip) != nil && clip.freeCrops?.isEmpty != false
            && clip.areaWindow == nil && clip.framingPlan?.isStatic != true
    }

    // Drawable highlights vary with a preview's source span. They remain in
    // render/cache evidence, but cannot decide camera-run membership.
    static func sameInputs(_ a: MultitrackRenderer.ResolvedClip, _ b: MultitrackRenderer.ResolvedClip) -> Bool {
        a.centerStage == b.centerStage && a.wide == b.wide && a.screenCrop == b.screenCrop
            && a.areaRegion == b.areaRegion && a.areaFocus == b.areaFocus && a.areaWindow == b.areaWindow
            && a.framingPlan == b.framingPlan && a.fitArea == b.fitArea && a.contentWindow == b.contentWindow
            && a.freeCrops == b.freeCrops && a.effectiveCropXFrac == b.effectiveCropXFrac
            && a.effectivePosition == b.effectivePosition && a.fillCanvas == b.fillCanvas
            && (a.continuityLayout ?? .fullScreen) == (b.continuityLayout ?? .fullScreen)
    }

    /// Use the same drawable snapshot for visible pieces and full-document
    /// preview context, before either participates in run membership.
    static func normalizingStrikeHighlights(_ clip: MultitrackRenderer.ResolvedClip,
                                           tracks: [StrikeHighlightRules.Track]) -> MultitrackRenderer.ResolvedClip {
        guard clip.strikeHighlights == true else { return clip }
        var clip = clip
        let showing = StrikeHighlightBurn.tracks(tracks, start: clip.sourceStart, duration: clip.sourceSpan)
        clip.strikeTracks = showing.isEmpty ? nil : showing
        if showing.isEmpty { clip.strikeHighlights = nil }
        return clip
    }

    static func normalizingStrikeHighlights(_ run: Run, tracks: [String: [StrikeHighlightRules.Track]]) -> Run {
        func normalized(_ clip: MultitrackRenderer.ResolvedClip) -> MultitrackRenderer.ResolvedClip {
            guard let sourceTracks = tracks[clip.sourcePath] else { return clip }
            return normalizingStrikeHighlights(clip, tracks: sourceTracks)
        }
        var run = run
        run.template = normalized(run.template)
        run.pieces = run.pieces?.map(normalized)
        return run
    }

    static func runs(_ clips: [MultitrackRenderer.ResolvedClip], ignoringStoredPaths: Bool = false,
                     excluding: Set<UUID> = []) -> [Run] {
        var result: [Run] = []
        for track in Set(clips.map(\.track)).sorted() {
            let ordered = clips.filter { $0.track == track }.sorted {
                ($0.startTime, $0.documentIndex) < ($1.startTime, $1.documentIndex)
            }
            var pending: [MultitrackRenderer.ResolvedClip] = []
            func flush() {
                defer { pending.removeAll(keepingCapacity: true) }
                guard pending.count >= 2, let first = pending.first,
                      pending.contains(where: { !$0.hold }),
                      pending.allSatisfy({ $0.continuityClipID != nil }) else { return }
                // Extending the area route must not change ordinary, unpaused cuts.
                if !first.centerStage && first.areaRegion == nil && !pending.contains(where: \.hold) { return }
                let start = pending.map(\.sourceStart).min() ?? 0
                let end = pending.map(sourceEnd).max() ?? start
                guard end > start else { return }
                result.append(Run(template: first, members: pending.compactMap { clip in
                    clip.continuityClipID.map { Member(id: $0, sourceStart: clip.sourceStart, sourceEnd: sourceEnd(clip)) }
                }, start: start, end: end, pieces: pending))
            }
            for clip in ordered {
                guard eligible(clip, ignoringStoredPaths: ignoringStoredPaths),
                      !(clip.continuityClipID.map { excluding.contains($0) } ?? false) else { flush(); continue }
                if let previous = pending.last,
                   previous.sourcePath != clip.sourcePath || !sameInputs(previous, clip)
                    || abs(previous.startTime + previous.duration - clip.startTime) > tolerance
                    || !(sourceContinuous(previous, clip)
                        || (previous.hold && !clip.hold && pending.last(where: { !$0.hold }).map {
                            sourceContinuous($0, previous)
                        } == true))
                    || (!clip.hold && pending.last(where: { !$0.hold }).map {
                        abs(sourceEnd($0) - clip.sourceStart) > tolerance
                    } == true) {
                    flush()
                }
                pending.append(clip)
            }
            flush()
        }
        return result
    }

    static func sourceContinuous(_ a: MultitrackRenderer.ResolvedClip, _ b: MultitrackRenderer.ResolvedClip) -> Bool {
        if a.hold != b.hold {
            let held = a.hold ? a : b
            let moving = a.hold ? b : a
            return held.sourceStart >= moving.sourceStart - tolerance
                && held.sourceStart <= sourceEnd(moving) + tolerance
        }
        return abs(sourceEnd(a) - b.sourceStart) <= tolerance
    }

    /// Exactly the route selection used by the framing prepasses.
    static func prepassArea(_ clip: MultitrackRenderer.ResolvedClip) -> ScreenCropArea? {
        let fullScreenPath = (clip.hold && clip.centerStage) || clip.framingPlan?.recipe?.fighterFocus == true
            || clip.cameraPath != nil && (clip.continuityLayout?.isFullScreen == true || clip.continuityTransform != nil)
        return clip.framingPlan?.area(forTrack: clip.track) ?? ScreenCropStore.area(reference: clip.screenCrop)
            ?? (clip.areaRegion != nil || fullScreenPath ? area(clip) : nil)
    }

    /// The saved piece's ordinary moving route decides its interpolation.
    /// Ignore only pause routing: splitters still supply rectangle boundary knots.
    static func savedPathUsesTransform(_ clip: MultitrackRenderer.ResolvedClip, sourceSize: CGSize? = nil) -> Bool {
        var moving = clip
        moving.hold = false
        moving.continuityTransform = nil
        return moving.centerStage && prepassArea(moving) == nil
            && storedPathApplies(moving, sourceSize: sourceSize)
    }

    static func pausedSavedPath(_ clip: MultitrackRenderer.ResolvedClip, sourceSize: CGSize? = nil) -> MultitrackRenderer.ResolvedClip {
        var clip = clip
        let transform = savedPathUsesTransform(clip, sourceSize: sourceSize)
        clip.continuityTransform = transform
        clip.continuitySavedTransform = transform ? true : nil
        return clip
    }

    static func storedPathApplies(_ clip: MultitrackRenderer.ResolvedClip, sourceSize: CGSize?) -> Bool {
        // A VIP recipe never replays a path saved in the document; the slice
        // of its own freshly tracked run is not a saved path.
        guard clip.framingPlan?.recipe?.centerStageVIPs != true || clip.continuityRunPath,
              let path = clip.cameraPath, path.count >= 2,
              TrackedPictureBounds.clamped(path).count == path.count else { return false }
        let knownSize = sourceSize ?? clip.framingSourceSize
        let sourceSize = knownSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        if let area = prepassArea(clip) {
            let box = AreaFramer.pixelBounds(of: area)
            guard clip.areaFocus == nil else { return false }
            if clip.framingPlan?.recipe?.fighterFocus == true { return true }
            // Preserve the area route's unknown-size rejection; only the
            // ordinary implicit-canvas route below assumes a 16:9 source.
            guard let sourceSize else { return false }
            return CenterStageService.pathMatchesCanvas(path, sourceSize: sourceSize, canvasAspect: box.width / box.height)
        }
        return CenterStageService.pathMatchesCanvas(path, sourceSize: sourceSize)
    }

    /// Probe only potential multi-piece runs. Single-piece renders retain
    /// their existing prepass order, log lines and cache identities.
    @concurrent
    static func applicableRuns(_ candidates: [Run], sourceSizes: [String: CGSize] = [:]) async -> [Run] {
        var result: [Run] = []
        var sizes = sourceSizes
        for candidate in candidates {
            guard let pieces = candidate.pieces else { result.append(candidate); continue }
            let paused = pieces.contains(where: \.hold)
            var excluded: Set<UUID> = []
            for var clip in pieces where clip.cameraPath != nil {
                // A paused saved path uses the graph even on an implicit
                // canvas. Validate that destination before excluding it;
                // rejected paths must still join the tracked union.
                if sizes[clip.sourcePath] == nil {
                    let size = await FFmpeg.dimensions(of: URL(fileURLWithPath: clip.sourcePath))
                    sizes[clip.sourcePath] = CGSize(width: size.width, height: size.height)
                }
                let size = sizes[clip.sourcePath].flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
                clip.framingSourceSize = size
                if paused { clip = pausedSavedPath(clip, sourceSize: size) }
                // Preserve paused-run filtering's failed-probe behavior: a
                // valid saved path without a focus override stays separate
                // from tracking until the prepass can validate real dimensions.
                // Known sizes still validate the paused and moving routes alike.
                if paused, let probedSize = sizes[clip.sourcePath], probedSize.width <= 0 || probedSize.height <= 0,
                   clip.framingPlan?.recipe?.centerStageVIPs != true,
                   clip.areaFocus == nil,
                   let path = clip.cameraPath, path.count >= 2,
                   TrackedPictureBounds.clamped(path).count == path.count,
                   let id = clip.continuityClipID {
                    excluded.insert(id)
                    continue
                }
                if storedPathApplies(clip, sourceSize: size), let id = clip.continuityClipID {
                    excluded.insert(id)
                }
            }
            result += runs(pieces, ignoringStoredPaths: true, excluding: excluded)
        }
        return result
    }

    static func slice(_ path: [CameraPathKeyframe], runStart: Double,
                      clip: MultitrackRenderer.ResolvedClip, transform: Bool = false) -> [CameraPathKeyframe] {
        let offset = clip.sourceStart - runStart
        if transform {
            return transformSlice(path, from: offset, duration: clip.hold ? 0 : clip.duration * clip.speed,
                holdDuration: clip.hold ? clip.duration : nil)
        }
        if clip.hold {
            return HoldClipRules.cameraPath(CenterStageService.slice(path, from: offset, duration: 0), duration: clip.duration)
        }
        return CenterStageService.slice(path, from: offset, duration: clip.duration * clip.speed)
    }

    /// AVFoundation ramps scale and translation, not crop coordinates. A
    /// boundary inside a zoom therefore has a harmonic width. Reconstructing
    /// this crop gives exactly the same affine transform at the split point.
    static func transformSlice(_ path: [CameraPathKeyframe], from: Double, duration: Double,
                               holdDuration: Double? = nil) -> [CameraPathKeyframe] {
        guard !path.isEmpty, TrackedPictureBounds.clamped(path).count == path.count else { return [] }
        func value(at time: Double) -> CameraPathKeyframe {
            var key = path[0]
            for next in path.dropFirst() {
                if next.t > time {
                    let fraction = max(0, min(1, (time - key.t) / (next.t - key.t)))
                    return transformValue(key, next, fraction: fraction, time: time)
                }
                key = next
            }
            key.t = time
            return key
        }
        var first = value(at: from)
        first.t = 0
        if let holdDuration { return HoldClipRules.cameraPath([first], duration: holdDuration) }
        var result = [first]
        for var key in path where key.t > from && key.t < from + duration {
            key.t -= from
            result.append(key)
        }
        var last = value(at: from + duration)
        last.t = duration
        result.append(last)
        return result
    }

    static func transformValue(_ a: CameraPathKeyframe, _ b: CameraPathKeyframe,
                               fraction: Double, time: Double) -> CameraPathKeyframe {
        let inverseWidth = (1 - fraction) / a.w + fraction / b.w
        return .init(t: time,
            x: ((1 - fraction) * a.x / a.w + fraction * b.x / b.w) / inverseWidth,
            y: ((1 - fraction) * a.y / a.w + fraction * b.y / b.w) / inverseWidth,
            w: 1 / inverseWidth,
            h: ((1 - fraction) * a.h / a.w + fraction * b.h / b.w) / inverseWidth)
    }

    static func area(_ clip: MultitrackRenderer.ResolvedClip) -> ScreenCropArea {
        clip.framingPlan?.area(forTrack: clip.track) ?? ScreenCropStore.area(reference: clip.screenCrop)
            ?? ScreenCropArea(name: CropLayoutRef.fullScreenName,
                points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
    }

    static func tuning(_ clip: MultitrackRenderer.ResolvedClip, defaultCamera: String) -> String {
        if clip.areaRegion != nil {
            return clip.framingPlan?.isSteady == true ? "steady"
                : clip.framingPlan?.sourceWindow == nil ? "conversation" : clip.framingPlan?.camera ?? "conversation"
        }
        return clip.framingPlan?.camera ?? defaultCamera
    }

    static func unsupported(_ clip: MultitrackRenderer.ResolvedClip, tuning: String) -> String? {
        if clip.framingPlan?.recipe?.fighterFocus == true { return "fighter framing requires its per-piece subject plan" }
        if CenterStageService.Tuning.named(tuning).stabilizes { return "camera motion stabilization requires per-piece analysis" }
        if clip.freeCrops?.isEmpty == false || clip.framingPlan?.fit == .blurredFill {
            return "composed framing cannot replay one crop path"
        }
        if let recipe = clip.framingPlan?.recipe, recipe.centerStage != true, !tracksArea(clip) {
            return "this framing recipe cannot replay the tracking path"
        }
        if clip.strikeHighlights == true { return "tracking uses per-piece strike highlights" }
        return nil
    }

    nonisolated struct Outcome: Codable, Sendable {
        var path: FeedCameraPath? = nil
        var failure: String? = nil
        var cacheable: Bool? = nil
    }

    @concurrent
    static func prepare(_ run: Run, defaultCamera: String, service: CenterStageService,
                        cache: RenderSegmentCache, cacheEnabled: Bool, database: Database,
                        reportFailure: (@Sendable (String) -> Void)? = nil,
                        emit: @escaping @Sendable (String) -> Void) async throws -> FeedCameraPath? {
        let clip = run.template
        let camera = tuning(clip, defaultCamera: defaultCamera)
        func fallback(_ reason: String) {
            let line = "Center Stage: pieces framed separately (\(reason))"
            if let reportFailure { reportFailure(line); return }
            emit(line)
            ErrorLog.record("Center Stage", line)
        }
        if let reason = unsupported(clip, tuning: camera) { fallback(reason); return nil }
        do {
            let source = URL(fileURLWithPath: clip.sourcePath)
            let box = AreaFramer.pixelBounds(of: area(clip))
            let portraits = prepassArea(clip) == nil && clip.framingPlan?.recipe?.centerStageVIPs == true
                ? await MultitrackRenderer.vipPortraits(sourcePath: clip.sourcePath,
                    keys: clip.framingPlan?.recipe?.centerStageVIPKeys, database: database) : []
            let identity = Identity(fingerprint: try SourceIdentityCache.shared.fingerprint(of: source),
                start: run.start, duration: run.end - run.start, area: area(clip), region: clip.areaRegion,
                focus: clip.areaFocus, plan: clip.framingPlan, content: clip.contentWindow,
                tuning: camera, aspect: box.width / box.height, portraits: portraits.isEmpty ? nil : portraits)
            let key = try RenderSegmentCache.key(identity)
            let result = try await cache.continuousPath(key: key, cacheEnabled: cacheEnabled) {
                var outcome = try await analyze(run, source: source, camera: camera, portraits: portraits,
                    aspect: box.width / box.height, service: service, emit: emit)
                if try SourceIdentityCache.shared.fingerprint(of: source) != identity.fingerprint {
                    outcome.cacheable = false
                }
                return outcome
            }
            if let reason = result.outcome.failure { fallback(reason); return nil }
            guard let path = result.outcome.path else { return nil }
            if result.reused {
                emit("Center Stage: continuous path cache hit")
            } else {
                emit("Center Stage: one camera path for \(run.members.count) continuous pieces")
            }
            return path
        } catch {
            try Task.checkCancellation()
            fallback(error.localizedDescription)
            return nil
        }
    }

    @concurrent
    private static func analyze(_ run: Run, source: URL, camera: String, portraits: [Data], aspect: Double,
                                service: CenterStageService, perPiece: Bool = false,
                                emit: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let failure = Outcome(failure: "tracking did not produce a reusable crop path")
        var path: FeedCameraPath
        if let trackingOverride {
            path = try await trackingOverride(source, run.start, run.end - run.start)
        } else if let region = run.template.areaRegion {
            path = try await service.cameraPath(source: source, start: run.start, duration: run.end - run.start,
                region: CenterStageService.validRegion(region), tuning: .named(camera), aspect: aspect,
                fallbackCenter: run.template.areaFocus, log: emit)
        } else {
            let tracked = try await service.cameraPath(source: source, start: run.start, duration: run.end - run.start,
                focusPortraits: portraits, tuning: .named(camera), aspect: aspect,
                requireWide: prepassArea(run.template) == nil, matchExport: true)
            // The tracker already knows it found nobody; don't probe source
            // dimensions or construct a reusable path for that failed union.
            guard perPiece || tracked.trackedShare >= 0.1 else { return failure }
            let size = await FFmpeg.dimensions(of: source)
            path = FeedCameraPath(keyframes: tracked.keyframes, samples: [], trackedShare: tracked.trackedShare,
                sourceSize: CGSize(width: size.width, height: size.height), usedFallback: false)
            if perPiece && tracked.trackedShare < 0.1 {
                let window = AreaFramer.fallbackWindow(aspect: aspect, sourceSize: path.sourceSize, center: nil)
                path.keyframes = [0, run.end - run.start].map {
                    .init(t: $0, x: window.xFrac, y: window.yFrac, w: window.wFrac, h: window.hFrac)
                }
                path.usedFallback = true
            }
        }
        if perPiece {
            path.keyframes = TrackedPictureBounds.clamped(path.keyframes, to: run.template.contentWindow ?? FreeCropRect())
            guard path.keyframes.count >= 2 else { return failure }
            return Outcome(path: path, cacheable: path.reusable != false)
        }
        // A decode or analysis hiccup is not a verdict on the footage: fall
        // back this once, and track again on the next render.
        if path.reusable == false {
            return Outcome(failure: "tracking was interrupted", cacheable: false)
        }
        path.keyframes = TrackedPictureBounds.clamped(path.keyframes, to: run.template.contentWindow ?? FreeCropRect())
        guard !path.usedFallback, path.trackedShare >= 0.1, path.keyframes.count >= 2,
              CenterStageService.pathMatchesCanvas(path.keyframes, sourceSize: path.sourceSize, canvasAspect: aspect) else {
            return failure
        }
        try Task.checkCancellation()
        return Outcome(path: path)
    }

    /// A failed union must not send its holds through the one-frame tracker.
    /// Replay each usable neighbour's own path and borrow its boundary for the hold.
    @concurrent
    static func neighbourPaths(_ run: Run, defaultCamera: String, service: CenterStageService,
                               database: Database, cache: RenderSegmentCache, cacheEnabled: Bool,
                               reportFailure: @escaping @Sendable (String) -> Void,
                               emit: @escaping @Sendable (String) -> Void) async throws -> [UUID: FeedCameraPath] {
        let camera = tuning(run.template, defaultCamera: defaultCamera)
        guard run.template.freeCrops?.isEmpty != false,
              run.template.framingPlan?.recipe?.fighterFocus != true,
              let pieces = run.pieces else { return [:] }
        let portraits = prepassArea(run.template) == nil && run.template.framingPlan?.recipe?.centerStageVIPs == true
            ? await MultitrackRenderer.vipPortraits(sourcePath: run.template.sourcePath,
                keys: run.template.framingPlan?.recipe?.centerStageVIPKeys, database: database) : []
        var paths: [UUID: FeedCameraPath] = [:]
        for piece in pieces where !piece.hold {
            guard let id = piece.continuityClipID else { continue }
            var single = Run(template: piece, members: [], start: piece.sourceStart, end: sourceEnd(piece))
            let box = AreaFramer.pixelBounds(of: area(piece))
            var source = URL(fileURLWithPath: piece.sourcePath)
            var burned: URL?
            defer { if let burned { try? FileManager.default.removeItem(at: burned.deletingLastPathComponent()) } }
            do {
                let fingerprint = try SourceIdentityCache.shared.fingerprint(of: source)
                let key = try RenderSegmentCache.key([
                    MultitrackRenderer.prepassKey(piece, area: prepassArea(piece), tuning: camera),
                    RenderSegmentCache.key(portraits)
                ], version: "center-stage-neighbour-v1")
                if cacheEnabled, piece.cacheable, let cached = await cache.readJSON(FeedCameraPath.self, key: key) {
                    paths[id] = cached
                    continue
                }
                if piece.areaRegion == nil, let tracks = piece.strikeTracks {
                    burned = try await StrikeHighlightBurn.burn(source: source, start: piece.sourceStart,
                        duration: piece.sourceSpan, tracks: tracks, scratch: FileManager.default.temporaryDirectory,
                        style: piece.strikeHighlightStyle ?? "outline")
                    if let burned { source = burned; single.start = 0; single.end = piece.sourceSpan }
                }
                let outcome = try await analyze(single, source: source,
                    camera: camera, portraits: portraits, aspect: box.width / box.height, service: service, perPiece: true, emit: emit)
                if let path = outcome.path {
                    paths[id] = path
                    if cacheEnabled, piece.cacheable, path.reusable != false,
                       try SourceIdentityCache.shared.fingerprint(of: URL(fileURLWithPath: piece.sourcePath)) == fingerprint {
                        await cache.storeJSON(path, key: key)
                    }
                }
            } catch {
                try Task.checkCancellation()
                reportFailure("Center Stage: neighbouring path unavailable (\(error.localizedDescription))")
            }
        }
        for (index, piece) in pieces.enumerated() where piece.hold {
            guard let id = piece.continuityClipID,
                  let path = neighbourPath(for: index, pieces: pieces, paths: paths) else { continue }
            paths[id] = path
        }
        return paths
    }

    static func neighbourPath(for index: Int, pieces: [MultitrackRenderer.ResolvedClip],
                              paths: [UUID: FeedCameraPath]) -> FeedCameraPath? {
        let previous = pieces[..<index].last { !$0.hold }
        let next = pieces.dropFirst(index + 1).first { !$0.hold }
        for (piece, last) in [(previous, true), (next, false)] {
            guard let piece, let id = piece.continuityClipID, var path = paths[id], !path.usedFallback,
                  let key = last ? path.keyframes.last : path.keyframes.first else { continue }
            path.keyframes = HoldClipRules.cameraPath([key], duration: pieces[index].duration)
            return path
        }
        return nil
    }

}
