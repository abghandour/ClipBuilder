import Foundation
import Observation

enum TimelineSelection: Equatable {
    case clip(UUID)
    case sound(UUID)
    case text(UUID)
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

    private(set) var profileName = ""
    private(set) var scenes: [SceneRecord] = []
    private var scenesByID: [Int64: SceneRecord] = [:]
    private var saveTask: Task<Void, Never>?
    private var suppressAutosave = false

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
        }
    }

    private func resetUndoHistory() {
        undoManager?.removeAllActions(withTarget: self)
        lastUndoKey = nil
    }

    // MARK: - Load / persistence

    func load(profileName: String) {
        saveTask?.cancel()
        resetUndoHistory()
        self.profileName = profileName
        suppressAutosave = true
        document = BuilderStateStore.load(profileName: profileName) ?? TimelineDocument()
        selection = nil
        playhead = 0
        hydrateClips()
        suppressAutosave = false
    }

    /// Replace the working document (e.g. "Open in Builder" from the Library).
    func loadDocument(_ newDocument: TimelineDocument) {
        registerUndo("Replace Timeline")
        document = newDocument
        selection = nil
        hydrateClips()
        documentDidChange()
    }

    func clear() {
        registerUndo("Clear Timeline")
        document = TimelineDocument()
        selection = nil
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
    }

    private func documentDidChange() {
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
        return max(clipEnd, soundEnd, textEnd)
    }

    func clips(inTrack track: Int) -> [TimelineClip] {
        document.videoTrack.filter { $0.track == track }
    }

    /// Greedy interval packing for overlap display in free-form mode: each
    /// clip gets the lowest row whose previous clip ended before it starts.
    func rowLayout(forTrack track: Int) -> (rows: [UUID: Int], rowCount: Int) {
        let clips = clips(inTrack: track).sorted {
            $0.startTime == $1.startTime ? $0.stackOrder < $1.stackOrder : $0.startTime < $1.startTime
        }
        var rowEnds: [Double] = []
        var rows: [UUID: Int] = [:]
        for clip in clips {
            if let row = rowEnds.firstIndex(where: { $0 <= clip.startTime + 0.001 }) {
                rows[clip.uid] = row
                rowEnds[row] = clip.startTime + clip.duration
            } else {
                rows[clip.uid] = rowEnds.count
                rowEnds.append(clip.startTime + clip.duration)
            }
        }
        return (rows, max(1, rowEnds.count))
    }

    func laneHeight(forTrack track: Int) -> CGFloat {
        CGFloat(rowLayout(forTrack: track).rowCount) * Self.rowHeight
    }

    /// Map a vertical drag offset from one video lane to a target track index.
    func trackIndex(fromTrack track: Int, verticalDelta: CGFloat) -> Int {
        guard document.trackCount > 1 else { return 0 }
        var centers: [CGFloat] = []
        var y: CGFloat = 0
        for index in 0..<document.trackCount {
            let height = laneHeight(forTrack: index)
            centers.append(y + height / 2)
            y += height + Self.laneSpacing
        }
        let target = centers[min(track, centers.count - 1)] + verticalDelta
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
        (clip.sourceStart ?? 0) + max(0, min(clip.duration, time - clip.startTime))
    }

    // MARK: - Clip mutations

    func addScene(_ scene: SceneRecord, at time: Double? = nil, track: Int = 0) {
        registerUndo("Add Clip")
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
        document.videoTrack.append(clip)
        resolveLayout(track: targetTrack)
        selection = .clip(clip.uid)
        documentDidChange()
    }

    func placeClip(_ uid: UUID, startTime: Double, track: Int) {
        guard let index = clipIndex(uid) else { return }
        registerUndo("Move Clip")
        let oldTrack = document.videoTrack[index].track
        let newTrack = min(max(0, track), document.trackCount - 1)
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
        var maxDuration = Double.greatestFiniteMagnitude
        if let scene = scene(for: clip) {
            maxDuration = max(0.5, scene.videoDuration - (clip.sourceStart ?? scene.startTime))
        } else if let start = clip.sourceStart, let end = clip.sourceEnd {
            maxDuration = max(0.5, end - start)
        }
        clip.duration = min(maxDuration, max(0.5, Self.snap(duration)))
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
        guard track >= 0, track < 3, document.trackSequential[track] else { return }
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
        guard track >= 0, track < 3 else { return }
        registerUndo("Change Track Layout")
        document.trackSequential[track] = sequential
        resolveLayout(track: track)
        documentDidChange()
    }

    func setTrackCount(_ count: Int) {
        let clamped = min(3, max(1, count))
        guard clamped != document.trackCount else { return }
        registerUndo("Change Track Count")
        document.trackCount = clamped
        // Pull clips from hidden tracks back onto the last visible one.
        for index in document.videoTrack.indices where document.videoTrack[index].track >= clamped {
            document.videoTrack[index].track = clamped - 1
        }
        resolveLayout(track: clamped - 1)
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

    // MARK: - Document toggles

    func setIncludeIntro(_ include: Bool) {
        guard include != document.includeIntro else { return }
        registerUndo("Toggle Intro")
        document.includeIntro = include
        documentDidChange()
    }

    func setIncludeOutro(_ include: Bool) {
        guard include != document.includeOutro else { return }
        registerUndo("Toggle Outro")
        document.includeOutro = include
        documentDidChange()
    }
}
