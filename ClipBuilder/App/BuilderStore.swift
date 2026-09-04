import Foundation
import Observation

enum TimelineSelection: Equatable {
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
    var document = TimelineDocument()
    var selection: TimelineSelection?
    var pointsPerSecond: CGFloat = 60          // timeline zoom
    var playhead: Double = 0
    /// The video track the user last clicked (its header or one of its
    /// clips). The cropping row paints that track's area green.
    var focusedTrack: Int?

    private(set) var profileName = ""
    private(set) var scenes: [SceneRecord] = []
    private var scenesByID: [Int64: SceneRecord] = [:]
    private var saveTask: Task<Void, Never>?
    private var suppressAutosave = false
    @ObservationIgnored private var cachedTimelineLayout: TimelineLayoutSnapshot?

    /// Window undo manager, injected by BuilderView. Registering with the
    /// window (instead of replacing the Undo menu command) keeps text-field
    /// editing on the field editor's own undo stack.
    weak var undoManager: UndoManager?
    private var lastUndoKey: String?
    private var lastUndoDate = Date.distantPast
    private static let undoCoalesceWindow: TimeInterval = 1.0

    static let rowHeight: CGFloat = 56
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
        guard let undoManager else { return }
        let snapshot = document
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
        undoManager?.removeAllActions(withTarget: self)
        lastUndoKey = nil
    }

    // MARK: - Load / persistence

    func load(profileName: String) {
        saveTask?.cancel()
        resetUndoHistory()
        self.profileName = profileName
        // Scene ids are per-profile; the previous profile's rows must not
        // hydrate this profile's clips. The library refresh refills them.
        scenes = []
        scenesByID = [:]
        suppressAutosave = true
        document = BuilderStateStore.load(profileName: profileName) ?? TimelineDocument()
        document.migrateLegacyScreenCrops()
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
        document = TimelineDocument()
        document.normalizeCropBlocks()
        cachedTimelineLayout = nil
        selection = nil
        focusedTrack = nil
        playhead = 0
        BuilderStateStore.clear(profileName: profileName)
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
        guard !scenesByID.isEmpty else { return }
        for index in document.videoTrack.indices {
            var clip = document.videoTrack[index]
            guard let sceneID = clip.sceneID, let scene = scenesByID[sceneID] else { continue }
            clip.sceneFullDuration = (scene.duration * 10).rounded() / 10
            if clip.videoFile == nil { clip.videoFile = scene.videoPath }
            if clip.sourceStart == nil { clip.sourceStart = scene.startTime }
            if clip.duration <= 0 { clip.duration = clip.sceneFullDuration ?? 0 }
            clip.wide = scene.wide
            document.videoTrack[index] = clip
        }
        cachedTimelineLayout = nil
    }

    private func documentDidChange() {
        // The cropping row always tiles the content; the track count follows it.
        document.normalizeCropBlocks()
        cachedTimelineLayout = nil
        guard !suppressAutosave else { return }
        let snapshot = document
        let name = profileName
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // Detached: this fires continuously during editing, and a plain
            // Task would inherit main-actor isolation for the encode + write.
            await Task.detached(priority: .utility) {
                BuilderStateStore.save(snapshot, profileName: name)
            }.value
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

    func clips(inTrack track: Int) -> [TimelineClip] {
        document.videoTrack.filter { $0.track == track }
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

    /// Map a vertical drag offset from one video lane to a target track index.
    func trackIndex(fromTrack track: Int, verticalDelta: CGFloat) -> Int {
        guard document.trackCount > 1 else { return 0 }
        let layout = timelineLayout()
        var centers: [CGFloat] = []
        var y: CGFloat = 0
        for index in 0..<document.trackCount {
            let height = CGFloat(layout.videoTracks[index].rowCount) * Self.rowHeight
            centers.append(y + height / 2)
            y += height + Self.laneSpacing
        }
        let sourceIndex = min(max(0, track), centers.count - 1)
        let target = centers[sourceIndex] + verticalDelta
        let nearest = centers.enumerated().min { abs($0.element - target) < abs($1.element - target) }
        return nearest?.offset ?? track
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

    func placeClip(_ uid: UUID, startTime: Double, track: Int) {
        guard let index = clipIndex(uid) else { return }
        let oldTrack = document.videoTrack[index].track
        let newTrack = min(max(0, track), document.trackCount - 1)
        // A track without an area there cannot take the clip: keep it put.
        guard canPlace(track: newTrack, at: Self.snap(startTime)) else { return }
        registerUndo("Move Clip")
        document.videoTrack[index].startTime = Self.snap(startTime)
        document.videoTrack[index].track = newTrack
        resolveLayout(track: newTrack)
        if oldTrack != newTrack {
            resolveLayout(track: oldTrack)
        }
        documentDidChange()
    }

    func trimClip(_ uid: UUID, duration: Double) {
        guard let index = clipIndex(uid) else { return }
        registerUndo("Trim Clip")
        var clip = document.videoTrack[index]
        // The ceiling is measured in source seconds; the clip's duration is
        // screen time, so scale by the playback speed before clamping.
        var maxDuration = Double.greatestFiniteMagnitude
        if let scene = scene(for: clip) {
            maxDuration = max(0.5, (scene.videoDuration - (clip.sourceStart ?? scene.startTime)) / clip.effectiveSpeed)
        } else if let start = clip.sourceStart, let end = clip.sourceEnd {
            maxDuration = max(0.5, (end - start) / clip.effectiveSpeed)
        }
        clip.duration = min(maxDuration, max(0.5, Self.snap(duration)))
        document.videoTrack[index] = clip
        resolveLayout(track: clip.track)
        documentDidChange()
    }

    /// Set the clip's source range in absolute source seconds. The screen
    /// duration follows through the playback speed; the timeline start
    /// stays put (sequential tracks repack after it).
    func setClipSourceRange(_ uid: UUID, start: Double, end: Double) {
        guard let index = clipIndex(uid) else { return }
        var clip = document.videoTrack[index]
        var ceiling = Double.greatestFiniteMagnitude
        if let scene = scene(for: clip) { ceiling = scene.videoDuration }
        let newStart = max(0, min(start, ceiling - 0.5))
        let newEnd = max(newStart + 0.5, min(end, ceiling))
        let duration = ((newEnd - newStart) / clip.effectiveSpeed * 10).rounded() / 10
        guard abs((clip.sourceStart ?? -1) - newStart) > 0.001 || abs(clip.duration - duration) > 0.001 else { return }
        registerUndo("Trim Clip", coalescing: "trim-\(uid)")
        clip.sourceStart = newStart
        clip.sourceEnd = newEnd
        clip.duration = max(0.5, duration)
        document.videoTrack[index] = clip
        resolveLayout(track: clip.track)
        documentDidChange()
    }

    func removeClip(_ uid: UUID) {
        guard let index = clipIndex(uid) else { return }
        registerUndo("Delete Clip")
        let track = document.videoTrack[index].track
        document.videoTrack.remove(at: index)
        if selection == .clip(uid) { selection = nil }
        resolveLayout(track: track)
        documentDidChange()
    }

    func duplicateClip(_ uid: UUID) {
        guard let original = clip(uid) else { return }
        registerUndo("Duplicate Clip")
        var copy = original
        copy.uid = UUID()
        copy.startTime = Self.snap(original.startTime + original.duration)
        document.videoTrack.append(copy)
        resolveLayout(track: copy.track)
        selection = .clip(copy.uid)
        documentDidChange()
    }

    func updateClip(_ uid: UUID, _ mutate: (inout TimelineClip) -> Void) {
        guard let index = clipIndex(uid) else { return }
        registerUndo("Edit Clip", coalescing: "clip-\(uid)")
        mutate(&document.videoTrack[index])
        documentDidChange()
    }

    /// Sequential tracks pack end-to-end from 0 in start-time order; free-form
    /// tracks keep clips where the user put them (overlaps render layered).
    func resolveLayout(track: Int) {
        guard track >= 0, track < TimelineDocument.maxTracks, document.trackSequential[track] else { return }
        let sorted = clips(inTrack: track).sorted { $0.startTime < $1.startTime }
        var cursor = 0.0
        for clip in sorted {
            if let index = clipIndex(clip.uid) {
                document.videoTrack[index].startTime = cursor
                cursor += document.videoTrack[index].duration
            }
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
