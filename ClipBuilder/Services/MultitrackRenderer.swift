import Foundation
import CoreGraphics
import Synchronization

// MAP (2.2k lines), by MARK section:
//   Entry point        render(document:) — plans segments, caches, and drives the stages
//   Clip resolution    timeline clips → concrete source ranges, crops, speeds
//   Segment rendering  per-segment encodes and the segment cache
//   FFmpeg stages      filter graphs, overlays, audio mix, final encode
// Hardware encodes are not byte-deterministic: compare renders by timing,
// audio, and per-frame SSIM (see MultitrackRenderTests.compareDecoded).

/// Multi-track builder render pipeline — the Swift port of clip_builder.py's
/// _generate_multitrack() + video.py's layered compositor. Slices the
/// timeline at clip boundaries into constant-membership segments, composites
/// each 1080x1920 segment with FFmpeg overlay chains (wide clips stack in
/// top/center/bottom slots), burns per-clip captions, concatenates with
/// transitions, then applies the music track and text overlays.
actor MultitrackRenderer {

    struct RenderResult: Sendable {
        var url: URL
        var duration: Double
        /// Clips whose tracking failed or fell back to a static crop; nil
        /// when every clip framed as planned. Also recorded into
        /// `RenderFramingFallbackCollector.current` when one is set.
        var framingFallbacks: [RenderFramingFallback]? = nil
        /// Timeline seconds to seconds of the assembled video (joins overlap).
        var clock: RenderClock? = nil
        /// The Library row the render was filed as; nil for previews.
        var recordID: Int64? = nil
    }

    /// One clip with every per-clip/track setting resolved to its effective
    /// value (clip override beats layer default; layer mute forces mute).
    nonisolated struct ResolvedClip: Codable, Sendable {
        var sourcePath: String
        var videoID: Int64?
        var sourceStart: Double
        var startTime: Double
        var duration: Double
        var track: Int
        var wide: Bool
        var bumper: Bool = false
        var hold: Bool = false
        var flashIn: Double? = nil
        var missingBumper: Bool = false
        /// Ordinary footage or a cutaway (B-roll) drawn over its track.
        var role: ClipRole = .main
        /// Cutaways only: cover the whole canvas instead of the track's area.
        var coverAllAreas: Bool = false
        /// Scale to cover the whole frame (cover-all cutaways) instead of
        /// an area mask or a slot band.
        var fillCanvas: Bool = false
        /// Timeline extent before crop splitting, and the document's
        /// persisted origin identity. Together with the layer they are the
        /// one draw-order key, unchanged by any split.
        var originalStart: Double = 0
        var originalEnd: Double = 0
        var originKey: String = ""
        /// Cutaway dissolves in seconds, measured from `originalStart` and
        /// `originalEnd` so a split never restarts a fade.
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        /// Position in `document.videoTrack` — the last, total tie-break of
        /// the draw order (array order survives save and load).
        var documentIndex: Int = 0
        var volume: Int = 5
        var centerStage: Bool = false
        var muted: Bool
        var transIn: String?
        var transOut: String?
        var effectivePosition: String
        var effectiveCropXFrac: Double?
        var freeCrops: [FreeCrop]?
        /// Screen Crop reference ("Layout/Area") masking this clip.
        var screenCrop: String?
        /// Hand-placed source window for the area (nil = tracking camera).
        var areaWindow: FreeCropRect?
        /// The feed the area's tracking camera stays inside (nil = whole frame).
        var areaRegion: FreeCropRect?
        /// Known face center in source-frame fractions for tracking fallback.
        var areaFocus: AreaFocus?
        var framingProgramAudio: FramingProgramAudio?
        var framingPlan: FramingPlan?
        var fitArea: ScreenCropArea?
        var contentWindow: FreeCropRect?
        var captionsPosition: String?     // nil = captions off for this clip
        /// Playback speed (1 = normal): `duration` is screen time; source
        /// consumption maps through this factor.
        var speed: Double = 1
        /// The scene's stored Center Stage camera path sliced to this clip's
        /// source range (t=0 at sourceStart, source seconds). When present,
        /// the reframe prepass replays it instead of re-tracking — the same
        /// path the manual build preview and workbench show, so WYSIWYG holds.
        var cameraPath: [CameraPathKeyframe]?
        var staticAreaFilter: String?
        var areaPathSource: CGSize?
        /// One original-source probe shared by saved-path route validation.
        var framingSourceSize: CGSize? = nil
        /// The camera path is a slice of this render's tracked run, not a
        /// path saved in the document (a VIP recipe never replays a saved one).
        var continuityRunPath: Bool = false
        var areaPathArea: ScreenCropArea?
        var effectiveEffect: EffectSpec? = nil
        /// Original input and framing parameters, before temporary paths replace them.
        var framingIdentity: String?
        var originalSourcePath: String?
        var sourceFingerprint: String?
        var programAudioFingerprint: String?
        var cacheable = true
        /// The clip asked for its strike highlights.
        var strikeHighlights: Bool? = nil
        var strikeHighlightStyle: String? = nil
        /// The saved highlights to draw, in the ORIGINAL source's seconds.
        /// Cleared once they are burned into a framing intermediate.
        var strikeTracks: [StrikeHighlightRules.Track]? = nil
        var telestration: Telestration? = nil
        var lingering: Telestration? = nil
        // An array breaks recursive value storage; it contains one hold snapshot.
        var lingeringHold: [ResolvedClip]? = nil
        var stayHoldID: UUID? = nil
        var slowGroup: UUID? = nil
        var slowLineage: UUID? = nil
        var stayCut: Bool? = nil
        var stayTransitionStart: Double? = nil
        var continuityClipID: UUID? = nil
        var continuityLayout: CropLayoutRef? = nil
        /// Paused graph pieces use their route's interpolation on the source
        /// clock. Unpaused pieces stay nil.
        var continuityTransform: Bool? = nil
        /// Distinguishes saved affine pieces from tracked runs for cache identity.
        var continuitySavedTransform: Bool? = nil
        var continuityGrid: ContinuityCameraGrid? = nil
        var holdFrameTime: Double? = nil
        var screenStay: TelestrationScreenStay.Mapping? = nil
        /// Original-video time, independent of a framing intermediate's seek time.
        var transcriptSourceStart: Double?
        /// A lip-synced copy of this clip's stretch of the source. Only pixel
        /// and sound reads go to it; every lookup stays on the source's path
        /// and clock. In the cache identity, so a take changes the result.
        var pictureTake: PictureTake? = nil

        // Render-only linger is deliberately excluded from Codable. Cache
        // evidence carries it separately, and nil leaves old keys unchanged.
        private nonisolated enum CodingKeys: String, CodingKey {
            case sourcePath, videoID, sourceStart, startTime, duration
            case track, wide, bumper, hold, missingBumper, flashIn
            case role, coverAllAreas, fillCanvas, originalStart, originalEnd
            case originKey, fadeIn, fadeOut, documentIndex, volume
            case centerStage, muted, transIn, transOut, effectivePosition
            case effectiveCropXFrac, freeCrops, screenCrop, areaWindow, areaRegion
            case areaFocus, framingProgramAudio, framingPlan, fitArea, contentWindow
            case captionsPosition, speed, cameraPath, staticAreaFilter, areaPathSource
            case areaPathArea, effectiveEffect, framingIdentity, originalSourcePath, sourceFingerprint
            case programAudioFingerprint, cacheable, strikeHighlights, strikeHighlightStyle, strikeTracks
            case telestration, transcriptSourceStart, pictureTake
        }

        var sourceSpan: Double { hold ? 0 : duration * speed }

        func transcriptStart(at timelineTime: Double) -> Double {
            (transcriptSourceStart ?? sourceStart) + (hold ? 0 : (timelineTime - startTime) * speed)
        }

        /// Where this clip's picture is read: its take when one covers it.
        /// Holds freeze one source frame and strike highlights are drawn on
        /// the source's own clock, so both keep the source.
        var pictureRead: (path: String, start: Double) {
            guard let take = pictureTake, !hold, strikeTracks == nil, abs(speed - 1) < 0.0005 else { return (sourcePath, sourceStart) }
            return (take.path, max(0, sourceStart - take.sourceStart))
        }

        mutating func useFramedSource(_ url: URL, identity: String, areaPass: Bool, reusable: Bool) {
            // The take was read into the intermediate.
            pictureTake = nil
            transcriptSourceStart = transcriptSourceStart ?? sourceStart
            framingIdentity = (framingIdentity ?? "") + identity
            sourcePath = url.path
            sourceStart = 0
            // Already drawn into the intermediate, before it was framed.
            strikeTracks = nil
            strikeHighlightStyle = nil
            telestration = nil
            if screenStay == nil { lingering = nil }
            fitArea = nil
            contentWindow = nil
            cacheable = cacheable && reusable
            wide = false
            if areaPass {
                centerStage = false
                cameraPath = nil
                effectiveCropXFrac = nil
            }
        }
    }

    /// One alpha dissolve inside a segment, in segment-local seconds.
    nonisolated struct Fade: Sendable, Equatable {
        var start: Double
        var duration: Double
    }

    nonisolated struct Segment: Sendable {
        var start: Double
        var end: Double
        var clips: [ResolvedClip]
        var duration: Double { end - start }
    }

    /// One clip's contribution to a single composited segment.
    nonisolated struct PictureTake: Codable, Sendable, Equatable {
        var path: String
        /// The source second the take's first frame shows.
        var sourceStart: Double
        var key: String
    }

    nonisolated struct Placement: Sendable {
        var sourcePath: String
        var sourceStart: Double
        var sourceDur: Double
        var isWide: Bool
        var bumper: Bool = false
        var hold: Bool = false
        var flashIn: Double? = nil
        var volume: Int = 5
        var layer: Int
        var position: String
        var muted: Bool
        /// Ordinary footage or a cutaway — a cutaway's own sound takes the
        /// volume gain, like a bumper's.
        var role: ClipRole = .main
        /// Scale to cover the whole frame, centred.
        var fillCanvas: Bool = false
        /// Order key beside `layer`: the clip's start before crop splitting
        /// and its persisted identity.
        var originalStart: Double = 0
        var originKey: String = ""
        /// Alpha dissolves for this segment, in segment-local seconds. A
        /// start before 0 means the fade began in an earlier segment.
        var fadeIn: Fade?
        var fadeOut: Fade?
        /// Position in `document.videoTrack`: the final tie-break.
        var documentIndex: Int = 0
        /// Index of the clip this placement came from in the segment.
        var clipIndex: Int = 0
        /// Timeline start of the clip this placement came from. Clips that
        /// overlap on one track stack by start time — the later one on top.
        var startTime: Double
        var cropXFrac: Double?
        var freeCrops: [FreeCrop]?
        var screenCrop: String?
        var speed: Double = 1
        var staticAreaFilter: String?
        var effectiveEffect: EffectSpec? = nil
        var framingProgramAudio: FramingProgramAudio?
        var framingPlan: FramingPlan?
        var snapshotArea: ScreenCropArea?
        var fitWindow: FreeCropRect?
        var fitArea: ScreenCropArea?
        /// Strike highlight pictures to lay on the source before any crop.
        var strikeOverlay: [StrikeHighlightBurn.Sequence]?
        var telestrationOverlay: [StrikeHighlightBurn.Sequence]?
        var telestrationSize: CGSize?
        var continuityTransform: Bool? = nil
        var holdFrameTime: Double? = nil
        var screenStay: TelestrationScreenStay.Mapping? = nil

        func holdOffset(at timelineOffset: Double) -> Double {
            max(0, timelineOffset - originalStart)
        }
    }

    private static var width: Int { RenderEngine.outputWidth }
    private static var height: Int { RenderEngine.outputHeight }
    private static var slotHeight: Int { max(2, height / 3) }
    private static var slotY: [String: Int] {
        ["top": 0, "center": slotHeight, "bottom": slotHeight * 2]
    }

    /// When the final overlay pass may run as cached ranges. `editsOnly`
    /// keeps a cold render on the single full pass and creates ranges only
    /// once a render reuses at least one cached segment, i.e. a re-render.
    nonisolated enum IncrementalFinishing: String, Sendable {
        case off, editsOnly, always
    }

    private let segmentCache: RenderSegmentCache
    private let finishingCacheEnabled: Bool
    private let assemblyCacheEnabled: Bool
    private let framingCacheEnabled: Bool
    private let incrementalFinishing: IncrementalFinishing
    /// Burn timeline-spanning overlays into the segments they touch instead
    /// of a final pass over the whole video. `CLIPBUILDER_OVERLAY_FUSION=off`
    /// keeps the final pass for same-binary measurement.
    private let overlayFusionEnabled: Bool
    private let dubSynthesizer: DubSynthesizer
    private let render: RenderEngine
    private let centerStageService = CenterStageService()

    init(render: RenderEngine, segmentCache: RenderSegmentCache = .shared,
         finishingCacheEnabled: Bool = true, assemblyCacheEnabled: Bool = true,
         framingCacheEnabled: Bool = true, incrementalFinishing: IncrementalFinishing = .editsOnly,
         overlayFusionEnabled: Bool = true, dubSynthesizer: DubSynthesizer = .shared) {
        self.dubSynthesizer = dubSynthesizer
        self.segmentCache = segmentCache
        self.overlayFusionEnabled = overlayFusionEnabled
            && ProcessInfo.processInfo.environment["CLIPBUILDER_OVERLAY_FUSION"] != "off"
        self.finishingCacheEnabled = finishingCacheEnabled
        self.assemblyCacheEnabled = assemblyCacheEnabled
        self.framingCacheEnabled = framingCacheEnabled
        self.incrementalFinishing = incrementalFinishing
        self.render = render
    }

    // MARK: - Entry point

    /// Tests intercept the final renderer call after Wizard orchestration has
    /// supplied its document and tracks. Nil uses the real render pipeline.
    @TaskLocal static var strikeHighlightRenderOverride: (@Sendable (TimelineDocument, [String: [StrikeHighlightRules.Track]]) async throws -> RenderResult)?

    /// `preview: true` runs the IDENTICAL pipeline (same framing, crops,
    /// transitions, music, overlays, encode settings — pixel-for-pixel what
    /// a real render produces) but writes to a temporary file and records
    /// nothing in the Library. The manual build's Exact Preview uses it.
    func render(document: TimelineDocument, scenes: [SceneRecord],
                profile: BrandProfile, database: Database,
                centerStageCamera: String = "balanced",
                projectID: Int64? = nil,
                outputName: String? = nil,
                batchID: String? = nil,
                wizardOptions: WizardOptions? = nil,
                roles: [AIRole] = [],
                renderFingerprint: String? = nil,
                preview: Bool = false,
                prerenderedSources: Set<String> = [],
                contentWindows: [String: FreeCropRect] = [:],
                strikeHighlightTracks: [String: [StrikeHighlightRules.Track]] = [:],
                lingering: [UUID: Telestration] = [:],
                lingerHolds: [UUID: ResolvedClip] = [:],
                continuity: [CenterStageContinuity.Run] = [],
                stayTransitions: [UUID: Double] = [:],
                dubState: DubRenderWindow.State? = nil,
                burnIns: [RenderEngine.ClipOverlay] = [],
                muteSource: Bool = false, compositeEffect: EffectSpec? = nil,
                emit: @escaping @Sendable (String) -> Void) async throws -> RenderResult {
        if let renderOverride = Self.strikeHighlightRenderOverride {
            return try await renderOverride(document, strikeHighlightTracks)
        }
        try FootageAvailability.requireSources(document: document, scenes: scenes)
        let editing = profile.editing ?? ProfileEditingDefaults(seedingFrom: SettingsStore.loadSettings())
        return try await FFmpeg.$renderLog.withValue(emit) {
            try await RenderContext.$transitions.withValue(editing.transitions) {
                try await RenderContext.$settings.withValue(document.renderSettings) {
                    // A Wizard document names the Center Stage default its extraction used.
                    try await renderConfigured(document: document, scenes: scenes, profile: profile,
                                               database: database, centerStageCamera: document.framingCamera ?? centerStageCamera,
                                               projectID: projectID, outputName: outputName, batchID: batchID, wizardOptions: wizardOptions, roles: roles,
                                               renderFingerprint: renderFingerprint, preview: preview,
                                               contentWindows: contentWindows, prerenderedSources: prerenderedSources,
                                               strikeHighlightTracks: strikeHighlightTracks, lingering: lingering, lingerHolds: lingerHolds, continuity: continuity, stayTransitions: stayTransitions, dubState: dubState, burnIns: burnIns, muteSource: muteSource, compositeEffect: compositeEffect, emit: emit)
                }
            }
        }
    }

    /// The base name of a Builder render: project, timeline (unless it is
    /// still the default name), and today's date as mm-dd-yy. The renderer
    /// appends " 2", " 3", … when the name is already taken that day.
    nonisolated static func outputBaseName(project: String?, timeline: String?, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yy"
        var parts: [String] = []
        if let project = project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            parts.append(project)
        }
        if let timeline = timeline?.trimmingCharacters(in: .whitespacesAndNewlines), !timeline.isEmpty,
           !Self.isDefaultTimelineName(timeline) {
            parts.append(timeline)
        }
        parts.append(formatter.string(from: date))
        let joined = parts.joined(separator: " - ")
        // Keep the name filesystem-safe: no path separators or colons, no
        // leading dot, and a sane length.
        let unsafe = CharacterSet(charactersIn: "/\\:\u{0}").union(.newlines).union(.controlCharacters)
        let cleaned = joined.unicodeScalars.map { unsafe.contains($0) ? "-" : Character($0) }
        var name = String(cleaned).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? formatter.string(from: date) : String(name.prefix(120))
    }

    /// "Untitled Timeline", its duplicates ("Untitled Timeline Copy", "… Copy 2")
    /// and an empty name all count as the default and are left out of the file name.
    nonisolated static func isDefaultTimelineName(_ name: String) -> Bool {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard lowered.hasPrefix("untitled timeline") else { return lowered.isEmpty }
        let rest = lowered.dropFirst("untitled timeline".count).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return true }
        // "copy", "copy 2", "2"
        let stripped = rest.hasPrefix("copy") ? rest.dropFirst(4).trimmingCharacters(in: .whitespaces) : rest
        return stripped.isEmpty || Int(stripped) != nil
    }

    private func renderConfigured(document: TimelineDocument, scenes: [SceneRecord],
                                  profile: BrandProfile, database: Database,
                                  centerStageCamera: String, projectID: Int64?,
                                  outputName: String? = nil, batchID: String? = nil, wizardOptions: WizardOptions? = nil,
                                  roles: [AIRole] = [], renderFingerprint: String? = nil, preview: Bool,
                                  contentWindows: [String: FreeCropRect] = [:],
                                  prerenderedSources: Set<String> = [],
                                  strikeHighlightTracks: [String: [StrikeHighlightRules.Track]] = [:],
                                  lingering: [UUID: Telestration] = [:],
                                  lingerHolds: [UUID: ResolvedClip] = [:],
                                  continuity: [CenterStageContinuity.Run] = [],
                                  stayTransitions: [UUID: Double] = [:],
                                  dubState: DubRenderWindow.State? = nil,
                                  burnIns: [RenderEngine.ClipOverlay] = [],
                                  muteSource: Bool = false, compositeEffect: EffectSpec? = nil,
                                  emit: @escaping @Sendable (String) -> Void) async throws -> RenderResult {
        // Overlay blocks render as their flattened text/image items.
        var preparedDocument = Self.removingMissingEdgeBumpers(document.expandingOverlayBlocks(), emit: emit)
        let hasDub = dubState?.enabled ?? (preparedDocument.dub?.enabled == true && !(preparedDocument.dubLines ?? []).isEmpty)
        if hasDub, let lines = preparedDocument.dubLines, !lines.isEmpty {
            emit("Preparing \(lines.count) dubbed line(s)…")
            preparedDocument.dubLines = try await dubSynthesizer.restoringAudio(lines: lines, database: database)
        }
        let document = preparedDocument
        var bumperSpans = document.videoTrack.filter(\.bumper).map { $0.startTime..<($0.startTime + $0.duration) }
        var clips = Self.resolveClips(document: document, scenes: scenes, centerStageCamera: centerStageCamera, lingering: lingering, lingerHolds: lingerHolds)
        // A preview may have cut away the hold. Resolve that hold's framing
        // with the same prepass, then discard its picture before segmenting.
        let visibleClipCount = clips.count
        var stayHolds: [Int: Int] = [:]
        for index in 0..<visibleClipCount where clips[index].lingering != nil {
            guard let snapshot = clips[index].lingeringHold?.first else { continue }
            if let holdIndex = clips.indices.filter({
                clips[$0].hold && snapshot.stayHoldID != nil && clips[$0].stayHoldID == snapshot.stayHoldID
            }).max(by: { clips[$0].startTime < clips[$1].startTime }) {
                stayHolds[index] = holdIndex
            } else {
                var hold = snapshot
                // The document index belongs to the unwindowed document.
                hold.documentIndex = -1
                stayHolds[index] = clips.count
                clips.append(hold)
            }
        }
        for index in clips.indices {
            // The Wizard records each cut's content box on its clips.
            guard let window = contentWindows[clips[index].sourcePath]
                    ?? document.videoTrack[safe: clips[index].documentIndex]?.contentWindow
                    ?? (index >= visibleClipCount ? clips[index].contentWindow : nil),
                  !clips[index].bumper else { continue }
            Self.applyContentWindow(window, to: &clips[index])
        }
        for index in clips.indices {
            if let path = clips[index].cameraPath {
                clips[index].cameraPath = TrackedPictureBounds.clamped(path, to: clips[index].contentWindow ?? FreeCropRect())
            }
        }
        // Wizard extractions share their run's post-marking drawable snapshot.
        // Missing paths still use the saved tracks, as Builder and previews do.
        var strikeTracks = strikeHighlightTracks
        var videosByPath: [String: Int64]?
        for index in clips.indices where clips[index].strikeHighlights == true {
            let clip = clips[index]
            if strikeTracks[clip.sourcePath] == nil {
                var videoID = clip.videoID ?? scenes.first { $0.videoPath == clip.sourcePath }?.videoID
                if videoID == nil {
                    if videosByPath == nil {
                        videosByPath = Dictionary(((try? await database.fetchVideos(projectID: projectID)) ?? [])
                            .map { ($0.url.path, $0.id) }, uniquingKeysWith: { first, _ in first })
                    }
                    videoID = videosByPath?[clip.sourcePath]
                }
                // Only what is drawn is kept: the tracks are part of the
                // clip's cache identity.
                var readError: String?
                strikeTracks[clip.sourcePath] = []
                if let videoID {
                    do {
                        strikeTracks[clip.sourcePath] = try await database.fetchStrikeHighlights(videoID: videoID)
                            .compactMap(\.track).map(StrikeHighlightRules.drawable)
                    } catch { readError = error.localizedDescription }
                }
                let sourceTracks = strikeTracks[clip.sourcePath] ?? []
                let drawsInRender = clips.contains { candidate in
                    candidate.strikeHighlights == true && candidate.sourcePath == clip.sourcePath
                        && !StrikeHighlightBurn.tracks(sourceTracks, start: candidate.sourceStart, duration: candidate.sourceSpan).isEmpty
                }
                if !drawsInRender {
                    // This branch runs once per source, including empty results.
                    let status: WizardStrikeHighlights.SavedStatus? = if readError == nil, let videoID {
                        try? await database.strikeHighlightStatus(videoID: videoID)
                    } else { nil }
                    emit(WizardStrikeHighlights.missingMarksMessage(
                        filename: URL(fileURLWithPath: clip.sourcePath).lastPathComponent, status: status, readError: readError))
                }
            }
            // A clip with nothing to draw renders, and caches, as one with the switch off.
            clips[index] = CenterStageContinuity.normalizingStrikeHighlights(clip,
                tracks: strikeTracks[clip.sourcePath] ?? [])
        }
        // Resolve a continuous take before any hold or moving-piece prepass.
        // Preview context carries the unwindowed union, including removed heads.
        let continuityCandidates = continuity.isEmpty
            ? CenterStageContinuity.runs(Array(clips.prefix(visibleClipCount)), ignoringStoredPaths: true)
            : continuity.map { CenterStageContinuity.normalizingStrikeHighlights($0, tracks: strikeTracks) }
        var sourceSizes: [String: CGSize] = [:]
        let sizeInputs = clips + continuityCandidates.flatMap { $0.pieces ?? [] }
        for clip in sizeInputs where clip.cameraPath != nil || clip.centerStage
            || CenterStageContinuity.prepassArea(clip) != nil || clip.hold && !stayHolds.isEmpty {
            guard sourceSizes[clip.sourcePath] == nil else { continue }
            let size = await FFmpeg.dimensions(of: URL(fileURLWithPath: clip.sourcePath))
            sourceSizes[clip.sourcePath] = CGSize(width: size.width, height: size.height)
        }
        for index in clips.indices {
            clips[index].framingSourceSize = sourceSizes[clips[index].sourcePath].flatMap {
                $0.width > 0 && $0.height > 0 ? $0 : nil
            }
        }
        for run in continuityCandidates where run.pieces?.contains(where: \.hold) == true {
            for index in clips.indices where run.containsSourcePiece(clips[index]) && clips[index].cameraPath != nil {
                clips[index] = CenterStageContinuity.pausedSavedPath(clips[index])
            }
        }
        // A stay preview can carry its removed hold without run context.
        // Both saved pieces use their ordinary route's interpolation in the graph.
        for (moving, hold) in stayHolds {
            for index in [moving, hold] where clips[index].cameraPath != nil {
                clips[index] = CenterStageContinuity.pausedSavedPath(clips[index])
            }
        }
        let framingSizes = sourceSizes
        let continuityRuns = await CenterStageContinuity.applicableRuns(continuityCandidates, sourceSizes: sourceSizes)
        let pausedContinuity = continuityCandidates.contains { $0.pieces?.contains(where: \.hold) == true }
        let continuityFailures = Mutex<Set<String>>([])
        let reportContinuityFailure: @Sendable (String) -> Void = { line in
            guard continuityFailures.withLock({ seen in
                if pausedContinuity && !seen.isEmpty { return false }
                return seen.insert(line).inserted
            }) else { return }
            emit(line)
            ErrorLog.record("Center Stage", line)
        }
        for run in continuityRuns {
            let indices = clips.indices.filter { run.contains(clips[$0]) }
            guard !indices.isEmpty else { continue }
            let path = try await CenterStageContinuity.prepare(run, defaultCamera: centerStageCamera,
                    service: centerStageService, cache: segmentCache, cacheEnabled: framingCacheEnabled,
                    database: database, reportFailure: reportContinuityFailure, emit: emit)
            let neighbours = path == nil ? try await CenterStageContinuity.neighbourPaths(run,
                defaultCamera: centerStageCamera, service: centerStageService, database: database,
                cache: segmentCache, cacheEnabled: framingCacheEnabled,
                reportFailure: reportContinuityFailure, emit: emit) : [:]
            let paused = run.pieces?.contains(where: \.hold) == true
            let grid: ContinuityCameraGrid?
            if paused, let source = path?.sourceSize ?? neighbours.values.first?.sourceSize {
                grid = ContinuityCameraGrid.choose(path: path?.keyframes ?? neighbours.values.flatMap(\.keyframes),
                    source: source, box: AreaFramer.pixelBounds(of: CenterStageContinuity.area(run.template)).size)
            } else { grid = nil }
            for index in indices {
                if let path {
                    clips[index].cameraPath = CenterStageContinuity.slice(path.keyframes, runStart: run.start,
                        clip: clips[index], transform: paused)
                    clips[index].continuityRunPath = true
                    if paused { clips[index].cacheable = clips[index].cacheable && path.reusable != false }
                } else if let id = clips[index].continuityClipID, let neighbour = neighbours[id],
                          let piece = run.pieces?.first(where: { $0.continuityClipID == id }) {
                    clips[index].cameraPath = CenterStageContinuity.slice(neighbour.keyframes,
                        runStart: piece.sourceStart, clip: clips[index], transform: paused)
                    clips[index].continuityRunPath = true
                    clips[index].cacheable = clips[index].cacheable && neighbour.reusable != false
                } else { continue }
                if paused {
                    clips[index].continuityTransform = true
                    clips[index].continuitySavedTransform = nil
                    clips[index].continuityGrid = grid
                }
                clips[index].areaRegion = clips[index].areaRegion ?? FreeCropRect()
                clips[index].areaFocus = nil
            }
        }
        let frameFailureReported = Mutex(false)
        let reportFrameFailure: @Sendable (any Error) -> Void = { error in
            guard frameFailureReported.withLock({ seen in
                if seen { return false }; seen = true; return true
            }) else { return }
            let message = "Containing hold frame unavailable; using the ordinary seek: \(error)"
            emit(message)
            ErrorLog.record("Renderer", message)
        }
        // This also covers ordinary Draw on pause, Freeze on impacts, reel
        // pauses, and removed preview holds that do not belong to a tracked run.
        for index in clips.indices where clips[index].hold {
            do {
                let source = URL(fileURLWithPath: clips[index].sourcePath)
                let time = clips[index].sourceStart
                clips[index].holdFrameTime = try await ContinuityFrameSelection.assetHoldTime(source, time: time)
            } catch {
                try Task.checkCancellation()
                clips[index].cacheable = false
                reportFrameFailure(error)
            }
        }
        var failedStayReferences: Set<Int> = []
        var fighterRosters: [String: [VideoPersonRecord]] = [:]
        let fighterHolds = Set(continuityRuns.filter { $0.template.framingPlan?.recipe?.fighterFocus == true }
            .flatMap { $0.pieces ?? [] }.filter(\.hold).compactMap(\.continuityClipID))
        for index in clips.indices where clips[index].framingPlan?.recipe?.fighterFocus == true
            && (!clips[index].hold || clips[index].cameraPath == nil)
            && !(clips[index].hold && clips[index].continuityClipID.map { fighterHolds.contains($0) } == true) {
            let clip = clips[index]
            if fighterRosters[clip.sourcePath] == nil {
                var videoID = clip.videoID ?? scenes.first { $0.videoPath == clip.sourcePath }?.videoID
                if videoID == nil {
                    videoID = (try? await database.fetchVideos(projectID: projectID))?.first { $0.url.path == clip.sourcePath }?.id
                }
                fighterRosters[clip.sourcePath] = if let videoID {
                    (try? await database.fetchVideoPeople(videoID: videoID)) ?? []
                } else { [] }
            }
            let roster = fighterRosters[clip.sourcePath] ?? []
            do {
                clips[index].cameraPath = try await FighterTrackingAdapter.cameraPath(source: URL(fileURLWithPath: clip.sourcePath),
                    start: clip.sourceStart, duration: clip.hold ? 1.0 / 30 : clip.sourceSpan, roster: roster,
                    region: clip.areaRegion ?? clip.framingPlan?.sourceWindow,
                    pullBack: clip.framingPlan?.recipe?.interviewZoom ?? 0, aspect: document.renderSettings.aspectRatio)
            } catch {
                try Task.checkCancellation()
                guard index >= visibleClipCount else { throw error }
                failedStayReferences.insert(index)
                for (moving, hold) in stayHolds where hold == index {
                    clips[moving].lingering = nil
                    clips[moving].cacheable = false
                }
                emit("Drawing: hold framing failed (\(error)); rendering without the stay")
                ErrorLog.record("Telestrator", "Stay fighter framing failed: \(error)")
                continue
            }
            if clip.hold, let path = clips[index].cameraPath {
                clips[index].cameraPath = HoldClipRules.cameraPath(path, duration: clip.duration)
            }
            clips[index].centerStage = true
            clips[index].areaFocus = nil
        }
        for run in continuityRuns where run.template.framingPlan?.recipe?.fighterFocus == true {
            guard let pieces = run.pieces else { continue }
            var paths: [UUID: FeedCameraPath] = [:]
            for piece in pieces where !piece.hold {
                guard let id = piece.continuityClipID,
                      let path = clips.first(where: { $0.continuityClipID == id })?.cameraPath else { continue }
                paths[id] = FeedCameraPath(keyframes: path, samples: [], trackedShare: 1,
                    sourceSize: .zero, usedFallback: false)
            }
            for (position, piece) in pieces.enumerated() where piece.hold {
                guard let id = piece.continuityClipID,
                      let path = CenterStageContinuity.neighbourPath(for: position, pieces: pieces, paths: paths) else { continue }
                for index in clips.indices where clips[index].continuityClipID == id {
                    clips[index].cameraPath = path.keyframes
                    clips[index].areaFocus = nil
                }
            }
        }
        for index in clips.indices {
            if clips[index].bumper && !FileManager.default.fileExists(atPath: clips[index].sourcePath) {
                clips[index].missingBumper = true
                continue
            }
            if let audio = clips[index].framingProgramAudio {
                clips[index].programAudioFingerprint = try SourceIdentityCache.shared.fingerprint(of: URL(fileURLWithPath: audio.path))
            }
            clips[index].originalSourcePath = clips[index].sourcePath
            clips[index].sourceFingerprint = try SourceIdentityCache.shared.fingerprint(
                of: URL(fileURLWithPath: clips[index].sourcePath))
        }
        let framingScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_areas_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: framingScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: framingScratch) }
        var framingArtifacts: [RenderSegmentCache.Entry] = []
        // Review flags: clips whose framing fell back to a static crop.
        var framingFallbacks: [RenderFramingFallback] = []
        #if PERFORMANCE_BASELINE
        let framingStarted = ContinuousClock.now
        #endif
        // Group only source/framing inputs, not timeline placement. A repeated
        // clip shares its intermediate. Permits remain in leaf media work.
        let hasStays = clips.contains {
            $0.lingering.map { TelestrationRules.carriedDuration(of: $0) > 0 } ?? false
        }
        let passes: [(area: Bool, holdsOnly: Bool)] = hasStays
            ? [(true, true), (false, false), (true, false)] : [(false, false), (true, false)]
        var reportedStayFallback = false
        var stayFrames: [Int: TelestrationScreenStay.Frame] = [:]
        for pass in passes {
            let areaPass = pass.area
            if hasStays && !pass.area {
                let canvas = CGSize(width: Self.width, height: Self.height)
                for holdIndex in Set(stayHolds.values) {
                    let hold = clips[holdIndex]
                    let size = framingSizes[hold.sourcePath] ?? .zero
                    stayFrames[holdIndex] = TelestrationScreenStay.frame(for: hold,
                        source: size, canvas: canvas)
                }
                for index in 0..<visibleClipCount where clips[index].lingering != nil {
                    if let holdIndex = stayHolds[index], let frame = stayFrames[holdIndex] {
                        clips[index].screenStay = TelestrationScreenStay.mapping(hold: frame, following: clips[index], canvas: canvas)
                    }
                    let clip = clips[index]
                    let awaitingAreaPath = CenterStageContinuity.prepassArea(clip) != nil
                        && (clip.areaRegion != nil || clip.cameraPath != nil)
                    if clip.screenStay == nil, clip.lingering?.motion == nil, !awaitingAreaPath, !reportedStayFallback,
                       TelestrationLingerResolution.drawingForPiece(clip) != nil {
                        emit(TelestrationScreenStay.fallbackMessage)
                        ErrorLog.record("Telestrator", TelestrationScreenStay.fallbackMessage)
                        reportedStayFallback = true
                    }
                }
            }
            #if PERFORMANCE_BASELINE
            let passStarted = ContinuousClock.now
            #endif
            var groups: [String: [Int]] = [:]
            var areas: [String: ScreenCropArea] = [:]
            for index in clips.indices {
                let clip = clips[index]
                if failedStayReferences.contains(index) { continue }
                if hasStays && (pass.holdsOnly != clip.hold) { continue }
                // Full-screen paths and VIP reactions use the same in-graph
                // framing route as a layout cell, without a redundant canvas pad.
                let area = CenterStageContinuity.prepassArea(clip)
                guard (areaPass ? (clip.freeCrops?.isEmpty != false && area != nil)
                       : (!clip.hold && clip.centerStage && !(area != nil && (clip.cameraPath != nil || clip.areaRegion != nil)))) else { continue }
                if areaPass, let area, clip.cameraPath == nil,
                   clip.areaWindow != nil || clip.framingPlan?.isStatic == true {
                    if clip.framingPlan != nil, !clip.bumper {
                        clips[index].fitArea = area
                    } else if let window = clip.areaWindow {
                        clips[index].staticAreaFilter = AreaFramer.staticFilter(area: area, window: window)
                    }
                    clips[index].wide = false
                    clips[index].effectiveCropXFrac = nil
                    emit("Clip \(index + 1): static area fused; intermediates=0")
                    continue
                }
                let key = try Self.prepassKey(clip, area: areaPass ? area : nil, tuning: clip.framingPlan?.camera ?? centerStageCamera)
                groups[key, default: []].append(index)
                if areaPass { areas[key] = area }
            }
            let jobs = groups.sorted { $0.key < $1.key }.map {
                (key: $0.key, indices: $0.value, clip: clips[$0.value[0]], area: areas[$0.key])
            }
            let fallbackReasons = FramingFallbackReasons()
            let results = try await BoundedConcurrency.map(jobs, limit: FFmpeg.jobLimit) { _, job -> PrepassArtifact? in
                try Task.checkCancellation()
                let clip = job.clip
                let source = URL(fileURLWithPath: clip.sourcePath)
                if clip.hold, let area = job.area {
                    do {
                        let size = framingSizes[clip.sourcePath] ?? .zero
                        let box = AreaFramer.pixelBounds(of: area)
                        let path: FeedCameraPath
                        if let saved = clip.cameraPath, CenterStageContinuity.storedPathApplies(clip, sourceSize: size) {
                            path = FeedCameraPath(keyframes: saved, samples: [], trackedShare: 1,
                                                  sourceSize: size, usedFallback: false)
                        } else if clip.framingPlan?.recipe?.centerStageVIPs == true {
                            let portraits = await Self.vipPortraits(sourcePath: clip.sourcePath,
                                keys: clip.framingPlan?.recipe?.centerStageVIPKeys, database: database)
                            let tracked = try await self.centerStageService.cameraPath(source: source,
                                start: clip.sourceStart, duration: 1.0 / 30, focusPortraits: portraits,
                                tuning: .named(clip.framingPlan?.camera ?? centerStageCamera), aspect: box.width / box.height)
                            path = FeedCameraPath(keyframes: tracked.keyframes, samples: [], trackedShare: tracked.trackedShare,
                                                  sourceSize: size, usedFallback: tracked.trackedShare == 0)
                        } else {
                            path = try await self.centerStageService.cameraPath(source: source,
                                start: clip.sourceStart, duration: 1.0 / 30,
                                region: CenterStageService.validRegion(clip.areaRegion ?? Self.cellBounds(of: clip) ?? FreeCropRect()),
                                tuning: .named(clip.framingPlan?.camera ?? centerStageCamera),
                                aspect: box.width / box.height, fallbackCenter: clip.areaFocus, log: emit)
                        }
                        var frozen = path
                        frozen.keyframes = HoldClipRules.cameraPath(TrackedPictureBounds.clamped(path.keyframes,
                            to: clip.contentWindow ?? FreeCropRect()), duration: clip.duration)
                        guard frozen.keyframes.count >= 2 else {
                            reportContinuityFailure("Framing: no usable bounded hold path; using the static crop")
                            fallbackReasons.set(job.key, "no usable bounded hold path")
                            return nil
                        }
                        if path.usedFallback { fallbackReasons.set(job.key, "tracking found too little to follow") }
                        return PrepassArtifact(path: frozen, cacheable: path.reusable != false)
                    } catch {
                        try Task.checkCancellation()
                        // A removed preview hold exists only to place the stay.
                        // Its failure must not prevent the moving picture rendering.
                        guard job.indices.allSatisfy({ $0 >= visibleClipCount }) else { throw error }
                        emit("Drawing: hold framing failed (\(error)); rendering without the stay")
                        ErrorLog.record("Telestrator", "Stay hold framing failed: \(error)")
                        return nil
                    }
                }
                if let area = job.area, clip.areaRegion != nil || clip.cameraPath != nil {
                    if self.framingCacheEnabled, clip.cacheable, !ExpressRenderTesting.exportAreaPaths,
                       var cached = await self.segmentCache.readJSON(FeedCameraPath.self, key: job.key) {
                        cached.keyframes = TrackedPictureBounds.clamped(cached.keyframes, to: clip.contentWindow ?? FreeCropRect())
                        guard cached.keyframes.count >= 2 else {
                            reportContinuityFailure("Framing: no usable bounded area path; using the static crop")
                            fallbackReasons.set(job.key, "no usable bounded area path")
                            return nil
                        }
                        emit("Framing cache hit; keyframes=\(cached.keyframes.count); intermediates=0")
                        // A cached fallback path still earns its review flag.
                        if cached.usedFallback {
                            fallbackReasons.set(job.key, "tracking found too little to follow")
                        }
                        return PrepassArtifact(path: cached, cacheable: true, wasCached: true)
                    }
                    var path: FeedCameraPath
                    let sourceSize = framingSizes[clip.sourcePath] ?? .zero
                    let box = AreaFramer.pixelBounds(of: area)
                    if let saved = clip.cameraPath, CenterStageContinuity.storedPathApplies(clip, sourceSize: sourceSize) {
                        path = FeedCameraPath(keyframes: saved, samples: [], trackedShare: 1,
                            sourceSize: sourceSize, usedFallback: false)
                        emit("Framing: saved framing used; keyframes=\(saved.count)")
                    } else {
                        // A saved path that no longer fits the cell is re-tracked
                        // inside the feed it framed, never the whole picture.
                        if let saved = clip.cameraPath, clip.areaRegion == nil {
                            emit("Framing: saved framing rejected (keyframes=\(saved.count)); re-tracking inside its bounds")
                        }
                        let region = CenterStageService.validRegion(clip.areaRegion ?? Self.cellBounds(of: clip) ?? FreeCropRect())
                        let box = AreaFramer.pixelBounds(of: area)
                        let camera = clip.framingPlan?.isSteady == true ? "steady"
                            : clip.framingPlan?.sourceWindow == nil ? "conversation" : clip.framingPlan?.camera ?? "conversation"
                        let identity = try FeedPathCache.identity(source: source, region: region,
                            start: clip.sourceStart, duration: clip.sourceSpan, tuning: camera,
                            aspect: box.width / box.height, focus: clip.areaFocus)
                        if self.framingCacheEnabled, let cached = await FeedPathCache.shared.read(identity) {
                            path = cached
                            emit("Feed path cache hit; decode=0; intermediates=0")
                        } else {
                            path = try await self.centerStageService.cameraPath(source: source,
                                start: clip.sourceStart, duration: clip.sourceSpan, region: region, tuning: .named(camera),
                                aspect: box.width / box.height, fallbackCenter: clip.areaFocus, log: emit)
                            try Task.checkCancellation()
                            if self.framingCacheEnabled, path.reusable != false,
                               try SourceIdentityCache.shared.fingerprint(of: source) == identity.fingerprint {
                                await FeedPathCache.shared.store(path, identity: identity)
                            }
                        }
                    }
                    path.keyframes = TrackedPictureBounds.clamped(path.keyframes, to: clip.contentWindow ?? FreeCropRect())
                    guard path.keyframes.count >= 2 else {
                        reportContinuityFailure("Framing: no usable bounded area path; using the static crop")
                        fallbackReasons.set(job.key, "no usable bounded area path")
                        return nil
                    }
                    if ExpressRenderTesting.exportAreaPaths, clip.continuityTransform == nil {
                        let url = try await AreaFramer.frame(source: source, start: clip.sourceStart,
                            duration: clip.sourceSpan, area: area, path: path.keyframes, pictureWindow: clip.contentWindow,
                            centerStage: self.centerStageService, scratch: framingScratch, log: emit)
                        return PrepassArtifact(url: url, cacheable: false)
                    }
                    if self.framingCacheEnabled, clip.cacheable, path.reusable != false,
                       try SourceIdentityCache.shared.fingerprint(of: source) == clip.sourceFingerprint {
                        await self.segmentCache.storeJSON(path, key: job.key)
                    }
                    emit("Framing prepass: keyframes=\(path.keyframes.count); intermediates=0; uses=\(job.indices.count)")
                    if path.usedFallback {
                        fallbackReasons.set(job.key, "tracking found too little to follow")
                    }
                    return PrepassArtifact(path: path, cacheable: path.reusable != false)
                }
                let owned = framingScratch.appendingPathComponent(UUID().uuidString + ".mp4")
                if self.framingCacheEnabled && clip.cacheable,
                   await self.segmentCache.restore(key: job.key, to: owned) {
                    try Task.checkCancellation()
                    emit("Framing cache hit; uses=\(job.indices.count); intermediates=0")
                    try Task.checkCancellation()
                    return PrepassArtifact(url: owned, cacheable: true, wasCached: true)
                }
                // A failed copy must not interfere with a fresh framing result.
                try? FileManager.default.removeItem(at: owned)
                let fellBack = Mutex(false)
                do {
                    // Highlights go on before the camera crops the picture.
                    var clip = clip, source = source
                    var tracking: (source: URL, start: Double)?
                    if clip.pictureTake != nil {
                        let read = clip.pictureRead
                        if read.path != clip.sourcePath {
                            // Cameras keep following the source; only the picture is the take's.
                            tracking = (source: source, start: clip.sourceStart)
                            source = URL(fileURLWithPath: read.path)
                            clip.sourceStart = read.start
                        }
                    }
                    var burnedSources: [URL] = []
                    var drawingFailed = false
                    defer {
                        for burned in burnedSources { try? FileManager.default.removeItem(at: burned.deletingLastPathComponent()) }
                    }
                    if let tracks = clip.strikeTracks,
                       let burned = try await StrikeHighlightBurn.burn(source: source, start: clip.sourceStart,
                           duration: clip.sourceSpan, tracks: tracks, scratch: framingScratch, style: clip.strikeHighlightStyle ?? "outline") {
                        emit("Strike highlights: \(tracks.count) drawn before framing")
                        source = burned
                        burnedSources.append(burned)
                        clip.sourceStart = 0
                    }
                    if clip.screenStay == nil, let drawing = TelestrationLingerResolution.drawingForPiece(clip) {
                        do {
                            if let burned = try await TelestrationBurn.burn(source: source, start: clip.sourceStart,
                                duration: clip.duration, drawing: drawing, offset: drawing.offset ?? 0,
                                speed: clip.speed, scratch: framingScratch) {
                                // Track the pre-stay picture, retaining any strike highlights.
                                tracking = (source: source, start: clip.sourceStart)
                                source = burned
                                burnedSources.append(burned)
                                clip.sourceStart = 0
                                emit("Drawing: stay drawn before framing")
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            drawingFailed = true
                            emit("Drawing: stay failed (\(error)); rendering without it")
                            ErrorLog.record("Telestrator", "Stay before framing failed: \(error)")
                        }
                    }
                    let framed: URL
                    if let area = job.area {
                        framed = try await AreaFramer.frame(source: source, start: clip.sourceStart,
                            duration: clip.sourceSpan, tracking: tracking, area: area, framingPlan: clip.framingPlan,
                            pictureWindow: clip.contentWindow,
                            tuning: .named(clip.framingPlan?.camera ?? centerStageCamera), centerStage: self.centerStageService,
                            scratch: framingScratch, onFallback: { fellBack.withLock { $0 = true } }, log: emit)
                    } else {
                        // CenterStageService's synchronous tracking loop still
                        // serializes on its actor; only export/encode overlaps.
                        if clip.framingPlan?.recipe?.centerStageVIPs == true {
                            // Stored scene paths framed everyone; VIP-only tracks fresh from the VIPs' portraits.
                            let portraits = await Self.vipPortraits(sourcePath: clip.sourcePath,
                                keys: clip.framingPlan?.recipe?.centerStageVIPKeys, database: database)
                            emit("Center Stage: VIPs only, \(portraits.count) portrait(s)")
                            framed = try await self.centerStageService.reframeClip(source: source,
                                start: clip.sourceStart, duration: clip.sourceSpan,
                                tracking: tracking,
                                focusPortraits: portraits,
                                tuning: .named(clip.framingPlan?.camera ?? centerStageCamera), log: emit)
                        } else if let path = clip.cameraPath, CenterStageContinuity.savedPathUsesTransform(clip) {
                            framed = try await self.centerStageService.reframeClip(source: source,
                                start: clip.sourceStart, duration: clip.sourceSpan, path: path, log: emit)
                        } else {
                            framed = try await self.centerStageService.reframeClip(source: source,
                                start: clip.sourceStart, duration: clip.sourceSpan,
                                tracking: tracking, tuning: .named(clip.framingPlan?.camera ?? centerStageCamera), log: emit)
                        }
                    }
                    defer { try? FileManager.default.removeItem(at: framed) }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: framed, to: owned)
                    if fellBack.withLock({ $0 }) {
                        fallbackReasons.set(job.key, "tracking lost the subject")
                    }
                    let intermediates = job.area == nil || fellBack.withLock({ $0 }) ? 1 : 2
                    emit("Framing prepass: intermediates=\(intermediates); uses=\(job.indices.count)")
                    try Task.checkCancellation()
                    return PrepassArtifact(url: owned, cacheable: !fellBack.withLock { $0 } && !drawingFailed)
                } catch {
                    try Task.checkCancellation()
                    emit("Framing failed (\(error)) — using the static crop")
                    fallbackReasons.set(job.key, "tracking failed (\(error.localizedDescription))")
                    return nil
                }
            }
            // Read before the results below swap in framed sources.
            for job in jobs {
                guard let reason = fallbackReasons.reason(job.key) else { continue }
                for index in job.indices {
                    let clip = clips[index]
                    framingFallbacks.append(RenderFramingFallback(clipOriginKey: clip.originKey.isEmpty ? nil : clip.originKey,
                        startTime: clip.originalStart, reason: reason,
                        sourcePath: clip.originalSourcePath ?? clip.sourcePath,
                        sourceStart: clip.transcriptSourceStart ?? clip.sourceStart))
                }
            }
            for (job, result) in zip(jobs, results) {
                guard let result else {
                    for index in job.indices {
                        clips[index].cacheable = false
                        if index >= visibleClipCount {
                            for (moving, hold) in stayHolds where hold == index {
                                clips[moving].lingering = nil
                                clips[moving].cacheable = false
                            }
                        }
                    }
                    continue
                }
                if let path = result.path, let area = job.area {
                    for index in job.indices {
                        clips[index].cacheable = clips[index].cacheable && result.cacheable
                        if let plan = clips[index].framingPlan, !plan.isStatic, let frame = plan.sourceWindow,
                           path.trackedShare == 0, path.samples.allSatisfy({ $0.faces.isEmpty }), clips[index].areaFocus == nil {
                            let fullCanvas = AreaFramer.pixelBounds(of: area) == CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
                            let window = fullCanvas ? FitSpec.intersection(frame, clips[index].contentWindow ?? FreeCropRect())
                                : clips[index].areaRegion ?? frame
                            clips[index].cameraPath = nil
                            if fullCanvas {
                                clips[index].freeCrops = [FreeCrop(src: window, dst: FreeCropRect())]
                                clips[index].areaWindow = nil
                            } else {
                                clips[index].areaWindow = window
                                clips[index].fitArea = area
                            }
                            clips[index].framingPlan = .static(window: window, fit: plan.fit, feather: plan.feather, blur: plan.blur)
                            emit(FocusFrame.nobodyInside)
                        } else {
                            clips[index].cameraPath = path.keyframes
                        }
                        clips[index].areaPathSource = path.sourceSize
                        clips[index].areaPathArea = area
                        if clips[index].continuitySavedTransform == true {
                            clips[index].continuityGrid = ContinuityCameraGrid.choose(path: path.keyframes,
                                source: path.sourceSize, box: AreaFramer.pixelBounds(of: area).size)
                        }
                        clips[index].framingIdentity = job.key
                        clips[index].centerStage = false
                        clips[index].wide = false
                        clips[index].effectiveCropXFrac = nil
                    }
                } else if let url = result.url {
                    let identity = result.identity ?? job.key
                    if framingCacheEnabled && job.clip.cacheable && result.cacheable && !result.wasCached {
                        framingArtifacts.append(.init(key: identity, source: url))
                    }
                    for index in job.indices {
                        clips[index].useFramedSource(url, identity: identity,
                            areaPass: areaPass, reusable: result.cacheable)
                    }
                }
            }
            #if PERFORMANCE_BASELINE
            emit("FRAMING_PASS area=\(areaPass) jobs=\(jobs.count) uses=\(jobs.reduce(0) { $0 + $1.indices.count }) seconds=\(passStarted.duration(to: .now).seconds)")
            #endif
        }
        for index in 0..<visibleClipCount {
            // A per-picture path can become resolved only in the moving area
            // pass. It has not burned the stay, so attach it after that pass.
            if clips[index].screenStay == nil, clips[index].lingering != nil,
               let holdIndex = stayHolds[index], let frame = stayFrames[holdIndex] {
                clips[index].screenStay = TelestrationScreenStay.mapping(hold: frame, following: clips[index],
                    canvas: CGSize(width: Self.width, height: Self.height))
            }
            if clips[index].screenStay == nil, clips[index].lingering?.motion == nil, !reportedStayFallback,
               TelestrationLingerResolution.drawingForPiece(clips[index]) != nil {
                emit(TelestrationScreenStay.fallbackMessage)
                ErrorLog.record("Telestrator", TelestrationScreenStay.fallbackMessage)
                reportedStayFallback = true
            }
            guard let mapping = clips[index].screenStay else { continue }
            var actual = clips[index]
            // Failed prepasses can leave their requested camera flags behind.
            // Validate the stream that the segment will actually produce.
            actual.centerStage = false
            if actual.areaPathSource == nil { actual.cameraPath = nil }
            let final = TelestrationScreenStay.mapping(hold: mapping.frame, following: actual,
                canvas: CGSize(width: Self.width, height: Self.height))
            if final != mapping {
                clips[index].lingering = nil
                clips[index].screenStay = nil
                clips[index].cacheable = false
                emit("Drawing: framing changed after preparation; rendering without the stay")
                ErrorLog.record("Telestrator", "Stay framing changed after preparation")
            }
        }
        if clips.count > visibleClipCount { clips.removeLast(clips.count - visibleClipCount) }
        #if PERFORMANCE_BASELINE
        emit("FRAMING_PREPARATION seconds=\(framingStarted.duration(to: .now).seconds)")
        #endif
        // Split pieces of one clip report one fallback: its earliest piece.
        var seenFallbacks: Set<String> = []
        framingFallbacks = framingFallbacks.sorted { $0.startTime < $1.startTime }.filter {
            let identity = $0.clipOriginKey ?? "\($0.sourcePath ?? "")|\($0.sourceStart ?? 0)"
            return seenFallbacks.insert(identity + "|" + $0.reason).inserted
        }
        RenderFramingFallbackCollector.current?.record(framingFallbacks)
        let renderedFallbacks = framingFallbacks.isEmpty ? nil : framingFallbacks
        guard !clips.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "No valid clips in the video track"])
        }
        guard FFmpeg.isAvailable else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg not found — install it (e.g. brew install ffmpeg)"])
        }

        let totalDuration = clips.map { $0.startTime + $0.duration }.max() ?? 0
        let outputURL = preview
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("ExactPreview-\(UUID().uuidString).mp4")
            : try Self.outputFile(profile: profile, totalDuration: totalDuration, baseName: outputName)
        let scratch = try await render.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var previewSucceeded = false
        defer {
            if preview && !previewSucceeded { try? FileManager.default.removeItem(at: outputURL) }
        }

        // Slice the timeline into constant-membership segments + black gaps.
        let planned = Self.plannedSegments(clips)
        if planned.segments.enumerated().contains(where: { index, segment in
            guard index > 0 else { return false }
            let incoming = Self.joinClip(in: segment.clips)
            let outgoing = TelestrationTransition.outgoing(in: planned.segments[index - 1].clips, incoming: incoming)
            return !TelestrationTransition.crossingHolds(outgoing: planned.segments[index - 1].clips, incoming: segment.clips, at: segment.start).isEmpty
                && TelestrationTransition.requiresCut(incoming?.transIn ?? outgoing?.transOut)
        }) { emit(TelestrationTransition.cutMessage) }
        let fullSegments = TelestrationTransition.synchronize(planned.segments, transitions: planned.transitions,
            timed: Self.usesTimedAssembly(document, transitions: planned.transitions), duration: RenderContext.transitions.xfadeDuration, context: stayTransitions)
        emit("Timeline: \(clips.count) clip(s) → \(fullSegments.count) segment(s), \(totalDuration.timecode) total")

        // Assemble clip list + transition list in the same order/rules as the
        // Python generator (pad/truncate at the end for exact parity).
        var clipPaths: [URL] = []

        // A Wizard document carries its run's caption style, language, safe
        // area and placement; a Builder document has none and uses the profile.
        let captionProfile = document.captionStyleID.map { profile.withCaptionStyle(id: $0) } ?? profile
        let captionLanguage: String? = if let language = document.captionLanguage {
            language.isEmpty ? nil : language
        } else {
            profile.captionLanguages.first
        }
        let captionSafeArea = document.captionSafeAreaOnly == true
            ? PlatformSafeArea.resolve(platforms: document.captionSafeAreaPlatforms ?? document.renderSettings.platformSafeArea.platforms,
                                       aspectRatio: document.renderSettings.aspectRatio)
            : PlatformSafeArea.resolve(document.renderSettings)
        let captionRenderer = CaptionRenderer(videoWidth: Self.width, videoHeight: Self.height,
                                              style: captionProfile.captions.applyingSharedStyle(profile.textStyles ?? []),
                                              safeArea: captionSafeArea, safeAreaOnly: document.captionSafeAreaOnly == true)
        let captionRenderers = CaptionRendererSet(base: captionRenderer,
            speakerStyles: captionProfile.speakerCaptionStyles(runStyleID: document.captionStyleID))
        let wizardCaptions = document.captionPosition.map { run in
            WizardCaptionPlacement(runPosition: run,
                                   defaultClipPosition: run == "auto" ? captionProfile.captions.position : run,
                                   speakerPositions: document.speakerCaptionPositions ?? [:])
        }
        let captionCache = CaptionPNGCache(renderers: captionRenderers, directory: scratch)
        let captionEvidence = CaptionSpeakerEvidenceMemo(database: database)
        let segmentDedupe = SegmentDedupe()
        let segmentCount = fullSegments.count
        // A Wizard document plans captions once per original cut, as the
        // Wizard's extraction does, so B-roll or layout boundaries never
        // change paging or the input-limit fallback; segments take their
        // slice. Builder documents keep planning per segment.
        let cutCaptions: [CutCaptionPlan]? = if let wizardCaptions {
            try await planCutCaptions(Self.captionCuts(clips), document: document, database: database,
                captionLanguage: captionLanguage, captionRenderers: captionRenderers,
                wizardCaptions: wizardCaptions,
                captionStyle: captionProfile.captions.applyingSharedStyle(profile.textStyles ?? []),
                captionEvidence: captionEvidence, emit: emit)
        } else { nil }

        // Text and image overlays — pre-rendered to full-frame PNGs and
        // composited in one pass (images first so text stays on top).
        func clampWindow(start: Double, end: Double) -> (Double, Double) {
            (start, min(end, totalDuration))
        }
        // The document's own safe-area choice, handed to the renderers
        // explicitly rather than read back from the task-local context.
        let safeArea = PlatformSafeArea.resolve(document.renderSettings)
        let textRenderer = TextOverlayRenderer(videoWidth: Self.width, videoHeight: Self.height, safeArea: safeArea, textStyles: profile.textStyles ?? [])
        let imageRenderer = ImageOverlayRenderer(videoWidth: Self.width, videoHeight: Self.height, safeArea: safeArea)
        var overlays: [TimedOverlayPNG] = []
        if let safeArea {
            emit("Overlays kept clear of \(safeArea.platforms.map(\.label).joined(separator: ", ")) buttons")
        }
        // Wizard brand layers (logo watermark, headline): full-frame PNGs with
        // their own stage in each segment, on the footage before captions,
        // name tags and overlays, like the Wizard's extraction; never over
        // bumpers or Wizard cards.
        var brandPNGs: [URL] = []
        for layer in document.brandLayers ?? [] {
            let url = URL(fileURLWithPath: layer.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                emit("Brand \(layer.kind) skipped: \(url.lastPathComponent) is missing")
                continue
            }
            brandPNGs.append(url)
        }
        let brandSpans = brandPNGs.isEmpty ? [] : Self.brandLayerSpans(document: document, totalDuration: totalDuration)
        let brandUnderCutaways = document.brandLayerStage == TimelineDocument.brandUnderCutaways
        for item in document.imageOverlays.map({ $0.keptClear(of: safeArea, frameAspectRatio: RenderContext.settings.aspectRatio) }) {
            let (start, end) = clampWindow(start: item.startTime, end: item.endTime)
            guard end > start, let png = try? imageRenderer.render(item, to: scratch) else { continue }
            let identity = try RenderSegmentCache.key(item) + SourceIdentityCache.shared.fingerprint(of: item.url)
            overlays.append(TimedOverlayPNG(png: png, startTime: start, endTime: end,
                transIn: item.transIn, transOut: item.transOut, identity: identity, track: item.track).positioned())
        }
        let statVideos = document.textOverlays.contains { $0.stat != nil } ? try await database.fetchVideos() : []
        let boundText = document.textOverlays.flatMap {
            StrikeStatSourceBinding.mapped($0, clips: document.videoTrack, scenes: scenes, videos: statVideos)
        }
        for item in boundText.map({ $0.keptClear(of: safeArea) })
        where item.stat != nil || !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (start, end) = clampWindow(start: item.startTime, end: item.endTime)
            guard end > start else { continue }
            // A Wizard word reveal: the extraction's progressive PNGs, hard cut.
            let reveal = item.animation == WordRevealSchedule.animation
                ? WordRevealSchedule.steps(duration: end - start, wordCount: TextOverlayRenderer.wordCount(item.text)) : []
            if !reveal.isEmpty {
                let identity = try RenderSegmentCache.key(item)
                for step in reveal {
                    guard let png = try? textRenderer.render(item, to: scratch, visibleWords: step.visibleWords) else { continue }
                    overlays.append(TimedOverlayPNG(png: png, startTime: start + step.start, endTime: start + step.end,
                        transIn: "cut", transOut: "cut", identity: identity + "|words:\(step.visibleWords)"))
                }
                continue
            }
            guard let png = try? textRenderer.render(item, to: scratch) else { continue }
            overlays.append(TimedOverlayPNG(png: png, startTime: start, endTime: end,
                transIn: item.transIn, transOut: item.transOut, identity: try RenderSegmentCache.key(item)))
        }
        // Include font-file identity as well as rendered pixels and style.
        // System-font output is represented by the raster PNG digest.
        let fontFingerprints = try? AssetStore.allFiles(of: .fonts).map {
            try SourceIdentityCache.shared.fingerprint(of: $0.url)
        }.sorted()
        var overlayPlan = Self.partitionOverlays(overlays, segments: fullSegments)
        let fusedOverlayCount = overlayPlan.bySegment.values.reduce(0) { $0 + $1.count }
        emit("Overlay plan: segment=\(fusedOverlayCount); timeline=\(overlayPlan.remaining.count)")

        // Joins are decided by the clips alone (`plannedSegments`), so they
        // are known before any segment is encoded.
        var transitions = planned.transitions

        // Spanning overlays ride the segments they touch, on each segment's
        // own clock, when every join keeps pixels in place and no overlay
        // touches a gap or bumper; that removes the final pass over the
        // whole video. Otherwise the final pass runs as before. Prerendered
        // clips are copied as segments, so one final pass beats re-encoding
        // each of them with the overlay burned in.
        var spanningFused = false
        if overlayFusionEnabled, prerenderedSources.isEmpty, !overlayPlan.remaining.isEmpty,
           transitions.allSatisfy(Self.transitionKeepsOverlayPixels),
           let fused = Self.fuseSpanningOverlays(overlayPlan, segments: fullSegments) {
            emit("Spanning overlays fused into segments: \(overlayPlan.remaining.count)")
            overlayPlan = fused
            spanningFused = true
        }

        // A transition changes the timeline clock and may not commute with a
        // nonlinear look. Retained overlays must also land BELOW the Express
        // look and burn-ins. Keep the old final extraction order in those cases.
        let deferExtract = ((compositeEffect != nil || !burnIns.isEmpty)
            && (!overlayPlan.remaining.isEmpty || transitions.contains { $0 != nil && $0 != "cut" }))
            || (muteSource && !document.soundTrack.isEmpty)

        // Render every segment concurrently (bounded) — each is one
        // independent ffmpeg job with captions burned in the same pass.
        // A fused spanning overlay adds its RGBA raster stream to every
        // segment process (about 190 MiB each), and three such processes
        // already saturate the shared hardware encoder, so fused renders cap
        // the concurrency at three to hold the peak memory down.
        let segmentJobs = spanningFused ? min(FFmpeg.jobLimit, 3) : FFmpeg.jobLimit
        let replaceFootage = dubState?.replaceBeforeAssembly ?? DubSourceEnvelope.replacesFootageBeforeAssembly(document)
        try Task.checkCancellation()
        let artifacts = try await BoundedConcurrency.map(fullSegments,
                                                        limit: segmentJobs) { index, segment in
            try await self.renderSegment(segment, index: index, of: segmentCount,
                                         scratch: scratch, database: database,
                                         captionLanguage: captionLanguage,
                                         captionRenderers: captionRenderers, wizardCaptions: wizardCaptions,
                                         cutCaptions: cutCaptions,
                                         captionCache: captionCache, captionEvidence: captionEvidence,
                                         dedupe: segmentDedupe,
                                         captionStyle: captionProfile.captions.applyingSharedStyle(profile.textStyles ?? []),
                                         fontFingerprints: fontFingerprints,
                                         overlays: overlayPlan.bySegment[index] ?? [],
                                         brandLayers: Self.brandLayerWindows(spans: brandSpans, segmentStart: segment.start,
                                                                             segmentEnd: segment.end).flatMap { window in
                                             brandPNGs.map { CaptionOverlay(png: $0, x: 0, y: 0, start: window.lowerBound,
                                                                            end: window.upperBound) }
                                         },
                                         brandUnderCutaways: brandUnderCutaways,
                                         prerendered: prerenderedSources,
                                         burnIns: RenderBurnIns.intersecting(deferExtract ? [] : burnIns, start: segment.start,
                                             duration: segment.duration, totalDuration: totalDuration),
                                         burnInDuration: totalDuration,
                                         muteSource: muteSource || (replaceFootage && !segment.clips.contains(where: \.bumper)),
                                         compositeEffect: deferExtract ? nil : compositeEffect, emit: emit)
        }
        clipPaths = artifacts.map(\.url)

        guard !clipPaths.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "No segments could be rendered"])
        }
        while transitions.count < clipPaths.count - 1 { transitions.append(nil) }
        transitions = Array(transitions.prefix(max(0, clipPaths.count - 1)))

        try Task.checkCancellation()
        // Reuse only a complete finishing pass. Its inputs are actual segment
        // bytes and raster pixels, not document JSON or scratch/overlay UUIDs.
        // Music, bumpers and recipe transitions retain their existing pipeline.
        let transitionDuration = RenderContext.transitions.xfadeDuration
        let timedAssembly = Self.usesTimedAssembly(document, transitions: transitions)
            || (dubState?.frameBounded == true && bumperSpans.isEmpty)
        // Timed joins use the document clock, not probed MP4 lengths. The
        // existing finishing/range caches reconstruct clocks from those probes.
        let canReuseAssembly = !timedAssembly && document.soundTrack.isEmpty && bumperSpans.isEmpty
            && !transitions.contains(where: { TransitionRecipes.isRecipe($0) })
            && artifacts.allSatisfy(\.reusable)
        // With the overlays fused there is no final pass, but the assembled
        // video is still worth restoring whole on an unchanged rerender.
        // An empty speech window still has a replacement pass; ordinary empty
        // documents share its dub JSON but must not reuse that silenced output.
        let emptyReplacementWindow = dubState?.replacementActive == true && (document.dubLines ?? []).isEmpty
        let canReuseFinishing = finishingCacheEnabled && canReuseAssembly && !emptyReplacementWindow
            && (!overlayPlan.remaining.isEmpty || clipPaths.count > 1)
        let segmentDigests = canReuseFinishing ? try? await RenderFinishingKey.digests(of: clipPaths) : nil
        var finishingKey: String?
        if let segmentDigests {
            // Only cacheable plain joins reach here. Their predicted clock is
            // the same one restored on a finishing hit; recipes/timed assembly
            // use measured overlaps below and never reuse this finishing key.
            var dubSegments: [DubPauseRules.CacheLine]?
            if hasDub, !DubFreezes.intervals(in: document).isEmpty {
                let dubClock = await Self.predictedClock(paths: clipPaths, segments: fullSegments,
                    transitions: transitions, transitionDuration: transitionDuration)
                dubSegments = DubPauseRules.cacheSegments(lines: dubClock.map(document.dubLines ?? []),
                    freezes: DubFreezes.intervals(in: document, clock: dubClock))
            }
            finishingKey = try? await RenderFinishingKey.make(
                segmentDigests: segmentDigests, transitions: transitions, transitionDuration: transitionDuration,
                overlays: overlayPlan.remaining, settings: Self.finishingSettings(RenderContext.settings),
                encoder: FFmpeg.encodeArgs + FFmpeg.intermediateCacheIdentity,
                dub: document.dub, dubLines: document.dub == nil ? nil : document.dubLines,
                dubSegments: dubSegments)
        }
        try Task.checkCancellation()
        // Ranges need the actual hard-cut groups and their encoded lengths;
        // both are known only while assembly's intermediates exist.
        let segmentHits = artifacts.filter(\.wasCached).count
        let rangesAllowed: Bool
        switch incrementalFinishing {
        case .off: rangesAllowed = false
        case .always: rangesAllowed = true
        case .editsOnly: rangesAllowed = segmentHits > 0
        }
        let assemblyGroups = Mutex<[RenderFinishingRanges.Group]>([])
        let digestByPath = Dictionary(zip(clipPaths, segmentDigests ?? []), uniquingKeysWith: { first, _ in first })
        let collectGroups: @Sendable ([RenderEngine.AssemblyGroup]) async -> Void = { groups in
            if let identified = await Self.identifyGroups(groups, digestByPath: digestByPath,
                                                          transitionDuration: transitionDuration) {
                assemblyGroups.withLock { $0 = identified }
            }
        }
        // Range identities describe pre-dub audio. A full finishing key includes
        // the reviewed dub; range reuse resumes for ordinary undubbed renders.
        let onGroups = rangesAllowed && finishingKey != nil && !hasDub ? collectGroups : nil
        var complete = true
        let assemblyArtifacts = Mutex<[RenderSegmentCache.Entry]>([])
        let assemblyCache = assemblyCacheEnabled && canReuseAssembly ? RenderEngine.AssemblyCache(
            cache: segmentCache, stagingDirectory: scratch,
            record: { entry in assemblyArtifacts.withLock { $0.append(entry) } },
            hit: { emit("Assembly cache hit; crossfade encode=0") },
            dub: document.dub, dubLines: document.dub == nil ? nil : document.dubLines) : nil
        var assembled = scratch.appendingPathComponent("assembled.mp4")
        var rangeArtifacts: [RenderSegmentCache.Entry] = []
        let joinOverlaps = JoinOverlaps()
        var clock = RenderClock.identity
        let finishingWasCached: Bool
        if let key = finishingKey {
            finishingWasCached = await segmentCache.restore(key: key, to: assembled)
        } else {
            finishingWasCached = false
        }
        if finishingWasCached {
            emit("Finishing cache hit; assembly and overlay encodes=0")
            PerfSignpost.event("FinishingCacheHit")
            // Deferred burn-ins still map onto the assembled clock. A cached
            // finishing pass only ever holds plain crossfades, so the same
            // clamping predicts every overlap exactly.
            clock = await Self.predictedClock(paths: clipPaths, segments: fullSegments,
                                              transitions: transitions, transitionDuration: transitionDuration)
        } else {
            emit("Assembling \(clipPaths.count) segment(s)…")
            if clipPaths.count == 1 {
                assembled = clipPaths[0]
            } else if !bumperSpans.isEmpty {
                bumperSpans = try await concatenateWithBumpers(paths: clipPaths, segments: fullSegments,
                    transitions: transitions, scratch: scratch, output: assembled, overlaps: joinOverlaps,
                    frameBounded: dubState?.frameBounded ?? Self.usesFrameBoundedBumpers(document, transitions: transitions))
            } else {
                let fellBack = Mutex(false)
                try await render.concatenate(clips: clipPaths, transitions: transitions, output: assembled,
                    clipDurations: timedAssembly ? fullSegments.map(\.duration) : nil,
                    boundRecipes: dubState?.frameBounded == true,
                    transitionDuration: transitionDuration, assemblyCache: assemblyCache,
                    overlaps: joinOverlaps,
                    onFallback: { fellBack.withLock { $0 = true } }, onGroups: onGroups)
                if fellBack.withLock({ $0 }) { finishingKey = nil }
            }

            let videoDuration = await FFmpeg.duration(of: assembled)
            // Joins overlap segments: work on the assembled video maps its
            // timeline times onto the shorter clock.
            clock = RenderClock(segmentStarts: fullSegments.map(\.start),
                segmentEnds: fullSegments.map(\.end), joins: joinOverlaps)
            if !joinOverlaps.assembledPieces.isEmpty {
                let oldClock = RenderClock(segmentStarts: fullSegments.map(\.start), overlaps: joinOverlaps.all)
                for segment in fullSegments {
                    emit(String(format: "Recipe clock %.6f–%.6fs: start %.6f → %.6f (%+.6fs), end %.6f → %.6f (%+.6fs); dub, music, final overlays and deferred captions follow",
                        segment.start, segment.end, oldClock.map(segment.start), clock.map(segment.start),
                        clock.map(segment.start) - oldClock.map(segment.start),
                        oldClock.map(segment.end, end: true), clock.map(segment.end, end: true),
                        clock.map(segment.end, end: true) - oldClock.map(segment.end, end: true)))
                }
            }
            if !clock.isIdentity {
                emit(String(format: "Transitions shortened the timeline by %.2fs; dub, music and overlays follow",
                            totalDuration - clock.map(totalDuration, end: true)))
            }

            // Dub the assembled source before music, so the speech duck never
            // lowers the music bed. Fail the render if reviewed speech is missing.
            if hasDub, let settings = document.dub,
               !(document.dubLines ?? []).isEmpty || (dubState?.replacementActive == true && !replaceFootage) {
                let timelineLines = document.dubLines ?? []
                let lines = clock.map(timelineLines)
                let freezes = DubFreezes.intervals(in: document, clock: clock)
                emit("Mixing \(lines.count) dubbed line(s)…")
                let track = scratch.appendingPathComponent("dub_track.caf")
                try await DubMixer.buildTrack(lines: lines, duration: videoDuration, output: track,
                                              directory: dubSynthesizer.directory, freezes: freezes)
                let withDub = scratch.appendingPathComponent("with_dub.mp4")
                try await DubMixer.overlay(video: assembled, track: track, lines: lines,
                                           settings: settings, output: withDub, freezes: freezes,
                                           bumpers: DubSourceEnvelope.bumpers(in: document, clock: clock),
                                           sourceAlreadyReplaced: replaceFootage)
                assembled = withDub
            }

            // A Wizard document mixes its music like the Wizard: one track from
            // the start under the whole reel, fixed gain, 2 s fade, no ducking.
            if document.musicMix == TimelineDocument.wizardMusicMix,
               let item = document.soundTrack.min(by: { $0.startTime < $1.startTime }) {
                let musicLookup = Self.musicLibraryOverride ?? Dictionary(uniqueKeysWithValues:
                    WizardEngine.availableMusic().map { ($0.name, $0.url) })
                if let url = musicLookup[item.name] {
                    emit("Adding music (\(item.name))...")
                    let withMusic = scratch.appendingPathComponent("with_music.mp4")
                    do {
                        try await render.overlayMusic(video: assembled, music: url, output: withMusic, volume: item.volume)
                        assembled = withMusic
                    } catch {
                        try Task.checkCancellation()
                        complete = false
                        emit("Music overlay failed, continuing without music (\(error))")
                    }
                } else {
                    emit("Music '\(item.name)' is not in the music library; continuing without music")
                }
            } else if !document.soundTrack.isEmpty {
                // Music track (blocks with silence-filled gaps + original-audio ducking).
                let musicLookup = Self.musicLibraryOverride ?? Dictionary(uniqueKeysWithValues:
                    WizardEngine.availableMusic().map { ($0.name, $0.url) })
                var blocks: [(start: Double, duration: Double, music: URL?, volume: Int, offset: Double)] = []
                for item in document.soundTrack.sorted(by: { $0.startTime < $1.startTime }) {
                    guard let url = musicLookup[item.name], item.duration > 0 else { continue }
                    let start = clock.map(item.startTime)
                    let end = clock.map(item.startTime + item.duration, end: true)
                    guard end > start else { continue }
                    blocks.append((start, end - start, url, item.volume, item.sourceOffset))
                }
                // A bumper owns the sound as well as the picture: cut every
                // music block around the measured bumper spans. Each remaining
                // piece keeps its offset into the song so it continues, not restarts.
                blocks = blocks.flatMap { block in
                    TimelineDocument.subtracting(bumperSpans, from: block.start..<(block.start + block.duration))
                        .map { (start: $0.lowerBound, duration: $0.upperBound - $0.lowerBound,
                                music: block.music, volume: block.volume, offset: block.offset + ($0.lowerBound - block.start)) }
                }
                if !blocks.isEmpty {
                    var filled: [(start: Double, duration: Double, music: URL?, volume: Int, offset: Double)] = []
                    var soundCursor = 0.0
                    for block in blocks {
                        if block.start > soundCursor + 0.05 {
                            filled.append((soundCursor, block.start - soundCursor, nil, 0, 0))
                        }
                        filled.append(block)
                        soundCursor = block.start + block.duration
                    }
                    if soundCursor < videoDuration {
                        filled.append((soundCursor, videoDuration - soundCursor, nil, 0, 0))
                    }
                    emit("Building music track (\(blocks.count) block(s))…")
                    let musicTrack = scratch.appendingPathComponent("music_track.m4a")
                    do {
                        try await buildMusicTrack(segments: filled, totalDuration: videoDuration, output: musicTrack)
                        let withMusic = scratch.appendingPathComponent("with_music.mp4")
                        try await overlayMusicTrack(video: assembled, musicTrack: musicTrack,
                                                    segments: filled, output: withMusic)
                        assembled = withMusic
                    } catch {
                        try Task.checkCancellation()
                        complete = false
                        emit("Music overlay failed, continuing without music (\(error))")
                    }
                }
            }

            let remainingOverlays = overlayPlan.remaining.compactMap { overlay -> TimedOverlayPNG? in
                var overlay = overlay
                overlay.remapTrack(using: clock)
                overlay.startTime = clock.map(overlay.startTime)
                overlay.endTime = min(clock.map(overlay.endTime, end: true), videoDuration)
                return overlay.endTime > overlay.startTime ? overlay : nil
            }
            if !remainingOverlays.isEmpty {
                let withText = scratch.appendingPathComponent("with_overlays.mp4")
                var burned = false
                let groups = assemblyGroups.withLock { $0 }
                if finishingKey != nil, bumperSpans.isEmpty, !groups.isEmpty {
                    do {
                        if let entries = try await addOverlaysByRange(
                            video: assembled, videoDuration: videoDuration, overlays: remainingOverlays,
                            groups: groups, scratch: scratch, output: withText, emit: emit) {
                            rangeArtifacts = entries
                            burned = true
                        }
                    } catch {
                        // A range failure must not cost the render its overlays.
                        try Task.checkCancellation()
                        try? FileManager.default.removeItem(at: withText)
                        emit("Finishing ranges failed; burning overlays in one pass (\(error))")
                    }
                }
                if !burned {
                    emit("Burning \(remainingOverlays.count) overlay(s)…")
                    do {
                        try await addOverlays(video: assembled, overlays: remainingOverlays, excluding: bumperSpans, output: withText)
                        burned = true
                    } catch {
                        try Task.checkCancellation()
                        complete = false
                        emit("Overlay burn failed, continuing without overlays (\(error))")
                    }
                }
                if burned { assembled = withText }
            }
        }

        // Speech Polish runs on the final mix (after dub, music and overlays)
        // so the loudness target applies to what the viewer hears. `assembled`
        // stays unpolished: it is the finishing cache's entry, keyed without
        // the polish choice, so toggling polish reuses it.
        var finalSource = assembled
        if let polish = document.renderSettings.speechPolish, polish.enabled {
            emit("Speech polish (\(polish.strength.label.lowercased()))…")
            let polished = scratch.appendingPathComponent("speech_polished.mp4")
            try await SpeechPolish.apply(input: assembled, output: polished, settings: polish)
            finalSource = polished
        }

        if deferExtract {
            emit("Express finishing: decode/encode whole-frame look after document overlays, then burn-ins")
            // Burn-ins were timed on the timeline; the assembled video may be shorter.
            let mappedBurnIns = burnIns.map { overlay -> RenderEngine.ClipOverlay in
                var overlay = overlay
                overlay.start = overlay.start.map { clock.map($0) }
                overlay.end = overlay.end.map { clock.map($0, end: true) }
                return overlay
            }
            try await render.extractClip(source: finalSource, start: 0, duration: clock.map(totalDuration, end: true),
                overlays: mappedBurnIns, effect: compositeEffect, mute: muteSource, intermediateSource: true, output: outputURL)
        } else {
            try FileManager.default.copyItemReplacing(at: finalSource, to: outputURL)
        }
        let finalDuration = await FFmpeg.duration(of: outputURL)

        try Task.checkCancellation()
        let finishingArtifact = finishingWasCached ? nil : finishingKey.map {
            RenderSegmentCache.Entry(key: $0, source: assembled)
        }
        let finishingArtifacts = framingArtifacts + assemblyArtifacts.withLock { $0 } + rangeArtifacts
            + [finishingArtifact].compactMap { $0 }
        if preview {
            if complete && finalDuration > 0 { await publishSegments(artifacts, clips: clips, finishing: finishingArtifacts) }
            try Task.checkCancellation()
            previewSucceeded = true
            emit("Exact preview ready (\(finalDuration.timecode))")
            return RenderResult(url: outputURL, duration: finalDuration, framingFallbacks: renderedFallbacks, clock: clock)
        }

        // Persist the COMPLETE editable document so "Open in Builder" (in
        // either app) restores every clip flag and layer setting.
        let encoder = JSONEncoder()
        let timelineJSON = (try? encoder.encode(document))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let recordID = try await database.insertGeneratedVideo(path: outputURL.path,
                                                               duration: (finalDuration * 10).rounded() / 10,
                                                               timelineJSON: timelineJSON,
                                                               wizardProvider: nil, wizardModel: nil,
                                                               projectID: projectID, batchID: batchID,
                                                               settings: WizardRunSettings(options: wizardOptions ?? WizardOptions(renderSettings: document.renderSettings),
                                                                   sourceProfile: profile.profileName, sourceVideoPaths: Array(Set(scenes.map(\.videoPath))).sorted(),
                                                                   sourceSceneIDs: scenes.map(\.id), builderDocumentJSON: timelineJSON,
                                                                   renderFingerprint: renderFingerprint), roles: roles)
        try await database.saveGeneratedTraits(videoID: recordID,
                                               traits: .derive(document: document, scenes: scenes))
        await ReelTraitRecording.record(url: outputURL, id: recordID, database: database,
            document: document, scenes: scenes, log: emit)
        try Task.checkCancellation()
        if complete && finalDuration > 0 { await publishSegments(artifacts, clips: clips, finishing: finishingArtifacts) }
        emit("Saved \(outputURL.lastPathComponent)")
        return RenderResult(url: outputURL, duration: finalDuration, framingFallbacks: renderedFallbacks,
                            clock: clock, recordID: recordID)
    }

    /// The clock plain crossfades produce, from the segment files' lengths
    /// and RenderEngine's own clamping; a run that cannot crossfade joins
    /// with hard cuts.
    nonisolated static func predictedClock(paths: [URL], segments: [Segment], transitions: [String?],
                                           transitionDuration: Double) async -> RenderClock {
        let names = transitions.map { $0 == "cut" ? nil : $0 }
        guard names.contains(where: { $0 != nil }), paths.count == segments.count else { return .identity }
        let durations = (try? await BoundedConcurrency.map(paths, limit: FFmpeg.jobLimit) { _, path in
            await FFmpeg.duration(of: path)
        }) ?? []
        guard durations.count == paths.count else { return .identity }
        return RenderClock(segmentStarts: segments.map(\.start),
                           overlaps: crossfadeOverlaps(durations: durations, transitions: names,
                                                       transitionDuration: transitionDuration))
    }

    /// Overlap per gap for runs of crossfaded segments (hard cuts are 0).
    nonisolated static func crossfadeOverlaps(durations: [Double], transitions: [String?],
                                              transitionDuration: Double) -> [Int: Double] {
        RenderEngine.crossfadeOverlaps(durations: durations, transitions: transitions,
            transitionDuration: transitionDuration)
    }

    /// Join ordinary runs normally, then join each bumper boundary while
    /// measuring the resulting clock. This accounts for recipe bridges and
    /// hard-cut fallbacks as well as successful crossfades; final overlays
    /// must never use an estimated, pre-transition bumper position.
    func concatenateWithBumpers(paths: [URL], segments: [Segment], transitions: [String?],
                                        scratch: URL, output: URL,
                                        overlaps: JoinOverlaps? = nil, frameBounded: Bool = false) async throws -> [Range<Double>] {
        if frameBounded {
            // Publish only a completed attempt; a failed bounded recipe must
            // not leave stale bridge records in the measured fallback clock.
            let joins = JoinOverlaps()
            // Container durations include AAC padding and extra terminal
            // video frames. They cannot predict a removed preview's speech
            // offset. Bound the streams to the shared editorial frame clock.
            do {
                try await render.concatenate(clips: paths, transitions: transitions, output: output,
                    clipDurations: segments.map(\.duration), boundRecipes: true, overlaps: joins)
                let clock = RenderClock(segmentStarts: segments.map(\.start),
                    segmentEnds: segments.map(\.end), joins: joins)
                var spans: [Range<Double>] = []
                for segment in segments where segment.clips.first?.bumper == true {
                    let span = clock.map(segment.start)..<clock.map(segment.end, end: true)
                    if let last = spans.last, span.lowerBound <= last.upperBound + 0.001 {
                        spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                    } else { spans.append(span) }
                }
                for (gap, value) in joins.all { overlaps?.record(gap, value) }
                for (index, range) in joins.assembledPieces { overlaps?.reconcile(index, range: range) }
                for bridge in joins.assembledBridges {
                    overlaps?.bridge(gap: bridge.gap, tail: bridge.tail, head: bridge.head, range: bridge.range)
                }
                return spans
            } catch {
                try Task.checkCancellation()
                ErrorLog.record("Dub", "Frame-bounded bumper assembly failed; using measured assembly: \(error)")
                try? FileManager.default.removeItem(at: output)
            }
        }
        var runs: [Range<Int>] = []
        var start = 0
        for index in 1..<segments.count {
            let previous = segments[index - 1].clips.first
            let current = segments[index].clips.first
            let sameBumper = previous?.bumper == true && current?.bumper == true
                && previous?.sourcePath == current?.sourcePath && previous?.startTime == current?.startTime
            if !sameBumper && (previous?.bumper == true || current?.bumper == true) {
                runs.append(start..<index)
                start = index
            }
        }
        runs.append(start..<segments.count)
        var assembled: URL?
        var elapsed = 0.0
        var spans: [Range<Double>] = []
        var recipePieces: [Int: Range<Double>] = [:]
        var recipeBridges: [JoinOverlaps.Bridge] = []
        var hasRecipeClock = false
        for (index, run) in runs.enumerated() {
            let part = scratch.appendingPathComponent("bumper_run_\(index).mp4")
            let runJoins = JoinOverlaps()
            try await render.concatenate(clips: Array(paths[run]),
                transitions: run.count > 1 ? Array(transitions[run.lowerBound..<(run.upperBound - 1)]) : [], output: part,
                overlaps: runJoins)
            for (gap, value) in runJoins.all { overlaps?.record(gap + run.lowerBound, value) }
            let runStart = segments[run.lowerBound].start
            let runClock = RenderClock(segmentStarts: run.map { segments[$0].start - runStart },
                segmentEnds: run.map { segments[$0].end - runStart }, joins: runJoins)
            let localPieces = Dictionary(uniqueKeysWithValues: runClock.assemblyPieces(
                segmentEnds: run.map { segments[$0].end - runStart }).map { index, range in
                    (index + run.lowerBound, range)
                })
            let localBridges = runJoins.assembledBridges.map { $0.shifted(gapOffset: run.lowerBound, timeOffset: 0) }
            hasRecipeClock = hasRecipeClock || !runJoins.assembledPieces.isEmpty
            let duration = await FFmpeg.duration(of: part)
            let isBumper = segments[run.lowerBound].clips.first?.bumper == true
            if let previous = assembled {
                let joined = scratch.appendingPathComponent("bumper_join_\(index).mp4")
                let outgoingDuration = segments[run.lowerBound - 1].duration
                let incomingDuration = segments[run.lowerBound].duration
                var transition = transitions[safe: run.lowerBound - 1] ?? nil
                if let name = transition, TransitionRecipes.isRecipe(name) {
                    let (tail, head) = TransitionRecipes.pieces(for: name)
                    if outgoingDuration - tail < 0.4 || incomingDuration - head < 0.4 { transition = nil }
                }
                // Grouping must not let a short adjacent clip borrow the
                // whole preceding run's duration for a longer crossfade.
                let boundaryJoins = JoinOverlaps()
                try await render.concatenate(clips: [previous, part], transitions: [transition], output: joined,
                    maximumOverlap: min(outgoingDuration, incomingDuration) * 0.4, overlaps: boundaryJoins)
                let measured = await FFmpeg.duration(of: joined)
                let overlap = max(0, elapsed + duration - measured)
                overlaps?.record(run.lowerBound - 1, overlap)
                if !boundaryJoins.assembledPieces.isEmpty {
                    hasRecipeClock = true
                    let boundaryClock = RenderClock(segmentStarts: [0, elapsed],
                        segmentEnds: [elapsed, elapsed + duration], joins: boundaryJoins)
                    let boundaryPieces = boundaryClock.assemblyPieces(segmentEnds: [elapsed, elapsed + duration])
                    let previousOffset = boundaryPieces[0]?.lowerBound ?? 0
                    let incomingOffset = boundaryPieces[1]?.lowerBound ?? (elapsed - overlap)
                    recipePieces = recipePieces.mapValues {
                        ($0.lowerBound + previousOffset)..<($0.upperBound + previousOffset)
                    }
                    recipeBridges = recipeBridges.map { $0.mapped(through: boundaryClock) }
                    recipeBridges += localBridges.map {
                        $0.shifted(gapOffset: 0, timeOffset: elapsed).mapped(through: boundaryClock)
                    }
                    recipeBridges += boundaryJoins.assembledBridges.map {
                        $0.shifted(gapOffset: run.lowerBound - 1, timeOffset: 0)
                    }
                    for (position, range) in localPieces {
                        recipePieces[position] = (incomingOffset + range.lowerBound)..<(incomingOffset + range.upperBound)
                    }
                } else {
                    recipeBridges += localBridges.map { $0.shifted(gapOffset: 0, timeOffset: elapsed - overlap) }
                    for (position, range) in localPieces {
                        recipePieces[position] = (elapsed - overlap + range.lowerBound)..<(elapsed - overlap + range.upperBound)
                    }
                }
                let pieces = transition.map { TransitionRecipes.pieces(for: $0) } ?? (0.0, 0.0)
                if isBumper { spans.append(max(0, elapsed - max(overlap, pieces.0))..<measured) }
                if segments[run.lowerBound - 1].clips.first?.bumper == true, let last = spans.indices.last,
                   !isBumper {
                    spans[last] = spans[last].lowerBound..<min(measured, elapsed + max(0, pieces.1 - overlap))
                }
                elapsed = measured
                assembled = joined
            } else {
                recipePieces = localPieces
                recipeBridges = localBridges
                assembled = part
                elapsed = duration
                if isBumper { spans.append(0..<duration) }
            }
        }
        if hasRecipeClock {
            for (position, range) in recipePieces { overlaps?.reconcile(position, range: range) }
            for bridge in recipeBridges {
                overlaps?.bridge(gap: bridge.gap, tail: bridge.tail, head: bridge.head, range: bridge.range)
            }
        }
        if let assembled { try FileManager.default.copyItemReplacing(at: assembled, to: output) }
        return spans
    }

    /// Missing interior bumpers remain exclusive black spans. Only an
    /// uncovered leading/trailing edge is removed, keeping interior timing.
    nonisolated static func removingMissingEdgeBumpers(_ input: TimelineDocument,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        emit: (String) -> Void = { _ in }) -> TimelineDocument {
        let missing = input.videoTrack.filter { $0.bumper && !exists($0.videoFile ?? "") }
        var logged: Set<String> = []
        for clip in missing where logged.insert(clip.videoFile ?? clip.uid.uuidString).inserted {
            let name = clip.bumperName ?? URL(fileURLWithPath: clip.videoFile ?? "Bumper").deletingPathExtension().lastPathComponent
            emit("Bumper '\(name)' is missing; skipped")
        }
        guard !missing.isEmpty else { return input }
        let missingIDs = Set(missing.map(\.uid))
        let live = input.videoTrack.filter { !missingIDs.contains($0.uid) }
        let end = input.videoTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let firstLive = live.map(\.startTime).min() ?? end
        let lastLive = live.map { $0.startTime + $0.duration }.max() ?? 0
        var lower = 0.0
        for clip in missing.sorted(by: { $0.startTime < $1.startTime }) {
            if clip.startTime <= lower + 0.001 {
                lower = min(firstLive, max(lower, clip.startTime + clip.duration))
            }
        }
        var upper = end
        for clip in missing.sorted(by: { $0.startTime > $1.startTime }) {
            if clip.startTime + clip.duration >= upper - 0.001 {
                upper = max(lastLive, min(upper, clip.startTime))
            }
        }
        upper = max(lower, upper)
        return windowed(input, from: lower, to: upper)
    }

    /// The document restricted to the output range `lower..<upper` and
    /// rebased so `lower` becomes 0. Straddling clips keep their source
    /// position (speed-aware); sound items keep their place in the song via
    /// `sourceOffset`; overlays, overlay blocks and crop blocks are clipped.
    /// Bumpers are treated like any other clip: the overlapping part of their
    /// span survives. A transition into the first surviving clip is ignored
    /// by the join planner, so it needs no special handling here.
    nonisolated static func windowed(_ input: TimelineDocument, from lower: Double, to upper: Double,
                                     dubClock: RenderClock = .identity) -> TimelineDocument {
        // Overlay blocks are expanded first: their items are placed relative
        // to the block, so trimming the block would silently drop items that
        // start after the cut. Expansion is idempotent for the renderer.
        let input = input.expandingOverlayBlocks()
        var document = input
        let lower = max(0, lower), upper = max(lower, upper)
        document.videoTrack = input.videoTrack.compactMap { item in
            let start = max(lower, item.startTime)
            let stop = min(upper, item.startTime + item.duration)
            guard stop > start else { return nil }
            var clip = item
            if start > item.startTime { clip.flashIn = nil }
            let skipped = item.hold == true ? 0 : (start - item.startTime) * item.effectiveSpeed
            clip.sourceStart = (item.sourceStart ?? 0) + skipped
            // The explicit camera path runs from the clip's source start:
            // move it with the window instead of replaying its opening.
            if skipped > 0, let path = item.cameraPath {
                let sliced = CenterStageService.slice(path, from: skipped,
                                                      duration: (stop - start) * item.effectiveSpeed)
                clip.cameraPath = sliced.count >= 2 ? sliced : nil
            }
            // A drawing entered part-way keeps its screen animation clock.
            if item.hold == true || item.telestration?.motion != nil,
               start > item.startTime, clip.telestration != nil {
                clip.telestration?.offset = (item.telestration?.offset ?? 0) + (start - item.startTime)
            }
            clip.startTime = start - lower
            clip.duration = stop - start
            return clip
        }
        document.soundTrack = input.soundTrack.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.startTime + item.duration)
            guard stop > start else { return nil }
            var item = item
            item.sourceOffset += start - item.startTime
            item.startTime = start - lower
            item.duration = stop - start
            return item
        }
        document.dubLines = DubRenderWindow.lines(input, clock: dubClock, lower: lower, upper: upper)
        // An overlay already on screen at the cut is shown settled, not
        // animating in again; one that outlives the window does not animate out.
        document.textOverlays = input.textOverlays.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.endTime)
            guard stop > start else { return nil }
            var item = item
            if item.startTime < lower { item.transIn = "cut" }
            if item.endTime > upper { item.transOut = "cut" }
            item.startTime = start - lower
            item.endTime = stop - lower
            return item
        }
        document.imageOverlays = input.imageOverlays.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.endTime)
            guard stop > start else { return nil }
            var item = item
            if item.startTime < lower { item.transIn = "cut" }
            if item.endTime > upper { item.transOut = "cut" }
            item.track = item.track?.map { key in
                var key = key
                key.time -= lower
                return key
            }
            item.startTime = start - lower
            item.endTime = stop - lower
            return item
        }
        document.overlayBlocks = input.overlayBlocks.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.endTime)
            guard stop > start else { return nil }
            var item = item
            item.startTime = start - lower
            item.duration = stop - start
            return item
        }
        document.cropBlocks = input.cropBlocks.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.endTime)
            guard stop > start else { return nil }
            return CropBlockItem(layout: item.layout, startTime: start - lower, duration: stop - start)
        }
        return document
    }

    // MARK: - Clip resolution

    /// Confine a clip's framing to the picture inside its letterbox bars
    /// (`window`, source fractions). Regions are content-relative and map
    /// into the window; path keyframes are source fractions. A recipe cell's
    /// shots are fitted into the window with their aspect kept, so a shot
    /// that leaves the bars does not change shape and get rejected as a saved
    /// path, and the path's bounds become the cell's region, so a cell that
    /// is re-tracked never widens past the feed its path framed.
    nonisolated static func applyContentWindow(_ window: FreeCropRect, to clip: inout ResolvedClip) {
        let contentBox = RenderEngine.ContentBox(x: window.xFrac, y: window.yFrac,
            w: window.wFrac, h: window.hFrac, aspect: 1)
        clip.freeCrops = clip.freeCrops?.map { crop in
            var crop = crop
            crop.src = FocusFrame.sourceWindow(crop.src, contentBox: contentBox)
            return crop
        }
        clip.contentWindow = window
        clip.areaWindow = clip.areaWindow.map { FitSpec.intersection($0, window) }
        if let region = clip.areaRegion {
            clip.areaRegion = FocusFrame.sourceWindow(region, contentBox: contentBox)
        } else if let bounds = Self.cellBounds(of: clip) {
            clip.areaRegion = FitSpec.intersection(bounds, window)
        } else if clip.centerStage || clip.cameraPath != nil {
            clip.areaRegion = FocusFrame.sourceWindow(FreeCropRect(), contentBox: contentBox)
        }
        if let path = clip.cameraPath {
            // A focused plan or a recipe cell keeps each shot's shape; a scene
            // path is clipped to the picture and re-tracked if that changes it.
            let keepsShape = clip.framingPlan?.sourceWindow != nil || Self.cellBounds(of: clip) != nil
            let bounds = clip.areaRegion ?? window
            clip.cameraPath = path.map { key in
                let shot = FreeCropRect(xFrac: key.x, yFrac: key.y, wFrac: key.w, hFrac: key.h)
                let crop = keepsShape ? FocusFrame.fitting(shot, inside: bounds) : FitSpec.intersection(shot, window)
                return CameraPathKeyframe(t: key.t, x: crop.xFrac, y: crop.yFrac, w: crop.wFrac, h: crop.hFrac)
            }
        }
    }

    /// The feed a recipe-planned cell's path frames, from the path itself. A
    /// scene's Center Stage path or a fighter path is not a cell: those may be
    /// re-tracked over the whole picture when the saved path no longer fits.
    nonisolated static func cellBounds(of clip: ResolvedClip) -> FreeCropRect? {
        guard let recipe = clip.framingPlan?.recipe, recipe.centerStage != true, recipe.fighterFocus != true,
              let path = clip.cameraPath else { return nil }
        return pathBounds(path)
    }

    /// The smallest source rectangle holding every keyframe of a path: the
    /// feed a cell's path stays inside. Nil for an empty or degenerate path.
    nonisolated static func pathBounds(_ path: [CameraPathKeyframe]) -> FreeCropRect? {
        let frames = path.filter { $0.w > 0 && $0.h > 0 }
        guard let first = frames.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x + first.w, maxY = first.y + first.h
        for key in frames.dropFirst() {
            minX = min(minX, key.x); minY = min(minY, key.y)
            maxX = max(maxX, key.x + key.w); maxY = max(maxY, key.y + key.h)
        }
        let x = max(0, minX), y = max(0, minY), w = min(1, maxX) - x, h = min(1, maxY) - y
        guard w > 0, h > 0 else { return nil }
        return FreeCropRect(xFrac: x, yFrac: y, wFrac: w, hFrac: h)
    }

    /// The camera path a clip renders with, on the clip's own clock (seconds
    /// from its source start): its explicit path, else its scene's stored
    /// path, else the file's analyzed scenes stitched together. Empty when
    /// the camera is off or nothing is known.
    nonisolated static func effectiveCameraPath(for clip: TimelineClip, scenes: [SceneRecord]) -> [CameraPathKeyframe] {
        guard clip.framingPlan?.sourceWindow == nil || FocusFrame.hasReplannedPath(clip) else { return [] }
        if clip.hold == true {
            var moving = clip
            moving.hold = nil
            moving.speed = nil
            return HoldClipRules.cameraPath(effectiveCameraPath(for: moving, scenes: scenes), duration: clip.duration)
        }
        let span = max(0, clip.duration * clip.effectiveSpeed)
        guard clip.wide, !clip.isCutaway, !clip.bumper, span > 0 else { return [] }
        if let explicit = clip.cameraPath { return CenterStageService.slice(explicit, from: 0, duration: span) }
        guard clip.centerStage else { return [] }
        if let sceneID = clip.sceneID, let scene = scenes.first(where: { $0.id == sceneID }) {
            guard let path = scene.centerStagePath, path.keyframes.count >= 2 else { return [] }
            return CenterStageService.slice(path.keyframes, from: (clip.sourceStart ?? scene.startTime) - scene.startTime, duration: span)
        }
        guard let file = clip.videoFile, let start = clip.sourceStart else { return [] }
        return stitchedCameraPath(scenes: scenes.filter { $0.videoPath == file }, from: start, duration: span)
    }

    /// The camera path for a stretch of a source file without a scene of
    /// its own: the stored paths of the file's analyzed scenes (each on its
    /// scene clock) laid out on the file clock and sliced to the range.
    /// Between scenes the camera glides from one path's end to the next
    /// path's start; a range no analyzed scene covers gets no path.
    nonisolated static func stitchedCameraPath(scenes: [SceneRecord], from: Double,
                                               duration: Double) -> [CameraPathKeyframe] {
        var absolute: [CameraPathKeyframe] = []
        for scene in scenes.sorted(by: { $0.startTime < $1.startTime }) {
            guard let path = scene.centerStagePath, path.keyframes.count >= 2 else { continue }
            for keyframe in path.keyframes {
                var shifted = keyframe
                shifted.t = keyframe.t + scene.startTime
                // Overlapping scenes: the earlier path keeps its say.
                if let last = absolute.last, shifted.t <= last.t + 0.001 { continue }
                absolute.append(shifted)
            }
        }
        guard absolute.count >= 2, let first = absolute.first, let last = absolute.last,
              first.t < from + duration, last.t > from else { return [] }
        return CenterStageService.slice(absolute, from: from, duration: duration)
    }

    /// Cover-all reaction footage keeps its own source crop while ordinary
    /// cover-all B-roll retains the existing scale-to-fill behavior.
    nonisolated static func reactionFilter(for clip: TimelineClip) -> String? {
        guard clip.isCutaway, clip.coverAllAreas, let window = clip.cutawaySourceWindow else { return nil }
        let canvas = ScreenCropArea(name: "Full Screen", points: [
            ScreenCropPoint(x: 0, y: 0), ScreenCropPoint(x: 1, y: 0),
            ScreenCropPoint(x: 1, y: 1), ScreenCropPoint(x: 0, y: 1)])
        return AreaFramer.staticFilter(area: canvas, window: window)
    }

    nonisolated static func isFullFrame(_ region: FreeCropRect?) -> Bool {
        guard let region else { return true }
        return abs(region.xFrac) < 1e-6 && abs(region.yFrac) < 1e-6
            && abs(region.wFrac - 1) < 1e-6 && abs(region.hFrac - 1) < 1e-6
    }

    /// Port of the resolve/effective-settings pass in _generate_multitrack.
    nonisolated static func resolveClips(document: TimelineDocument,
                                         scenes: [SceneRecord], centerStageCamera: String = "balanced",
                                         lingering: [UUID: Telestration] = [:],
                                         lingerHolds: [UUID: ResolvedClip] = [:]) -> [ResolvedClip] {
        let scenesByID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let settings = document.trackSettings
        var resolved: [ResolvedClip] = []

        for (documentIndex, original) in document.videoTrack.enumerated() {
            var clip = original
            clip.enforceCutawayRules()
            if !clip.bumper, let plan = clip.framingPlan { FocusFrame.apply(plan, to: &clip) }
            var sourcePath: String?
            var videoID: Int64?
            var sourceStart = 0.0
            var duration = 0.0
            var cameraPath: [CameraPathKeyframe]?
            if let sceneID = clip.sceneID, let scene = scenesByID[sceneID] {
                sourcePath = scene.videoPath
                videoID = scene.videoID
                sourceStart = clip.sourceStart ?? scene.startTime
                duration = clip.duration > 0 ? clip.duration : (scene.duration * 10).rounded() / 10
                // Stored camera path (scene-relative source time) → this
                // clip's range, so the render replays exactly what the
                // preview showed instead of re-tracking.
                if let explicit = clip.cameraPath, !clip.isCutaway {
                    // The clip's own path (from the clip's source start) wins.
                    let sliced = CenterStageService.slice(explicit, from: 0, duration: duration * clip.effectiveSpeed)
                    if sliced.count >= 2 { cameraPath = sliced }
                } else if clip.framingPlan?.sourceWindow == nil, clip.framingPlan?.recipe?.centerStageVIPs != true,
                   (clip.centerStage && clip.wide) || clip.areaRegion != nil,
                   let path = scene.centerStagePath, path.keyframes.count >= 2,
                   clip.areaRegion == nil || (Self.isFullFrame(clip.areaRegion) && path.camera == (clip.framingPlan?.camera ?? centerStageCamera)) {
                    let sliced = CenterStageService.slice(
                        path.keyframes, from: sourceStart - scene.startTime,
                        duration: duration * clip.effectiveSpeed)
                    if sliced.count >= 2 { cameraPath = sliced }
                }
            } else if let file = clip.videoFile, let start = clip.sourceStart {
                sourcePath = file
                sourceStart = start
                duration = clip.duration > 0 ? clip.duration
                    : max(0, (clip.sourceEnd ?? start) - start)
                // A whole-file clip has no scene of its own but the file's
                // analyzed scenes know its video (captions) and its framing.
                let own = scenes.filter { $0.videoPath == file }
                videoID = own.first?.videoID
                if let explicit = clip.cameraPath, !clip.isCutaway {
                    let sliced = CenterStageService.slice(explicit, from: 0, duration: duration * clip.effectiveSpeed)
                    if sliced.count >= 2 { cameraPath = sliced }
                } else if clip.centerStage, clip.wide, !clip.isCutaway, clip.areaRegion == nil {
                    let sliced = Self.stitchedCameraPath(scenes: own, from: start,
                                                         duration: duration * clip.effectiveSpeed)
                    if sliced.count >= 2 { cameraPath = sliced }
                }
            }
            guard let sourcePath, duration > 0 else { continue }
            if clip.hold == true, let path = cameraPath {
                cameraPath = HoldClipRules.cameraPath(path, duration: duration)
            }

            let track = min(max(0, clip.track), TimelineDocument.maxTracks - 1)
            let trackSettings = settings[safe: track] ?? TrackSettings()
            let effectivePosition = clip.position ?? trackSettings.defaultPosition
            let effectiveCrop = clip.bumper ? nil : clip.cropXFrac ?? trackSettings.defaultCropXFrac
            let effect = clip.effect ?? trackSettings.effect
            let effectiveEffect = clip.bumper || effect?.preset == "none" ? nil : effect
            let muted = clip.hold == true || clip.muted || trackSettings.muted
            let captionsResolved = clip.captions == "inherit" ? trackSettings.captions : clip.captions

            resolved.append(ResolvedClip(sourcePath: sourcePath,
                                         videoID: videoID,
                                         sourceStart: sourceStart,
                                         startTime: clip.startTime,
                                         duration: duration,
                                         track: track,
                                         wide: clip.wide,
                                         bumper: clip.bumper,
                                         hold: clip.hold == true,
                                         flashIn: clip.flashIn,
                                         role: clip.role,
                                         coverAllAreas: clip.isCutaway && clip.coverAllAreas,
                                         originalStart: clip.startTime,
                                         originalEnd: clip.startTime + duration,
                                         originKey: clip.originKey,
                                         fadeIn: clip.isCutaway ? clip.fadeIn : 0,
                                         fadeOut: clip.isCutaway ? clip.fadeOut : 0,
                                         documentIndex: documentIndex,
                                         volume: clip.volume,
                                         centerStage: (clip.centerStage || cameraPath != nil) && clip.wide,
                                         muted: muted,
                                         transIn: clip.transIn,
                                         transOut: clip.transOut,
                                         effectivePosition: effectivePosition,
                                         effectiveCropXFrac: clip.wide ? effectiveCrop : nil,
                                         freeCrops: clip.freeCrops,
                                         screenCrop: clip.screenCrop,
                                         areaWindow: clip.areaWindow,
                                         // A window or the clip's own path decides the cell; a scene
                                         // path keeps the region and focus so it can still be rejected.
                                         areaRegion: clip.areaWindow == nil && (clip.cameraPath == nil || FocusFrame.hasReplannedPath(clip)) ? clip.areaRegion : nil,
                                         areaFocus: clip.areaWindow == nil && clip.cameraPath == nil && clip.areaRegion != nil ? clip.areaFocus : nil,
                                         framingProgramAudio: clip.framingProgramAudio.map {
                                             FramingProgramAudio(path: $0.path,
                                                 start: $0.start + (clip.sourceStart ?? 0) - ($0.visualStart ?? clip.sourceStart ?? 0))
                                         },
                                         framingPlan: clip.framingPlan,
                                         fitArea: clip.framingPlan?.area(forTrack: clip.track),
                                         captionsPosition: (clip.hold == true && !(clip.strikeImpactsFrozen == true && document.captionPosition != nil))
                                            || captionsResolved == "none" ? nil : captionsResolved,
                                         speed: clip.effectiveSpeed,
                                         cameraPath: cameraPath, staticAreaFilter: reactionFilter(for: clip), effectiveEffect: effectiveEffect))
            if !clip.bumper, clip.hold != true, !LipSyncTakes.current.isEmpty {
                let made = resolved[resolved.count - 1]
                resolved[resolved.count - 1].pictureTake = LipSyncTakes.substitute(
                    path: made.sourcePath, start: made.sourceStart, span: made.sourceSpan
                ).map { PictureTake(path: $0.path, sourceStart: $0.takeStart, key: $0.key) }
            }
            resolved[resolved.count - 1].slowGroup = clip.slowGroup
            resolved[resolved.count - 1].slowLineage = clip.slowLineage
            resolved[resolved.count - 1].stayCut = clip.stayCut
            resolved[resolved.count - 1].continuityClipID = clip.uid
            resolved[resolved.count - 1].continuityLayout = document.cropBlock(at: clip.startTime)?.layout
            if clip.strikeHighlights == true, !clip.bumper {
                resolved[resolved.count - 1].strikeHighlights = true
                resolved[resolved.count - 1].strikeHighlightStyle = clip.strikeHighlightStyle
            }
            if clip.hold == true, !clip.bumper {
                resolved[resolved.count - 1].telestration = clip.telestration.map(TelestrationMotionRules.paused)
                if let drawing = clip.telestration, TelestrationRules.lingerDuration(of: drawing) > 0 {
                    resolved[resolved.count - 1].stayHoldID = clip.uid
                }
            } else if !clip.bumper, !clip.isCutaway, let drawing = clip.telestration, drawing.motion != nil,
                      (drawing.offset ?? 0) < TelestrationRules.carriedDuration(of: drawing) {
                resolved[resolved.count - 1].lingering = drawing
            }
        }
        resolved = TelestrationLingerResolution.attaching(to: resolved)
        for index in resolved.indices {
            let item = document.videoTrack[resolved[index].documentIndex]
            if resolved[index].telestration == nil, !resolved[index].bumper, resolved[index].role != .cutaway,
               let drawing = lingering[item.uid] {
                resolved[index].lingering = drawing
                if let hold = lingerHolds[item.uid] { resolved[index].lingeringHold = [hold] }
            }
        }
        // Validate scene-derived paths after crop-block splitting: each piece
        // may target a different aspect, and a scene-wide path cannot represent
        // a cell's distinct focus. A clip's own path always wins here; the
        // framing prepass re-checks its aspect against the real source size.
        let pieces = Self.applyCropBlocks(resolved, document: document).map { clip in
            var clip = clip
            let explicit = document.videoTrack.indices.contains(clip.documentIndex)
                && document.videoTrack[clip.documentIndex].cameraPath != nil
            guard let path = clip.cameraPath, !explicit else { return clip }
            let area = (clip.framingPlan?.area(forTrack: clip.track) ?? ScreenCropStore.area(reference: clip.screenCrop))
            let box = area.map { AreaFramer.pixelBounds(of: $0) }
            let aspect = box.map { $0.width / $0.height } ?? RenderContext.settings.aspectRatio
            let scene = scenes.first { $0.videoPath == clip.sourcePath }
            let size = scene.flatMap { $0.videoWidth > 0 && $0.videoHeight > 0
                ? CGSize(width: $0.videoWidth, height: $0.videoHeight) : nil }
            // Without a known source size the aspect is settled at render time.
            let mismatch = size.map { !CenterStageService.pathMatchesCanvas(path, sourceSize: $0, canvasAspect: aspect) } ?? false
            if clip.areaFocus != nil || mismatch {
                clip.cameraPath = nil
                // Keep the tracking-only route even for Full Screen, whose
                // layout reference is nil, when rejecting a saved path.
                if clip.areaWindow == nil { clip.areaRegion = clip.areaRegion ?? FreeCropRect() }
            }
            return clip
        }.sorted {
            ($0.track, $0.startTime) < ($1.track, $1.startTime)
        }

        // Carry the last crop-block piece of the hold, not its pre-split layout.
        return pieces.map { clip in
            var clip = clip
            if let snapshot = clip.lingeringHold?.first,
               let hold = pieces.filter({ $0.hold && snapshot.stayHoldID != nil && $0.stayHoldID == snapshot.stayHoldID })
                .max(by: { $0.startTime < $1.startTime }) {
                clip.lingeringHold = [hold]
            }
            return clip
        }
    }

    /// The cropping row decides each clip's area: a clip is cut at every
    /// crop-block boundary it crosses, each piece masked to its track's area
    /// under that block (none under Full Screen), and pieces on a track the
    /// block gives no area to are dropped. Documents without a row keep the
    /// per-clip `screenCrop` they carry.
    nonisolated static func applyCropBlocks(_ clips: [ResolvedClip],
                                            document: TimelineDocument) -> [ResolvedClip] {
        let blocks = document.cropBlocks.sorted { $0.startTime < $1.startTime }
        guard !blocks.isEmpty else {
            // Legacy document without a Screen row: a cover-all cutaway
            // still fills the canvas instead of taking a legacy crop.
            return clips.map { clip in
                guard clip.coverAllAreas else { return clip }
                var piece = clip
                piece.screenCrop = nil
                piece.fillCanvas = true
                return piece
            }
        }
        var pieces: [ResolvedClip] = []
        for clip in clips {
            if clip.bumper || clip.framingPlan?.area(forTrack: clip.track) != nil { pieces.append(clip); continue }
            let clipEnd = clip.startTime + clip.duration
            var cursor = clip.startTime
            let firstPiece = pieces.count
            var covering = blocks.filter { $0.startTime < clipEnd - 0.001 && cursor < $0.endTime - 0.001 }
            // The row always tiles to the content end; anything past the
            // last block behaves like that block.
            if covering.isEmpty, let last = blocks.last { covering = [last] }
            for (index, block) in covering.enumerated() {
                let pieceStart = max(cursor, block.startTime)
                let isLast = index == covering.count - 1
                let pieceEnd = isLast ? clipEnd : min(clipEnd, block.endTime)
                // Match buildLayeredSegments: 4.05 - 4.0 is slightly below
                // 0.05 in binary, even when the entire accepted hold is covered.
                guard pieceEnd - pieceStart >= 0.05 - 1e-9 else { continue }
                cursor = pieceEnd
                let layout = block.layout
                // Track without an area under this block: not rendered. A
                // cover-all cutaway needs no area, so it survives anywhere.
                guard clip.track < layout.areaCount || clip.coverAllAreas else { continue }
                var piece = clip
                piece.continuityLayout = layout
                let offset = pieceStart - clip.startTime
                piece.startTime = pieceStart
                piece.duration = pieceEnd - pieceStart
                // A first sliver too short to render is dropped above; the flash
                // then opens the piece that replaces it.
                if offset > 0, !(pieces.count == firstPiece && offset < 0.05) { piece.flashIn = nil }
                piece.sourceStart = clip.sourceStart + (clip.hold ? 0 : offset * clip.speed)
                piece.transcriptSourceStart = clip.transcriptStart(at: pieceStart)
                if clip.coverAllAreas {
                    // The whole canvas: no mask, scaled to fill.
                    piece.screenCrop = nil
                    piece.fillCanvas = true
                } else {
                    // A cutaway inherits its track's area like a main clip.
                    piece.screenCrop = layout.reference(forTrack: clip.track)
                }
                piece.transIn = pieceStart > clip.startTime + 0.001 ? nil : clip.transIn
                piece.transOut = pieceEnd < clipEnd - 0.001 ? nil : clip.transOut
                if let path = clip.cameraPath, !clip.hold, offset > 0.001 {
                    let sliced = CenterStageService.slice(path, from: offset * clip.speed,
                                                          duration: piece.sourceSpan)
                    piece.cameraPath = sliced.count >= 2 ? sliced : nil
                }
                pieces.append(piece)
            }
        }
        return pieces
    }

    /// Every clip in a segment as a placement, in the one draw order the
    /// masks are keyed by. `compositeLayeredSegment` consumes this order
    /// as given.
    nonisolated static func placements(for segment: Segment) -> [Placement] {
        var placements: [Placement] = []
        for (clipIndex, clip) in segment.clips.enumerated() {
            // Timeline offsets map into the source through the clip's speed
            // — a 0.5× clip consumes half a source second per screen second.
            let clipOffset = clip.hold ? 0 : (segment.start - clip.startTime) * clip.speed
            let areaFilter: String?
            if let path = clip.cameraPath, let source = clip.areaPathSource, let area = clip.areaPathArea {
                let sliced = clip.continuityTransform == true
                    ? CenterStageContinuity.transformSlice(path, from: clipOffset, duration: clip.hold ? 0 : segment.duration * clip.speed)
                    : CenterStageService.slice(path, from: clipOffset, duration: clip.hold ? 0 : segment.duration * clip.speed)
                areaFilter = AreaFramer.pathFilter(keyframes: sliced, source: source,
                    area: area, namespace: "area\(clipIndex)", framingPlan: clip.framingPlan,
                    transformInterpolation: clip.continuityTransform == true, continuityGrid: clip.continuityGrid,
                    preserveSourceTiming: clip.continuityTransform == false)
            } else { areaFilter = clip.staticAreaFilter }
            let pictureRead = clip.pictureRead
            placements.append(Placement(sourcePath: pictureRead.path,
                                        sourceStart: pictureRead.start + clipOffset,
                                        sourceDur: clip.hold ? 0 : segment.duration * clip.speed,
                                        isWide: clip.wide,
                                        bumper: clip.bumper, hold: clip.hold,
                                        flashIn: segment.start - clip.startTime > 0.002 ? nil : clip.flashIn, volume: clip.volume,
                                        layer: Self.placementLayer(for: clip),
                                        position: clip.effectivePosition,
                                        muted: clip.muted,
                                        role: clip.role,
                                        fillCanvas: clip.fillCanvas,
                                        originalStart: clip.originalStart,
                                        originKey: clip.originKey,
                                        fadeIn: Self.fade(into: segment, start: clip.originalStart,
                                                          seconds: clip.fadeIn),
                                        fadeOut: Self.fade(into: segment,
                                                           start: clip.originalEnd - clip.fadeOut,
                                                           seconds: clip.fadeOut),
                                        documentIndex: clip.documentIndex,
                                        clipIndex: clipIndex,
                                        startTime: clip.startTime,
                                        cropXFrac: clip.effectiveCropXFrac,
                                        freeCrops: clip.freeCrops,
                                        screenCrop: clip.screenCrop,
                                        speed: clip.speed, staticAreaFilter: areaFilter,
                                        effectiveEffect: clip.effectiveEffect,
                                        framingProgramAudio: clip.framingProgramAudio.map {
                                            FramingProgramAudio(path: $0.path, start: $0.start + clipOffset)
                                        }, framingPlan: clip.bumper ? nil : clip.framingPlan,
                                        snapshotArea: clip.framingPlan?.area(forTrack: clip.track),
                                        fitWindow: clip.originalSourcePath != nil && clip.originalSourcePath != clip.sourcePath
                                            ? FreeCropRect() : FitSpec.intersection(clip.areaWindow ?? clip.framingPlan?.sourceWindow ?? FreeCropRect(), clip.contentWindow ?? FreeCropRect()),
                                        fitArea: clip.fitArea, continuityTransform: clip.continuityTransform, holdFrameTime: clip.holdFrameTime, screenStay: clip.screenStay))
        }

        return orderedPlacements(placements)
    }

    /// A dissolve that begins at absolute time `start` and runs `seconds`,
    /// expressed in this segment's local time. Nil when the window falls
    /// entirely outside the segment; a negative start means the fade began
    /// in an earlier segment and continues through this one.
    nonisolated static func fade(into segment: Segment, start: Double, seconds: Double) -> Fade? {
        guard seconds > 0.001 else { return nil }
        let local = start - segment.start
        guard local < segment.duration - 0.001, local + seconds > 0.001 else { return nil }
        return Fade(start: local, duration: seconds)
    }

    /// The dissolve step for one placement. It runs AFTER the mask: the
    /// clip chain ends without alpha, and alphamerge is what introduces it,
    /// so an alpha fade before that has nothing to fade.
    nonisolated static func fadeFilters(for placement: Placement, index: Int,
                                        masked: Bool) -> (filters: [String], label: String) {
        let input = masked ? "vm\(index)" : "v\(index)"
        var steps: [String] = []
        steps.append(contentsOf: envelope(for: placement.fadeIn, kind: "in"))
        steps.append(contentsOf: envelope(for: placement.fadeOut, kind: "out"))
        guard !steps.isEmpty else { return ([], input) }
        // Without a mask the frames have no alpha channel to fade.
        if !masked { steps.insert("format=yuva420p", at: 0) }
        let label = "vf\(index)"
        return (["[\(input)]" + steps.joined(separator: ",") + "[\(label)]"], label)
    }

    /// One dissolve as filter steps. `fade`'s `st` cannot be negative and
    /// the ramp always starts from transparent, so a dissolve that began in
    /// an earlier segment is not restarted: the segment is padded by the
    /// part that already happened, the WHOLE fade runs over that padded
    /// timeline, and the padding is trimmed away again. The frames that
    /// survive therefore carry the middle of the envelope, which is what
    /// continuing a dissolve means.
    private nonisolated static func envelope(for fade: Fade?, kind: String) -> [String] {
        guard let fade else { return [] }
        // A window that is already over contributes nothing.
        guard fade.start + fade.duration > 0.001 else { return [] }
        guard fade.start < -0.001 else {
            // A start a hair below zero is still zero: `st=-0.000` is not
            // something ffmpeg should ever be asked to parse.
            return [String(format: "fade=t=%@:alpha=1:st=%.3f:d=%.3f",
                           kind, max(0, fade.start), fade.duration)]
        }
        let lead = -fade.start
        return [String(format: "tpad=start_duration=%.3f:start_mode=clone", lead),
                String(format: "fade=t=%@:alpha=1:st=0.000:d=%.3f", kind, fade.duration),
                String(format: "trim=start=%.3f", lead),
                "setpts=PTS-STARTPTS"]
    }

    /// Screen-crop masks for an ordered placement list, keyed by the index
    /// into that same list (a placement with free crops draws its own
    /// rectangles and an unresolvable reference renders unmasked).
    nonisolated static func maskFiles(for ordered: [Placement], in scratch: URL) -> [Int: URL] {
        var masks: [Int: URL] = [:]
        for (index, placement) in ordered.enumerated() where placement.freeCrops?.isEmpty != false {
            if let area = placement.snapshotArea {
                masks[index] = ScreenCropStore.maskFile(area: area, name: area.name, in: scratch)
            } else {
                masks[index] = ScreenCropStore.maskFile(reference: placement.screenCrop, in: scratch)
            }
        }
        return masks
    }

    /// How the segment's audio streams become one. When a mixed-in cutaway
    /// is part of the segment the mix runs with `normalize=0`: amix would
    /// otherwise divide every input by their number, so adding the cutaway's
    /// sound would duck the dialogue underneath it. The fast preview keeps
    /// each source at its own gain, so the two agree. Segments without a
    /// cutaway keep amix's default, exactly as before B-roll existed.
    /// Whether the segment's mix has to run at unity gain: only when one of
    /// the streams actually going into it belongs to a mixed-in cutaway. A
    /// cutaway whose file carries no audio contributes nothing, so it must
    /// not change how everything else is mixed.
    nonisolated static func mixNeedsUnityGain(_ contributing: [Placement]) -> Bool {
        contributing.contains { !$0.muted && $0.role == .cutaway }
    }

    nonisolated static func audioMixFilter(labels: [String], cutawayAudio: Bool,
                                           duration: Double) -> (filters: [String], source: String) {
        if labels.isEmpty {
            // Silence is made inside the graph, not taken from the anullsrc
            // input: with ffmpeg 8.1 a segment whose only audio was that
            // input's decoder stalled at the end about once in 50 runs
            // (every thread idle until the timeout). 0 of 400 this way.
            return ([String(format: "anullsrc=r=44100:cl=stereo:d=%.3f,asetpts=PTS-STARTPTS[asilent]", duration)],
                    "[asilent]")
        }
        if labels.count == 1 { return ([], labels[0]) }
        // Only a mixed-in cutaway needs the un-normalized mix; every other
        // segment keeps the levels it has had since before B-roll existed.
        let normalize = cutawayAudio ? ":normalize=0" : ""
        return ([labels.joined() + "amix=inputs=\(labels.count):duration=longest:"
                 + "dropout_transition=0" + normalize + "[amix]"], "[amix]")
    }

    /// The volume filter a placement's audio takes in the mix: bumpers and
    /// mixed-in cutaways honour the volume slider, ordinary clips do not.
    nonisolated static func audioGainFilter(for placement: Placement) -> String {
        guard placement.bumper || placement.role == .cutaway else { return "" }
        return String(format: "volume=%.3f,", Double(min(5, max(0, placement.volume))) / 5)
    }

    /// The clip a segment join belongs to: the lowest-layer main clip (or
    /// the bumper that owns the segment). Cutaways are never a join's
    /// incoming or outgoing clip.
    nonisolated static func joinClip(in clips: [ResolvedClip]) -> ResolvedClip? {
        clips.filter { $0.bumper || $0.role != .cutaway }
            .min { placementLayer(for: $0) < placementLayer(for: $1) }
    }

    /// Draw order for one resolved clip. Main clips on a track sit under
    /// that track's cutaways; a cover-all cutaway sits above every track;
    /// a bumper (which owns its segment outright anyway) sits above all.
    nonisolated static func placementLayer(for clip: ResolvedClip) -> Int {
        if clip.bumper { return TimelineDocument.maxTracks * 2 + 2 }
        if clip.role == .cutaway {
            return clip.coverAllAreas
                ? TimelineDocument.maxTracks * 2 + 1
                : clip.track * 2 + 1
        }
        return clip.track * 2
    }

    nonisolated static func drawOrder(layer: Int, start: Double, origin: String, index: Int) -> (Int, Double, String, Int) {
        (layer, start, origin, index)
    }

    nonisolated static func drawOrder(_ clip: ResolvedClip) -> (Int, Double, String, Int) {
        drawOrder(layer: placementLayer(for: clip), start: clip.originalStart,
                  origin: clip.originKey, index: clip.documentIndex)
    }

    /// The one placement order: layer, then the clip's start before crop
    /// splitting, then its persisted identity. `renderSegment` computes it
    /// once, keys the masks by it, and `compositeLayeredSegment` consumes
    /// both without sorting again.
    nonisolated static func orderedPlacements(_ placements: [Placement]) -> [Placement] {
        placements.enumerated().sorted {
            let lhs = drawOrder(layer: $0.element.layer, start: $0.element.originalStart,
                origin: $0.element.originKey, index: $0.element.documentIndex)
            let rhs = drawOrder(layer: $1.element.layer, start: $1.element.originalStart,
                origin: $1.element.originKey, index: $1.element.documentIndex)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    /// The segments resolved clips are rendered as, black gaps included, and
    /// the join before each segment but the first. The renderer assembles
    /// exactly these, and `WizardPreviewClips.assembly` predicts the reel's
    /// clock from them, so the two cannot disagree about slicing or joins.
    ///
    /// Cutaways never take part in a join: a boundary a cutaway introduced
    /// must not replay the main clip's transition, so the incoming and
    /// outgoing clips are the lowest-layer main clips and their ORIGINAL
    /// extent decides. A join takes the incoming clip's transition in, else
    /// the outgoing clip's transition out.
    nonisolated static func plannedSegments(_ clips: [ResolvedClip]) -> (segments: [Segment], transitions: [String?]) {
        var segments: [Segment] = []
        var cursor = 0.0
        for segment in buildLayeredSegments(clips) {
            if segment.start > cursor + 0.05 {
                segments.append(Segment(start: cursor, end: segment.start, clips: []))
            }
            segments.append(segment)
            cursor = segment.end
        }
        var transitions: [String?] = []
        for (index, segment) in segments.enumerated() where index > 0 {
            let incoming = joinClip(in: segment.clips)
            let outgoing = TelestrationTransition.outgoing(in: segments[index - 1].clips, incoming: incoming)
            let entry = incoming.flatMap { abs($0.originalStart - segment.start) < 0.001 ? $0.transIn : nil }
            let exit = outgoing.flatMap { abs($0.originalEnd - segment.start) < 0.001 ? $0.transOut : nil }
            let requested = entry ?? exit
            transitions.append(!TelestrationTransition.crossingHolds(outgoing: segments[index - 1].clips, incoming: segment.clips, at: segment.start).isEmpty
                && TelestrationTransition.requiresCut(requested) ? "cut" : requested)
        }
        return (segments, transitions)
    }

    /// Any dub line plus a bumper selects the exact frame clock, independent
    /// of holds, enabled state or recipes (all can differ in a preview window).
    nonisolated static func usesFrameBoundedBumpers(_ document: TimelineDocument, transitions: [String?]) -> Bool {
        document.dubLines?.isEmpty == false
            && document.videoTrack.contains(where: \.bumper)
    }

    /// A reel with pauses, no bumper and no recipe join is assembled on the
    /// document's clock, in whole frames (`RenderEngine.concatenateTimed`).
    nonisolated static func usesTimedAssembly(_ document: TimelineDocument, transitions: [String?]) -> Bool {
        // A slowed piece's tempo-changed audio runs short of its planned
        // length; the stream-copy join would leave a hole after it.
        document.videoTrack.contains { $0.hold == true || $0.strikeImpactsFrozen == true || $0.timedAssembly == true
            || $0.slowGroup != nil }
            && !document.videoTrack.contains(where: \.bumper)
            && !transitions.contains(where: { TransitionRecipes.isRecipe($0) })
    }

    /// Port of _build_layered_segments: slice at every clip boundary so each
    /// segment has a constant active clip set (3dp boundaries, ≥0.05s
    /// intervals, 1e-3 coverage tolerance).
    nonisolated static func buildLayeredSegments(_ clips: [ResolvedClip]) -> [Segment] {
        guard !clips.isEmpty else { return [] }
        var boundaries = Set<Double>()
        for clip in clips {
            boundaries.insert((clip.startTime * 1000).rounded() / 1000)
            boundaries.insert(((clip.startTime + clip.duration) * 1000).rounded() / 1000)
        }
        let sorted = boundaries.sorted()
        // Compare plain numbers: testing every clip value against every
        // boundary copied each large clip and took 13 ms for 200 clips in Debug.
        let spans = clips.map { (start: $0.startTime, end: $0.startTime + $0.duration) }
        var segments: [Segment] = []
        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            // Rounded millisecond boundaries can subtract to 0.0499999999999998.
            // Keep the accepted 50 ms hold on both document and extraction clocks.
            guard end - start >= 0.05 - 1e-9 else { continue }
            let active = spans.indices.filter {
                spans[$0].start <= start + 0.001 && spans[$0].end >= end - 0.001
            }.map { clips[$0] }
            if !active.isEmpty {
                // A bumper owns the canvas regardless of track, layout, or
                // other clips. Later-starting bumpers win deterministically.
                let winner = active.filter(\.bumper).sorted {
                    ($0.startTime, $0.track) < ($1.startTime, $1.track)
                }.last
                segments.append(Segment(start: start, end: end, clips: winner.map { [$0] } ?? active))
            }
        }
        return segments
    }

    private nonisolated struct PrepassArtifact: Sendable {
        var url: URL?
        var path: FeedCameraPath?
        var cacheable: Bool
        var wasCached = false
        var identity: String? = nil
    }

    /// Bump when CenterStageService/AreaFramer output or tracking semantics change.
    nonisolated static let framingVersion = "multitrack-framing-v13-vip-paths"

    /// Portraits of the tagged VIPs in a source, cropped from their roster frames.
    /// Empty when nobody is tagged, which lets Center Stage frame everyone.
    nonisolated static func vipPortraits(sourcePath: String, keys: [String]? = nil, database: Database) async -> [Data] {
        guard let video = (try? await database.fetchVideos())?.first(where: { $0.url.path == sourcePath }),
              let roster = try? await database.fetchVideoPeople(videoID: video.id) else { return [] }
        let chosen = keys.map(Set.init)
        let vips = roster.filter { (chosen?.contains($0.key) ?? $0.isVIP) && $0.portraitBox != nil }
        guard !vips.isEmpty else { return [] }
        let frames = await ThumbnailService.jpegFrames(url: video.url, at: vips.map(\.portraitAt))
        return zip(vips, frames).compactMap { person, frame in
            frame.flatMap { Analyzer.boxPortrait(from: $0, box: person.portraitBox!) }
        }
    }

    nonisolated static func prepassKey(_ clip: ResolvedClip, area: ScreenCropArea?,
                                      tuning: String, settings: RenderSettings = RenderContext.settings,
                                      encoder: [String] = FFmpeg.encodeArgs,
                                      version: String = framingVersion) throws -> String {
        nonisolated struct Input: Encodable {
            var source: String
            var fingerprint: String
            var start: Double
            var duration: Double
            var hold: Bool
            var path: [CameraPathKeyframe]?
            var area: ScreenCropArea?
            var region: FreeCropRect?
            var focus: AreaFocus?
            var framingPlan: FramingPlan?
            var contentWindow: FreeCropRect?
            var tuning: String
            var settings: RenderSettings
            var encoder: [String]
            var rendererVersion = RenderSegmentCache.rendererVersion
            var strikeTracks: [StrikeHighlightRules.Track]?
            var strikeBurn: Int?
            var strikeHighlightStyle: String?
            var lingering: Telestration?
            var lingeringSpeed: Double?
            /// Set only for a slice of this render's own run path, so a
            /// result cached for the same keyframes as a saved path is not reused.
            var runPath: Bool?
            var pictureTake: String?
        }
        // A job that only tracks a camera path reads the untouched source.
        let drawsPicture = !(area != nil && (clip.areaRegion != nil || clip.cameraPath != nil))
        // Holds only track a camera path; moving stays also enter a prepass
        // that writes pictures. Their source-clock spacing depends on speed.
        let lingering = drawsPicture && clip.screenStay == nil ? TelestrationLingerResolution.drawingForPiece(clip) : nil
        return try RenderSegmentCache.key(Input(source: clip.framingIdentity ?? clip.sourcePath,
            fingerprint: clip.framingIdentity ?? SourceIdentityCache.shared.fingerprint(of: URL(fileURLWithPath: clip.sourcePath)),
            start: clip.sourceStart, duration: clip.sourceSpan, hold: clip.hold,
            path: clip.cameraPath, area: area, region: area == nil ? nil : clip.areaRegion ?? Self.cellBounds(of: clip),
            focus: area != nil && clip.areaRegion != nil ? clip.areaFocus : nil,
            framingPlan: clip.framingPlan, contentWindow: clip.contentWindow, tuning: tuning, settings: settings, encoder: encoder,
            strikeTracks: drawsPicture ? clip.strikeTracks : nil,
            strikeBurn: drawsPicture && clip.strikeTracks != nil ? StrikeHighlightBurn.version : nil,
            strikeHighlightStyle: drawsPicture && clip.strikeTracks != nil ? clip.strikeHighlightStyle : nil,
            lingering: lingering, lingeringSpeed: lingering == nil ? nil : clip.speed,
            runPath: clip.continuityRunPath ? true : nil,
            pictureTake: drawsPicture && clip.pictureRead.path != clip.sourcePath ? clip.pictureTake?.key : nil), version: version)
    }

    /// Tests only: the music catalog by name, instead of the music library.
    @TaskLocal static var musicLibraryOverride: [String: URL]?

    /// The Wizard's caption placement, from a Wizard-made document: the
    /// run's position ("auto" or an override), the clip position the Wizard
    /// wrote for it, and positions per person key.
    nonisolated struct WizardCaptionPlacement: Sendable {
        var runPosition: String
        var defaultClipPosition: String
        var speakerPositions: [String: String]
    }

    /// Where brand layers show: the main-track footage, merged where clips
    /// touch, without bumpers, cutaways or the Wizard's title/outro cards.
    nonisolated static func brandLayerSpans(document: TimelineDocument, totalDuration: Double) -> [Range<Double>] {
        let footage = document.videoTrack.filter { clip in
            clip.track == 0 && !clip.bumper && !clip.isCutaway && clip.duration > 0
                && !(clip.videoFile.map(WizardEngine.isWizardCard) ?? false)
        }.sorted { $0.startTime < $1.startTime }
        var spans: [Range<Double>] = []
        for clip in footage {
            let start = max(0, clip.startTime)
            let end = min(totalDuration, clip.startTime + clip.duration)
            guard end > start else { continue }
            if let last = spans.last, start <= last.upperBound + 0.01 {
                spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                spans.append(start..<end)
            }
        }
        return spans
    }

    /// The brand spans inside one segment, on the segment's own clock.
    nonisolated static func brandLayerWindows(spans: [Range<Double>], segmentStart: Double,
                                              segmentEnd: Double) -> [Range<Double>] {
        spans.compactMap { span in
            let start = max(span.lowerBound, segmentStart) - segmentStart
            let end = min(span.upperBound, segmentEnd) - segmentStart
            return end - start > 0.001 ? start..<end : nil
        }
    }

    /// Where the brand stage joins a segment's overlay chain (bottom first),
    /// given which footage steps are cutaways. Under cutaways (the full
    /// Wizard) it follows the last main-footage step, so every cutaway drawn
    /// after it covers the brand; otherwise it follows every footage step.
    nonisolated static func brandInsertionIndex(stepIsCutaway: [Bool], underCutaways: Bool) -> Int {
        guard underCutaways else { return stepIsCutaway.count }
        guard let lastMain = stepIsCutaway.lastIndex(of: false) else { return 0 }
        return lastMain + 1
    }

    /// One original Wizard cut's captioned footage on one track: contiguous
    /// main clips sharing an origin (or, without one, a video) whose source
    /// clock runs on, so crop splits and B-roll boundaries stay one cut.
    nonisolated struct CaptionCut: Equatable, Sendable {
        var start: Double
        var end: Double
        /// Transcript clock at `start`, and its rate per timeline second.
        var sourceStart: Double
        var speed: Double
        var videoID: Int64
        var track: Int
        var captionsPosition: String
        var originKey: String
        /// The first clip's index in `document.videoTrack` (its video file owns dub lines).
        var documentIndex: Int

        var pauses: [WizardStrikePauses.Pause] = []
        var timing: WizardStrikePauses.Timing {
            .init(plannedDuration: end - start - pauses.reduce(0) { $0 + $1.duration }, pauses: pauses)
        }
        var sourceEnd: Double { sourceStart + timing.plannedDuration * speed }
    }

    nonisolated static func captionCuts(_ clips: [ResolvedClip]) -> [CaptionCut] {
        let captioned = clips.filter {
            $0.captionsPosition != nil && $0.videoID != nil && $0.role == .main && !$0.bumper && $0.duration > 0
        }.sorted { ($0.track, $0.startTime) < ($1.track, $1.startTime) }
        var cuts: [CaptionCut] = []
        for clip in captioned {
            guard let position = clip.captionsPosition, let videoID = clip.videoID else { continue }
            let sourceStart = clip.transcriptStart(at: clip.startTime)
            // A Wizard freeze retains the cut's origin. Keep caption pagination
            // on the original source clock across every moving/held piece,
            // then map the finished windows through the recorded holds once.
            if clip.hold {
                if let last = cuts.last, last.originKey == clip.originKey, last.videoID == videoID,
                   last.track == clip.track, last.captionsPosition == position,
                   abs(last.end - clip.startTime) < 0.01, abs(last.sourceEnd - sourceStart) < 0.05 {
                    cuts[cuts.count - 1].pauses.append(.init(time: last.timing.plannedDuration, duration: clip.duration))
                    cuts[cuts.count - 1].end = clip.startTime + clip.duration
                } else {
                    // An exact-preview window can begin inside a hold. Its
                    // source clock is stationary even without a preceding piece.
                    cuts.append(CaptionCut(start: clip.startTime, end: clip.startTime + clip.duration,
                        sourceStart: sourceStart, speed: 1, videoID: videoID, track: clip.track,
                        captionsPosition: position, originKey: clip.originKey, documentIndex: clip.documentIndex,
                        pauses: [.init(time: 0, duration: clip.duration)]))
                }
                continue
            }
            if let last = cuts.last, last.track == clip.track, last.captionsPosition == position,
               abs(last.speed - clip.speed) < 1e-6, abs(last.end - clip.startTime) < 0.01,
               abs(last.sourceEnd - sourceStart) < 0.05,
               last.originKey.isEmpty ? (clip.originKey.isEmpty && last.videoID == videoID) : last.originKey == clip.originKey {
                cuts[cuts.count - 1].end = max(last.end, clip.startTime + clip.duration)
                continue
            }
            cuts.append(CaptionCut(start: clip.startTime, end: clip.startTime + clip.duration, sourceStart: sourceStart,
                                   speed: clip.speed, videoID: videoID, track: clip.track, captionsPosition: position,
                                   originKey: clip.originKey, documentIndex: clip.documentIndex))
        }
        return cuts
    }

    /// A cut's caption overlays (timeline seconds) inside one segment, on the segment's clock.
    nonisolated static func captionOverlays(_ overlays: [CaptionOverlayPlan.Overlay], segmentStart: Double,
                                            segmentEnd: Double) -> [CaptionOverlayPlan.Overlay] {
        overlays.compactMap { overlay in
            let start = max(overlay.start, segmentStart)
            let end = min(overlay.end, segmentEnd)
            guard end - start > 0.0005 else { return nil }
            var local = overlay
            local.start = start - segmentStart
            local.end = end - segmentStart
            return local
        }
    }

    /// One cut's planned captions in timeline seconds; `complete` is false
    /// when its transcript could not be read.
    nonisolated struct CutCaptionPlan: Sendable {
        var cut: CaptionCut
        var overlays: [CaptionOverlayPlan.Overlay]
        var complete: Bool
    }

    /// Captions for each Wizard cut over its whole extent, from the
    /// reviewed dub lines when the document is dubbed (the Wizard's
    /// `DubPlanning.captionSegments`), else from the transcript.
    private func planCutCaptions(_ cuts: [CaptionCut], document: TimelineDocument, database: Database, captionLanguage: String?,
                                 captionRenderers: CaptionRendererSet, wizardCaptions: WizardCaptionPlacement,
                                 captionStyle: CaptionStyle, captionEvidence: CaptionSpeakerEvidenceMemo,
                                 emit: @escaping @Sendable (String) -> Void) async throws -> [CutCaptionPlan] {
        let owners = Dictionary(document.videoTrack.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let dubLines = document.dub == nil ? [] : (document.dubLines ?? [])
        var plans: [CutCaptionPlan] = []
        for cut in cuts {
            try Task.checkCancellation()
            let videoFile = document.videoTrack[safe: cut.documentIndex]?.videoFile
            // A hold-only preview samples the caption at one source frame,
            // then keeps that caption for the stationary output window.
            let captionDuration = cut.timing.plannedDuration > 1e-9 ? cut.timing.plannedDuration : 1.0 / 30
            let captionSourceEnd = cut.sourceStart + captionDuration * cut.speed
            let lines = dubLines.filter { line in
                guard let owner = owners[line.clipUID] else { return false }
                return owner.hold != true && owner.videoFile == videoFile && !owner.muted
            }
            let dubbed = DubPlanning.captionSegments(lines: lines, sourceStart: cut.sourceStart,
                                                     sourceEnd: captionSourceEnd, speed: cut.speed)
            let rows: [TranscriptSegment]
            if !dubbed.isEmpty {
                rows = dubbed
            } else {
                do {
                    rows = try await database.transcriptSegments(videoID: cut.videoID, start: cut.sourceStart,
                                                                 end: captionSourceEnd, language: captionLanguage)
                } catch {
                    try Task.checkCancellation()
                    plans.append(CutCaptionPlan(cut: cut, overlays: [], complete: false))
                    continue
                }
            }
            let position = cut.captionsPosition == wizardCaptions.defaultClipPosition
                ? wizardCaptions.runPosition : cut.captionsPosition
            let map = wizardCaptions.speakerPositions
            let speakerPositions: ((String?) -> String)? = map.isEmpty ? nil : { person in person.flatMap { map[$0] } ?? position }
            let needsSpeakers = captionStyle.resolvedSpeakerColors || captionRenderers.usesSpeakers
                || speakerPositions != nil
            let evidence = needsSpeakers
                ? await captionEvidence.evidence(videoID: cut.videoID)
                : CaptionSpeakerEvidence()
            try Task.checkCancellation()
            let captionRows = dubbed.isEmpty
                ? FillerCutRules.captions(rows, removing: FillerCutRules.skipped(
                    document.appliedFillerSpans?[cut.videoID] ?? [],
                    playing: cut.sourceStart...(cut.sourceStart + max(0, captionDuration * cut.speed)))) : rows
            let pages = CaptionOverlayPlan.pages(segments: captionRows, renderers: captionRenderers,
                sourceStart: cut.sourceStart, speed: cut.speed, duration: captionDuration,
                position: position, language: captionLanguage ?? "",
                speakerTurns: evidence.turns, speakerRows: evidence.rows, streamID: cut.originKey,
                speakerPositions: speakerPositions)
            let plan = try CaptionOverlayPlan.plan(pages: pages, style: captionStyle, styles: captionRenderers.styles)
            if plan.usedRevealFallback { emit("Captions: input limit reached; simplified word reveal or motion for this clip") }
            if plan.usedPageFallback { emit("Captions: over 400 inputs; using static page overlays for this clip") }
            plans.append(CutCaptionPlan(cut: cut, overlays: cut.timing.captions(plan.overlays).map { overlay in
                var shifted = overlay
                shifted.start += cut.start
                shifted.end += cut.start
                return shifted
            }, complete: true))
        }
        return plans
    }

    // MARK: - Segment rendering

    /// A caption PNG composited over a segment inside its enable window.
    nonisolated struct CaptionOverlay: Codable, Sendable {
        var png: URL
        var x: Int
        var y: Int
        var start: Double
        var end: Double
        var text: String?
    }

    /// Render one timeline segment to its own file: black gap placeholder, or
    /// layered composite with captions burned in the same encode pass.
    private func renderSegment(_ segment: Segment, index: Int, of total: Int,
                               scratch: URL, database: Database,
                               captionLanguage: String?,
                               captionRenderers: CaptionRendererSet,
                               wizardCaptions: WizardCaptionPlacement? = nil,
                               cutCaptions: [CutCaptionPlan]? = nil,
                               captionCache: CaptionPNGCache,
                               captionEvidence: CaptionSpeakerEvidenceMemo,
                               dedupe: SegmentDedupe,
                               captionStyle: CaptionStyle, fontFingerprints: [String]?,
                               overlays: [TimedOverlayPNG],
                               brandLayers: [CaptionOverlay] = [], brandUnderCutaways: Bool = false,
                               prerendered: Set<String> = [],
                               burnIns: [RenderEngine.ClipOverlay] = [], burnInDuration: Double = 0,
                               muteSource: Bool = false, compositeEffect: EffectSpec? = nil,
                               emit: @escaping @Sendable (String) -> Void) async throws -> SegmentArtifact {
        let timing = PerfSignpost.begin("SegmentEncode", metadata: "segment=\(index)/\(total)")
        defer { PerfSignpost.end(timing) }
        if burnIns.isEmpty, !muteSource, compositeEffect == nil, segment.clips.isEmpty || segment.clips.allSatisfy(\.missingBumper) {
            emit("Segment \(index + 1)/\(total): gap (\(String(format: "%.1fs", segment.duration)))")
            let gapPath = scratch.appendingPathComponent(String(format: "gap%03d.mp4", index))
            let input = RenderSegmentKey(start: 0, duration: segment.duration.rounded(toPlaces: 6), clips: [],
                captions: [], overlays: [], masks: [:], fontFingerprints: [], captionStyle: CaptionStyle(),
                speakerCaptionStyles: [:],
                settings: RenderContext.settings, encoder: FFmpeg.encodeArgs)
            let key = try RenderSegmentCache.key(input)
            if await segmentCache.restore(key: key, to: gapPath) {
                emit("Segment \(index + 1): cache hit; encodes=0")
                return SegmentArtifact(url: gapPath, key: nil, wasCached: true)
            }
            let owns: Bool
            switch await dedupe.claim(key) {
            case .owner: owns = true
            case .shared(let url):
                try FileManager.default.copyItemReplacing(at: url, to: gapPath)
                emit("Segment \(index + 1): same as another segment; encodes=0")
                return SegmentArtifact(url: gapPath, key: nil, wasShared: true)
            case .ownerFailed: owns = false
            }
            do {
                emit("Segment \(index + 1): encode pass")
                try await generatePlaceholder(duration: segment.duration, output: gapPath)
                try Task.checkCancellation()
            } catch {
                if owns { await dedupe.finish(key, url: nil) }
                throw error
            }
            if owns { await dedupe.finish(key, url: gapPath) }
            return SegmentArtifact(url: gapPath, key: key)
        }

        emit("Segment \(index + 1)/\(total): compositing \(segment.clips.count) clip(s)…")
        var placements = Self.placements(for: segment).filter { !segment.clips[$0.clipIndex].missingBumper }

        // Captions ride the composite's filter graph — no second encode pass.
        var captions: [CaptionOverlay] = []
        var segmentComplete = true
        var captionPages: [CaptionOverlayPlan.Page] = []
        var cutOverlays: [CaptionOverlayPlan.Overlay] = []
        if let cutCaptions {
            for cut in cutCaptions where cut.cut.start < segment.end && cut.cut.end > segment.start
                && segment.clips.contains(where: { $0.captionsPosition != nil && $0.role == .main && $0.track == cut.cut.track }) {
                if !cut.complete { segmentComplete = false }
                cutOverlays += Self.captionOverlays(cut.overlays, segmentStart: segment.start, segmentEnd: segment.end)
            }
        }
        for clip in segment.clips where cutCaptions == nil {
            guard let captionPosition = clip.captionsPosition, let videoID = clip.videoID else { continue }
            let sourceStart = clip.transcriptStart(at: segment.start)
            let sourceEnd = sourceStart + segment.duration * clip.speed
            let rows: [TranscriptSegment]
            do {
                rows = try await database.transcriptSegments(videoID: videoID,
                    start: sourceStart, end: sourceEnd, language: captionLanguage)
            } catch {
                try Task.checkCancellation()
                segmentComplete = false
                continue
            }
            // A Wizard document places captions like its extraction: the run's
            // position unless this clip was moved in the Builder, per speaker
            // where the run set one.
            var position = captionPosition
            var speakerPositions: ((String?) -> String)?
            if let wizardCaptions {
                if captionPosition == wizardCaptions.defaultClipPosition { position = wizardCaptions.runPosition }
                let map = wizardCaptions.speakerPositions
                let run = position
                if !map.isEmpty { speakerPositions = { person in person.flatMap { map[$0] } ?? run } }
            }
            // Missing speaker evidence falls back to the run style.
            let needsSpeakers = captionStyle.resolvedSpeakerColors || captionRenderers.usesSpeakers
                || speakerPositions != nil
            let evidence = needsSpeakers
                ? await captionEvidence.evidence(videoID: videoID)
                : CaptionSpeakerEvidence()
            try Task.checkCancellation()
            captionPages += CaptionOverlayPlan.pages(segments: rows, renderers: captionRenderers,
                sourceStart: sourceStart, speed: clip.speed, duration: segment.duration,
                position: position, language: captionLanguage ?? "",
                speakerTurns: evidence.turns, speakerRows: evidence.rows, streamID: clip.originKey,
                speakerPositions: speakerPositions)
        }
        let plannedCaptions: [CaptionOverlayPlan.Overlay]
        if cutCaptions != nil {
            plannedCaptions = cutOverlays
        } else {
            let captionPlan = try CaptionOverlayPlan.plan(pages: captionPages, style: captionStyle, styles: captionRenderers.styles)
            if captionPlan.usedRevealFallback { emit("Captions: input limit reached; simplified word reveal or motion for this segment") }
            if captionPlan.usedPageFallback { emit("Captions: over 400 inputs; using static page overlays for this segment") }
            plannedCaptions = captionPlan.overlays
        }
        for overlay in plannedCaptions {
            guard let rendered = try? await captionCache.rendered(overlay.raster) else {
                try Task.checkCancellation()
                segmentComplete = false
                continue
            }
            let renderer = captionCache.renderer(styleID: overlay.raster.styleID)
            let (x, y) = wizardCaptions == nil
                ? renderer.position(for: rendered, clipPosition: overlay.position)
                : renderer.position(for: rendered, positionOverride: overlay.position)
            captions.append(CaptionOverlay(png: rendered.pngURL, x: x, y: y,
                start: overlay.start, end: overlay.end, text: overlay.raster.text))
        }

        let segmentPath = scratch.appendingPathComponent(String(format: "seg%03d_layered.mp4", index))
        let masks = Self.maskFiles(for: placements, in: scratch)
        var keyClips = segment.clips
        for index in keyClips.indices {
            if keyClips[index].hold {
                keyClips[index].framingIdentity = (keyClips[index].framingIdentity ?? "") + "-editor-hold-v5"
            }
            if keyClips[index].continuityTransform == true {
                let version = keyClips[index].continuitySavedTransform == true
                    ? "-continuity-saved-transform-v6" : "-continuity-graph-v3"
                keyClips[index].framingIdentity = (keyClips[index].framingIdentity ?? "") + version
                    + (keyClips[index].continuityGrid?.cacheSuffix ?? "")
            } else if keyClips[index].continuityTransform == false {
                keyClips[index].framingIdentity = (keyClips[index].framingIdentity ?? "") + "-continuity-saved-rectangle-v5"
            }
            keyClips[index].telestration = keyClips[index].telestration.map(TelestrationLingerResolution.cacheDrawing)
            keyClips[index].sourcePath = keyClips[index].originalSourcePath ?? keyClips[index].sourcePath
        }
        // The origin identity is a document-side tie-breaker, not pixels:
        // caching it would miss on every clip whose key differs. Its only
        // effect on the output is the draw order, so store that instead.
        for index in keyClips.indices { keyClips[index].documentIndex = 0 }
        for (rank, placement) in placements.enumerated() where keyClips.indices.contains(placement.clipIndex) {
            keyClips[placement.clipIndex].originKey = String(rank)
        }
        var keyCaptions = captions
        for index in keyCaptions.indices {
            let digest = try RenderSegmentCache.key(Data(contentsOf: captions[index].png))
            keyCaptions[index].png = URL(fileURLWithPath: "/" + digest)
        }
        var keyOverlays = overlays
        for index in keyOverlays.indices {
            let digest = try RenderSegmentCache.key(Data(contentsOf: overlays[index].png))
            keyOverlays[index].png = URL(fileURLWithPath: "/" + digest)
        }
        let maskKeys = try masks.reduce(into: [String: String]()) { result, entry in
            result[String(entry.key)] = try RenderSegmentCache.key(Data(contentsOf: entry.value))
        }
        var keyBrand = brandLayers
        for index in keyBrand.indices {
            let digest = try RenderSegmentCache.key(Data(contentsOf: brandLayers[index].png))
            keyBrand[index].png = URL(fileURLWithPath: "/" + digest)
            keyBrand[index].start = keyBrand[index].start.rounded(toPlaces: 6)
            keyBrand[index].end = keyBrand[index].end.rounded(toPlaces: 6)
        }
        var keyBurnIns = burnIns
        for index in keyBurnIns.indices {
            keyBurnIns[index].png = URL(fileURLWithPath: "/" + (try RenderSegmentCache.key(Data(contentsOf: burnIns[index].png))))
        }
        var lookAssets: [String: String] = [:]
        for effect in keyClips.compactMap(\.effectiveEffect) + [compositeEffect].compactMap({ $0 }) where effect.preset.hasPrefix("lut:") {
            if let lut = EffectCatalog.lutURL(named: String(effect.preset.dropFirst(4))) {
                lookAssets[effect.preset] = try RenderSegmentCache.key(Data(contentsOf: lut))
            }
        }
        let localBumper = segment.clips.count == 1 && segment.clips[0].bumper
            && captions.isEmpty && overlays.isEmpty && brandLayers.isEmpty
            && burnIns.isEmpty
        // A segment's pixels depend on its clips relative to the segment, not
        // on where it sits in the timeline (captions and fused overlays are
        // already segment-local): lengthening an early clip must not
        // re-encode every later segment. Burn-ins are placed at absolute
        // times, so those segments keep their position in the key.
        for index in keyClips.indices {
            keyClips[index].startTime = (keyClips[index].startTime - segment.start).rounded(toPlaces: 6)
            keyClips[index].originalStart = (keyClips[index].originalStart - segment.start).rounded(toPlaces: 6)
            keyClips[index].originalEnd = (keyClips[index].originalEnd - segment.start).rounded(toPlaces: 6)
        }
        for index in keyCaptions.indices {
            keyCaptions[index].start = keyCaptions[index].start.rounded(toPlaces: 6)
            keyCaptions[index].end = keyCaptions[index].end.rounded(toPlaces: 6)
        }
        for index in keyOverlays.indices {
            keyOverlays[index].startTime = keyOverlays[index].startTime.rounded(toPlaces: 6)
            keyOverlays[index].endTime = keyOverlays[index].endTime.rounded(toPlaces: 6)
        }
        if localBumper {
            for index in keyClips.indices {
                // Joins happen after this segment and cannot change its pixels.
                keyClips[index].transIn = nil
                keyClips[index].transOut = nil
            }
        }
        let input = RenderSegmentKey(start: burnIns.isEmpty ? 0 : segment.start,
            duration: segment.duration.rounded(toPlaces: 6), clips: keyClips,
            captions: keyCaptions, overlays: keyOverlays, masks: maskKeys,
            fontFingerprints: fontFingerprints ?? [], captionStyle: captionStyle,
            speakerCaptionStyles: captionRenderers.styles,
            settings: RenderContext.settings, encoder: FFmpeg.encodeArgs + FFmpeg.intermediateCacheIdentity,
            burnIns: keyBurnIns.isEmpty ? nil : keyBurnIns,
            burnInDuration: keyBurnIns.contains { $0.animation != nil } ? burnInDuration : nil,
            muteSource: muteSource ? true : nil, compositeEffect: compositeEffect, lookAssets: lookAssets.isEmpty ? nil : lookAssets,
            brandLayers: keyBrand.isEmpty ? nil : keyBrand,
            brandUnderCutaways: keyBrand.isEmpty || !brandUnderCutaways ? nil : true,
            lingering: TelestrationLingerResolution.cacheEvidence(keyClips),
            screenStays: TelestrationLingerResolution.screenEvidence(keyClips),
            stayTransitions: keyClips.contains { $0.stayTransitionStart != nil } ? keyClips.map(\.stayTransitionStart) : nil,
            fixedStayFlash: placements.contains { $0.screenStay != nil && ($0.flashIn ?? 0) > 0 } ? true : nil,
            slowAudio: keyClips.contains { !$0.hold && $0.speed >= StrikeImpactRules.minimumSpeed && $0.speed < 0.5 } ? true : nil)
        var key: String? = segmentComplete && fontFingerprints != nil && segment.clips.allSatisfy(\.cacheable)
            ? try RenderSegmentCache.key(input) : nil
        if let key, await segmentCache.restore(key: key, to: segmentPath) {
            emit("Segment \(index + 1): cache hit; encodes=0")
            return SegmentArtifact(url: segmentPath, key: nil, wasCached: true)
        }
        // A clip this app already rendered to the output format, shown whole
        // and untouched, is the segment: copy it instead of encoding it again.
        if burnIns.isEmpty, !muteSource, compositeEffect == nil, captions.isEmpty, overlays.isEmpty, brandLayers.isEmpty, masks.isEmpty, placements.count == 1, segment.clips.count == 1,
           await Self.isPrerenderedPassthrough(placements[0], clip: segment.clips[0], prerendered: prerendered) {
            emit("Segment \(index + 1): prerendered clip; copied, encodes=0")
            try FileManager.default.copyItemReplacing(at: URL(fileURLWithPath: placements[0].sourcePath), to: segmentPath)
            try Task.checkCancellation()
            return SegmentArtifact(url: segmentPath, key: nil)
        }
        // A repeated clip makes an identical segment: encode it once and copy
        // the bytes, so both the work and the finishing digests are shared.
        var ownedKey: String?
        if let key {
            switch await dedupe.claim(key) {
            case .owner: ownedKey = key
            case .shared(let url):
                try FileManager.default.copyItemReplacing(at: url, to: segmentPath)
                emit("Segment \(index + 1): same as another segment; encodes=0")
                return SegmentArtifact(url: segmentPath, key: nil, wasShared: true)
            case .ownerFailed: ownedKey = nil
            }
        }
        do {
            // Strike highlights are laid on each placement's source inside
            // the encode graph, before any crop, so every crop carries them.
            // Their pictures are drawn here, after the cache had its chance
            // and inside the block that always releases the segment key.
            for position in placements.indices {
                let placement = placements[position]
                guard let tracks = segment.clips[placement.clipIndex].strikeTracks else { continue }
                do {
                    guard let marks = try await StrikeHighlightBurn.prepare(source: URL(fileURLWithPath: placement.sourcePath),
                        start: placement.sourceStart, duration: placement.sourceDur, tracks: tracks, scratch: scratch,
                        style: segment.clips[placement.clipIndex].strikeHighlightStyle ?? "outline")
                    else { continue }
                    placements[position].strikeOverlay = marks.sequences
                    emit("Segment \(index + 1): strike highlights; intermediates=0")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    key = nil // A segment missing its highlights must never satisfy the full key.
                    emit("Segment \(index + 1): strike highlights failed (\(error)); rendering without them")
                }
            }
            for position in placements.indices {
                let placement = placements[position]
                let clip = segment.clips[placement.clipIndex]
                let pausedStay = placement.hold && clip.telestration == nil && clip.lingering != nil
                guard let drawing = placement.hold && !pausedStay ? clip.telestration : clip.lingering else { continue }
                do {
                    guard let marks = try await TelestrationBurn.prepare(source: URL(fileURLWithPath: placement.sourcePath),
                        drawing: drawing, offset: (pausedStay ? 0 : placement.holdOffset(at: segment.start)) + (drawing.offset ?? 0),
                        duration: placement.hold ? segment.duration : min(segment.duration, clip.startTime + clip.duration - segment.start), scratch: scratch,
                        lingering: !placement.hold || pausedStay, speed: placement.screenStay == nil ? placement.speed : 1,
                        pausedStay: pausedStay,
                        screenStay: placement.screenStay, stayTransitionStart: clip.stayTransitionStart.map {
                            pausedStay ? $0 - placement.holdOffset(at: segment.start) : $0
                        })
                    else { continue }
                    // Validate graph paths here as well, inside the degradation
                    // boundary that clears the cache key on a drawing failure.
                    if placement.hold {
                        _ = try StrikeHighlightBurn.inHoldGraph(marks.sequences, size: marks.size, input: "[hold]", tag: "drawing")
                    } else {
                        _ = try StrikeHighlightBurn.inGraph(marks.sequences, size: marks.size, input: "[motion]", tag: "drawing")
                    }
                    placements[position].telestrationOverlay = marks.sequences
                    placements[position].telestrationSize = marks.size
                    emit("Drawing: segment \(index + 1); intermediates=0")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    key = nil
                    emit("Drawing: segment \(index + 1) failed (\(error)); rendering without it")
                    ErrorLog.record("Telestrator", "Drawing preparation failed: \(error)")
                }
            }
            let attempts = SegmentEncodeFallback.attempts(
                drawings: placements.contains { $0.telestrationOverlay != nil }, captions: !captions.isEmpty)
            for (attemptIndex, attempt) in attempts.enumerated() {
                if !attempt.drawings {
                    for position in placements.indices { placements[position].telestrationOverlay = nil }
                }
                do {
                    emit("Segment \(index + 1): encode pass")
                    try await compositeLayeredSegment(placements: placements, duration: segment.duration,
                        captions: attempt.captions ? captions : [], overlays: overlays, brandLayers: brandLayers,
                        brandUnderCutaways: brandUnderCutaways, maskFiles: masks, burnIns: burnIns,
                        burnInDuration: burnInDuration, timelineOffset: segment.start, muteSource: muteSource, compositeEffect: compositeEffect,
                        intermediateSources: prerendered.union(segment.clips.filter {
                            $0.originalSourcePath != nil && $0.originalSourcePath != $0.sourcePath
                        }.map(\.sourcePath)), output: segmentPath)
                    break
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    key = nil // Every degraded path stays out of both caches.
                    guard attemptIndex + 1 < attempts.count else { throw error }
                    let next = attempts[attemptIndex + 1]
                    if attempt.drawings && !next.drawings {
                        emit("Drawing: segment \(index + 1) encode failed (\(error)); rendering without it")
                        ErrorLog.record("Telestrator", "Drawing encode failed: \(error)")
                    } else {
                        emit("Segment \(index + 1): caption burn failed, retrying without captions; encode pass")
                    }
                }
            }
            try Task.checkCancellation()
        } catch {
            if let ownedKey { await dedupe.finish(ownedKey, url: nil) }
            throw error
        }
        // A degraded (caption-less) result is not the keyed segment: siblings encode their own.
        if let ownedKey { await dedupe.finish(ownedKey, url: key == nil ? nil : segmentPath) }
        return SegmentArtifact(url: segmentPath, key: key)
    }

    nonisolated struct SegmentArtifact: Sendable {
        var url: URL
        var key: String?
        var wasCached = false
        /// A copy of an identical segment encoded earlier in this render.
        var wasShared = false
        var reusable: Bool { key != nil || wasCached || wasShared }
    }

    /// Identical segments in one render (a repeated clip, equal gaps): the
    /// first claims the key and encodes, the rest wait and copy its file.
    actor SegmentDedupe {
        enum Claim { case owner, shared(URL), ownerFailed }
        private var owners: Set<String> = []
        private var results: [String: URL?] = [:]
        private var waiters: [String: [CheckedContinuation<URL?, Never>]] = [:]

        /// `.owner` obliges the caller to `finish` the key on every path.
        func claim(_ key: String) async -> Claim {
            if let done = results[key] { return done.map(Claim.shared) ?? .ownerFailed }
            if owners.insert(key).inserted { return .owner }
            let url = await withCheckedContinuation { waiters[key, default: []].append($0) }
            return url.map(Claim.shared) ?? .ownerFailed
        }

        func finish(_ key: String, url: URL?) {
            results[key] = url
            for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume(returning: url) }
        }
    }

    /// True when the segment would re-encode `placement` unchanged: the
    /// source is one the caller rendered with this app's encode settings,
    /// fills the frame at the output size with its own audio, plays whole
    /// at normal speed, and carries no crop, fade, effect, mask or layout.
    nonisolated static func isPrerenderedPassthrough(_ placement: Placement, clip: ResolvedClip,
                                                     prerendered: Set<String>) async -> Bool {
        guard prerendered.contains(placement.sourcePath),
              !placement.isWide, !placement.bumper, !placement.fillCanvas, !placement.muted,
              placement.role == .main, placement.speed == 1, placement.flashIn == nil,
              placement.staticAreaFilter == nil, placement.effectiveEffect == nil, placement.framingPlan == nil,
              placement.freeCrops?.isEmpty != false, placement.cropXFrac == nil, placement.screenCrop == nil,
              placement.fadeIn == nil, placement.fadeOut == nil,
              clip.lingering == nil,
              clip.cameraPath == nil, clip.areaWindow == nil, clip.areaRegion == nil, !clip.centerStage,
              placement.sourceStart <= 0.001 else { return false }
        let probe = await FFmpeg.info(of: URL(fileURLWithPath: placement.sourcePath))
        return probe.hasAudio && probe.width == width && probe.height == height
            && abs(probe.duration - placement.sourceDur) <= 0.1
    }

    private func publishSegments(_ artifacts: [SegmentArtifact], clips: [ResolvedClip],
                                 finishing: [RenderSegmentCache.Entry] = []) async {
        // Do not cache an encode whose source changed during the run.
        for clip in clips {
            guard let path = clip.originalSourcePath,
                  let fingerprint = try? SourceIdentityCache.shared.fingerprint(of: URL(fileURLWithPath: path)),
                  fingerprint == clip.sourceFingerprint else { return }
        }
        var entries = artifacts.compactMap { artifact in
            artifact.key.map { RenderSegmentCache.Entry(key: $0, source: artifact.url) }
        }
        entries.append(contentsOf: finishing)
        await segmentCache.store(entries)
    }

    // MARK: - FFmpeg stages

    /// The finishing cache stores the mix before Speech Polish, so its key
    /// must not depend on the polish choice.
    nonisolated static func finishingSettings(_ settings: RenderSettings) -> RenderSettings {
        var settings = settings
        settings.speechPolish = nil
        return settings
    }

    /// Solid black 1080x1920 clip with silent audio (video.py generate_placeholder).
    private func generatePlaceholder(duration: Double, output: URL) async throws {
        try await FFmpeg.run(["-y",
                              "-f", "lavfi", "-i",
                              String(format: "color=c=black:s=%dx%d:d=%.2f:r=30",
                                     Self.width, Self.height, duration),
                              "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                              "-t", String(format: "%.2f", duration)]
                             + FFmpeg.encodeArgs + [output.path], timeout: 120, capture: .boundedStderrTail(), purpose: "silent gap placeholder")
    }

    /// Splice a placement look before masks and fades, with unique graph pads.
    nonisolated static func insertEffect(_ effect: EffectSpec, label: String, width: Int,
                                        height: Int, filters: inout [String]) {
        let fragment = EffectCatalog.filter(for: effect, width: width, height: height, namespace: "fx_\(label)_")
        guard !fragment.isEmpty,
              let index = filters.firstIndex(where: { $0.hasSuffix("[\(label)]") }) else { return }
        let producer = String(filters[index].dropLast(label.count + 2))
        if fragment.contains(";") {
            filters[index] = producer + "[pre_\(label)]"
            filters.append("[pre_\(label)]\(fragment)[\(label)]")
        } else {
            filters[index] = producer + ",\(fragment)[\(label)]"
        }
    }

    /// Port of video.py composite_layered_segment(): black base canvas, each
    /// placement overlaid in (layer, stack order) order — non-wide clips fill
    /// the frame, cropped wides fill the frame through a 9:16 window, slot
    /// wides land in a 1080x640 band, free-crop rectangles composite in z
    /// order, caption PNGs overlay last inside their enable windows. Unmuted
    /// clip audio mixes via amix (silence when none).
    private func compositeLayeredSegment(placements: [Placement], duration: Double,
                                         captions: [CaptionOverlay] = [],
                                         overlays: [TimedOverlayPNG] = [],
                                         brandLayers: [CaptionOverlay] = [], brandUnderCutaways: Bool = false,
                                         maskFiles: [Int: URL] = [:],
                                         burnIns: [RenderEngine.ClipOverlay] = [], burnInDuration: Double = 0,
                                         timelineOffset: Double = 0, muteSource: Bool = false, compositeEffect: EffectSpec? = nil,
                                         intermediateSources: Set<String> = [], output: URL) async throws {
        // Already in the one order `renderSegment` computed; the masks are
        // keyed by index into exactly this list, so it must not be re-sorted.
        let ordered = placements

        var arguments = ["-y",
                         "-f", "lavfi", "-i",
                         String(format: "color=c=black:s=%dx%d:d=%.3f:r=30",
                                Self.width, Self.height, duration),
                         "-f", "lavfi", "-i",
                         String(format: "anullsrc=r=44100:cl=stereo:d=%.3f", duration)]
        for placement in ordered {
            arguments += await FFmpeg.intermediateDecodeArguments(
                for: URL(fileURLWithPath: placement.sourcePath), eligible: intermediateSources.contains(placement.sourcePath))
            let seek = placement.holdFrameTime.map(ContinuityFrameSelection.seek)
                ?? String(format: "%.3f", max(0, placement.sourceStart))
            arguments += ["-ss", seek,
                          // A Double on both sides: a bare `1` here is passed to the
                          // format as an Int and prints as 0.000.
                          "-t", String(format: "%.3f", placement.hold ? 1.0 : placement.sourceDur),
                          "-i", placement.sourcePath]
        }
        // A still PNG needs one decoder thread; ffmpeg otherwise spawns a
        // frame-thread pool per input and hundreds of inputs hit the
        // process thread ceiling.
        for caption in captions { arguments += ["-threads", "1", "-i", caption.png.path] }
        // Screen-crop masks: one PNG input per masked placement (after the
        // captions), looped for the segment so alphamerge has a frame for
        // every video frame.
        var maskInputs: [Int: Int] = [:]   // placement index → input index
        for (index, placement) in ordered.enumerated() where placement.freeCrops?.isEmpty != false {
            guard let mask = maskFiles[index]
            else { continue }
            maskInputs[index] = 2 + ordered.count + captions.count + maskInputs.count
            arguments += ["-loop", "1", "-t", String(format: "%.3f", duration), "-i", mask.path]
        }

        var filters: [String] = []
        var fitInputs: [URL] = []
        let fitInputOffset = 2 + ordered.count + captions.count + maskInputs.count
        var freeCropOutputs: [Int: [(label: String, x: Int, y: Int)]] = [:]

        for (index, placement) in ordered.enumerated() {
            let sourceIndex = index + 2
            // Slow motion stretches this clip's timestamps inside the
            // segment; the audio atempo below matches.
            let pts = placement.speed == 1 ? "setpts=PTS-STARTPTS"
                : String(format: "setpts=(PTS-STARTPTS)/%.4f", placement.speed)
            var input = "[\(sourceIndex):v]"
            if let marks = placement.strikeOverlay, !marks.isEmpty {
                let size = await FFmpeg.dimensions(of: URL(fileURLWithPath: placement.sourcePath))
                filters += try StrikeHighlightBurn.inGraph(marks, size: CGSize(width: size.width, height: size.height),
                                                           input: input, tag: "strike\(index)")
                input = "[strike\(index)]"
            }
            if placement.hold {
                filters.append("\(input)trim=end_frame=1," +
                    String(format: "tpad=stop_mode=clone:stop_duration=%.6f", duration) +
                    ",setpts=PTS-STARTPTS,fps=30,trim=end_frame=\(max(1, Int((duration * 30).rounded())))[hold\(index)]")
                input = "[hold\(index)]"
                if placement.screenStay == nil, let marks = placement.telestrationOverlay, !marks.isEmpty, let size = placement.telestrationSize {
                    // The held frame repeats at the source's own rate; the
                    // drawing is animated, so the pause runs at the output rate.
                    filters.append("\(input)fps=30[hold30_\(index)]")
                    input = "[hold30_\(index)]"
                    // tpad's stream already starts at zero. Give the animation
                    // a 30 fps clock independent of image2's default timebase.
                    filters += try StrikeHighlightBurn.inHoldGraph(marks, size: size, input: input, tag: "drawing\(index)")
                    input = "[drawing\(index)]"
                }
            } else if placement.screenStay == nil, let marks = placement.telestrationOverlay, !marks.isEmpty, let size = placement.telestrationSize {
                filters += try StrikeHighlightBurn.inGraph(marks, size: size, input: input, tag: "drawing\(index)")
                input = "[drawing\(index)]"
            }
            if (placement.screenStay == nil || placement.telestrationOverlay?.isEmpty != false),
               let flash = StrikeImpactRender.flash(placement.flashIn, speed: placement.speed, hold: placement.hold) {
                filters.append("\(input)\(flash)[flash\(index)]")
                input = "[flash\(index)]"
            }
            if let crops = Self.normalizedFreeCrops(placement.freeCrops), !crops.isEmpty {
                let splitOuts = (0..<crops.count).map { "[s\(index)_\($0)]" }.joined()
                filters.append("\(input)\(pts),setsar=1,fps=30," +
                               "split=\(crops.count)\(splitOuts)")
                var outs: [(label: String, x: Int, y: Int, z: Int)] = []
                for (cropIndex, crop) in crops.enumerated() {
                    let dstW = max(2, Int((Double(Self.width) * crop.dw).rounded()))
                    let dstH = max(2, Int((Double(Self.height) * crop.dh).rounded()))
                    if let plan = placement.framingPlan, plan.fit == .blurredFill {
                        let dimensions = await FFmpeg.dimensions(of: URL(fileURLWithPath: placement.sourcePath))
                        let size = CGSize(width: dstW, height: dstH)
                        let spec = FitSpec(sourceWindow: FreeCropRect(xFrac: crop.sx, yFrac: crop.sy, wFrac: crop.sw, hFrac: crop.sh),
                            sourceSize: CGSize(width: dimensions.width, height: dimensions.height),
                            destination: CGRect(origin: .zero, size: size), canvasSize: size,
                            fit: plan.fit, feather: plan.feather, blur: plan.blur)
                        filters.append(try FitComposer.graph(spec, inputLabel: "s\(index)_\(cropIndex)",
                            outputLabel: "v\(index)_\(cropIndex)", extraInputs: &fitInputs, inputOffset: fitInputOffset))
                    } else {
                        filters.append(String(format: "[s%d_%d]crop=iw*%.5f:ih*%.5f:iw*%.5f:ih*%.5f,scale=%d:%d[v%d_%d]",
                                              index, cropIndex, crop.sw, crop.sh, crop.sx, crop.sy,
                                              dstW, dstH, index, cropIndex))
                    }
                    outs.append(("v\(index)_\(cropIndex)",
                                 Int((Double(Self.width) * crop.dx).rounded()),
                                 Int((Double(Self.height) * crop.dy).rounded()),
                                 crop.z))
                }
                freeCropOutputs[index] = outs.sorted { $0.z < $1.z }.map { ($0.label, $0.x, $0.y) }
                continue
            }

            if let areaFilter = placement.staticAreaFilter {
                let cameraClock = placement.continuityTransform == true ? "" : "setpts=PTS-STARTPTS,"
                filters.append("\(input)\(cameraClock)\(areaFilter),\(pts)," +
                               "setsar=1,fps=30[v\(index)]")
                continue
            }

            if let plan = placement.framingPlan, !placement.bumper {
                let size = await FFmpeg.dimensions(of: URL(fileURLWithPath: placement.sourcePath))
                let canvas = CGSize(width: Self.width, height: Self.height)
                let destination = placement.fitArea.map(AreaFramer.pixelBounds) ?? CGRect(origin: .zero, size: canvas)
                let spec = FitSpec(sourceWindow: placement.fitWindow ?? plan.sourceWindow ?? FreeCropRect(),
                    sourceSize: CGSize(width: size.width, height: size.height), destination: destination,
                    canvasSize: canvas, fit: plan.fit, feather: plan.feather, blur: plan.blur)
                filters.append("\(input)\(pts),setsar=1,fps=30[fit_source\(index)]")
                filters.append(try FitComposer.graph(spec, inputLabel: "fit_source\(index)", outputLabel: "v\(index)",
                    extraInputs: &fitInputs, inputOffset: fitInputOffset))
                continue
            }

            if placement.fillCanvas {
                // Cover-all cutaway: crop to fill the whole canvas, centred
                // (scale up to cover, then take the middle of the frame).
                filters.append(String(format: "%@%@," +
                                      "scale=%d:%d:force_original_aspect_ratio=increase," +
                                      "crop=%d:%d,setsar=1,fps=30[v%d]",
                                      input, pts, Self.width, Self.height,
                                      Self.width, Self.height, index))
                continue
            }

            var sourceStream = input
            if !placement.bumper, let window = placement.fitWindow, !Self.isFullFrame(window) {
                filters.append(String(format: "%@crop=iw*%.5f:ih*%.5f:iw*%.5f:ih*%.5f[content%d]",
                    sourceStream, window.wFrac, window.hFrac, window.xFrac, window.yFrac, index))
                sourceStream = "[content\(index)]"
            }
            let wideCropped = placement.isWide && placement.cropXFrac != nil
            if wideCropped {
                let fraction = max(0, min(1, placement.cropXFrac ?? 0.5))
                let aspect = RenderContext.settings.aspectRatio
                filters.append(String(format: "%@%@," +
                                      "crop='min(iw\\,ih*%.5f)':ih:(iw-min(iw\\,ih*%.5f))*%.4f:0," +
                                      "scale=%d:%d:force_original_aspect_ratio=decrease," +
                                      "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black," +
                                      "setsar=1,fps=30[v%d]",
                                      sourceStream, pts, aspect, aspect, fraction, Self.width, Self.height,
                                      Self.width, Self.height, index))
            } else {
                // Bumpers deliberately use fit, with black padding: no
                // content (including text baked into the video) is cropped.
                let targetHeight = placement.isWide ? Self.slotHeight : Self.height
                filters.append(String(format: "%@%@," +
                                      "scale=%d:%d:force_original_aspect_ratio=decrease," +
                                      "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black," +
                                      "setsar=1,fps=30[v%d]",
                                      sourceStream, pts, Self.width, targetHeight,
                                      Self.width, targetHeight, index))
            }
        }

        // Fixed stays ride the already-framed 30 fps screen clock. Every
        // branch has produced a picture, but no area mask or stack has run.
        for (index, placement) in ordered.enumerated() where placement.screenStay != nil {
            guard let marks = placement.telestrationOverlay, !marks.isEmpty,
                  let size = placement.telestrationSize else { continue }
            let label = placement.freeCrops?.isEmpty == false ? "v\(index)_0" : "v\(index)"
            let raw = "\(label)_before_stay"
            for position in filters.indices {
                filters[position] = filters[position].replacingOccurrences(of: "[\(label)]", with: "[\(raw)]")
            }
            let flashed = StrikeImpactRender.flash(placement.flashIn, speed: 1, hold: false)
            let drawn = flashed == nil ? label : "\(label)_before_flash"
            filters += try StrikeHighlightBurn.inGraph(marks, size: size, input: "[\(raw)]", tag: drawn)
            if let flashed { filters.append("[\(drawn)]\(flashed)[\(label)]") }
        }

        // All placement branches have produced their labels. Rewrite only
        // those producers, before any mask or fade can consume the result.
        for (index, placement) in ordered.enumerated() where !placement.bumper {
            guard let effect = placement.effectiveEffect else { continue }
            try EffectCatalog.validate(effect)
            guard EffectCatalog.isAvailable(effect.preset) else {
                throw BuilderCommandFailure.invalid("Effect unavailable in ffmpeg: \(effect.preset).")
            }
            if let crops = Self.normalizedFreeCrops(placement.freeCrops), !crops.isEmpty {
                for (cropIndex, crop) in crops.enumerated() {
                    Self.insertEffect(effect, label: "v\(index)_\(cropIndex)",
                        width: max(2, Int((Double(Self.width) * crop.dw).rounded())),
                        height: max(2, Int((Double(Self.height) * crop.dh).rounded())), filters: &filters)
                }
            } else {
                let slot = placement.isWide && placement.cropXFrac == nil
                    && !placement.fillCanvas && placement.staticAreaFilter == nil && placement.framingPlan == nil
                Self.insertEffect(effect, label: "v\(index)", width: Self.width,
                                  height: slot ? Self.slotHeight : Self.height, filters: &filters)
            }
        }

        // Screen crops: the mask's gray level becomes the clip's alpha, so
        // the overlay chain composites only the named area.
        for (index, inputIndex) in maskInputs {
            // alphamerge needs identical sizes: a wide clip that isn't
            // cropped sits in the 1080×640 slot, not the full frame.
            let placement = ordered[index]
            let maskHeight = placement.isWide && placement.cropXFrac == nil && placement.framingPlan == nil ? Self.slotHeight : Self.height
            filters.append("[\(inputIndex):v]format=gray,scale=\(Self.width):\(maskHeight)[mk\(index)]")
            filters.append("[v\(index)][mk\(index)]alphamerge[vm\(index)]")
        }

        // Overlay chain — bottom layer first.
        var overlaySteps: [(label: String, x: Int, y: Int)] = []
        var stepIsCutaway: [Bool] = []
        for (index, placement) in ordered.enumerated() {
            if let outs = freeCropOutputs[index] {
                overlaySteps.append(contentsOf: outs)
                stepIsCutaway += Array(repeating: placement.role == .cutaway, count: outs.count)
                continue
            }
            let wideCropped = placement.isWide && placement.cropXFrac != nil
            let y = (placement.isWide && !wideCropped && placement.framingPlan == nil)
                ? (Self.slotY[placement.position] ?? 0) : 0
            // A masked slot-band clip still lands in its band; the mask is
            // full-frame, so it's shifted by the band's offset.
            // Dissolves come after the mask, which is what creates alpha.
            let fade = Self.fadeFilters(for: placement, index: index,
                                        masked: maskInputs[index] != nil)
            filters.append(contentsOf: fade.filters)
            overlaySteps.append((fade.label, 0, y))
            stepIsCutaway.append(placement.role == .cutaway)
        }
        // Brand layers: their own stage on the footage, below captions, name
        // tags and overlays; below cutaways for the full Wizard. Their PNG
        // inputs follow every other image input (see the burn-ins below).
        let brandFirstInput = 2 + ordered.count + captions.count + maskInputs.count + fitInputs.count
            + overlays.count + burnIns.count
        var chainSteps: [(label: String, x: Int, y: Int, enable: String?)] = overlaySteps.map { ($0.label, $0.x, $0.y, nil) }
        if !brandLayers.isEmpty {
            let brandSteps: [(label: String, x: Int, y: Int, enable: String?)] = brandLayers.enumerated().map { offset, layer in
                ("\(brandFirstInput + offset):v", layer.x, layer.y,
                 String(format: "enable='gte(t,%.3f)*lt(t,%.3f)'", layer.start, layer.end))
            }
            let at = Self.brandInsertionIndex(stepIsCutaway: stepIsCutaway, underCutaways: brandUnderCutaways)
            chainSteps.insert(contentsOf: brandSteps, at: at)
        }
        var previous = "[0:v]"
        for (stepIndex, step) in chainSteps.enumerated() {
            let isLast = stepIndex == chainSteps.count - 1 && captions.isEmpty && overlays.isEmpty
            let outLabel = isLast ? "[vout]" : "[ov\(stepIndex)]"
            let options = step.enable.map { ":" + $0 } ?? ""
            filters.append("\(previous)[\(step.label)]overlay=x=\(step.x):y=\(step.y):shortest=0\(options)\(outLabel)")
            previous = outLabel
        }

        // Caption overlays chain onto the composited frame (single-frame PNG
        // inputs persist via repeatlast, gated by their enable windows).
        let captionBase = 2 + ordered.count
        for (capIndex, caption) in captions.enumerated() {
            let outLabel = capIndex == captions.count - 1 && overlays.isEmpty ? "[vout]" : "[cap\(capIndex)]"
            filters.append("\(previous)[\(captionBase + capIndex):v]overlay=x=\(caption.x):y=\(caption.y):" +
                           String(format: "enable='gte(t,%.3f)*lt(t,%.3f)'", caption.start, caption.end) + outLabel)
            previous = outLabel
        }

        for input in fitInputs { arguments += ["-threads", "1", "-loop", "1", "-i", input.path] }
        if !overlays.isEmpty {
            previous = Self.appendOverlayFilters(overlays, firstInput: 2 + ordered.count + captions.count + maskInputs.count + fitInputs.count,
                previous: previous, arguments: &arguments, filters: &filters)
            filters.append("\(previous)null[vout]")
        }

        if chainSteps.isEmpty && captions.isEmpty && overlays.isEmpty {
            filters.append("[0:v]null[vout]")
        }
        // extractClip graded the already composited document (including its
        // text/images and black canvas), then drew the extraction burn-ins.
        if let effect = compositeEffect {
            try EffectCatalog.validate(effect)
            guard EffectCatalog.isAvailable(effect.preset) else {
                throw BuilderCommandFailure.invalid("Effect unavailable in ffmpeg: \(effect.preset).")
            }
            Self.insertEffect(effect, label: "vout", width: Self.width, height: Self.height, filters: &filters)
        }
        if !burnIns.isEmpty {
            filters = filters.map { $0.replacingOccurrences(of: "[vout]", with: "[beforeburn]") }
            let firstInput = 2 + ordered.count + captions.count + maskInputs.count + fitInputs.count + overlays.count
            for overlay in burnIns {
                arguments += ["-threads", "1"]
                if overlay.animation != nil { arguments += ["-loop", "1", "-t", String(format: "%.6f", duration)] }
                arguments += ["-i", overlay.png.path]
            }
            RenderBurnIns.append(burnIns, duration: burnInDuration, offset: timelineOffset,
                firstInput: firstInput, previous: "[beforeburn]", output: "[vout]", filters: &filters)
        }
        for layer in brandLayers { arguments += ["-threads", "1", "-i", layer.png.path] }

        // Audio: mix unmuted clips that actually carry audio. With muteSource,
        // the empty mix maps input 1's duration-bounded 44.1 kHz stereo silence,
        // matching FFmpeg.audioEncodeArgs and keeping concat/xfade compatible.
        var audioLabels: [String] = []
        var contributing: [Placement] = []
        for (index, placement) in ordered.enumerated() {
            guard !muteSource, !placement.muted else { continue }
            let audioPath = placement.framingProgramAudio?.path ?? placement.sourcePath
            guard await FFmpeg.hasAudioStream(URL(fileURLWithPath: audioPath)) else { continue }
            var audioInput = index + 2
            if let program = placement.framingProgramAudio {
                audioInput = arguments.filter { $0 == "-i" }.count
                arguments += ["-ss", String(format: "%.6f", program.start),
                              "-t", String(format: "%.6f", placement.sourceDur), "-i", program.path]
            }
            contributing.append(placement)
            let tempo = StrikeImpactRender.audioTempo(speed: placement.speed)
            // Bumpers and mixed-in cutaways honour the volume slider; a
            // muted cutaway never gets here (it resolves to muted).
            let gain = Self.audioGainFilter(for: placement)
            filters.append("[\(audioInput):a]\(tempo)\(gain)asetpts=PTS-STARTPTS[a\(index)]")
            audioLabels.append("[a\(index)]")
        }
        let mix = Self.audioMixFilter(labels: audioLabels, cutawayAudio: Self.mixNeedsUnityGain(contributing),
                                      duration: duration)
        filters.append(contentsOf: mix.filters)

        let graph = output.deletingPathExtension().appendingPathExtension("filters")
        try filters.joined(separator: ";").write(to: graph, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: graph) }
        try await FFmpeg.run(arguments + [
            "-/filter_complex", graph.path,
            "-map", "[vout]",
            "-t", String(format: "%.3f", duration),
        ] + ["-map", mix.source] + FFmpeg.encodeArgs + [output.path],
            timeout: 600, capture: .boundedStderrTail(), purpose: "segment compositor")
    }

    private nonisolated struct NormalizedCrop {
        var sx: Double, sy: Double, sw: Double, sh: Double
        var dx: Double, dy: Double, dw: Double, dh: Double
        var z: Int
    }

    /// Clamp free-crop rectangles into the unit square, dropping degenerates
    /// (same guards as the Python renderer).
    private nonisolated static func normalizedFreeCrops(_ crops: [FreeCrop]?) -> [NormalizedCrop]? {
        guard let crops, !crops.isEmpty else { return nil }
        var normalized: [NormalizedCrop] = []
        for crop in crops {
            var sw = max(0.001, min(1, crop.src.wFrac))
            var sh = max(0.001, min(1, crop.src.hFrac))
            let sx = max(0, min(1, crop.src.xFrac))
            let sy = max(0, min(1, crop.src.yFrac))
            var dw = max(0.001, min(1, crop.dst.wFrac))
            var dh = max(0.001, min(1, crop.dst.hFrac))
            let dx = max(0, min(1, crop.dst.xFrac))
            let dy = max(0, min(1, crop.dst.yFrac))
            if sx + sw > 1 { sw = 1 - sx }
            if sy + sh > 1 { sh = 1 - sy }
            if dx + dw > 1 { dw = 1 - dx }
            if dy + dh > 1 { dh = 1 - dy }
            normalized.append(NormalizedCrop(sx: sx, sy: sy, sw: sw, sh: sh,
                                             dx: dx, dy: dy, dw: dw, dh: dh, z: crop.z))
        }
        return normalized
    }

    /// Port of video.py build_music_track(): concat per-block trimmed music
    /// (volume = level/5 × 0.7) and silence gaps, 2s fade-out at the end.
    private func buildMusicTrack(segments: [(start: Double, duration: Double, music: URL?, volume: Int, offset: Double)],
                                 totalDuration: Double, output: URL) async throws {
        var arguments = ["-y"]
        var filters: [String] = []
        var index = 0
        for segment in segments where segment.duration > 0 {
            let musicVolume = Double(segment.volume) / 5.0 * 0.7
            if let music = segment.music, musicVolume > 0 {
                arguments += ["-stream_loop", "-1", "-i", music.path]
                filters.append(String(format: "[%d:a]atrim=%.3f:%.3f,asetpts=PTS-STARTPTS,volume=%.3f[s%d]",
                                      index, segment.offset, segment.offset + segment.duration, musicVolume, index))
            } else {
                arguments += ["-f", "lavfi", "-i",
                              String(format: "anullsrc=r=44100:cl=stereo:d=%.3f", segment.duration)]
                filters.append(String(format: "[%d:a]atrim=0:%.3f,asetpts=PTS-STARTPTS[s%d]",
                                      index, segment.duration, index))
            }
            index += 1
        }
        guard index > 0 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "No music segments"])
        }
        if index == 1 {
            filters.append("[s0]asetpts=PTS-STARTPTS[aout]")
        } else {
            let joined = (0..<index).map { "[s\($0)]" }.joined()
            filters.append("\(joined)concat=n=\(index):v=0:a=1[aout]")
        }
        filters.append(String(format: "[aout]afade=t=out:st=%.2f:d=2.0[final]",
                              max(0, totalDuration - 2)))
        try await FFmpeg.run(arguments + [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[final]",
            "-c:a", "aac", "-b:a", "192k", output.path,
        ], timeout: 600, capture: .boundedStderrTail(), purpose: "music bed with silence and fades")
    }

    /// Port of video.py overlay_music_track(): duck the original audio per
    /// block (1 − level/5) and mix the pre-built music bed under it.
    private func overlayMusicTrack(video: URL, musicTrack: URL,
                                   segments: [(start: Double, duration: Double, music: URL?, volume: Int, offset: Double)],
                                   output: URL) async throws {
        if await FFmpeg.hasAudioStream(video) {
            let parts = segments.map { segment in
                String(format: "between(t\\,%.3f\\,%.3f)*%.3f",
                       segment.start, segment.start + segment.duration,
                       1.0 - Double(segment.volume) / 5.0)
            }
            let expression = parts.isEmpty ? "1.0" : parts.joined(separator: "+")
            try await FFmpeg.run(["-y", "-i", video.path, "-i", musicTrack.path,
                                  "-filter_complex",
                                  "[0:a]volume='\(expression)':eval=frame[orig];" +
                                  "[orig][1:a]amix=inputs=2:duration=first:dropout_transition=2[aout]",
                                  "-map", "0:v", "-map", "[aout]",
                                  "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                                  "-shortest", "-movflags", "+faststart", output.path], timeout: 600, capture: .boundedStderrTail(), purpose: "music mix; video stream copy")
        } else {
            try await FFmpeg.run(["-y", "-i", video.path, "-i", musicTrack.path,
                                  "-map", "0:v", "-map", "1:a",
                                  "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                                  "-shortest", "-movflags", "+faststart", output.path], timeout: 600, capture: .boundedStderrTail(), purpose: "music mix; video stream copy")
        }
    }

    /// A raster overlay with its window and transitions. Static overlays are
    /// full-frame; tracked stickers carry expressions for their smaller raster.
    nonisolated struct TimedOverlayPNG: Codable, Sendable {
        var png: URL
        var startTime: Double
        var endTime: Double
        var transIn: String
        var transOut: String
        var identity: String?
        var xExpr: String?
        var yExpr: String?
        var track: [ImageTrackKey]?

        nonisolated func positioned() -> Self {
            var result = self
            if let track, !track.isEmpty {
                result.xExpr = "W*(\(ImageTracker.expression(track, axis: \.xFrac)))-w/2"
                result.yExpr = "H*(\(ImageTracker.expression(track, axis: \.yFrac)))-h/2"
            }
            return result
        }

        nonisolated mutating func remapTrack(using clock: RenderClock) {
            if let track {
                // Crossfades can map neighbouring timeline keys out of order.
                // Sort on the output clock; at a collision the later source key wins.
                var mapped: [(index: Int, key: ImageTrackKey)] = []
                for (index, original) in track.enumerated() {
                    var key = original
                    key.time = clock.map(key.time)
                    mapped.append((index: index, key: key))
                }
                mapped.sort { a, b in
                    if a.key.time == b.key.time { return a.index < b.index }
                    return a.key.time < b.key.time
                }
                var keys: [ImageTrackKey] = []
                for (_, key) in mapped {
                    if keys.last?.time == key.time { keys[keys.count - 1] = key }
                    else { keys.append(key) }
                }
                self.track = keys
                self = positioned()
            }
        }

        nonisolated mutating func shiftTrack(by offset: Double) {
            track = track?.map { key in
                var key = key
                key.time += offset
                return key
            }
            self = positioned()
        }
    }

    nonisolated struct OverlayPlan {
        var bySegment: [Int: [TimedOverlayPNG]] = [:]
        var remaining: [TimedOverlayPNG] = []
    }

    /// Conservatively fuse before the first transition. Crossfades can shorten
    /// all subsequent timeline positions (and can fall back to hard cuts), so
    /// those overlays retain their original absolute clock in the final pass.
    nonisolated static func partitionOverlays(_ overlays: [TimedOverlayPNG], segments: [Segment]) -> OverlayPlan {
        var plan = OverlayPlan()
        for overlay in overlays {
            // An intersecting overlay stays in the final pass, where its
            // visible windows are split around every bumper (including black
            // placeholders for missing mid-roll files).
            if segments.contains(where: { segment in
                segment.clips.contains(where: \.bumper) && overlay.startTime < segment.end && overlay.endTime > segment.start
            }) {
                plan.remaining.append(overlay)
                continue
            }
            var elapsed = 0.0
            var destination: Int?
            for (index, segment) in segments.enumerated() {
                if index > 0, segment.clips.first?.transIn != nil { break }
                guard abs(elapsed - segment.start) < 0.001 else { break }
                elapsed += segment.duration
                var safeEnd = segment.end
                if index + 1 < segments.count, let transition = segments[index + 1].clips.first?.transIn {
                    // xfade consumes at most 40% of either adjacent clip;
                    // recipe bridges consume their explicit tail piece.
                    let tail = TransitionRecipes.isRecipe(transition) ? TransitionRecipes.pieces(for: transition).0 : 0
                    safeEnd -= max(segment.duration * 0.4, tail)
                }
                if !segment.clips.isEmpty, !segment.clips.contains(where: \.bumper), overlay.startTime >= segment.start,
                   overlay.endTime < safeEnd || (index == segments.count - 1 && overlay.endTime <= safeEnd) {
                    destination = index
                    break
                }
            }
            // Images precede text. A lower layer left for the final pass must
            // not suddenly cover a higher overlapping layer fused below it.
            let overlapsRetained = plan.remaining.contains {
                $0.startTime <= overlay.endTime && overlay.startTime <= $0.endTime
            }
            if let index = destination, !overlapsRetained {
                var local = overlay
                local.shiftTrack(by: -segments[index].start)
                local.startTime -= segments[index].start
                local.endTime -= segments[index].start
                plan.bySegment[index, default: []].append(local)
            } else {
                plan.remaining.append(overlay)
            }
        }
        return plan
    }

    /// Entry and exit animation length, capped at a third of the overlay.
    nonisolated static let overlayAnimationDuration = 0.4

    /// xfade transitions that combine the two clips pixel by pixel in place
    /// (blends, dissolves, wipes and mask reveals): an overlay burned into
    /// both clips at the same absolute time survives them unchanged.
    /// Transitions that move, scale, crop or dip the picture (slides, covers,
    /// reveals, zoom, circle crop, pixelize, flashes) and recipes keep the
    /// final pass. Hard cuts trivially qualify.
    nonisolated static func transitionKeepsOverlayPixels(_ name: String?) -> Bool {
        guard let name, name != "cut" else { return true }
        return Self.inPlaceTransitions.contains(name)
    }

    private nonisolated static let inPlaceTransitions: Set<String> = [
        "fade", "dissolve", "wipeleft", "wiperight", "wipeup", "wipedown",
        "circleopen", "circleclose", "radial", "smoothleft", "smoothright", "diagtl", "diagbr",
        "horzopen", "horzclose", "vertopen", "vertclose", "hlslice", "hrslice",
    ]

    /// Every remaining overlay burned into each segment it touches, on the
    /// segment's own clock: an overlay that started earlier keeps a negative
    /// start, so its entry animation is already over, and one that ends later
    /// stays enabled to the segment's end. Spanning overlays follow the
    /// segment-local ones so the final-pass stacking (spanning on top) holds.
    /// Nil when an overlay touches a gap or bumper segment, which only the
    /// final pass can window correctly.
    nonisolated static func fuseSpanningOverlays(_ plan: OverlayPlan, segments: [Segment]) -> OverlayPlan? {
        var fused = plan
        for overlay in plan.remaining {
            let anim = min(overlayAnimationDuration, (overlay.endTime - overlay.startTime) / 3)
            let fadesIn = overlay.transIn == "fade" || overlay.transIn == "pop"
            let fadesOut = overlay.transOut == "fade" || overlay.transOut == "pop"
            for (index, segment) in segments.enumerated()
            where overlay.startTime < segment.end && overlay.endTime > segment.start {
                guard !segment.clips.isEmpty, !segment.clips.allSatisfy(\.missingBumper),
                      !segment.clips.contains(where: \.bumper) else { return nil }
                var local = overlay
                local.shiftTrack(by: -segment.start)
                local.startTime -= segment.start
                local.endTime -= segment.start
                // ffmpeg's fade cannot begin before the segment's first frame,
                // so a fade that is half over at a cut keeps the final pass.
                let entryStraddles = fadesIn && local.startTime < 0 && local.startTime + anim > 0
                let exitStraddles = fadesOut && local.endTime - anim < 0 && local.endTime > 0
                if entryStraddles || exitStraddles { return nil }
                fused.bySegment[index, default: []].append(local)
            }
        }
        fused.remaining = []
        return fused
    }

    /// Half-open visibility windows prevent an overlay from leaking onto
    /// the first bumper frame. Keep animations only at the original edges.
    nonisolated static func overlayWindows(_ overlays: [TimedOverlayPNG],
                                           excluding spans: [Range<Double>]) -> [TimedOverlayPNG] {
        overlays.flatMap { overlay in
            var windows = [overlay]
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                windows = windows.flatMap { item -> [TimedOverlayPNG] in
                    guard item.startTime < span.upperBound, item.endTime > span.lowerBound else { return [item] }
                    var result: [TimedOverlayPNG] = []
                    if item.startTime < span.lowerBound {
                        var head = item
                        head.endTime = span.lowerBound
                        head.transOut = "none"
                        result.append(head)
                    }
                    if item.endTime > span.upperBound {
                        var tail = item
                        tail.startTime = span.upperBound
                        tail.transIn = "none"
                        result.append(tail)
                    }
                    return result
                }
            }
            return windows
        }
    }

    /// Port of video.py add_multiple_text_overlays(): loop each pre-rendered
    /// full-frame PNG as an input and composite with fade/slide expressions
    /// inside its enable window.
    private func addOverlays(video: URL, overlays: [TimedOverlayPNG],
                             excluding bumperSpans: [Range<Double>] = [], output: URL) async throws {
        let overlays = Self.overlayWindows(overlays, excluding: bumperSpans)
        let timing = PerfSignpost.begin("OverlayBurn", metadata: "overlays=\(overlays.count)")
        defer { PerfSignpost.end(timing) }
        let videoDuration = await FFmpeg.duration(of: video)
        var arguments = ["-y"] + (await FFmpeg.intermediateDecodeArguments(for: video)) + ["-i", video.path]
        var filters: [String] = []
        let previous = Self.appendOverlayFilters(overlays, firstInput: 1, previous: "[0:v]",
                                                 arguments: &arguments, filters: &filters)

        guard !filters.isEmpty else {
            try FileManager.default.copyItemReplacing(at: video, to: output)
            return
        }
        // Overlay inputs can outlast the video; cap the output to the
        // measured length. A failed probe reports 0 — leave the length
        // alone rather than emit an empty file.
        let lengthCap: [String] = videoDuration > 0
            ? ["-t", String(format: "%.3f", videoDuration)] : []
        try await FFmpeg.run(arguments + [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", previous, "-map", "0:a?",
        ] + FFmpeg.videoEncodeArgs + [
            "-c:a", "copy", "-pix_fmt", "yuv420p",
        ] + lengthCap + [
            "-movflags", "+faststart", output.path,
        ], timeout: 900, capture: .boundedStderrTail(), purpose: "final overlay burn")
    }

    /// Durations and identities of the hard-cut assembly groups, or nil when
    /// any group is not made of digested segments.
    private nonisolated static func identifyGroups(_ groups: [RenderEngine.AssemblyGroup], digestByPath: [URL: String],
                                                   transitionDuration: Double) async -> [RenderFinishingRanges.Group]? {
        guard let durations = try? await BoundedConcurrency.map(groups, limit: FFmpeg.jobLimit, { _, group in
            await FFmpeg.duration(of: group.output)
        }) else { return nil }
        var identified: [RenderFinishingRanges.Group] = []
        for (group, duration) in zip(groups, durations) {
            let digests = group.clips.compactMap { digestByPath[$0] }
            guard digests.count == group.clips.count,
                  let identity = try? RenderFinishingRanges.groupIdentity(
                    segmentDigests: digests, transitions: group.transitions,
                    transitionDuration: transitionDuration) else { return nil }
            identified.append(RenderFinishingRanges.Group(duration: duration, identity: identity))
        }
        return identified
    }

    /// The full-timeline burn as cached ranges: restore every range whose
    /// assembly groups, neighbors and rasters are unchanged, encode only the
    /// missing ranges from a seeked read of the assembled video, then join
    /// them with the assembled audio by stream copy. Returns nil when the
    /// output is not eligible (fewer than two ranges or an unexpected clock);
    /// throws when an encode or the join fails so the caller can fall back.
    private func addOverlaysByRange(video: URL, videoDuration: Double, overlays: [TimedOverlayPNG],
                                    groups: [RenderFinishingRanges.Group], scratch: URL, output: URL,
                                    emit: @escaping @Sendable (String) -> Void) async throws
        -> [RenderSegmentCache.Entry]? {
        guard groups.count >= 2, videoDuration > 0,
              let clock = await FFmpeg.videoClock(of: video),
              clock.frameRate == RenderFinishingRanges.frameRateLabel else { return nil }
        // The full pass caps its output at the probed length to three decimals.
        let limit = Double(String(format: "%.3f", videoDuration)) ?? videoDuration
        var parts = try RenderFinishingRanges.plan(durations: groups.map(\.duration),
            target: RenderFinishingRanges.targetLength(totalDuration: videoDuration))
        guard parts.count >= 2 else { return nil }
        RenderFinishingRanges.clock(&parts, startTime: clock.startTime, limit: limit)
        let overlayIdentities = try RenderFinishingKey.overlayIdentities(overlays)
        let encoder = FFmpeg.encodeArgs + FFmpeg.intermediateCacheIdentity
        let videoEncoder = FFmpeg.videoEncodeArgs
        let settings = RenderContext.settings
        let keys = try parts.map {
            try RenderFinishingRanges.key(part: $0, groups: groups, overlays: overlayIdentities,
                                          settings: settings, encoder: encoder)
        }
        let timing = PerfSignpost.begin("OverlayBurnRanges", metadata: "ranges=\(parts.count)")
        defer { PerfSignpost.end(timing) }
        let cache = segmentCache
        let indexed = Array(zip(parts, keys).enumerated())
        // Each range process holds the decoded video plus every raster's
        // RGBA frames; the shared hardware encoder gains little beyond two
        // workers, so two bounds first-edit memory near a single full pass.
        let ranges = try await BoundedConcurrency.map(indexed, limit: min(2, FFmpeg.jobLimit)) {
            _, item -> (file: URL, entry: RenderSegmentCache.Entry?) in
            let (index, (part, key)) = item
            let file = scratch.appendingPathComponent("range-\(index).mp4")
            if await cache.restore(key: key, to: file) {
                PerfSignpost.event("FinishingRangeHit", metadata: "range=\(index)")
                return (file: file, entry: RenderSegmentCache.Entry?.none)
            }
            try Task.checkCancellation()
            var arguments = await FFmpeg.intermediateDecodeArguments(for: video)
            arguments += RenderFinishingRanges.inputArguments(video: video, part: part)
            var filters: [String] = []
            let previous = Self.appendOverlayFilters(overlays, firstInput: 1, previous: "[0:v]",
                                                     arguments: &arguments, filters: &filters,
                                                     inputSeek: RenderFinishingRanges.seekArguments(part))
            filters.append(RenderFinishingRanges.rangeFilter(previous: previous, part: part))
            try await FFmpeg.run(arguments + ["-filter_complex", filters.joined(separator: ";")]
                + RenderFinishingRanges.outputArguments(part: part, encoder: videoEncoder, output: file),
                timeout: 900, capture: .boundedStderrTail(), purpose: "overlay finishing range \(index + 1)")
            return (file: file, entry: RenderSegmentCache.Entry(key: key, source: file))
        }
        try Task.checkCancellation()
        let listing = scratch.appendingPathComponent("ranges.txt")
        try RenderFinishingRanges.concatListing(ranges.map(\.file))
            .write(to: listing, atomically: true, encoding: .utf8)
        try await FFmpeg.run(RenderFinishingRanges.joinArguments(listing: listing, audio: video,
            firstClockStart: parts[0].clockStart, output: output), timeout: 600,
            capture: .boundedStderrTail(), purpose: "overlay ranges: stream-copy join")
        let entries = ranges.compactMap(\.entry)
        emit("Finishing ranges: hits=\(ranges.count - entries.count) encodes=\(entries.count)")
        return entries
    }

    /// Both segment and full-timeline burns use the identical animation graph.
    /// Wizard extractClip has a whole-clip animation API; Builder's independent
    /// entry/exit windows must remain intact here.
    private nonisolated static func appendOverlayFilters(_ overlays: [TimedOverlayPNG], firstInput: Int,
        previous: String, arguments: inout [String], filters: inout [String], inputSeek: [String] = []) -> String {
        var previous = previous
        var inputIndex = firstInput - 1
        let animDuration = overlayAnimationDuration

        for (index, overlay) in overlays.enumerated() {
            let pngURL = overlay.png
            inputIndex += 1
            let start = overlay.startTime
            let end = overlay.endTime
            let duration = end - start
            let anim = min(animDuration, duration / 3)
            // The looped PNG's own clock starts at 0 like the main video's,
            // so it must run through `end` (not just the overlay's length)
            // and its fades are stamped in absolute time — otherwise a
            // faded overlay that starts after t=0 has already faded to
            // transparent by the time `enable` lets it through.
            arguments += inputSeek + ["-loop", "1", "-t", String(format: "%.2f", end + 1), "-i", pngURL.path]

            var current = "[\(inputIndex):v]"
            let fadeIn = overlay.transIn == "fade" || overlay.transIn == "pop"
            let fadeOut = overlay.transOut == "fade" || overlay.transOut == "pop"
            // A fused overlay that began before this segment keeps a negative
            // start: an entry fade already over is simply not applied (the
            // raster is opaque), and `fuseSpanningOverlays` never lets a fade
            // straddle the segment start, since `fade` cannot start before 0.
            let entryFadeOver = start + anim <= 0
            let exitFadeOver = end - anim < 0 && end <= 0
            if (fadeIn && !entryFadeOver) || (fadeOut && !exitFadeOver) {
                var fadeParts = ["format=rgba"]
                if fadeIn, !entryFadeOver {
                    fadeParts.append(String(format: "fade=t=in:st=%.3f:d=%.3f:alpha=1", max(0, start), anim))
                }
                if fadeOut, !exitFadeOver {
                    fadeParts.append(String(format: "fade=t=out:st=%.3f:d=%.3f:alpha=1", max(0, end - anim), anim))
                }
                let label = "[tf\(index)]"
                filters.append("\(current)\(fadeParts.joined(separator: ","))\(label)")
                current = label
            }

            let outLabel = "[txt\(index)]"
            let slideIn = overlay.transIn.hasPrefix("slide_") || overlay.transIn == "pop"
            let slideOut = overlay.transOut.hasPrefix("slide_") || overlay.transOut == "pop"
            if slideIn || slideOut {
                let enterX = slideIn ? Self.slideExpression(overlay.transIn, axis: "x", at: start, anim: anim, entering: true) : "0"
                let enterY = slideIn ? Self.slideExpression(overlay.transIn, axis: "y", at: start, anim: anim, entering: true) : "0"
                let exitX = slideOut ? Self.slideExpression(overlay.transOut, axis: "x", at: end, anim: anim, entering: false) : "0"
                let exitY = slideOut ? Self.slideExpression(overlay.transOut, axis: "y", at: end, anim: anim, entering: false) : "0"
                var xExpr = String(format: "if(lt(t,%.3f),%@,if(gt(t,%.3f),%@,0))",
                                   start + anim, enterX, end - anim, exitX)
                var yExpr = String(format: "if(lt(t,%.3f),%@,if(gt(t,%.3f),%@,0))",
                                   start + anim, enterY, end - anim, exitY)
                if enterX == "0" && exitX == "0" { xExpr = "0" }
                if enterY == "0" && exitY == "0" { yExpr = "0" }
                xExpr = "(\(overlay.xExpr ?? "0"))+(\(xExpr))"
                yExpr = "(\(overlay.yExpr ?? "0"))+(\(yExpr))"
                filters.append("\(previous)\(current)overlay=x='\(xExpr)':y='\(yExpr)':" +
                               String(format: "enable='gte(t,%.3f)*lt(t,%.3f)'", start, end) + outLabel)
            } else {
                filters.append("\(previous)\(current)overlay=x='\(overlay.xExpr ?? "0")':y='\(overlay.yExpr ?? "0")':" +
                               String(format: "enable='gte(t,%.3f)*lt(t,%.3f)':shortest=0", start, end) + outLabel)
            }
            previous = outLabel
        }

        return previous
    }

    /// Slide enter/exit x/y expressions (video.py _slide_enter/_slide_exit).
    private nonisolated static func slideExpression(_ transition: String, axis: String,
                                                    at time: Double, anim: Double,
                                                    entering: Bool) -> String {
        let direction = transition.split(separator: "_").last.map(String.init) ?? ""
        if entering {
            switch (axis, direction) {
            case ("x", "left"): return String(format: "if(lt(t-%.3f,%.3f),W-W*(t-%.3f)/%.3f,0)", time, anim, time, anim)
            case ("x", "right"): return String(format: "if(lt(t-%.3f,%.3f),-W+W*(t-%.3f)/%.3f,0)", time, anim, time, anim)
            case ("y", "up"): return String(format: "if(lt(t-%.3f,%.3f),H-H*(t-%.3f)/%.3f,0)", time, anim, time, anim)
            case ("y", "down"): return String(format: "if(lt(t-%.3f,%.3f),-H+H*(t-%.3f)/%.3f,0)", time, anim, time, anim)
            // Rise-settle from 5% below with a cubic ease-out.
            case ("y", "pop"): return String(format: "if(lt(t-%.3f,%.3f),round(H*0.05*pow(1-(t-%.3f)/%.3f,3)),0)", time, anim, time, anim)
            default: return "0"
            }
        } else {
            let exitStart = time - anim
            switch (axis, direction) {
            case ("x", "left"): return String(format: "if(gt(t,%.3f),-W*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("x", "right"): return String(format: "if(gt(t,%.3f),W*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("y", "up"): return String(format: "if(gt(t,%.3f),-H*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("y", "down"): return String(format: "if(gt(t,%.3f),H*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("y", "pop"): return String(format: "if(gt(t,%.3f),round(H*0.05*pow((t-%.3f)/%.3f,3)),0)", exitStart, exitStart, anim)
            default: return "0"
            }
        }
    }

    // MARK: - Output naming

    /// <output>/<YYYY-MM-DD>/hl-<duration>-<n>.mp4, sharing the per-day
    /// counter with the Python builder (it scans every mp4's trailing number).
    private nonisolated static func outputFile(profile: BrandProfile,
                                               totalDuration: Double,
                                               baseName: String? = nil) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = profile.outputFolderURL
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let baseName {
            return Self.uniqueFile(named: baseName, in: directory)
        }

        var counter = 1
        let existing = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        for file in existing where file.pathExtension.lowercased() == "mp4" {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-")
            if parts.count >= 3, let value = Int(parts[parts.count - 1]), value >= counter {
                counter = value + 1
            }
        }
        return directory.appendingPathComponent("hl-\(Int(totalDuration))-\(counter).mp4")
    }

    /// `<name>.mp4`, or `<name> 2.mp4`, `<name> 3.mp4`, … when taken.
    nonisolated static func uniqueFile(named baseName: String, in directory: URL) -> URL {
        let first = directory.appendingPathComponent(baseName + ".mp4")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName) \(counter).mp4")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}

/// Per-pass framing fallback reasons keyed by prepass job, written from the
/// concurrent prepass jobs.
private nonisolated final class FramingFallbackReasons: Sendable {
    private let reasons = Mutex<[String: String]>([:])

    func set(_ key: String, _ reason: String) {
        reasons.withLock { $0[key] = reason }
    }

    func reason(_ key: String) -> String? { reasons.withLock { $0[key] } }
}
