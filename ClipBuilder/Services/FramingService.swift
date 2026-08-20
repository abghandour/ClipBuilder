import AVFoundation
import Foundation
import Vision

/// Framing Detection: the optional third analyze pass, for footage that is
/// not already 9:16. Every scene of the video gets its exact 9:16 framing —
/// a single static rectangle by default, or a moving Center Stage camera
/// path — with the user's framing hints honored as hard picks. Optionally
/// each scene is also tagged with who sits inside that framing
/// (`framed:<personKey>`), so scenes can later be filtered by the people
/// actually in frame, not just in the scene. Scenes the pass can't frame
/// (nobody detected, no hint) keep no path and render letterboxed.
enum FramingService {
    /// Camera choice meaning "one fixed rect per scene" (the default);
    /// any other value is a CenterStageService tuning preset name.
    static let staticCamera = "static"

    struct Summary: Sendable {
        var framed = 0
        var skipped = 0
    }

    /// One sampled moment of a scene: the detected people (normalized,
    /// top-left origin), an appearance signature per box for identity
    /// matching, and the union box for static framing.
    struct SceneSample: Sendable {
        var time: Double                              // scene-relative
        var boxes: [CGRect]
        var signatures: [AppearanceSignature?]
        var union: CGRect
    }

    /// A roster person's appearance references, built from their user-drawn
    /// marker portraits — the same ground truth the live tracker matches on.
    struct PersonSignature: Sendable {
        var key: String
        var signatures: [AppearanceSignature]
    }

