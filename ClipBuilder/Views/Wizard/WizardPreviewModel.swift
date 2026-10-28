import CoreGraphics
import Foundation
import Observation
import OSLog

/// Only visual state participates in invalidation; audio and planning edits do not.
nonisolated struct PreviewKey: Hashable, Sendable {
    var visual: MiniWizardSettings
    var width: Int
    var height: Int
    var safeArea: PlatformSafeAreaSettings
    var sceneID: Int64
    var videoPath: String
    var time: Double
    var profileName: String
    var captions: CaptionStyle
    var captionStyles: [NamedCaptionStyle]?
    var personCaptionStyles: [String: String]?
    var tagStyle: TagStyle?
    var tagStyles: [NamedTagStyle]?
    var logoPath: String
    var profileRenderSettings: RenderSettings
    var contentRevision: Int
    var captionLanguage: String?
    var shownSpeakers: Set<String>
    var captionOrdinals: [String: Int]?
    var look: String
    var lookIntensity: Double?

    init(options: WizardOptions, scene: SceneRecord, profile: BrandProfile,
         contentRevision: Int, overlayTexts: [String], time: Double? = nil,
         shownSpeakers: Set<String> = [], captionOrdinals: [String: Int]? = nil) {
        var visual = MiniWizardSettings()
        visual.preset = options.renderSettings.preset
        visual.captions = options.addCaptions
        visual.englishCaptions = options.captionLanguage == "en"
        visual.captionPosition = options.captionPositionOverride
        visual.speakerCaptionPositions = options.speakerCaptionPositions
        self.shownSpeakers = shownSpeakers
        self.captionOrdinals = captionOrdinals
        visual.captionStyleID = options.captionStyleID
        visual.nameTags = options.usesNameTags
        visual.nameTagContent = options.nameTagContent
        visual.nameTagStyle = options.nameTagStyle
        visual.nameTagStyleID = options.nameTagStyleID
        visual.nameTagPosition = options.nameTagPosition
        visual.safeAreaOnly = options.safeAreaOnly == true
        visual.safeAreaPlatforms = options.safeAreaPlatforms?.map(\.rawValue)
        visual.watermark = options.includeWatermark
        visual.watermarkOverlay = options.watermarkOverlayTemplate
        visual.watermarkOpacity = options.watermarkOpacity
        visual.overlay = options.fixedOverlayTemplate != nil
        visual.overlayTemplate = options.fixedOverlayTemplate
        visual.overlayStart = options.fixedOverlayStart ?? 0
        visual.overlayDuration = options.fixedOverlayDuration
        visual.overlayTexts = overlayTexts
        visual.overlayPosition = options.fixedOverlayPosition
        visual.framing = options.framing ?? Framing.legacy(from: options)
        visual.overlayEdits = options.fixedOverlayEdits ?? OverlayEdits()
        look = options.lookPreset ?? "none"
        lookIntensity = options.lookIntensity
        captionLanguage = options.effectiveCaptionLanguage
        self.visual = visual
        width = options.renderSettings.width
        height = options.renderSettings.height
        safeArea = options.renderSettings.platformSafeArea
        sceneID = scene.id
        videoPath = scene.videoPath
        self.time = time ?? (scene.startTime + scene.endTime) / 2
        profileName = profile.profileName
        captions = profile.captions
        captionStyles = profile.captionStyles
        personCaptionStyles = profile.personCaptionStyles
        tagStyle = profile.tagStyle
        tagStyles = profile.tagStyles
        logoPath = profile.logoPath
        // Encoding quality does not alter a still preview.
        profileRenderSettings = profile.defaultRenderSettings
        profileRenderSettings.quality = .balanced
        profileRenderSettings.customCRF = 20
        self.contentRevision = contentRevision
    }
}

@Observable @MainActor final class WizardPreviewModel {
    private(set) var image: CGImage?
    /// Where the caption, tags and overlay landed in `image`, in canvas pixels.
    private(set) var layout: WizardPreviewComposite.Layout?
    private(set) var isRendering = false
    private(set) var error: String?
    var sceneIndex = 0
    private(set) var scenes: [SceneRecord] = []
    private(set) var scene: WizardPreviewComposite.Scene?
    private(set) var templates: [OverlayTemplate] = []
    private(set) var contentRevision = 0
    private(set) var loadedSceneID: Int64?
    /// The source time the loaded still was taken at.
    private(set) var loadedTime: Double?
    private(set) var isLoadingScene = false
    private(set) var renderCount = 0
    private var sceneNeedsReload = false

