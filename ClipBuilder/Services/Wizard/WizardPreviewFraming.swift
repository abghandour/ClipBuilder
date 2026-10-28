import CoreGraphics
import Foundation

/// Resolves a still from the same feed assignments and source clocks as the timeline.
nonisolated enum WizardPreviewFraming {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Composite-only and handle-only edits must not restart scene planning. Pull-back also
    /// changes interview shot geometry and the fight tracker's crop tuning.
    static func planningFraming(_ framing: Framing, videoType: VideoType?) -> Framing {
        var result = framing
        result.fit = .fill
        result.feather = 0
        result.blur = 0
        result.lockAspect = nil
        let usesPullBack = framing.subject == .speakerFocus || framing.subject == .auto
            || (framing.subject == .vipFocus && (videoType == .fight || videoType == nil))
        if !usesPullBack { result.pullBack = 0 }
        return result
    }

    /// Source-clock window for one still, intersected with its active feed span.
    static func trackingWindow(time: Double, range: ClosedRange<Double>,
                               span: ClosedRange<Double>? = nil) -> ClosedRange<Double> {
        let start = max(range.lowerBound, span?.lowerBound ?? range.lowerBound)
        let end = max(start, min(range.upperBound, span?.upperBound ?? range.upperBound))
        let time = min(end, max(start, time))
        return max(start, time - 2)...min(end, time + 2)
    }

    typealias FocusTracker = @Sendable (URL, FeedPathCache.Identity) async throws -> FeedCameraPath

    static func trackFocus(source: URL, identity: FeedPathCache.Identity) async throws -> FeedCameraPath {
        try await CenterStageService().cameraPath(source: source, start: identity.start,
            duration: identity.duration, region: identity.region, tuning: .named(identity.tuning),
            aspect: identity.aspect, fallbackCenter: identity.focus)
    }

    static func talker(original: Bool, path: SceneCameraPath?, wide: Bool,
                       time: Double, face: CGRect?) -> WizardPreviewComposite.Framing {
        if original { return .original }
        if wide, let keyframe = path?.keyframes.min(by: { abs($0.t - time) < abs($1.t - time) }) {
            return .path(keyframe)
        }
        return .cover(face: face)
    }

    /// `time` is the moment shown; nil means the middle of the record's range.
    static func speaker(video: VideoRecord, record: SceneRecord, turns: [SpeakerTurn],
                        roster: [VideoPersonRecord], people: [PersonRecord],
                        time moment: Double? = nil) -> (person: PersonRecord?, face: CGRect?)? {
        let time = moment ?? (record.startTime + record.endTime) / 2
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        let spans = CropRecipePlanner.segments(turns: turns, tiles: tiles,
            range: record.startTime...record.endTime, hold: 1.5)
        guard let talker = spans.first(where: { $0.start <= time && time < $0.end }),
              let tile = tiles.first(where: { $0.index == talker.talker }) else { return nil }
        let entry = roster.first { $0.key == tile.personKey }
            ?? roster.first { person in
                guard let box = person.portraitBox else { return false }
                return tile.contains(x: box.x + box.w / 2, y: box.y + box.h / 2)
            }
        let person = people.first { !$0.hidden && $0.tagName != nil && $0.key == (entry?.key ?? tile.personKey) }
        let face: CGRect
        if let box = entry?.portraitBox {
            face = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
        } else if let center = tile.faceCenter {
            face = CGRect(x: center.x - 0.025, y: center.y - 0.025, width: 0.05, height: 0.05)
        } else {
            face = CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)
        }
        return (person, face)
    }

    /// Who the preview tag names when the scene has no identified speaker:
    /// a named person from this video's roster first, then any named person,
    /// so the tag shows what the user typed in the people editor instead of a
    /// sample name.
    static func fallbackPerson(roster: [VideoPersonRecord], people: [PersonRecord]) -> PersonRecord? {
        let named = people.filter { !$0.hidden && $0.tagName != nil }
        let rosterKeys = Set(roster.map(\.key))
        return named.first { rosterKeys.contains($0.key) } ?? named.first
    }

    /// `time` is the moment shown, on the source clock; nil means the middle
    /// of the record's range. The plan always covers the whole range, as the
    /// render's does, and the moment picks the keyframe inside it.
    /// `sceneStart` is the scene's own start when `record` carries a kept
    /// range instead: the saved Center Stage path counts from the scene.
    static func resolve(options: WizardOptions, record: SceneRecord, video: VideoRecord?,
                        face: CGRect?, turns: [SpeakerTurn], roster: [VideoPersonRecord],
                        people: [PersonRecord], layouts: [ScreenCropLayout], time moment: Double? = nil,
                        sceneStart: Double? = nil, contentBox: RenderEngine.ContentBox? = nil,
                        sources: [VideoRecord] = [], scenes: [SceneRecord] = [],
                        brollCuts: [PodcastHighlightBRollPlanner.Cut] = [])
        -> (framing: WizardPreviewComposite.Framing, warning: String?) {
        let time = min(record.endTime, max(record.startTime, moment ?? (record.startTime + record.endTime) / 2))
        var context = video.map { FramingContext(video: $0, range: record.startTime...record.endTime,
            canvasAspect: options.renderSettings.aspectRatio, roster: roster, turns: turns,
            storedPath: record.centerStagePath, layouts: layouts, hasBRoll: options.requestsBRollBreaks) }
            ?? FramingContext(scene: record, range: record.startTime...record.endTime,
                canvasAspect: options.renderSettings.aspectRatio)
        context.sources = sources
        context.scenes = scenes
        context.brollCuts = brollCuts
        let resolved = FocusFrame.clipped(FramingPlanner.resolve(framing: options.requestedFraming, context: context), contentBox: contentBox)
        let warning = FramingPlanner.warning(framing: options.requestedFraming, context: context)
        let fallback: WizardPreviewComposite.Framing
        if resolved.isStatic { fallback = .original }
        else if let region = resolved.sourceWindow {
            fallback = .cells([.init(source: FocusFrame.rect(region), area: full)])
        } else if resolved.recipe?.centerStage == true {
            // One full-source cell: the still then tracks everyone (or the VIPs) at this moment.
            fallback = .cells([.init(source: full, area: full)])
        } else {
            fallback = talker(original: false, path: record.centerStagePath,
                wide: record.wide, time: time - (sceneStart ?? record.startTime), face: face)
        }
        do {
            if video == nil, !resolved.isStatic, resolved.recipe?.centerStage != true {
                throw CropRecipePlanner.Failure(description: "The file's frame size is unknown; analyze it first.")
            }
            guard let plan = try FramingPlanner.composition(plan: resolved, context: context) else { return (fallback, warning) }
            return (.cells(cells(plan: plan, layouts: layouts, video: context.video, time: time,
                rangeStart: record.startTime, roster: roster, people: people,
                canvasAspect: options.renderSettings.aspectRatio, focusFrame: resolved.sourceWindow)), warning)
        } catch let failure as CropRecipePlanner.Failure {
            return (fallback, failure.description)
        } catch {
            return (fallback, error.localizedDescription)
        }
    }

    /// Refines a roster's portraits from faces seen in the scene, the way the
    /// render does before it plans Interview focus.
    typealias RosterRefiner = @Sendable (VideoRecord, [VideoPersonRecord], ClosedRange<Double>, [SpeakerTurn], InterviewPunchIn, Bool) async -> [VideoPersonRecord]

    /// Interview focus is the one camera focus whose render plans from faces
    /// sampled in the clip (`InterviewFaceSampling.refinedRoster`) instead of
    /// the roster's stored portraits. A preview planned from the stored
    /// portraits lands its crop and name tags elsewhere, so it refines too.
    static func usesRefinedRoster(options: WizardOptions) -> Bool {
        options.requestedFraming.subject == .speakerFocus
    }

    /// Called from the preview's background task. Focus edits re-plan bounded
    /// tracking on cache misses; ordinary previews keep their cheap still. The
    /// Interview focus face samples (a few frame decodes per scene) are kept
    /// in `InterviewPreviewRosterCache` so revisiting a scene is free.
    static func resolveCached(options: WizardOptions, record: SceneRecord, video: VideoRecord?,
                              face: CGRect?, turns: [SpeakerTurn], roster: [VideoPersonRecord],
                              people: [PersonRecord], layouts: [ScreenCropLayout],
                              cache: FeedPathCache = .shared,
                              refine: RosterRefiner = InterviewPreviewRosterCache.shared.refined,
                              track: FocusTracker = trackFocus,
                              time moment: Double? = nil, sceneStart: Double? = nil,
                              contentBox: RenderEngine.ContentBox? = nil,
                              sources: [VideoRecord] = [], scenes: [SceneRecord] = [],
                              brollCuts: [PodcastHighlightBRollPlanner.Cut] = []) async
        -> (framing: WizardPreviewComposite.Framing, warning: String?) {
        var roster = roster
        if video?.type == .fight, options.requestedFraming.subject == .vipFocus {
            do {
                let path = try await FighterTrackingAdapter.cameraPath(source: record.videoURL, start: record.startTime,
                    duration: record.duration, roster: roster,
                    region: FocusFrame.sourceWindow(options.requestedFraming.focusFrame ?? FreeCropRect(), contentBox: contentBox),
                    pullBack: options.requestedFraming.pullBack, aspect: options.renderSettings.aspectRatio)
                if let key = CenterStageService.interpolated(path, at: (moment ?? (record.startTime + record.endTime) / 2) - record.startTime) {
                    return (.path(key), nil)
                }
            } catch { return (.original, error.localizedDescription) }
        }
        if usesRefinedRoster(options: options), let video {
            roster = await refine(video, roster, record.startTime...record.endTime, turns,
                .talker, options.requestedFraming.moves == .cuts)
            if Task.isCancelled { return (.cover(face: face), nil) }
        }
        let fallback = resolve(options: options, record: record, video: video, face: face,
            turns: turns, roster: roster, people: people, layouts: layouts, time: moment, sceneStart: sceneStart, contentBox: contentBox,
            sources: sources, scenes: scenes, brollCuts: brollCuts)
        let centerStage = options.requestedFraming.subject == .centerStage
        if options.requestedFraming.focusFrame != nil || centerStage, options.requestedFraming.subject != .layout,
           case .cells(var cells) = fallback.framing {
            let focusedPlan = video.flatMap { try? Self.composition(options: options, video: $0, record: record,
                turns: turns, roster: roster, layouts: layouts, contentBox: contentBox) }
            let time = min(record.endTime, max(record.startTime, moment ?? (record.startTime + record.endTime) / 2))
            var warning = fallback.warning
            for index in cells.indices {
                let slot = focusedPlan?.slots[safe: index]
                // Fresh recipe paths already contain the focused shot/move plan.
                if slot?.path?.isEmpty == false { continue }
                let span = slot?.trackingSpans?.first { $0.start <= time - record.startTime && time - record.startTime < $0.end }
                let region = span?.region ?? slot?.region ?? FocusFrame.window(cells[index].source)
                // VIPs-only Center stage: with one VIP the still tracks from that portrait; with
                // several the export frames every matching face, which the balanced everyone
                // camera approximates better than seeding the camera from one of them.
                let vipKeys = options.requestedFraming.vips.map(Set.init)
                let vipBoxes = centerStage && options.requestedFraming.people == .vips
                    ? roster.filter { vipKeys?.contains($0.key) ?? $0.isVIP }.compactMap(\.portraitBox) : []
                let vipFocus = vipBoxes.count == 1
                    ? vipBoxes.first.map { AreaFocus(x: $0.x + $0.w / 2, y: $0.y + $0.h / 2) } : nil
                let focus = span?.focus ?? slot?.focus.map { AreaFocus(x: $0.x, y: $0.y) } ?? vipFocus
                let aspect = options.renderSettings.aspectRatio * cells[index].area.width / cells[index].area.height
                do {
                    let window = trackingWindow(time: time, range: record.startTime...record.endTime,
                        span: span.map { (record.startTime + $0.start)...(record.startTime + $0.end) })
                    let camera = options.requestedFraming.subject == .centerStage ? "balanced" : "conversation"
                    let identity = try FeedPathCache.identity(source: record.videoURL, region: region,
                        start: window.lowerBound, duration: window.upperBound - window.lowerBound,
                        tuning: camera, aspect: aspect, focus: focus)
                    let path: FeedCameraPath
                    let pathStart: Double
                    if let cached = await cache.covering(source: record.videoURL, region: region,
                        start: time, duration: 0, tuning: camera, aspect: aspect, focus: focus) {
                        path = cached.path
                        pathStart = cached.identity.start
                    } else {
                        path = try await track(record.videoURL, identity)
                        pathStart = identity.start
                        try Task.checkCancellation()
                        if path.reusable != false { await cache.store(path, identity: identity) }
                    }
                    if path.trackedShare == 0, path.samples.allSatisfy({ $0.faces.isEmpty }), focus == nil {
                        cells[index].source = FocusFrame.rect(region)
                        warning = FocusFrame.nobodyInside
                    } else if let frame = CenterStageService.interpolated(path.keyframes, at: time - pathStart) {
                        cells[index].source = CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
                    }
                } catch {
                    cells[index].source = FocusFrame.rect(region)
                    if !Task.isCancelled { warning = error.localizedDescription }
                }
            }
            if warning == FocusFrame.nobodyInside, cells.count == 1, cells[0].area == full {
                return (.original, warning)
            }
            return (.cells(cells), warning)
        }
        if options.requestedFraming.subject == .layout, case .cells(var cells) = fallback.framing {
            for index in cells.indices {
                guard let region = cells[index].trackingRegion,
                      let path = cells[index].sourcePath, let time = cells[index].sourceTime else { continue }
                let aspect = options.renderSettings.aspectRatio * cells[index].area.width / cells[index].area.height
                if let cached = await cache.covering(source: URL(fileURLWithPath: path),
                    region: CenterStageService.validRegion(region), start: time, duration: 0,
                    aspect: aspect, focus: cells[index].focus),
                   let key = CenterStageService.interpolated(cached.path.keyframes, at: time - cached.identity.start) {
                    cells[index].source = CGRect(x: key.x, y: key.y, width: key.w, height: key.h)
                }
            }
            return (.cells(cells), fallback.warning)
        }
        guard case .cells(var cells) = fallback.framing, let video,
              let plan = try? composition(options: options, video: video, record: record,
                turns: turns, roster: roster, layouts: layouts) else { return fallback }
        let time = min(record.endTime, max(record.startTime, moment ?? (record.startTime + record.endTime) / 2))
        for index in cells.indices where plan.slots.indices.contains(index) {
            let slot = plan.slots[index]
            let span = slot.trackingSpans?.first { $0.start <= time - record.startTime && time - record.startTime < $0.end }
            guard let region = span?.region ?? slot.region else { continue }
            let focus = span?.focus ?? slot.focus.map { AreaFocus(x: $0.x, y: $0.y) }
            let aspect = options.renderSettings.aspectRatio * cells[index].area.width / cells[index].area.height
            if let cached = await cache.covering(source: record.videoURL,
                region: CenterStageService.validRegion(region), start: time, duration: 0, aspect: aspect, focus: focus),
               let frame = CenterStageService.interpolated(cached.path.keyframes, at: time - cached.identity.start) {
                cells[index].source = CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
            }
        }
        return (.cells(cells), fallback.warning)
    }

    static func composition(options: WizardOptions, video: VideoRecord, record: SceneRecord,
                            turns: [SpeakerTurn], roster: [VideoPersonRecord], layouts: [ScreenCropLayout],
                            contentBox: RenderEngine.ContentBox? = nil) throws -> CropRecipePlanner.Plan? {
        let context = FramingContext(video: video, range: record.startTime...record.endTime,
            canvasAspect: options.renderSettings.aspectRatio, roster: roster, turns: turns,
            storedPath: record.centerStagePath, layouts: layouts, hasBRoll: options.requestsBRollBreaks)
        return try FramingPlanner.composition(plan: FocusFrame.clipped(
            FramingPlanner.resolve(framing: options.requestedFraming, context: context), contentBox: contentBox), context: context)
    }

    /// Only pixels affect the base-frame cache; tag text and talking metadata do not.
    static func pixelFraming(_ framing: WizardPreviewComposite.Framing) -> WizardPreviewComposite.Framing {
        if case .cells(let cells) = framing {
            return .cells(cells.map { cell in
                var cell = cell
                cell.person = nil
                cell.face = nil
                cell.isTalking = false
                return cell
            })
        }
        return framing
    }

    private static func contextTile(segment: AreaSegment, tiles: [PodcastTile]) -> PodcastTile? {
        guard let region = segment.region else { return nil }
        return tiles.first { $0.contains(x: region.xFrac + region.wFrac / 2, y: region.yFrac + region.hFrac / 2) }
    }

    static func cells(plan: CropRecipePlanner.Plan, layouts: [ScreenCropLayout], video: VideoRecord,
                      time: Double, rangeStart: Double, roster: [VideoPersonRecord],
                      people: [PersonRecord], canvasAspect: Double, focusFrame: FreeCropRect? = nil) -> [WizardPreviewComposite.Cell] {
        if let snapshot = plan.snapshot, let segments = plan.areas {
            let offset = time - rangeStart
            return snapshot.areas.compactMap { area in
                guard let segment = segments.last(where: {
                    $0.areaID == area.id && ($0.timelineStart ?? 0) <= offset
                }) else { return nil }
                let window: FreeCropRect
                switch segment.framing {
                case .static(let value): window = value ?? FreeCropRect()
                case .recipe: window = segment.region ?? FreeCropRect()
                }
                let box = area.bounds
                let tile = contextTile(segment: segment, tiles: plan.tiles)
                let person = people.first { !$0.hidden && $0.key == tile?.personKey }
                return WizardPreviewComposite.Cell(source: FocusFrame.rect(window),
                    area: CGRect(x: box.x, y: box.y, width: box.w, height: box.h), person: person,
                    sourcePath: segment.sourcePath,
                    sourceTime: segment.start + max(0, offset - (segment.timelineStart ?? 0)),
                    mask: area, role: area.role, trackingRegion: segment.region, focus: segment.focus)
            }
        }
        let areas = layouts.first { $0.name.caseInsensitiveCompare(plan.layout.name) == .orderedSame }?.areasInTrackOrder ?? []
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        return plan.slots.enumerated().compactMap { index, slot in
            let area: CGRect
            if plan.layout.isFullScreen {
                area = full
            } else if areas.indices.contains(index) {
                let box = areas[index].bounds
                area = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
            } else { return nil }
            // The export interpolates the path, so a moment inside a camera
            // move shows the crop part-way; hard cuts stay cuts because the
            // planner puts a hold key just before each one.
            let keyframe = slot.path.flatMap { CenterStageService.interpolated($0, at: time - rangeStart) }
            let region = keyframe.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
                ?? (slot.window ?? slot.region).map { CGRect(x: $0.xFrac, y: $0.yFrac, width: $0.wFrac, height: $0.hFrac) }
                ?? full
            let tile = tiles.first { $0.contains(x: region.midX, y: region.midY) }
            let entry = roster.first { $0.key == tile?.personKey }
                ?? roster.first { person in
                    guard let box = person.portraitBox else { return false }
                    return tile?.contains(x: box.x + box.w / 2, y: box.y + box.h / 2) == true
                }
            let portrait = entry?.portraitBox.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            let crop = CropRecipePlanner.crop(
                tile: PodcastTile(index: -1, x: region.minX, y: region.minY, w: region.width, h: region.height),
                aspect: canvasAspect * area.width / max(0.001, area.height),
                sourceAspect: Double(video.width) / Double(video.height), center: keyframe == nil ? slot.focus : nil,
                face: keyframe == nil ? portrait : nil)
            let source = focusFrame != nil && slot.region != nil && slot.path == nil && slot.window == nil
                ? region : CGRect(x: crop.xFrac, y: crop.yFrac, width: crop.wFrac, height: crop.hFrac)
            let person = people.first { !$0.hidden && $0.tagName != nil && $0.key == (entry?.key ?? tile?.personKey) }
            let face = entry?.portraitBox.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            return WizardPreviewComposite.Cell(source: source, area: area, person: person, face: face,
                                               isTalking: slot.talking.contains { $0.contains(time) })
        }
    }
}