    /// Run the pass over every non-excluded scene of `video`. Local only —
    /// Vision + the Center Stage tracker, no AI cost.
    static func detectFraming(video: VideoRecord,
                              database: Database,
                              camera: String,
                              tagFramedPeople: Bool,
                              log: @escaping @Sendable (String) -> Void,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> Summary {
        let scenes = try await database.fetchScenes(videoID: video.id, includeExcluded: false)
        guard !scenes.isEmpty else {
            log("Framing: no scenes yet — run tag detection first")
            return Summary()
        }
        let hints = (try? await database.centerStageHints(videoID: video.id)) ?? []
        let size = CGSize(width: max(1, video.width), height: max(1, video.height))
        let people = tagFramedPeople ? await personSignatures(video: video, database: database) : []
        if tagFramedPeople, people.isEmpty {
            log("Framing: no named person markers — framed: tags fall back to the everyone-fits check")
        }

        // Identity-aware tracking for the moving camera: the user's person
        // markers keep the camera on the named people, never referees/staff.
        var focusPortraits: [Data] = []
        var avoidPortraits: [Data] = []
        if camera != staticCamera {
            let markers = (try? await database.personMarkers(videoID: video.id)) ?? []
            let named = markers.filter { $0.personID != nil && !$0.ignored }
            let ignored = markers.filter(\.ignored)
            focusPortraits = named.isEmpty ? []
                : await Analyzer.markerPortraits(url: video.url, markers: named,
                                                 duration: video.duration)
            avoidPortraits = ignored.isEmpty ? []
                : await Analyzer.markerPortraits(url: video.url, markers: ignored,
                                                 duration: video.duration)
        }

        let centerStage = CenterStageService()
        var summary = Summary()
        for (index, scene) in scenes.enumerated() {
            try Task.checkCancellation()
            progress?(Double(index) / Double(scenes.count))

            // People at three sample moments: the static rect's subject, and
            // the "who sits inside the framing" evidence for framed: tags.
            let samples = await sampleFrames(url: video.url, scene: scene)
            let sceneHints = hints
                .filter { $0.atTime >= scene.startTime - 0.25 && $0.atTime <= scene.endTime + 0.25 }

            let path: SceneCameraPath?
            if camera == staticCamera {
                path = staticPath(scene: scene, samples: samples,
                                  hints: sceneHints, size: size)
            } else {
                path = await trackedPath(video: video, scene: scene,
                                         hints: sceneHints, camera: camera,
                                         focusPortraits: focusPortraits,
                                         avoidPortraits: avoidPortraits,
                                         centerStage: centerStage, log: log)
            }

            guard let path,
                  let data = try? JSONEncoder().encode(path),
                  let json = String(data: data, encoding: .utf8) else {
                summary.skipped += 1
                continue
            }
            try? await database.setSceneCenterStagePath(scene.id, json: json)
            summary.framed += 1

            if tagFramedPeople {
                try? await database.removeSceneTags(sceneID: scene.id, withPrefix: "framed:")
                for key in framedKeys(scene: scene, samples: samples, path: path, people: people) {
                    try? await database.addSceneTag(sceneID: scene.id, tag: "framed:\(key)")
                }
            }
        }
        progress?(1)
        log("Framing: \(summary.framed) scene(s) framed"
            + (summary.skipped > 0 ? ", \(summary.skipped) left letterboxed (nobody to frame)" : ""))
        return summary
    }

    /// Recompute one scene's static framing — hint edits refresh the stored
    /// rect through this without a full pass.
    static func staticScenePath(video: VideoRecord, scene: SceneRecord,
                                hints: [CameraHint]) async -> SceneCameraPath? {
        let samples = await sampleFrames(url: video.url, scene: scene)
        let sceneHints = hints
            .filter { $0.atTime >= scene.startTime - 0.25 && $0.atTime <= scene.endTime + 0.25 }
        return staticPath(scene: scene, samples: samples, hints: sceneHints,
                          size: CGSize(width: max(1, video.width), height: max(1, video.height)))
    }

    /// Refresh one scene's framed: tags after its path changed (hint edits,
    /// recomputes) — the framing moved, so who is inside it may have too.
    static func retagFramedPeople(video: VideoRecord, scene: SceneRecord,
                                  path: SceneCameraPath, database: Database,
                                  people: [PersonSignature]) async {
        let samples = await sampleFrames(url: video.url, scene: scene)
        try? await database.removeSceneTags(sceneID: scene.id, withPrefix: "framed:")
        for key in framedKeys(scene: scene, samples: samples, path: path, people: people) {
            try? await database.addSceneTag(sceneID: scene.id, tag: "framed:\(key)")
        }
    }

    // MARK: - Identity references

    /// Appearance references per roster person, from their named (and not
    /// ignored) marker portraits. Several markers per person = several
    /// references; a detection matches on its best one.
    static func personSignatures(video: VideoRecord,
                                 database: Database) async -> [PersonSignature] {
        let markers = (try? await database.personMarkers(videoID: video.id)) ?? []
        let named = markers.filter { $0.personID != nil && !$0.ignored }
        guard !named.isEmpty else { return [] }
        let people = (try? await database.fetchPeople()) ?? []
        let keyByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.key) })
        var byKey: [String: [AppearanceSignature]] = [:]
        for marker in named {
            guard let personID = marker.personID, let key = keyByID[personID] else { continue }
            let at = min(max(0, marker.atTime), max(0, video.duration - 0.1))
            guard let frame = await ThumbnailService.jpegFrame(url: video.url, at: at),
                  let portrait = Analyzer.markerPortrait(from: frame, marker: marker),
                  let signature = AppearanceSignature(jpeg: portrait) else { continue }
            byKey[key, default: []].append(signature)
        }
        return byKey.map { PersonSignature(key: $0.key, signatures: $0.value) }
    }

    // MARK: - Static framing

    /// The still-frame rect for one scene: a hint inside the scene wins
    /// verbatim (nearest to the middle when there are several); otherwise
    /// the 9:16 crop around everyone detected across the sampled frames.
    /// Two identical keyframes so the stored path plays anywhere a moving
    /// one does.
    private static func staticPath(scene: SceneRecord,
                                   samples: [SceneSample],
                                   hints: [CameraHint],
                                   size: CGSize) -> SceneCameraPath? {
        let rect: CGRect
        if let hint = hints.min(by: {
            abs($0.atTime - (scene.startTime + scene.endTime) / 2)
                < abs($1.atTime - (scene.startTime + scene.endTime) / 2)
        }) {
            rect = CenterStageService.hintCrop(
                CGRect(x: hint.x, y: hint.y, width: hint.width, height: hint.height),
                size: size)
        } else {
            guard let first = samples.first?.union else { return nil }
            let union = samples.dropFirst().reduce(first) { $0.union($1.union) }
            rect = CenterStageService.desiredCrop(forUnion: union, size: size,
                                                  tuning: .balanced)
        }
        let normalized = CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                                width: rect.width / size.width, height: rect.height / size.height)
        let keyframe = CameraPathKeyframe(t: 0, x: normalized.minX, y: normalized.minY,
                                          w: normalized.width, h: normalized.height)
        var last = keyframe
        last.t = max(scene.duration, 0.1)
        return SceneCameraPath(camera: staticCamera, keyframes: [keyframe, last])
    }

    // MARK: - Moving framing

    private static func trackedPath(video: VideoRecord, scene: SceneRecord,
                                    hints: [CameraHint], camera: String,
                                    focusPortraits: [Data], avoidPortraits: [Data],
                                    centerStage: CenterStageService,
                                    log: @escaping @Sendable (String) -> Void) async -> SceneCameraPath? {
        let clipHints = hints.map { hint in
            (time: min(max(0, hint.atTime - scene.startTime), scene.duration),
             crop: CGRect(x: hint.x, y: hint.y, width: hint.width, height: hint.height))
        }
        guard let result = try? await centerStage.cameraPath(
                source: video.url, start: scene.startTime, duration: scene.duration,
                focusPortraits: focusPortraits, avoidPortraits: avoidPortraits,
                hints: clipHints, tuning: .named(camera)),
              result.keyframes.count >= 2 else { return nil }
        // Nobody on screen means the camera would frame guesswork — leave
        // the scene letterboxed instead (unless the user pinned a hint).
        guard result.trackedShare >= 0.1 || !clipHints.isEmpty else {
            log(String(format: "Framing: skipped %.0fs–%.0fs (people visible in only %.0f%%)",
                       scene.startTime, scene.endTime, result.trackedShare * 100))
            return nil
        }
        return SceneCameraPath(camera: camera, keyframes: result.keyframes)
    }

    // MARK: - Who is inside the framing

    /// People detections (normalized, top-left origin) at three moments of
    /// the scene — same peripheral-people filter as portrait fit — plus an
    /// appearance signature per box for identity matching.
    private static func sampleFrames(url: URL, scene: SceneRecord) async -> [SceneSample] {
        var samples: [SceneSample] = []
        for fraction in [0.25, 0.5, 0.75] {
            let time = scene.startTime + scene.duration * fraction
            guard let data = await ThumbnailService.jpegFrame(url: url, at: time,
                                                              maxDimension: 720),
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { continue }
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? VNImageRequestHandler(data: data).perform([request])
            let boxes = Analyzer.primaryPeopleBoxes((request.results ?? []).map { observation in
                let box = observation.boundingBox
                return CGRect(x: box.minX, y: 1 - box.maxY,
                              width: box.width, height: box.height)
            })
            guard let first = boxes.first else { continue }
            samples.append(SceneSample(
                time: time - scene.startTime,
                boxes: boxes,
                signatures: boxes.map { AppearanceSignature(cgImage: cg, normalizedRect: $0) },
                union: boxes.dropFirst().reduce(first) { $0.union($1) }))
        }
        return samples
    }

    /// The scene's people that sit inside the framing. Identity-matched per
    /// person: their best-matching detection (appearance distance ≤ 0.85,
    /// same threshold the live tracker uses) must be mostly inside the crop
    /// in a majority of the samples where they're detected. People with no
    /// appearance references fall back to the everyone-fits union check.
    private static func framedKeys(scene: SceneRecord, samples: [SceneSample],
                                   path: SceneCameraPath,
                                   people: [PersonSignature]) -> Set<String> {
        let personKeys = scene.tags.filter { $0.hasPrefix("person:") }
            .map { String($0.dropFirst("person:".count)) }
        guard !personKeys.isEmpty, !samples.isEmpty else { return [] }
        let referencesByKey = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.signatures) })
        var framed = Set<String>()
        for key in personKeys {
            if let references = referencesByKey[key], !references.isEmpty {
                var matched = 0, inside = 0
                for sample in samples {
                    guard let box = bestMatch(references: references, sample: sample),
                          let crop = CenterStageService.interpolated(path.keyframes,
                                                                     at: sample.time) else { continue }
                    matched += 1
                    if mostlyInside(box, crop: crop) { inside += 1 }
                }
                if matched > 0, inside * 2 >= matched { framed.insert(key) }
            } else if everyoneFits(samples: samples, path: path) {
                framed.insert(key)
            }
        }
        return framed
    }

    /// The detection best matching a person's references, if any is within
    /// the appearance threshold.
    private static func bestMatch(references: [AppearanceSignature],
                                  sample: SceneSample) -> CGRect? {
        var best: (distance: Double, box: CGRect)?
        for (box, signature) in zip(sample.boxes, sample.signatures) {
            guard let signature else { continue }
            let distance = references.map { AppearanceSignature.distance($0, signature) }
                .min() ?? .infinity
            if distance <= 0.85, distance < (best?.distance ?? .infinity) {
                best = (distance, box)
            }
        }
        return best?.box
    }

    /// At least 70% of the person's box area must sit inside the crop —
    /// someone half cut off by the framing doesn't count as framed.
    private static func mostlyInside(_ box: CGRect, crop: CameraPathKeyframe) -> Bool {
        let rect = CGRect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)
        let overlap = rect.intersection(box)
        guard !overlap.isEmpty, box.width > 0, box.height > 0 else { return false }
        return (overlap.width * overlap.height) / (box.width * box.height) >= 0.7
    }

    /// Identity-blind fallback: the union of everyone detected must sit
    /// inside the crop (5% slack per edge) in a majority of samples.
    private static func everyoneFits(samples: [SceneSample],
                                     path: SceneCameraPath) -> Bool {
        guard !samples.isEmpty else { return false }
        var fits = 0
        for sample in samples {
            guard let crop = CenterStageService.interpolated(path.keyframes,
                                                             at: sample.time) else { continue }
            let rect = CGRect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)
                .insetBy(dx: -crop.w * 0.05, dy: -crop.h * 0.05)
            if rect.contains(sample.union) { fits += 1 }
        }
        return fits * 2 >= samples.count
    }
}