    var isSceneCurrent: Bool { scene != nil && !sceneNeedsReload && !isLoadingScene }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var sceneRequestID = UUID()
    @ObservationIgnored private var currentKey: PreviewKey?
    @ObservationIgnored private var cache: [(key: PreviewKey, image: CGImage, layout: WizardPreviewComposite.Layout)] = []
    @ObservationIgnored private var baseFrame: (key: FrameKey, data: Data)?
    /// The recording-wide reads of `loadScene` (transcript, roster, turns, tag
    /// text), kept across scrubs and framing changes of the same recording.
    @ObservationIgnored private var snapshot: RecordingSnapshot?

    private struct RecordingSnapshot: Sendable {
        var key: String
        var segments: [TranscriptSegment]
        var roster: [VideoPersonRecord]
        var video: VideoRecord?
        var turns: [SpeakerTurn]
        var speakerRows: [TranscriptRow]
        var tagText: [String: String]
        var captionOrdinals: [String: Int]
        var speakingPeople: Set<String>
        var layoutSources: [VideoRecord] = []
        var layoutScenes: [SceneRecord] = []
    }
    @ObservationIgnored private var gradedFrames: [(key: GradeKey, image: CGImage)] = []
    private let thumbnails: ThumbnailService

    private nonisolated struct GradeKey: Equatable, Sendable {
        var frame: FrameKey
        var framing: WizardPreviewComposite.Framing
        var request: Framing
        var contentWindow: FreeCropRect?
        var width: Int
        var height: Int
        var look: String
        var intensity: Double?
    }

    private nonisolated struct FrameKey: Equatable, Sendable {
        var url: URL
        var time: Double
        var dimension: Int
    }

    init(thumbnails: ThumbnailService) { self.thumbnails = thumbnails }

    var selectedScene: SceneRecord? {
        scenes.indices.contains(sceneIndex) ? scenes[sceneIndex] : nil
    }