/// Face-refined rosters for Interview focus previews, keyed by the recording,
/// the scene's source range and the roster the refinement started from.
actor InterviewPreviewRosterCache {
    static let shared = InterviewPreviewRosterCache()

    private struct Key: Hashable {
        var path: String
        var start: Double
        var end: Double
        var roster: [VideoPersonRecord]
        /// Speaker turns decide which feed each person is sampled on.
        var turns: [SpeakerTurn]
        var punchIn: InterviewPunchIn
        var cuts: Bool
    }

    private var entries: [Key: [VideoPersonRecord]] = [:]
    private var inFlight: [Key: Task<[VideoPersonRecord], Never>] = [:]
    private let limit = 64

    /// The render's refinement for `range`; one decode pass per scene, shared
    /// by concurrent callers.
    func refined(video: VideoRecord, roster: [VideoPersonRecord], range: ClosedRange<Double>,
                 turns: [SpeakerTurn], punchIn: InterviewPunchIn, cuts: Bool) async -> [VideoPersonRecord] {
        let key = Key(path: video.url.path, start: range.lowerBound, end: range.upperBound, roster: roster, turns: turns,
                      punchIn: punchIn, cuts: cuts)
        if let hit = entries[key] { return hit }
        let task: Task<[VideoPersonRecord], Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) {
                await InterviewFaceSampling.refinedRoster(video: video, roster: roster, range: range, turns: turns,
                    punchIn: punchIn, cuts: cuts, log: { _ in })
            }
            inFlight[key] = task
        }
        let result = await task.value
        if inFlight[key] == task {
            inFlight[key] = nil
            if entries.count >= limit { entries.removeAll() }
            entries[key] = result
        }
        return result
    }
}
