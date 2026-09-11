import Foundation
import Observation

/// What the clip browser puts on the pasteboard when a scene is dragged
/// onto a lane. Option-drag asks for B-roll instead of a main clip.
nonisolated enum TimelineDropPayload {
    static func scene(_ id: Int64, cutaway: Bool = false) -> String {
        cutaway ? "scene:\(id):cutaway" : "scene:\(id)"
    }

    static func parse(_ payload: String) -> (sceneID: Int64, cutaway: Bool)? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "scene", let id = Int64(parts[1]) else { return nil }
        return (id, parts.count > 2 && parts[2] == "cutaway")
    }
}

/// What happened when B-roll was added — the picker and the browser both
/// say so out loud rather than doing nothing visible.
nonisolated enum CutawayInsertion: Sendable, Equatable {
    /// Added. `clampedTo` is set when the footage was shorter than asked.
    case added(uid: UUID, clampedTo: Double?)
    /// The track has no crop area at that time and cover-all was off.
    case noArea(track: Int)
    /// The window starts at or past the end of the footage.
    case noSource

    var uid: UUID? {
        if case .added(let uid, _) = self { return uid }
        return nil
    }

    /// A sentence for the picker's status line, or nil when all is well.
    func message(at time: Double) -> String? {
        switch self {
        case .added(_, let clampedTo?):
            String(format: "The footage was shorter than asked: added %.1f s.", clampedTo)
        case .added:
            nil
        case .noArea(let track):
            "Track \(track + 1) has no area at \(time.timecode). Pick another track, or turn on Cover all areas."
        case .noSource:
            "That footage has no usable range left at this window."
        }
    }
}

/// Where a cutaway's footage comes from: an analyzed scene, or a video file
/// from the Library the picker windows by hand.
nonisolated enum CutawaySource: Sendable {
    case scene(SceneRecord)
    case file(url: URL, duration: Double)

    var url: URL {
        switch self {
        case .scene(let scene): scene.videoURL
        case .file(let url, _): url
        }
    }

    /// Where inside the file the source window may run.
    var window: (start: Double, end: Double) {
        switch self {
        case .scene(let scene): (scene.startTime, scene.endTime)
        case .file(_, let duration): (0, duration)
        }
    }

    var displayName: String {
        switch self {
        case .scene(let scene): scene.videoFilename
        case .file(let url, _): url.deletingPathExtension().lastPathComponent
        }
    }
}

nonisolated enum TimelineSelection: Codable, Sendable, Equatable {
    case clip(UUID)
    case sound(UUID)
    case text(UUID)
    case image(UUID)
    case overlay(UUID)
    case crop(UUID)
}

/// One item in the unified overlay lane — texts, images, and overlay blocks
/// share a single timeline that stacks rows when items overlap in time.
enum OverlayLaneEntry: Identifiable {
    case text(TextOverlayItem)
    case image(ImageOverlayItem)
    case block(OverlayBlockItem)

    var uid: UUID {
        switch self {
        case .text(let item): return item.uid
        case .image(let item): return item.uid
        case .block(let item): return item.uid
        }
    }

    var start: Double {
        switch self {
        case .text(let item): return item.startTime
        case .image(let item): return item.startTime
        case .block(let item): return item.startTime
        }
    }

    var end: Double {
        switch self {
        case .text(let item): return item.endTime
        case .image(let item): return item.endTime
        case .block(let item): return item.endTime
        }
    }

    var id: UUID { uid }
}

/// Observable editing model for the Clip Builder timeline: owns the document,
/// selection, zoom, and playhead, and implements every mutation (drop, move,
/// trim, pack, overlap layout) so views stay declarative and the math is
/// testable. Autosaves per profile after each mutation (debounced).
@Observable
final class BuilderTimelineModel {
    nonisolated enum Mode: Sendable { case persistent, transient }
    let mode: Mode

    init(mode: Mode = .persistent) { self.mode = mode }

    /// Seed by value after populating the lookup cache: hydration must not
    /// change the captured document or its runtime identities.
    func seed(document: TimelineDocument, scenes: [SceneRecord],
              driveBackedPaths: Set<String> = [], selection: TimelineSelection? = nil,
              playhead: Double = 0, focusedTrack: Int? = nil, zoom: CGFloat = 60) {
        precondition(mode == .transient)
        cancelPendingAutosave()
        updateScenes(scenes)
        self.document = document
        updateDriveBackedPaths(driveBackedPaths)
        self.selection = selection
        self.playhead = playhead
        self.focusedTrack = focusedTrack
        pointsPerSecond = zoom
        cachedTimelineLayout = nil
    }

    /// Monotonic for this model's lifetime, including direct binding edits,
    /// hydration, loads and exact undo/redo. Persisted in timelines.document_revision.
    private(set) var revision = 0
    private(set) var persistedRevision = 0

    func acknowledgePersistedRevision(_ revision: Int) { persistedRevision = revision }
    private var installingExactSnapshot = false
    var document = TimelineDocument() {
        didSet {
            if !installingExactSnapshot {
                revision += 1
                cachedTimelineLayout = nil
            }
        }
    }
    private(set) var scriptRunStatus: (uuid: String, status: BuilderRunStatus)?
    var selection: TimelineSelection? {
        didSet { notifyUIStateChange() }
    }
    var pointsPerSecond: CGFloat = 60 {          // timeline zoom
        didSet { notifyUIStateChange() }
    }
    var playhead: Double = 0 {
        didSet { notifyUIStateChange() }
    }
    /// The video track the user last clicked (its header or one of its
    /// clips). The cropping row paints that track's area green.
    var focusedTrack: Int? {
        didSet { notifyUIStateChange() }
    }

    private(set) var profileName = ""
    private(set) var timelineID: Int64?
    private(set) var scenes: [SceneRecord] = []
    private var scenesByID: [Int64: SceneRecord] = [:]
    /// Source paths the Library knows are Drive-backed. Such a file may not
    /// be on disk yet and is fetched on demand, so the fast preview must not
    /// mistake it for footage that has been deleted.
    private(set) var driveBackedPaths: Set<String> = []

    func updateDriveBackedPaths(_ paths: Set<String>) {
        guard driveBackedPaths != paths else { return }
        driveBackedPaths = paths
    }
    private var saveTask: Task<Void, Never>?
    private var hasPendingAutosave = false
    @ObservationIgnored var onTimelineAutosave: ((Int64, TimelineDocument) -> Void)?
    @ObservationIgnored var onUIStateChange: (() -> Void)?
    private var suppressAutosave = false
    @ObservationIgnored private var cachedTimelineLayout: TimelineLayoutSnapshot?

    /// Window undo manager, injected by BuilderView. Registering with the
    /// window (instead of replacing the Undo menu command) keeps text-field
    /// editing on the field editor's own undo stack.
    weak var undoManager: UndoManager?
    private var lastUndoKey: String?
    private var lastUndoDate = Date.distantPast
    private static let undoCoalesceWindow: TimeInterval = 1.0

    /// One main-clip row. The B-roll strip band is `stripHeight` per row;
    /// both live on the layout snapshot so every reader agrees.
    /// A request to open the B-roll picker somewhere specific (the track
    /// context menu). Nil means "at the playhead, on the focused track".
    var brollRequest: BRollRequest?

    nonisolated struct BRollRequest: Sendable, Equatable {
        var time: Double
        var track: Int
    }

    /// What the B-roll picker was last set to, so the next B opens where
    /// the last one left off. Per document: cleared by `loadDocument`.
    var lastBRollPick: BRollPick?

    nonisolated struct BRollPick: Sendable, Equatable {
        var sourceKey: String
        var sourceStart: Double
        var length: Double
        var track: Int
        var coverAll: Bool
    }

    static let rowHeight: CGFloat = TimelineLayoutSnapshot.rowHeight
    static let stripHeight: CGFloat = TimelineLayoutSnapshot.stripHeight
    static let laneSpacing: CGFloat = 6

    // MARK: - Undo

    /// Push the pre-mutation document as an undo step. Continuous edits
    /// (slider drags, per-keystroke text changes) pass a stable `coalescing`
    /// key so a burst of updates becomes a single step.
    private func registerUndo(_ actionName: String, coalescing key: String? = nil) {
        let now = Date()
        if let key, key == lastUndoKey,
           now.timeIntervalSince(lastUndoDate) < Self.undoCoalesceWindow {
            lastUndoDate = now
            return
        }
        lastUndoKey = key
        lastUndoDate = now
        registerUndoStep(actionName)
    }