    func setScenes(_ values: [SceneRecord]) {
        let selectedID = selectedScene?.id
        scenes = values.filter { !$0.excluded && !$0.ignored && $0.endTime > $0.startTime }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id < $1.id
        }
        sceneIndex = selectedID.flatMap { id in scenes.firstIndex { $0.id == id } } ?? 0
        if scenes.isEmpty {
            cancel()
            image = nil
            scene = nil
            loadedSceneID = nil
            loadedTime = nil
            error = nil
        }
    }

    /// Database reads and template loading run on the worker, then publish a value snapshot.
    /// `range` is the source stretch the render will plan over (kept footage
    /// can be trimmed inside its scene); `time` is the moment to show, by
    /// default the middle of that range. Both default to the scene's own.
    func loadScene(_ record: SceneRecord?, database: Database?, people: [PersonRecord],
                   language: String?, tagStyleID: String?, profile: BrandProfile, options: WizardOptions,
                   range: ClosedRange<Double>? = nil, time moment: Double? = nil, snapshotKey: String? = nil,
                   reviewedBRoll: [BRollCut]? = nil) async {
        let id = UUID()
        sceneRequestID = id
        cancel()
        sceneNeedsReload = true
        if record == nil || record?.id != loadedSceneID {
            loadedSceneID = nil
            loadedTime = nil
            scene = nil
            image = nil
            layout = nil
        }
        error = nil
        guard let original = record else { isLoadingScene = false; return }
        isLoadingScene = true
        defer { if sceneRequestID == id { isLoadingScene = false } }
        // Framing and speaker lookups plan over the kept range, as the render does.
        var record = original
        if let range, range.upperBound > range.lowerBound {
            record.startTime = range.lowerBound
            record.endTime = range.upperBound
        }
        // Recording-wide reads happen once per snapshot key; a scrub or a
        // framing change reuses them.
        var loaded: RecordingSnapshot?
        if let database {
            let key = (snapshotKey ?? "\(record.videoID)|\(language ?? "")|\(tagStyleID ?? "")")
                + "|layout=\(options.requestedFraming.subject == .layout)|broll=\(options.useBRoll)"
            if let snapshot, snapshot.key == key {
                loaded = snapshot
            } else {
                let segments = (try? await database.transcriptSegments(videoID: record.videoID,
                    start: 0, end: max(record.videoDuration, record.endTime), language: language)) ?? []
                let video = try? await database.video(id: record.videoID)
                let transcription = try? await database.activeTranscription(videoID: record.videoID).key
                let evidence = await CaptionSpeakerEvidence.load(database: database, videoID: record.videoID,
                    transcriptionKey: transcription)
                let tagText = (try? await database.tagText(field: profile.tagStyle(id: tagStyleID).description.field)) ?? [:]
                let captionOrder = await Task.detached {
                    let speaking = CaptionSpeakerOrder.ordinals(turns: evidence.turns, rows: evidence.rows, roster: [])
                    let all = CaptionSpeakerOrder.ordinals(turns: evidence.turns, rows: evidence.rows, roster: evidence.rosterKeys)
                    return (all, Set(speaking.keys))
                }.value
                guard sceneRequestID == id, !Task.isCancelled else { return }
                let layoutSources = options.requestedFraming.subject == .layout
                    ? (try? await database.fetchVideos(projectID: options.projectID)) ?? [] : []
                let layoutScenes = options.requestedFraming.subject == .layout && options.useBRoll
                    ? (try? await database.fetchScenes(projectID: options.projectID, scope: .active, includeExcluded: false)) ?? [] : []
                guard sceneRequestID == id, !Task.isCancelled else { return }
                let fresh = RecordingSnapshot(key: key, segments: segments, roster: evidence.roster, video: video,
                    turns: evidence.turns, speakerRows: evidence.rows, tagText: tagText,
                    captionOrdinals: captionOrder.0, speakingPeople: captionOrder.1,
                    layoutSources: layoutSources, layoutScenes: layoutScenes)
                snapshot = fresh
                loaded = fresh
            }
        }
        if let database, let reviewedBRoll, options.requestedFraming.subject == .layout, options.useBRoll {
            let known = Set(loaded?.layoutScenes.map(\.id) ?? [])
            let missing = Set(reviewedBRoll.map(\.sceneID)).subtracting(known)
            if !missing.isEmpty, let extra = try? await database.fetchScenes(ids: missing) {
                loaded?.layoutScenes += extra
            }
        }
        let snapshotForWorker = loaded
        let worker = Task.detached(priority: .userInitiated) {
            let time = min(record.endTime, max(record.startTime, moment ?? (record.startTime + record.endTime) / 2))
            var person = people.first { !$0.hidden && !$0.name.isEmpty && record.tags.contains($0.tag) }
            var face: CGRect?
            var segment: TranscriptSegment?
            var video: VideoRecord?
            var roster: [VideoPersonRecord] = []
            var turns: [SpeakerTurn] = []
            var taggedPeople = people
            if let snapshotForWorker {
                let segments = snapshotForWorker.segments
                segment = segments.first { $0.start <= time && time < $0.end } ?? segments.first
                roster = snapshotForWorker.roster
                video = snapshotForWorker.video
                turns = snapshotForWorker.turns
                if let video, let talker = WizardPreviewFraming.speaker(video: video, record: record,
                    turns: turns, roster: roster, people: people, time: time) {
                    person = talker.person ?? person
                    face = talker.face
                }
                if let entry = roster.first(where: { $0.key == person?.key }),
                   record.startTime <= entry.portraitAt, entry.portraitAt < record.endTime,
                   let box = entry.portraitBox {
                    face = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
                }
                let text = snapshotForWorker.tagText
                taggedPeople = people.map { value in
                    var value = value
                    value.descriptor = text[value.key] ?? ""
                    return value
                }
                person = taggedPeople.first { $0.key == person?.key } ?? person
            }
            if person == nil {
                person = WizardPreviewFraming.fallbackPerson(roster: roster, people: taggedPeople)
            }
            try Task.checkCancellation()
            var scene = WizardPreviewComposite.Scene(videoURL: record.videoURL, time: time,
                faceRect: face, person: person, captionText: segment?.text, words: segment?.words)
            scene.roster = Dictionary(roster.map { ($0.key, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            scene.speakerTurns = turns
            scene.speakerRows = snapshotForWorker?.speakerRows ?? []
            scene.captionSegment = segment
            scene.speakingPeople = snapshotForWorker?.speakingPeople ?? []
            scene.captionOrdinals = snapshotForWorker?.captionOrdinals ?? [:]
            scene.cameraPath = original.centerStagePath
            scene.contentIsWide = record.wide
            if let video, video.width > 0, video.height > 0 {
                scene.sourceSize = CGSize(width: video.width, height: video.height)
            } else if options.requestedFraming.focusFrame != nil {
                let dimensions = await FFmpeg.dimensions(of: record.videoURL)
                scene.sourceSize = CGSize(width: dimensions.width, height: dimensions.height)
            }
            if options.requestedFraming.focusFrame != nil {
                scene.contentBox = await RenderEngine().detectContentBox(source: record.videoURL,
                    start: record.startTime, duration: record.duration)
            }
            var brollCuts: [PodcastHighlightBRollPlanner.Cut] = []
            if options.requestedFraming.subject == .layout, options.useBRoll, let video {
                let scenes = snapshotForWorker?.layoutScenes ?? []
                let candidate = HighlightCandidate(sourceStart: record.startTime, sourceEnd: record.endTime,
                    title: "Layout", reason: "", score: 0, kind: .whole, speakerKeys: [])
                let sources = PodcastHighlightBRollPlanner.sources(videoID: video.id, range: record.startTime...record.endTime,
                    turns: turns, roster: roster, scenes: scenes, segments: [], people: taggedPeople)
                if let reviewedBRoll {
                    brollCuts = reviewedBRoll.compactMap { cut in
                        guard let source = scenes.first(where: { $0.id == cut.sceneID }) else { return nil }
                        let start = max(record.startTime, cut.start), end = min(record.endTime, cut.end)
                        guard end > start else { return nil }
                        return .init(source: .scene(source.id), sourceStart: source.startTime + cut.sceneOffset + start - cut.start,
                            start: start - record.startTime, duration: end - start, reason: cut.reason)
                    }
                } else {
                    brollCuts = PodcastHighlightBRollPlanner.plan(candidate: candidate, sources: sources,
                        turns: turns, segments: [], tiles: CropRecipePlanner.tiles(video: video, roster: roster),
                        scenes: scenes, threshold: 7, instructions: options.brollInstructions)
                }
            }
            let framing = await WizardPreviewFraming.resolveCached(options: options, record: record, video: video,
                face: face, turns: turns, roster: roster, people: taggedPeople, layouts: ScreenCropStore.all(), time: time,
                sceneStart: original.startTime, contentBox: scene.contentBox,
                sources: snapshotForWorker?.layoutSources ?? [], scenes: snapshotForWorker?.layoutScenes ?? [], brollCuts: brollCuts)
            scene.framing = framing.framing
            scene.framingWarning = framing.warning
            let templates = OverlayTemplateStore.list()
            // Stable content identity lets revisiting a scene hit the composite LRU.
            var fingerprint = Hasher()
            fingerprint.combine(scene.person)
            fingerprint.combine(scene.framing)
            fingerprint.combine(scene.framingWarning)
            fingerprint.combine(scene.contentBox.map { FreeCropRect(xFrac: $0.x, yFrac: $0.y, wFrac: $0.w, hFrac: $0.h) })
            fingerprint.combine(scene.captionText)
            fingerprint.combine(try JSONEncoder().encode(scene.words))
            fingerprint.combine(scene.roster)
            fingerprint.combine(scene.speakerTurns)
            fingerprint.combine(scene.speakerRows)
            fingerprint.combine(scene.captionSegment?.start)
            fingerprint.combine(scene.captionSegment?.end)
            fingerprint.combine(face?.minX)
            fingerprint.combine(face?.minY)
            fingerprint.combine(face?.width)
            fingerprint.combine(face?.height)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for template in templates {
                fingerprint.combine(template.name)
                fingerprint.combine(try encoder.encode(template.composition))
            }
            return (scene, templates, fingerprint.finalize())
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard sceneRequestID == id else { return }
            scene = result.0
            templates = result.1
            loadedSceneID = original.id
            loadedTime = result.0.time
            contentRevision = result.2
            sceneNeedsReload = false
        } catch is CancellationError {
            // A newer scene request owns the column now.
        } catch {
            if sceneRequestID == id { self.error = error.localizedDescription }
        }
    }

    func update(key: PreviewKey, input: () -> WizardPreviewComposite.Input?) {
        // A retained scene is display-only until its replacement is published.
        // Do not poison currentKey or the composite LRU after a failed reload.
        guard !sceneNeedsReload, !isLoadingScene else { return }
        guard key != currentKey else { return }
        task?.cancel()
        requestID = UUID()
        currentKey = key
        error = nil
        guard let input = input() else { isRendering = false; return }
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let hit = cache.remove(at: index)
            cache.append(hit)
            image = hit.image
            layout = hit.layout
            isRendering = false
            return
        }
        isRendering = true
        let id = requestID
        let thumbnails = thumbnails
        let frameKey = FrameKey(url: input.scene.videoURL, time: input.scene.time,
                                dimension: max(input.options.renderSettings.width, input.options.renderSettings.height))
        let cachedFrame = baseFrame?.key == frameKey ? baseFrame?.data : nil
        let gradeKey = GradeKey(frame: frameKey, framing: WizardPreviewFraming.pixelFraming(input.scene.framing),
            request: input.options.requestedFraming,
            contentWindow: input.scene.contentBox.map { FreeCropRect(xFrac: $0.x, yFrac: $0.y, wFrac: $0.w, hFrac: $0.h) },
            width: key.width, height: key.height, look: key.look, intensity: key.lookIntensity)
        let cachedGrade: CGImage?
        if let index = gradedFrames.firstIndex(where: { $0.key == gradeKey }) {
            let hit = gradedFrames.remove(at: index)
            gradedFrames.append(hit)
            cachedGrade = hit.image
        } else { cachedGrade = nil }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                var input = input
                if input.frameData.isEmpty {
                    if let cachedFrame {
                        input.frameData = cachedFrame
                    } else {
                        guard let data = await thumbnails.thumbnail(for: frameKey.url, at: frameKey.time,
                            maxDimension: CGFloat(frameKey.dimension)) else {
                            throw WizardPreviewComposite.PreviewError.unreadableFrame
                        }
                        input.frameData = data
                    }
                }
                if case .cells(let cells) = input.scene.framing {
                    for cell in cells {
                        guard let path = cell.sourcePath, let time = cell.sourceTime else { continue }
                        if path == frameKey.url.path, abs(time - frameKey.time) < 0.001 {
                            input.cellFrames[cell.frameKey] = input.frameData
                        } else if let data = await thumbnails.thumbnail(for: URL(fileURLWithPath: path), at: time,
                            maxDimension: CGFloat(frameKey.dimension)) {
                            input.cellFrames[cell.frameKey] = data
                        }
                    }
                }
                try Task.checkCancellation()
                let base: WizardPreviewComposite.BaseFrame
                if let cachedGrade { base = .init(image: cachedGrade) }
                else { base = try await WizardPreviewComposite.prepareBase(input) }
                let rendered = try WizardPreviewComposite.renderWithLayout(input, baseFrame: base.image)
                try Task.checkCancellation()
                await self?.finish(image: rendered.image, layout: rendered.layout, key: key, frameKey: frameKey,
                                   frameData: input.frameData, gradeKey: gradeKey, base: base, requestID: id)
            } catch is CancellationError {
                // Cancellation must not clear the next request's busy state.
            } catch {
                await self?.failed(error.localizedDescription, requestID: id)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        currentKey = nil
        isRendering = false
    }

    private func finish(image: CGImage, layout: WizardPreviewComposite.Layout, key: PreviewKey, frameKey: FrameKey,
                        frameData: Data, gradeKey: GradeKey, base: WizardPreviewComposite.BaseFrame, requestID: UUID) {
        guard self.requestID == requestID else { return }
        self.image = image
        self.layout = layout
        baseFrame = (frameKey, frameData)
        error = base.error
        if base.error == nil {
            cache.append((key, image, layout))
            gradedFrames.removeAll { $0.key == gradeKey }
            gradedFrames.append((gradeKey, base.image))
            if gradedFrames.count > 4 { gradedFrames.removeFirst(gradedFrames.count - 4) }
        } else { currentKey = nil }
        if cache.count > 8 { cache.removeFirst(cache.count - 8) }
        isRendering = false
        task = nil
        renderCount += 1
        #if DEBUG
        Logger(subsystem: "ClipBuilder", category: "WizardPreview").debug("Composite render \(self.renderCount)")
        #endif
    }

    private func failed(_ message: String, requestID: UUID) {
        guard self.requestID == requestID else { return }
        error = message
        isRendering = false
        task = nil
        currentKey = nil
    }
}