    private func registerUndoStep(_ actionName: String) {
        guard mode == .persistent, let undoManager else { return }
        let snapshot = document
        // An undo manager that does not group by event (tests, scripted
        // hosts) raises NSInternalInconsistencyException when a step is
        // registered outside a group; AppKit turns that into a hung process.
        let needsGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        defer { if needsGroup { undoManager.endUndoGrouping() } }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.registerUndoStep(actionName)   // becomes the redo step
                model.restore(snapshot)
            }
        }
        if !undoManager.isUndoing && !undoManager.isRedoing {
            undoManager.setActionName(actionName)
        }
    }

    private func restore(_ snapshot: TimelineDocument) {
        document = snapshot
        lastUndoKey = nil
        hydrateClips()
        if let selection, !contains(selection) { self.selection = nil }
        documentDidChange()
    }

    /// Normalize only on the transient copy, before the preview is frozen.
    func normalizeScriptCandidate() {
        precondition(mode == .transient)
        normalizeBumpers()
        for index in document.videoTrack.indices {
            document.videoTrack[index].enforceBumperRules()
            document.videoTrack[index].enforceCutawayRules()
        }
        document.normalizeCropBlocks()
    }

    func validateScriptSnapshot(candidate: BuilderScriptSnapshot, baseline: TimelineDocument,
                                baselineRevision: Int, requiresUndo: Bool = true) -> ApplyFailure? {
        guard mode == .persistent, timelineID == candidate.timelineID,
              profileName == candidate.profileName else { return .identityChanged }
        guard revision == baselineRevision, ScriptValue.stored(document) == ScriptValue.stored(baseline) else { return .staleRevision }
        guard !requiresUndo || undoManager != nil else { return .missingUndoManager }
        guard ScriptValue.stored(candidate.document) == ScriptValue.stored(candidate.preview) else { return .candidateChanged }
        return nil
    }

    /// The coordinator must durably commit before calling this synchronous API.
    /// No normalization, hydration, or per-command undo is allowed here.
    func applyScriptSnapshot(candidate: BuilderScriptSnapshot, baseline: TimelineDocument,
                             baselineRevision: Int, actionName: String) -> Result<Int, ApplyFailure> {
        if let failure = validateScriptSnapshot(candidate: candidate, baseline: baseline,
                                                baselineRevision: baselineRevision) {
            return .failure(failure)
        }
        guard ScriptValue.stored(candidate.document) != ScriptValue.stored(baseline) else {
            return .failure(.notApplicable)
        }
        installScriptSnapshot(candidate, actionName: "Wizard: \(actionName)", status: .applied)
        return .success(revision)
    }

    /// Revert shares the exact installation primitive but does not require a window.
    func applyRevertSnapshot(candidate: BuilderScriptSnapshot, baseline: TimelineDocument,
                             baselineRevision: Int) -> Result<Int, ApplyFailure> {
        if let failure = validateScriptSnapshot(candidate: candidate, baseline: baseline,
                                                baselineRevision: baselineRevision, requiresUndo: false) {
            return .failure(failure)
        }
        installScriptSnapshot(candidate, actionName: "Revert Wizard run", status: .reverted)
        return .success(revision)
    }

    private func installScriptSnapshot(_ candidate: BuilderScriptSnapshot, actionName: String,
                                       status: BuilderRunStatus) {
        registerExactUndo(document, inverse: candidate.document, actionName: actionName,
                          status: (candidate.runUUID, status == .applied ? .reverted : .applied),
                          inverseStatus: (candidate.runUUID, status))
        scriptRunStatus = (candidate.runUUID, status)
        restoreExact(candidate.document)
        // This value was committed already. Later edits/undo still use the installed callbacks.
        cancelPendingAutosave()
    }

    private func registerExactUndo(_ snapshot: TimelineDocument, inverse: TimelineDocument,
                                   actionName: String, status: (uuid: String, status: BuilderRunStatus),
                                   inverseStatus: (uuid: String, status: BuilderRunStatus)) {
        guard let undoManager else { return }
        let needsGroup = undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        defer { if needsGroup { undoManager.endUndoGrouping() } }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                // Capture both sides at installation: Library hydration can
                // change the live value before undo without adding an undo step.
                model.registerExactUndo(inverse, inverse: snapshot, actionName: actionName,
                                        status: inverseStatus, inverseStatus: status)
                model.scriptRunStatus = status
                model.restoreExact(snapshot)
                if let id = model.timelineID { model.onTimelineAutosave?(id, model.document) }
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Restore the actual value, including runtime IDs and hydrated metadata.
    /// Unlike restore(), changed Library rows never participate in undo/redo.
    private func restoreExact(_ snapshot: TimelineDocument) {
        let wasSuppressed = suppressAutosave
        suppressAutosave = true
        defer { suppressAutosave = wasSuppressed }
        installingExactSnapshot = true
        document = snapshot
        installingExactSnapshot = false
        revision += 1
        cachedTimelineLayout = nil
        lastUndoKey = nil
        if let selection, !contains(selection) { self.selection = nil }
        if let focusedTrack, !(0..<document.trackCount).contains(focusedTrack) { self.focusedTrack = nil }
        playhead = min(max(0, playhead), totalDuration)
    }

    private func contains(_ selection: TimelineSelection) -> Bool {
        switch selection {
        case .clip(let uid): return document.videoTrack.contains { $0.uid == uid }
        case .sound(let uid): return document.soundTrack.contains { $0.uid == uid }
        case .text(let uid): return document.textOverlays.contains { $0.uid == uid }
        case .image(let uid): return document.imageOverlays.contains { $0.uid == uid }
        case .overlay(let uid): return document.overlayBlocks.contains { $0.uid == uid }
        case .crop(let uid): return document.cropBlocks.contains { $0.uid == uid }
        }
    }

    private func resetUndoHistory() {
        // Only this model's steps: the window's manager also carries the
        // inspector text fields' own undo stack.
        if mode == .persistent { undoManager?.removeAllActions(withTarget: self) }
        lastUndoKey = nil
        scriptRunStatus = nil
    }

    // MARK: - Load / persistence

    func load(profileName: String, defaultRenderSettings: RenderSettings = RenderSettings()) {
        flushPendingAutosave()
        resetUndoHistory()
        self.profileName = profileName
        timelineID = nil
        // Remembered B-roll picks belong to the document they were made in.
        lastBRollPick = nil
        brollRequest = nil
        // Scene ids are per-profile; the previous profile's rows must not
        // hydrate this profile's clips. The library refresh refills them.
        scenes = []
        scenesByID = [:]
        suppressAutosave = true
        if mode == .persistent, let saved = BuilderStateStore.load(profileName: profileName) {
            document = saved
        } else {
            document = TimelineDocument()
            document.renderSettings = defaultRenderSettings
        }
        document.migrateLegacyScreenCrops()
        document.normalizeCropBlocks()
        cachedTimelineLayout = nil
        selection = nil
        focusedTrack = nil
        playhead = 0
        suppressAutosave = false
    }

    /// Open one database-backed project timeline without creating an undo
    /// step or writing it back before the user changes anything.
    func loadTimeline(id: Int64, document newDocument: TimelineDocument,
                      revision persistedRevision: Int = 0,
                      playhead: Double = 0, zoom: Double = 60,
                      selection: TimelineSelection? = nil, focusedTrack: Int? = nil) {
        flushPendingAutosave()
        resetUndoHistory()
        suppressAutosave = true
        self.persistedRevision = persistedRevision
        revision = max(revision, persistedRevision)
        timelineID = id
        lastBRollPick = nil
        brollRequest = nil
        document = newDocument
        document.migrateLegacyScreenCrops()
        document.normalizeCropBlocks()
        cachedTimelineLayout = nil
        self.selection = selection
        self.focusedTrack = focusedTrack
        // Scene clips carry no duration in JSON — hydrate first, or the
        // clamp below sees a zero-length timeline and drops the playhead.
        hydrateClips()
        self.playhead = min(max(0, playhead), totalDuration)
        pointsPerSecond = max(20, min(200, zoom))
        suppressAutosave = false
    }

    func closeTimeline(defaultRenderSettings: RenderSettings = RenderSettings()) {
        flushPendingAutosave()
        resetUndoHistory()
        suppressAutosave = true
        timelineID = nil
        lastBRollPick = nil
        brollRequest = nil
        document = TimelineDocument()
        document.renderSettings = defaultRenderSettings
        document.normalizeCropBlocks()
        cachedTimelineLayout = nil
        selection = nil
        focusedTrack = nil
        playhead = 0
        suppressAutosave = false
    }

    /// Replace the working document (e.g. "Open in Builder" from the Library).
    func loadDocument(_ newDocument: TimelineDocument) {
        registerUndo("Replace Timeline")
        document = newDocument
        // The B-roll picker's memory belongs to the document it was used on.
        lastBRollPick = nil
        brollRequest = nil
        document.migrateLegacyScreenCrops()
        selection = nil
        focusedTrack = nil
        hydrateClips()
        documentDidChange()
    }

    func clear() {
        registerUndo("Clear Timeline")
        // A debounced autosave holding the pre-clear snapshot would write
        // the timeline straight back after the file is deleted.
        saveTask?.cancel()
        hasPendingAutosave = false
        document = TimelineDocument()
        document.normalizeCropBlocks()
        cachedTimelineLayout = nil
        selection = nil
        focusedTrack = nil
        playhead = 0
        if timelineID == nil, mode == .persistent {
            cancelPendingAutosave()
            BuilderStateStore.clear(profileName: profileName)
        } else {
            documentDidChange()
        }
    }

    func setRenderSettings(_ settings: RenderSettings) {
        guard document.renderSettings != settings else { return }
        registerUndo("Change Output Format", coalescing: "output-format")
        document.renderSettings = settings
        documentDidChange()
    }

    func setPacing(_ pacing: EditPacing) {
        guard document.pacing != pacing else { return }
        registerUndo("Change Cut Cadence", coalescing: "cut-cadence")
        document.pacing = pacing
        documentDidChange()
    }

    /// Called whenever the scene cache refreshes; fills in the scene-derived
    /// fields the timeline JSON doesn't carry (duration, source path, wide).
    func updateScenes(_ scenes: [SceneRecord]) {
        self.scenes = scenes
        scenesByID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        hydrateClips()
    }

    /// Merge a set of changed library rows and hydrate the timeline once.
    /// Bulk scene actions use this instead of rescanning the scene cache and
    /// video track for every selected card.
    func updateChangedScenes(_ changedScenes: [SceneRecord], rehydrateClips: Bool = true) {
        guard !changedScenes.isEmpty else { return }
        let previousScenesByID = scenesByID
        let changedByID = Dictionary(uniqueKeysWithValues: changedScenes.map { ($0.id, $0) })
        var foundIDs = Set<Int64>()
        scenes = scenes.map { scene in
            guard let changed = changedByID[scene.id] else { return scene }
            foundIDs.insert(scene.id)
            return changed
        }
        scenes.append(contentsOf: changedScenes.filter { !foundIDs.contains($0.id) })
        for scene in changedScenes { scenesByID[scene.id] = scene }

        let changedIDs = Set(changedByID.keys)
        if rehydrateClips,
           document.videoTrack.contains(where: { $0.sceneID.map(changedIDs.contains) == true }) {
            // Keep user trims, but move clips that represented the complete
            // old scene to the complete new scene range.
            for index in document.videoTrack.indices {
                var clip = document.videoTrack[index]
                guard let sceneID = clip.sceneID, let changed = changedByID[sceneID] else { continue }
                if let previous = previousScenesByID[sceneID] {
                    let representedWholeScene = abs((clip.sourceStart ?? previous.startTime) - previous.startTime) < 0.05
                        && abs(clip.sourceSpan - previous.duration) < 0.05
                    if representedWholeScene {
                        clip.sourceStart = changed.startTime
                        clip.sourceEnd = changed.endTime
                        clip.duration = changed.duration / clip.effectiveSpeed
                    }
                }
                clip.videoFile = changed.videoPath
                document.videoTrack[index] = clip
            }
            hydrateClips()
        }
    }

    /// One scene changed: refresh its cache entry and only re-hydrate when
    /// a clip on the timeline actually references it.
    func updateScene(_ scene: SceneRecord, rehydrateClips: Bool = true) {
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
            scenes[index] = scene
        } else {
            scenes.append(scene)
        }
        scenesByID[scene.id] = scene
        if rehydrateClips, document.videoTrack.contains(where: { $0.sceneID == scene.id }) {
            hydrateClips()
        }
    }

    private func hydrateClips() {
        revision += 1
        // Bumper and B-roll rules hold even in a project with no analyzed
        // scenes yet; only the scene-derived fields need the library.
        normalizeBumpers()
        for index in document.videoTrack.indices {
            var clip = document.videoTrack[index]
            if clip.bumper {
                clip.enforceBumperRules()
                document.videoTrack[index] = clip
                continue
            }
            clip.enforceCutawayRules()
            document.videoTrack[index] = clip
            guard let sceneID = clip.sceneID, let scene = scenesByID[sceneID] else { continue }
            clip.sceneFullDuration = (scene.duration * 10).rounded() / 10
            if clip.videoFile == nil { clip.videoFile = scene.videoPath }
            if clip.sourceStart == nil { clip.sourceStart = scene.startTime }
            if clip.duration <= 0 { clip.duration = clip.sceneFullDuration ?? 0 }
            clip.wide = scene.wide
            // The scene's shape must not undo a cover-all cutaway's framing.
            clip.enforceCutawayRules()
            document.videoTrack[index] = clip
        }
        cachedTimelineLayout = nil
    }

    private func documentDidChange() {
        revision += 1
        // The cropping row always tiles the content; the track count follows it.
        document.normalizeCropBlocks()
        cachedTimelineLayout = nil
        scheduleDocumentAutosave()
    }

    private func scheduleDocumentAutosave() {
        guard mode == .persistent, !suppressAutosave else { return }
        let name = profileName
        let id = timelineID
        let autosave = onTimelineAutosave
        saveTask?.cancel()
        hasPendingAutosave = true
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            hasPendingAutosave = false
            let snapshot = document
            if let id, let autosave {
                autosave(id, snapshot)
                return
            }
            // Detached: this fires continuously during editing, and a plain
            // Task would inherit main-actor isolation for the encode + write.
            await Task.detached(priority: .utility) {
                BuilderStateStore.save(snapshot, profileName: name)
            }.value
        }
    }

    private func notifyUIStateChange() {
        guard mode == .persistent, !suppressAutosave else { return }
        onUIStateChange?()
    }

    /// Drop a pending debounced autosave because the caller is about to
    /// write the document itself (termination).
    func cancelPendingAutosave() {
        saveTask?.cancel()
        saveTask = nil
        hasPendingAutosave = false
    }

    /// Save the latest document before replacing it. This closes the debounce
    /// window during project switches and app termination instead of silently
    /// dropping the user's final edit.
    func flushPendingAutosave() {
        guard mode == .persistent else { cancelPendingAutosave(); return }
        guard hasPendingAutosave else {
            saveTask?.cancel()
            saveTask = nil
            return
        }
        saveTask?.cancel()
        saveTask = nil
        hasPendingAutosave = false
        if let timelineID, let onTimelineAutosave {
            onTimelineAutosave(timelineID, document)
        } else {
            BuilderStateStore.save(document, profileName: profileName)
        }
    }

    // MARK: - Geometry helpers

    /// 0.5-second grid, matching the web timeline's snapping.
    nonisolated static func snap(_ time: Double) -> Double {
        max(0, (time * 2).rounded() / 2)
    }

    var totalDuration: Double {
        let clipEnd = document.videoTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let soundEnd = document.soundTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let textEnd = document.textOverlays.map(\.endTime).max() ?? 0
        let imageEnd = document.imageOverlays.map(\.endTime).max() ?? 0
        let blockEnd = document.overlayBlocks.map(\.endTime).max() ?? 0
        return max(clipEnd, soundEnd, textEnd, imageEnd, blockEnd)
    }

    // MARK: - Unified overlay lane

    static let overlayRowHeight: CGFloat = 40

    /// Shared by the timeline header and lanes until the document changes.
    func timelineLayout() -> TimelineLayoutSnapshot {
        if let cachedTimelineLayout { return cachedTimelineLayout }
        let layout = TimelineLayoutSnapshot(document: document)
        cachedTimelineLayout = layout
        return layout
    }

    /// The track's own clips; bumpers belong to the cropping row.
    func clips(inTrack track: Int) -> [TimelineClip] {
        document.videoTrack.filter { $0.track == track && !$0.bumper }
    }

    /// The track whose area the cropping row highlights: the selected clip's
    /// track, else the last clicked header.
    var highlightedTrack: Int? {
        if case .clip(let uid) = selection, let clip = clip(uid) { return clip.track }
        return focusedTrack
    }

    func focusTrack(_ track: Int) {
        focusedTrack = track
        if case .clip(let uid) = selection, clip(uid)?.track != track { selection = nil }
    }

    /// The crop block a style change applies to: the selected block, else
    /// the one under the playhead.
    var targetCropBlock: CropBlockItem? {
        if case .crop(let uid) = selection, let block = cropBlock(uid) { return block }
        return document.cropBlock(at: playhead)
    }

    /// The area `track` shows at `time` (nil under Full Screen or when the
    /// track has none there).
    func area(forTrack track: Int, at time: Double) -> ScreenCropArea? {
        document.cropBlock(at: time)?.layout.area(forTrack: track)
    }

    /// Whether a clip may be placed on `track` at `time` — the cropping row
    /// must give that track an area there.
    func canPlace(track: Int, at time: Double) -> Bool {
        document.hasArea(track: track, at: time)
    }

    /// Map a vertical drag offset from one video lane to a target track
    /// index. `blockOffset` is where the dragged block sits inside its own
    /// lane (B-roll rides in the strip band above the main rows), so the
    /// drag is measured from the block, not from the lane's middle.
    func trackIndex(fromTrack track: Int, verticalDelta: CGFloat, blockOffset: CGFloat = 0) -> Int {
        guard document.trackCount > 1 else { return 0 }
        let layout = timelineLayout()
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        var y: CGFloat = 0
        for index in 0..<document.trackCount {
            let height = layout.videoTracks[index].laneHeight
            tops.append(y)
            heights.append(height)
            y += height + Self.laneSpacing
        }
        let sourceIndex = min(max(0, track), tops.count - 1)
        let target = tops[sourceIndex] + blockOffset + verticalDelta
        if let hit = (0..<tops.count).first(where: { target >= tops[$0] && target < tops[$0] + heights[$0] }) {
            return hit
        }
        let nearest = (0..<tops.count).min {
            abs(tops[$0] + heights[$0] / 2 - target) < abs(tops[$1] + heights[$1] / 2 - target)
        }
        return nearest ?? sourceIndex
    }

    // MARK: - Clip lookup

    func clipIndex(_ uid: UUID) -> Int? {
        document.videoTrack.firstIndex { $0.uid == uid }
    }

    func clip(_ uid: UUID) -> TimelineClip? {
        clipIndex(uid).map { document.videoTrack[$0] }
    }

    func scene(for clip: TimelineClip) -> SceneRecord? {
        clip.sceneID.flatMap { scenesByID[$0] }
    }

    func sourceURL(for clip: TimelineClip) -> URL? {
        if let scene = scene(for: clip) { return scene.videoURL }
        return clip.videoFile.map { URL(fileURLWithPath: $0) }
    }

    /// Source-file time to preview for a clip at a given timeline time.
    func sourceTime(for clip: TimelineClip, atTimeline time: Double) -> Double {
        (clip.sourceStart ?? 0) + max(0, min(clip.duration, time - clip.startTime)) * clip.effectiveSpeed
    }

    // MARK: - Clip mutations

    /// Bumpers go on the cropping row and are exclusive while they play.
    /// In overlap mode nothing moves for them; in pause mode the timeline
    /// opens a gap of the bumper's length. Two bumpers never overlap: a
    /// bumper placed onto another slides to just after it.
    func addBumper(_ bumper: BumperAsset, at time: Double? = nil, mode: BumperMode = .overlap) {
        guard var clip = bumper.clip(at: max(0, Self.snap(time ?? playhead))) else { return }
        registerUndo("Add Bumper")
        clip.bumperMode = mode
        clip.startTime = nonOverlappingBumperStart(clip.startTime, duration: clip.duration, excluding: nil)
        if mode == .pause {
            BumperPlanner.insertGap(in: &document, at: clip.startTime, duration: clip.duration)
        }
        document.videoTrack.append(clip)
        selection = .clip(clip.uid)
        documentDidChange()
    }

    // MARK: - Bumper rules

    /// Bumpers other than `excluding`, in time order.
    private func otherBumpers(excluding uid: UUID?) -> [TimelineClip] {
        document.videoTrack.filter { $0.bumper && $0.uid != uid }.sorted { $0.startTime < $1.startTime }
    }

    /// The first time at or after `start` where a bumper of `duration`
    /// touches no other bumper.
    func nonOverlappingBumperStart(_ start: Double, duration: Double, excluding uid: UUID?) -> Double {
        var start = max(0, start)
        let others = otherBumpers(excluding: uid)
        // Round UP to the grid: rounding a 6.1 s end down to 6.0 would leave
        // the overlap in place and this loop would never finish. The bound
        // is a belt on top of that: each pass moves past at least one bumper.
        for _ in 0...(others.count + 1) {
            var moved = false
            for other in others where start < other.startTime + other.duration - 0.001
                && other.startTime < start + duration - 0.001 {
                start = Self.snapUp(other.startTime + other.duration)
                moved = true
            }
            if !moved { break }
        }
        return start
    }

    /// The half-second grid, never earlier than the given time.
    static func snapUp(_ time: Double) -> Double {
        max(0, (time * 2 - 0.0001).rounded(.up) / 2)
    }

    /// The longest an overlap-mode bumper at `start` can be before it would
    /// touch the next bumper. Pause-mode bumpers push later bumpers instead.
    func maximumBumperDuration(for uid: UUID) -> Double {
        guard let clip = clip(uid), clip.bumper, clip.bumperMode == .overlap else { return .greatestFiniteMagnitude }
        let next = otherBumpers(excluding: uid).first { $0.startTime >= clip.startTime + 0.001 }
        return next.map { max(0.5, $0.startTime - clip.startTime) } ?? .greatestFiniteMagnitude
    }

    /// Switch a bumper between covering and pausing. Pausing opens the gap
    /// the bumper needs; going back closes it.
    func setBumperMode(_ uid: UUID, mode: BumperMode) {
        guard let index = clipIndex(uid), document.videoTrack[index].bumper,
              document.videoTrack[index].bumperMode != mode else { return }
        registerUndo("Change Bumper Behavior")
        var bumper = document.videoTrack.remove(at: index)
        bumper.bumperMode = mode
        switch mode {
        case .pause:
            BumperPlanner.insertGap(in: &document, at: bumper.startTime, duration: bumper.duration)
        case .overlap:
            BumperPlanner.removeGap(in: &document, at: bumper.startTime, duration: bumper.duration)
            bumper.startTime = nonOverlappingBumperStart(bumper.startTime, duration: bumper.duration, excluding: uid)
        }
        document.videoTrack.append(bumper)
        resolveAllLayouts()
        documentDidChange()
    }

    /// Move a bumper to `startTime`, keeping the no-overlap rule and, for a
    /// pausing bumper, closing its old gap and opening a new one.
    private func moveBumper(at index: Int, to startTime: Double) {
        var bumper = document.videoTrack.remove(at: index)
        let old = bumper.startTime
        var target = max(0, Self.snap(startTime))
        if bumper.bumperMode == .pause {
            BumperPlanner.removeGap(in: &document, at: old, duration: bumper.duration)
            // The drop point was read off a timeline that still had the
            // gap: content after it now sits earlier by the gap's length.
            if target > old { target = max(old, target - bumper.duration) }
        }
        target = nonOverlappingBumperStart(target, duration: bumper.duration, excluding: bumper.uid)
        bumper.startTime = target
        if bumper.bumperMode == .pause {
            BumperPlanner.insertGap(in: &document, at: target, duration: bumper.duration)
        }
        document.videoTrack.append(bumper)
        resolveAllLayouts()
    }

    /// Move a bumper by a relative amount (arrow keys, accessibility). Unlike
    /// a drop point, the delta is not read off the gapped timeline, so a
    /// pausing bumper needs no drop adjustment.
    func nudgeBumper(_ uid: UUID, by delta: Double) {
        guard let index = clipIndex(uid), document.videoTrack[index].bumper else { return }
        registerUndo("Move Bumper")
        var bumper = document.videoTrack.remove(at: index)
        if bumper.bumperMode == .pause {
            BumperPlanner.removeGap(in: &document, at: bumper.startTime, duration: bumper.duration)
        }
        let target = nonOverlappingBumperStart(max(0, Self.snap(bumper.startTime + delta)),
                                               duration: bumper.duration, excluding: bumper.uid)
        bumper.startTime = target
        if bumper.bumperMode == .pause {
            BumperPlanner.insertGap(in: &document, at: target, duration: bumper.duration)
        }
        document.videoTrack.append(bumper)
        resolveAllLayouts()
        documentDidChange()
    }

    /// Change a bumper's length; a pausing bumper's gap grows or shrinks
    /// with it and an overlapping one stops short of the next bumper.
    private func resizeBumper(at index: Int, duration: Double) {
        var bumper = document.videoTrack.remove(at: index)
        let old = bumper.duration
        var new = max(0.5, Self.snap(duration))
        // Never longer than the bumper file itself, even when the file is
        // shorter than the half-second minimum.
        if let start = bumper.sourceStart, let end = bumper.sourceEnd {
            new = max(0.05, min(new, (end - start) / bumper.effectiveSpeed))
        }
        if bumper.bumperMode == .overlap {
            document.videoTrack.append(bumper)
            new = min(new, maximumBumperDuration(for: bumper.uid))
            document.videoTrack.removeLast()
        }
        if bumper.bumperMode == .pause {
            if new > old {
                BumperPlanner.insertGap(in: &document, at: bumper.startTime + old, duration: new - old)
            } else if new < old {
                BumperPlanner.removeGap(in: &document, at: bumper.startTime + new, duration: old - new)
            }
        }
        bumper.duration = new
        document.videoTrack.append(bumper)
        resolveAllLayouts()
    }

    private func resolveAllLayouts() {
        for track in 0..<document.trackCount { resolveLayout(track: track) }
    }

    /// Loaded documents: bumpers must not overlap; a later one that does
    /// slides after the earlier one. A pausing bumper takes its gap along.
    private func normalizeBumpers() {
        let uids = document.videoTrack.filter(\.bumper)
            .sorted { $0.startTime < $1.startTime }.map(\.uid)
        var cursor = -Double.greatestFiniteMagnitude
        for uid in uids {
            guard let index = clipIndex(uid) else { continue }
            if document.videoTrack[index].startTime < cursor - 0.001 {
                var bumper = document.videoTrack.remove(at: index)
                if bumper.bumperMode == .pause {
                    BumperPlanner.removeGap(in: &document, at: bumper.startTime, duration: bumper.duration)
                }
                bumper.startTime = Self.snapUp(cursor)
                if bumper.bumperMode == .pause {
                    BumperPlanner.insertGap(in: &document, at: bumper.startTime, duration: bumper.duration)
                }
                document.videoTrack.append(bumper)
            }
            guard let moved = clip(uid) else { continue }
            cursor = moved.startTime + moved.duration
        }
    }

    func addScene(_ scene: SceneRecord, at time: Double? = nil, track: Int = 0) {
        var clip = TimelineClip()
        clip.sceneID = scene.id
        clip.videoFile = scene.videoPath
        clip.sourceStart = scene.startTime
        clip.sourceEnd = scene.endTime
        clip.duration = (scene.duration * 10).rounded() / 10
        clip.sceneFullDuration = clip.duration
        clip.wide = scene.wide
        clip.cropXFrac = scene.cropXFrac
        if let json = scene.freeCropsJSON, let data = json.data(using: .utf8),
           let crops = try? JSONDecoder().decode([FreeCrop].self, from: data), !crops.isEmpty {
            clip.freeCrops = crops
        }
        let targetTrack = min(max(0, track), document.trackCount - 1)
        clip.track = targetTrack
        let trackEnd = clips(inTrack: targetTrack).map { $0.startTime + $0.duration }.max() ?? 0
        clip.startTime = Self.snap(time ?? trackEnd)
        guard canPlace(track: targetTrack, at: clip.startTime) else { return }
        registerUndo("Add Clip")
        document.videoTrack.append(clip)
        resolveLayout(track: targetTrack)
        selection = .clip(clip.uid)
        documentDidChange()
    }

    // MARK: - B-roll (cutaways)

    /// How long a new cutaway should be at `time` on `track`: up to the next
    /// main-clip cut ahead, clamped to 1–5 s, or 3 s when nothing is ahead.
    func defaultCutawayDuration(at time: Double, track: Int) -> Double {
        let cuts = document.mainClips(inTrack: track)
            .flatMap { [$0.startTime, $0.startTime + $0.duration] }
            .filter { $0 > time + 0.05 }
            .sorted()
        guard let next = cuts.first else { return 3 }
        return min(5, max(1, Self.snap(next - time)))
    }

    /// The main-clip cuts on `track` inside a span — the picker draws these
    /// as marks so a cutaway that straddles a cut is visible.
    func mainCuts(inTrack track: Int, from start: Double, to end: Double) -> [Double] {
        var seen: [Double] = []
        for cut in document.mainClips(inTrack: track)
            .flatMap({ [$0.startTime, $0.startTime + $0.duration] })
            .filter({ $0 > start + 0.05 && $0 < end - 0.05 })
            .sorted() where seen.last.map({ abs($0 - cut) > 0.01 }) ?? true {
            // One clip's end and the next one's start are the same cut.
            seen.append(cut)
        }
        return seen
    }

    /// Whether any main clip is playing under a span on `track` — B-roll
    /// over nothing renders over black, which is worth flagging.
    func hasMainClip(inTrack track: Int, from start: Double, to end: Double) -> Bool {
        document.mainClips(inTrack: track).contains {
            $0.startTime < end - 0.001 && start < $0.startTime + $0.duration - 0.001
        }
    }

    /// Source seconds a cutaway source can give, from the Library rather
    /// than the caller: a scene ends where the scene ends, a Library video
    /// where the file does.
    private func sourceLength(of source: CutawaySource) -> Double {
        switch source {
        case .scene(let scene):
            return max(scene.endTime, scene.videoDuration)
        case .file(_, let duration):
            return duration
        }
    }

    /// Add B-roll bound to time: it never packs, never moves its neighbours,
    /// and is muted so the clip underneath keeps talking.
    @discardableResult
    func addCutaway(source: CutawaySource, at time: Double? = nil, track: Int = 0,
                    duration: Double? = nil, sourceStart: Double? = nil,
                    coverAll: Bool = false) -> CutawayInsertion {
        let targetTrack = min(max(0, track), document.trackCount - 1)
        let start = max(0, Self.snap(time ?? playhead))
        guard coverAll || canPlace(track: targetTrack, at: start) else {
            return .noArea(track: targetTrack)
        }
        var clip = TimelineClip()
        switch source {
        case .scene(let scene):
            clip.sceneID = scene.id
            clip.videoFile = scene.videoPath
            clip.sourceStart = sourceStart ?? scene.startTime
            clip.sceneFullDuration = (scene.duration * 10).rounded() / 10
            clip.wide = scene.wide
        case .file(let url, _):
            clip.videoFile = url.path
            clip.sourceStart = sourceStart ?? 0
        }
        clip.track = targetTrack
        clip.startTime = start
        // Never ask for more source than the file holds: clamp the window
        // first, then round, so the rounding cannot push it past the end.
        let sourceLimit = sourceLength(of: source)
        let windowStart = max(0, clip.sourceStart ?? 0)
        clip.sourceStart = windowStart
        // A picked window is exact: only the fallback length is snapped to
        // the timeline's half-second grid.
        let wanted = duration ?? Self.snap(defaultCutawayDuration(at: start, track: targetTrack))
        let available = max(0, sourceLimit - windowStart)
        // A window at (or past) the end of the file has nothing to show:
        // refuse it rather than insert a sliver the user did not ask for.
        guard available > 0.2 else { return .noSource }
        clip.duration = max(0.1, min(wanted, available))
        // Say so when the ask could not be honoured in full.
        let clampedTo = wanted - clip.duration > 0.05 ? clip.duration : nil
        clip.sourceEnd = windowStart + clip.sourceSpan
        clip.role = .cutaway
        clip.coverAllAreas = coverAll
        if !coverAll {
            clip.screenCrop = document.cropBlock(at: start)?.layout.reference(forTrack: targetTrack)
        }
        clip.enforceCutawayRules()
        registerUndo("Add B-roll")
        document.videoTrack.append(clip)
        selection = .clip(clip.uid)
        documentDidChange()
        return .added(uid: clip.uid, clampedTo: clampedTo)
    }

    /// Turn a clip into B-roll or back. Lossy by design: captions, Center
    /// Stage and free crops are dropped on the way in and never restored,
    /// and the track repacks in both directions.
    func setClipRole(_ uid: UUID, role: ClipRole) {
        guard let index = clipIndex(uid), !document.videoTrack[index].bumper,
              document.videoTrack[index].role != role else { return }
        registerUndo(role == .cutaway ? "Make B-roll" : "Make main clip")
        document.videoTrack[index].role = role
        if role == .main { document.videoTrack[index].coverAllAreas = false }
        document.videoTrack[index].enforceCutawayRules()
        resolveLayout(track: document.videoTrack[index].track)
        documentDidChange()
    }

    func setCutawayAudio(_ uid: UUID, _ audio: CutawayAudio) {
        guard let index = clipIndex(uid), document.videoTrack[index].isCutaway,
              document.videoTrack[index].cutawayAudio != audio else { return }
        registerUndo("Change B-roll Sound")
        document.videoTrack[index].cutawayAudio = audio
        document.videoTrack[index].enforceCutawayRules()
        documentDidChange()
    }

    func setCutawayCoverAll(_ uid: UUID, _ coverAll: Bool) {
        guard let index = clipIndex(uid), document.videoTrack[index].isCutaway,
              document.videoTrack[index].coverAllAreas != coverAll else { return }
        registerUndo("Change B-roll Area")
        document.videoTrack[index].coverAllAreas = coverAll
        if !coverAll {
            document.videoTrack[index].screenCrop = document
                .cropBlock(at: document.videoTrack[index].startTime)?
                .layout.reference(forTrack: document.videoTrack[index].track)
        }
        document.videoTrack[index].enforceCutawayRules()
        documentDidChange()
    }

    func placeClip(_ uid: UUID, startTime: Double, track: Int) {
        guard let index = clipIndex(uid) else { return }
        if document.videoTrack[index].bumper {
            // Bumpers only move in time; the cropping row has no tracks.
            registerUndo("Move Bumper")
            moveBumper(at: index, to: startTime)
            documentDidChange()
            return
        }
        let oldTrack = document.videoTrack[index].track
        let newTrack = min(max(0, track), document.trackCount - 1)
        // A track without an area there cannot take the clip: keep it put.
        // A cover-all cutaway needs no area, so it may go anywhere.
        let coverAll = document.videoTrack[index].isCutaway && document.videoTrack[index].coverAllAreas
        guard coverAll || canPlace(track: newTrack, at: Self.snap(startTime)) else { return }
        registerUndo(document.videoTrack[index].isCutaway ? "Move B-roll" : "Move Clip")
        document.videoTrack[index].startTime = Self.snap(startTime)
        document.videoTrack[index].track = newTrack
        if document.videoTrack[index].isCutaway, !coverAll {
            // B-roll takes the new track's area with it.
            document.videoTrack[index].screenCrop = document.cropBlock(at: Self.snap(startTime))?
                .layout.reference(forTrack: newTrack)
        }
        resolveLayout(track: newTrack)
        if oldTrack != newTrack { resolveLayout(track: oldTrack) }
        documentDidChange()
    }

    /// An app-resolved ceiling permits raw-file edits without trusting a script
    /// for media metadata. Existing UI callers retain their original policy.
    @discardableResult
    func trimClip(_ uid: UUID, duration: Double, precision: TimelinePrecision = .ordinary,
                  sourceDuration: Double? = nil) -> Result<Void, ClipEditFailure> {
        if precision == .speech {
            guard let clip = clip(uid) else { return .failure(.notFound) }
            guard !clip.bumper else { return .failure(.bumper) }
            guard duration.isFinite, duration >= 0,
                  let start = clip.sourceStart, start.isFinite else { return .failure(.outOfBounds) }
            let rounded = precision.rounded(duration)
            guard rounded >= precision.minimumDuration else { return .failure(.tooShort) }
            return setClipSourceRange(uid, start: start, end: start + rounded * clip.effectiveSpeed,
                                      precision: precision, sourceDuration: sourceDuration)
        }
        guard let index = clipIndex(uid) else { return .failure(.notFound) }
        if document.videoTrack[index].bumper {
            registerUndo("Trim Bumper")
            resizeBumper(at: index, duration: duration)
            documentDidChange()
            return .success(())
        }
        registerUndo("Trim Clip")
        var clip = document.videoTrack[index]
        // The ceiling is measured in source seconds; the clip's duration is
        // screen time, so scale by the playback speed before clamping.
        var maxDuration = Double.greatestFiniteMagnitude
        if let sourceDuration {
            maxDuration = max(0.05, (sourceDuration - (clip.sourceStart ?? 0)) / clip.effectiveSpeed)
        } else if let scene = scene(for: clip) {
            maxDuration = max(0.5, (scene.videoDuration - (clip.sourceStart ?? scene.startTime)) / clip.effectiveSpeed)
        } else if let start = clip.sourceStart, let end = clip.sourceEnd {
            maxDuration = max(0.5, (end - start) / clip.effectiveSpeed)
        }
        clip.duration = min(maxDuration, max(0.5, Self.snap(duration)))
        document.videoTrack[index] = clip
        resolveLayout(track: clip.track)
        documentDidChange()
        return .success(())
    }

    /// Set the clip's source range in absolute source seconds. The screen
    /// duration follows through the playback speed; the timeline start
    /// stays put (sequential tracks repack after it).
    @discardableResult
    func setClipSourceRange(_ uid: UUID, start: Double, end: Double,
                            precision: TimelinePrecision = .ordinary,
                            sourceDuration: Double? = nil) -> Result<Void, ClipEditFailure> {
        if precision == .speech {
            guard let index = clipIndex(uid) else { return .failure(.notFound) }
            var clip = document.videoTrack[index]
            guard !clip.bumper else { return .failure(.bumper) }
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  clip.effectiveSpeed.isFinite, clip.effectiveSpeed > 0 else { return .failure(.outOfBounds) }
            let start = precision.rounded(start), end = precision.rounded(end)
            guard let ceiling = sourceDuration ?? scene(for: clip)?.videoDuration ?? clip.sourceEnd,
                  ceiling.isFinite, start >= 0, start <= ceiling, end <= ceiling else { return .failure(.outOfBounds) }
            let duration = (end - start) / clip.effectiveSpeed
            guard duration.isFinite else { return .failure(.outOfBounds) }
            guard duration >= precision.minimumDuration - 1e-9 else { return .failure(.tooShort) }
            guard clip.sourceStart != start || clip.sourceEnd != end || clip.duration != duration
                || clip.precision != .speech else { return .success(()) }
            registerUndo("Trim Clip", coalescing: "trim-\(uid)")
            clip.sourceStart = start
            clip.sourceEnd = end
            clip.duration = duration
            clip.precision = .speech
            document.videoTrack[index] = clip
            resolveLayout(track: clip.track)
            documentDidChange()
            return .success(())
        }
        guard let index = clipIndex(uid) else { return .failure(.notFound) }
        var clip = document.videoTrack[index]
        var ceiling = Double.greatestFiniteMagnitude
        if let sourceDuration { ceiling = sourceDuration }
        else if let scene = scene(for: clip) { ceiling = scene.videoDuration }
        let newStart = max(0, min(start, ceiling - 0.5))
        let newEnd = max(newStart + 0.5, min(end, ceiling))
        let duration = ((newEnd - newStart) / clip.effectiveSpeed * 10).rounded() / 10
        guard abs((clip.sourceStart ?? -1) - newStart) > 0.001 || abs(clip.duration - duration) > 0.001 else { return .success(()) }
        if clip.bumper {
            registerUndo("Trim Bumper", coalescing: "trim-\(uid)")
            document.videoTrack[index].sourceStart = newStart
            document.videoTrack[index].sourceEnd = newEnd
            resizeBumper(at: index, duration: max(0.5, duration))
            documentDidChange()
            return .success(())
        }
        registerUndo("Trim Clip", coalescing: "trim-\(uid)")
        clip.sourceStart = newStart
        clip.sourceEnd = newEnd
        clip.duration = max(0.5, duration)
        if sourceDuration != nil {
            clip.duration = min(clip.duration, (ceiling - newStart) / clip.effectiveSpeed)
        }
        document.videoTrack[index] = clip
        resolveLayout(track: clip.track)
        documentDidChange()
        return .success(())
    }

    /// A cut preserves source continuity and identity without opening a gap.
    @discardableResult
    func splitClip(_ uid: UUID, at time: Double,
                   precision: TimelinePrecision = .ordinary,
                   sourceDuration: Double? = nil) -> Result<ClipSplitResult, ClipEditFailure> {
        guard let index = clipIndex(uid) else { return .failure(.notFound) }
        let original = document.videoTrack[index]
        guard !original.bumper else { return .failure(.bumper) }
        let at = precision.rounded(time)
        let sourceStart = original.sourceStart ?? scene(for: original)?.startTime
        let ceiling = sourceDuration ?? scene(for: original)?.videoDuration ?? original.sourceEnd
        guard time.isFinite, at.isFinite, original.startTime.isFinite, original.duration.isFinite,
              original.effectiveSpeed.isFinite, original.effectiveSpeed > 0,
              let sourceStart, sourceStart.isFinite, sourceStart >= 0,
              let ceiling, ceiling.isFinite,
              sourceStart + original.sourceSpan <= ceiling + 1e-9,
              at > original.startTime, at < original.startTime + original.duration else {
            return .failure(.outOfBounds)
        }
        guard at - original.startTime >= precision.minimumDuration - 1e-9,
              original.startTime + original.duration - at >= precision.minimumDuration - 1e-9 else {
            return .failure(.tooShort)
        }
        // Resolve a missing start on a value copy; never substitute the media
        // ceiling for the clip's stored trim end, even temporarily.
        var source = original
        source.sourceStart = sourceStart
        if precision == .speech { source.precision = .speech }
        guard let pieces = TimelineSplit.pieces(source, at: at, minimum: precision.minimumDuration, ceiling: ceiling),
              let cut = pieces.tail.sourceStart, let end = pieces.tail.sourceEnd else {
            return .failure(.outOfBounds)
        }
        registerUndo("Split Clip")
        document.videoTrack[index] = pieces.head
        document.videoTrack.insert(pieces.tail, at: index + 1)
        resolveLayout(track: source.track)
        documentDidChange()
        return .success(ClipSplitResult(head: pieces.head.uid, tail: pieces.tail.uid,
                                       at: clip(pieces.tail.uid)?.startTime ?? at,
                                       sourceStart: sourceStart, sourceCut: cut, sourceEnd: end))
    }

    func removeClip(_ uid: UUID) {
        guard let index = clipIndex(uid) else { return }
        registerUndo("Delete Clip")
        let removed = document.videoTrack.remove(at: index)
        if selection == .clip(uid) { selection = nil }
        if removed.bumper, removed.bumperMode == .pause {
            BumperPlanner.removeGap(in: &document, at: removed.startTime, duration: removed.duration)
            resolveAllLayouts()
        } else {
            resolveLayout(track: removed.track)
        }
        documentDidChange()
    }

    func duplicateClip(_ uid: UUID) {
        guard let original = clip(uid) else { return }
        registerUndo("Duplicate Clip")
        var copy = original
        copy.uid = UUID()
        // A duplicate is a new clip, not a piece of the original: it gets
        // its own origin identity so the draw order can separate them.
        copy.originKey = UUID().uuidString
        copy.startTime = Self.snap(original.startTime + original.duration)
        if copy.bumper {
            copy.startTime = nonOverlappingBumperStart(copy.startTime, duration: copy.duration, excluding: nil)
            if copy.bumperMode == .pause {
                BumperPlanner.insertGap(in: &document, at: copy.startTime, duration: copy.duration)
            }
            document.videoTrack.append(copy)
            resolveAllLayouts()
        } else {
            document.videoTrack.append(copy)
            resolveLayout(track: copy.track)
        }
        selection = .clip(copy.uid)
        documentDidChange()
    }

    func updateClip(_ uid: UUID, _ mutate: (inout TimelineClip) -> Void) {
        guard let index = clipIndex(uid) else { return }
        registerUndo("Edit Clip", coalescing: "clip-\(uid)")
        let before = document.videoTrack[index]
        mutate(&document.videoTrack[index])
        document.videoTrack[index].enforceCutawayRules()
        if before.bumper {
            let after = document.videoTrack[index]
            if abs(after.duration - before.duration) > 0.001 {
                document.videoTrack[index].duration = before.duration
                resizeBumper(at: index, duration: after.duration)
            }
            if let bumperIndex = clipIndex(uid), abs(after.startTime - before.startTime) > 0.001 {
                document.videoTrack[bumperIndex].startTime = before.startTime
                moveBumper(at: bumperIndex, to: after.startTime)
            }
        }
        documentDidChange()
    }

    /// Turn one side-by-side podcast clip into two synchronized, pinned
    /// source halves under the built-in 50/50 output layout.
    func splitZoomFeeds(_ uid: UUID, leftName: String, rightName: String,
                        sourceAspect: Double) {
        guard let index = clipIndex(uid),
              ScreenCropStore.layout(named: "50-50 Horizontal") != nil else { return }
        let source = document.videoTrack[index]
        guard !document.videoTrack.contains(where: {
            $0.uid != uid && $0.track == 1 && $0.sceneID == source.sceneID
                && abs($0.startTime - source.startTime) < 0.01
                && abs(($0.sourceStart ?? 0) - (source.sourceStart ?? 0)) < 0.01
                && abs(($0.sourceEnd ?? 0) - (source.sourceEnd ?? 0)) < 0.01
        }) else { return }
        registerUndo("Split Zoom Feeds")
        var left = source
        var right = left
        right.uid = UUID()
        // An independent feed, not a piece of the left one.
        right.originKey = UUID().uuidString
        left.track = 0
        right.track = 1
        left.screenCrop = ScreenCropStore.reference(layout: "50-50 Horizontal", area: "Top")
        right.screenCrop = ScreenCropStore.reference(layout: "50-50 Horizontal", area: "Bottom")
        let windows = PodcastFramingService.splitFeedWindows(sourceAspect: sourceAspect)
        left.areaWindow = windows.left
        right.areaWindow = windows.right
        left.centerStage = false
        right.centerStage = false
        right.muted = true
        // The copies may be B-roll: the role's own rules decide the mute
        // flag and the framing, so the secondary feed's silence has to be
        // expressed as its audio choice, not as a bare mute flag.
        right.cutawayAudio = .muted
        left.enforceCutawayRules()
        right.enforceCutawayRules()
        document.videoTrack[index] = left
        document.videoTrack.append(right)
        document.trackCount = max(document.trackCount, 2)
        document.trackSequential[1] = false
        document.trackSettings[0].label = leftName.isEmpty ? "Left speaker" : leftName
        document.trackSettings[1].label = rightName.isEmpty ? "Right speaker" : rightName
        let block = CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"),
                                  startTime: left.startTime, duration: left.duration)
        document.cropBlocks.append(block)
        document.normalizeCropBlocks(winner: block.uid)
        selection = .clip(left.uid)
        documentDidChange()
    }

    /// Sequential tracks pack end-to-end from 0 in start-time order; free-form
    /// tracks keep clips where the user put them (overlaps render layered).
    /// Bumpers are not part of any track. An overlapping bumper is ignored
    /// and covers whatever the packing puts under it; a pausing bumper is
    /// an obstacle the packing steps over, which keeps its gap open.
    func resolveLayout(track: Int) {
        guard track >= 0, track < TimelineDocument.maxTracks, document.trackSequential[track] else { return }
        let sorted = clips(inTrack: track).sorted { $0.startTime < $1.startTime }
        let pauses = document.videoTrack
            .filter { $0.bumper && $0.bumperMode == .pause }
            .sorted { $0.startTime < $1.startTime }
        var cursor = 0.0
        // B-roll is bound to time: packing neither moves it nor steps over it.
        var pending = sorted.filter { !$0.bumper && !$0.isCutaway }.map(\.uid)
        var position = 0
        while position < pending.count {
            guard let index = clipIndex(pending[position]) else { position += 1; continue }
            for pause in pauses where pause.startTime <= cursor + 0.001 && pause.startTime + pause.duration > cursor {
                cursor = pause.startTime + pause.duration
            }
            let duration = document.videoTrack[index].duration
            // A clip that would run into a pausing bumper is split there so
            // its tail resumes after it; a sliver of a head is pushed whole.
            if let pause = pauses.first(where: {
                $0.startTime > cursor + 0.001 && $0.startTime < cursor + duration - 0.001
            }) {
                let head = pause.startTime - cursor
                if head < document.videoTrack[index].precision.minimumDuration {
                    cursor = pause.startTime + pause.duration
                    continue
                }
                var source = document.videoTrack[index]
                source.startTime = cursor
                // Legacy file clips may not carry an explicit end; packing
                // already knows the played window and supplies it to the math.
                source.sourceStart = source.sourceStart ?? 0
                let ceiling = max(source.sourceEnd ?? 0,
                                  (source.sourceStart ?? 0) + duration * source.effectiveSpeed)
                guard let pieces = TimelineSplit.pieces(source, at: pause.startTime,
                                                       minimum: source.precision == .speech ? 0.05 : 0.001, ceiling: ceiling) else {
                    cursor = pause.startTime + pause.duration
                    continue
                }
                document.videoTrack[index] = pieces.head
                document.videoTrack.append(pieces.tail)
                pending.insert(pieces.tail.uid, at: position + 1)
                cursor = pause.startTime + pause.duration
                position += 1
                continue
            }
            document.videoTrack[index].startTime = cursor
            cursor += duration
            position += 1
        }
    }

    func setTrackSequential(_ sequential: Bool, track: Int) {
        guard track >= 0, track < TimelineDocument.maxTracks else { return }
        registerUndo("Change Track Layout")
        document.trackSequential[track] = sequential
        resolveLayout(track: track)
        documentDidChange()
    }

    // MARK: - Cropping row

    func cropBlockIndex(_ uid: UUID) -> Int? {
        document.cropBlocks.firstIndex { $0.uid == uid }
    }

    func cropBlock(_ uid: UUID) -> CropBlockItem? {
        cropBlockIndex(uid).map { document.cropBlocks[$0] }
    }

    /// Layouts a block can use: Full Screen, then every Screen Crop resource.
    static func availableCropLayouts() -> [CropLayoutRef] {
        [.fullScreen] + ScreenCropStore.all().filter { !$0.areas.isEmpty }.map { CropLayoutRef(name: $0.name) }
    }

    /// Put a layout on the row at `time` (the playhead by default). The new
    /// block wins over whatever it overlaps.
    @discardableResult
    func addCropBlock(_ layout: CropLayoutRef, at time: Double? = nil,
                      duration: Double = CropBlockItem.defaultDuration) -> UUID {
        registerUndo("Add Crop")
        let start = Self.snap(time ?? playhead)
        let block = CropBlockItem(layout: layout, startTime: start, duration: max(0.5, Self.snap(duration)))
        document.cropBlocks.append(block)
        document.normalizeCropBlocks(winner: block.uid)
        selection = .crop(block.uid)
        documentDidChange()
        return block.uid
    }

    /// Select a block and bring the playhead inside it, so the preview
    /// shows a still of that layout with the clips under it.
    func selectCropBlock(_ uid: UUID) {
        guard let block = cropBlock(uid) else { return }
        selection = .crop(uid)
        if playhead < block.startTime - 0.001 || playhead >= block.endTime - 0.001 {
            playhead = Self.snap(block.startTime)
        }
    }

    /// Clips on `track` that overlap the block's time range, in time order.
    func clips(inTrack track: Int, within block: CropBlockItem) -> [TimelineClip] {
        clips(inTrack: track)
            .filter { $0.startTime < block.endTime - 0.001 && block.startTime < $0.startTime + $0.duration - 0.001 }
            .sorted { $0.startTime < $1.startTime }
    }

    /// Change which layout a block shows. Fewer areas can strand clips on
    /// the higher tracks — they stay, flagged, until moved.
    func setCropLayout(_ layout: CropLayoutRef, for uid: UUID) {
        guard let index = cropBlockIndex(uid) else { return }
        registerUndo("Change Crop")
        document.cropBlocks[index].layout = layout
        documentDidChange()
    }

    /// Move a block's end. Growing eats into the following blocks; shrinking
    /// leaves Full Screen behind.
    func resizeCropBlock(_ uid: UUID, duration: Double) {
        guard let index = cropBlockIndex(uid) else { return }
        registerUndo("Resize Crop")
        document.cropBlocks[index].duration = max(0.5, Self.snap(duration))
        document.normalizeCropBlocks(winner: uid)
        documentDidChange()
    }

    /// Split the block under `time` into two so the second half can take a
    /// different layout.
    func splitCropBlock(at time: Double? = nil) {
        let at = Self.snap(time ?? playhead)
        guard let block = document.cropBlock(at: at),
              at > block.startTime + 0.499, at < block.endTime - 0.499,
              let index = cropBlockIndex(block.uid) else { return }
        registerUndo("Split Crop")
        var tail = block
        tail.uid = UUID()
        tail.startTime = at
        tail.duration = block.endTime - at
        document.cropBlocks[index].duration = at - block.startTime
        document.cropBlocks.append(tail)
        selection = .crop(tail.uid)
        documentDidChange()
    }

    /// Remove a block; Full Screen takes its place.
    func removeCropBlock(_ uid: UUID) {
        guard let index = cropBlockIndex(uid) else { return }
        registerUndo("Delete Crop")
        document.cropBlocks.remove(at: index)
        if selection == .crop(uid) { selection = nil }
        documentDidChange()
    }

    func updateTrackSettings(_ track: Int, _ mutate: (inout TrackSettings) -> Void) {
        guard track >= 0, track < document.trackSettings.count else { return }
        registerUndo("Edit Track", coalescing: "track-\(track)")
        mutate(&document.trackSettings[track])
        documentDidChange()
    }

    // MARK: - Sound track

    func addSound(name: String, at time: Double? = nil, duration: Double = 10) {
        registerUndo("Add Music")
        let start = Self.snap(time ?? playhead)
        let item = SoundItem(name: name, volume: 3, startTime: start, duration: duration)
        document.soundTrack.append(item)
        selection = .sound(item.uid)
        documentDidChange()
    }

    func soundIndex(_ uid: UUID) -> Int? {
        document.soundTrack.firstIndex { $0.uid == uid }
    }

    func updateSound(_ uid: UUID, _ mutate: (inout SoundItem) -> Void) {
        guard let index = soundIndex(uid) else { return }
        registerUndo("Edit Music", coalescing: "sound-\(uid)")
        mutate(&document.soundTrack[index])
        document.soundTrack[index].startTime = max(0, document.soundTrack[index].startTime)
        document.soundTrack[index].duration = max(0.5, document.soundTrack[index].duration)
        documentDidChange()
    }

    func removeSound(_ uid: UUID) {
        guard soundIndex(uid) != nil else { return }
        registerUndo("Delete Music")
        document.soundTrack.removeAll { $0.uid == uid }
        if selection == .sound(uid) { selection = nil }
        documentDidChange()
    }

    // MARK: - Text overlays

    func addText(at time: Double? = nil) -> UUID {
        registerUndo("Add Text")
        let start = Self.snap(time ?? playhead)
        var item = TextOverlayItem(text: "Text", startTime: start, endTime: start + 3)
        item.xFrac = 0.5
        item.yFrac = 0.8
        document.textOverlays.append(item)
        selection = .text(item.uid)
        documentDidChange()
        return item.uid
    }

    // MARK: - Overlay blocks

    /// Place an overlay template at the playhead as ONE timeline unit: the
    /// whole composition (a snapshot — later template edits don't touch it)
    /// moves and trims as a single block.
    func addOverlayBlock(name: String, composition: OverlayComposition, at time: Double? = nil) {
        guard !composition.isEmpty else { return }
        registerUndo("Add Overlay")
        var block = OverlayBlockItem()
        block.name = name
        block.composition = composition
        block.startTime = Self.snap(time ?? playhead)
        block.duration = max(1, (composition.duration * 10).rounded() / 10)
        document.overlayBlocks.append(block)
        selection = .overlay(block.uid)
        documentDidChange()
    }

    func overlayBlockIndex(_ uid: UUID) -> Int? {
        document.overlayBlocks.firstIndex { $0.uid == uid }
    }

    func overlayBlock(_ uid: UUID) -> OverlayBlockItem? {
        overlayBlockIndex(uid).map { document.overlayBlocks[$0] }
    }

    func updateOverlayBlock(_ uid: UUID, _ mutate: (inout OverlayBlockItem) -> Void) {
        guard let index = overlayBlockIndex(uid) else { return }
        registerUndo("Edit Overlay", coalescing: "overlay-\(uid)")
        mutate(&document.overlayBlocks[index])
        let block = document.overlayBlocks[index]
        document.overlayBlocks[index].startTime = max(0, block.startTime)
        document.overlayBlocks[index].duration = max(0.5, block.duration)
        documentDidChange()
    }

    func removeOverlayBlock(_ uid: UUID) {
        guard overlayBlockIndex(uid) != nil else { return }
        registerUndo("Delete Overlay")
        document.overlayBlocks.removeAll { $0.uid == uid }
        if selection == .overlay(uid) { selection = nil }
        documentDidChange()
    }

    func textIndex(_ uid: UUID) -> Int? {
        document.textOverlays.firstIndex { $0.uid == uid }
    }

    func textItem(_ uid: UUID) -> TextOverlayItem? {
        textIndex(uid).map { document.textOverlays[$0] }
    }

    func updateText(_ uid: UUID, _ mutate: (inout TextOverlayItem) -> Void) {
        guard let index = textIndex(uid) else { return }
        registerUndo("Edit Text", coalescing: "text-\(uid)")
        mutate(&document.textOverlays[index])
        let item = document.textOverlays[index]
        document.textOverlays[index].startTime = max(0, item.startTime)
        document.textOverlays[index].endTime = max(item.startTime + 0.5, item.endTime)
        documentDidChange()
    }

    func removeText(_ uid: UUID) {
        guard textIndex(uid) != nil else { return }
        registerUndo("Delete Text")
        document.textOverlays.removeAll { $0.uid == uid }
        if selection == .text(uid) { selection = nil }
        documentDidChange()
    }

    // MARK: - Image overlays

    @discardableResult
    func addImage(path: String, at time: Double? = nil) -> UUID {
        registerUndo("Add Image")
        let start = Self.snap(time ?? playhead)
        let item = ImageOverlayItem(path: path, startTime: start, endTime: start + 3)
        document.imageOverlays.append(item)
        selection = .image(item.uid)
        documentDidChange()
        return item.uid
    }

    /// A suggested Library photo, placed as an image overlay for a fixed
    /// length. It is not B-roll: it has no track and no area, and nothing
    /// on the timeline moves for it.
    @discardableResult
    func addPhotoOverlay(path: String, at time: Double? = nil, length: Double = 3) -> UUID {
        let start = Self.snap(time ?? playhead)
        let uid = addImage(path: path, at: start)
        updateImage(uid) { $0.endTime = start + max(0.5, length) }
        return uid
    }

    func imageIndex(_ uid: UUID) -> Int? {
        document.imageOverlays.firstIndex { $0.uid == uid }
    }

    func imageItem(_ uid: UUID) -> ImageOverlayItem? {
        imageIndex(uid).map { document.imageOverlays[$0] }
    }

    func updateImage(_ uid: UUID, _ mutate: (inout ImageOverlayItem) -> Void) {
        guard let index = imageIndex(uid) else { return }
        registerUndo("Edit Image", coalescing: "image-\(uid)")
        mutate(&document.imageOverlays[index])
        let item = document.imageOverlays[index]
        document.imageOverlays[index].startTime = max(0, item.startTime)
        document.imageOverlays[index].endTime = max(item.startTime + 0.5, item.endTime)
        documentDidChange()
    }

    func removeImage(_ uid: UUID) {
        guard imageIndex(uid) != nil else { return }
        registerUndo("Delete Image")
        document.imageOverlays.removeAll { $0.uid == uid }
        if selection == .image(uid) { selection = nil }
        documentDidChange()
    }

}
