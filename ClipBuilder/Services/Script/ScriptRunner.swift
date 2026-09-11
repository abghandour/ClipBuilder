import Foundation

nonisolated enum CommandOutcome: Codable, Sendable, Equatable {
    case applied(actualValues: ScriptValue, createdIDs: [String: String], warnings: [String])
    case unchanged(reason: String)
    case refused(code: String, reason: String)

    var isRefused: Bool { if case .refused = self { true } else { false } }
    var createdIDs: [String: String] {
        if case .applied(_, let ids, _) = self { ids } else { [:] }
    }
}

nonisolated struct BuilderScriptResult: Codable, Sendable, Equatable {
    var outcomes: [CommandOutcome]
    var completed: Bool
    var hasDocumentChanges: Bool
}

/// No suspension points in phase 1a: each list completes on MainActor before
/// another call can enter. Future prerequisite adapters need an admission queue.
@MainActor
final class ScriptRunner {
    nonisolated static let maximumBytes = 256 * 1024
    nonisolated static let maximumSteps = 200
    nonisolated static let maximumAffectedItems = 2000
    nonisolated static let maximumResultBytes = 1024 * 1024
    private(set) var diagnosticDocument: TimelineDocument?
    private var bindings: [String: UUID] = [:]
    private var boundNames: Set<String> = []
    private var affectedItems = 0

    nonisolated static func decode(_ data: Data) throws -> [BuilderScriptStep] {
        guard data.count <= maximumBytes else { throw ScriptError.invalid("Script exceeds 256 KiB.") }
        let steps = try JSONDecoder().decode([BuilderScriptStep].self, from: data)
        guard steps.count <= maximumSteps else { throw ScriptError.invalid("Script exceeds 200 steps.") }
        return steps
    }

    func run(_ steps: [BuilderScriptStep], model: BuilderTimelineModel,
             library: ScriptLibrarySnapshot) -> [CommandOutcome] {
        guard model.mode == .transient else {
            return [.refused(code: "live_model", reason: "Scripts require a transient model.")]
        }
        guard steps.count <= Self.maximumSteps else {
            return [.refused(code: "limit", reason: "Too many steps.")]
        }
        diagnosticDocument = nil
        let baseline = model.document
        let selection = model.selection
        let playhead = model.playhead
        let focusedTrack = model.focusedTrack
        let zoom = model.pointsPerSecond
        bindings = [:]; boundNames = []; affectedItems = 0
        var outcomes: [CommandOutcome] = []
        var resultBytes = 0
        let started = ContinuousClock.now
        for step in steps {
            if started.duration(to: .now) >= .seconds(10) {
                outcomes.append(.refused(code: "timeout", reason: "Preview exceeded ten seconds.")); break
            }
            if Task.isCancelled {
                outcomes.append(.refused(code: "cancelled", reason: "Run cancelled.")); break
            }
            do {
                if let name = step.bind {
                    guard !name.isEmpty, name.count <= 64,
                          name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                          !boundNames.contains(name), Self.canBind(step.command) else {
                        throw ScriptError.invalid("Binding must be unique and name an ID-producing command.")
                    }
                }
                // Encoding also rejects nonfinite programmatic commands; the
                // strict decoder validates fields for callers bypassing JSON.
                let encoded = try JSONEncoder().encode(step.command)
                guard encoded.count <= Self.maximumBytes else { throw ScriptError.invalid("Command too large.") }
                _ = try JSONDecoder().decode(BuilderCommand.self, from: encoded)
                // Keep queries, store normalization/packing, placement/area
                // checks and the command diff under the same resource snapshot.
                let outcome = try library.withLayouts { try execute(step.command, model: model, library: library) }
                if let name = step.bind, !outcome.isRefused {
                    guard !outcome.createdIDs.isEmpty else {
                        throw ScriptError.invalid("The requested item merged away and has no bindable ID.")
                    }
                    boundNames.insert(name)
                    for (key, value) in outcome.createdIDs {
                        if let uid = UUID(uuidString: value) { bindings[name + "." + key] = uid }
                    }
                    let preferred = outcome.createdIDs["tail"] ?? outcome.createdIDs["clip"]
                        ?? outcome.createdIDs["overlay"] ?? outcome.createdIDs["block"] ?? outcome.createdIDs["sound"]
                    if let preferred, let uid = UUID(uuidString: preferred) { bindings[name] = uid }
                }
                resultBytes += try JSONEncoder().encode(outcome).count
                guard resultBytes <= Self.maximumResultBytes else {
                    throw ScriptError.invalid("Run results exceed 1 MiB; use smaller queries or fewer steps.")
                }
                outcomes.append(outcome)
                if outcome.isRefused { break }
            } catch let failure as ClipEditFailure {
                outcomes.append(.refused(code: failure.rawValue, reason: failure.reason))
                break
            } catch {
                outcomes.append(.refused(code: "invalid_command", reason: error.localizedDescription))
                break
            }
        }
        if outcomes.contains(where: \.isRefused) {
            diagnosticDocument = model.document
            library.withLayouts {
                model.seed(document: baseline, scenes: model.scenes,
                           driveBackedPaths: model.driveBackedPaths, selection: selection,
                           playhead: playhead, focusedTrack: focusedTrack, zoom: zoom)
            }
        }
        return outcomes
    }

    private static func canBind(_ command: BuilderCommand) -> Bool {
        switch command {
        case .splitClip, .duplicateClip, .addScene, .addCutaway, .addCropBlock,
             .addBumper, .addSound, .addText, .addImage: true
        default: false
        }
    }

    private func resolve(_ reference: String) throws -> UUID {
        if reference.hasPrefix("$"), let uid = bindings[String(reference.dropFirst())] { return uid }
        if let uid = UUID(uuidString: reference) { return uid }
        throw ScriptError.invalid("Unknown session ID or binding: \(reference)")
    }

    private func execute(_ command: BuilderCommand, model: BuilderTimelineModel,
                         library: ScriptLibrarySnapshot) throws -> CommandOutcome {
        let before = model.document
        var created: [String: String] = [:]
        var warnings: [String] = []
        var actual: ScriptValue?
        var target: UUID?
        @MainActor func time(_ value: Double, positive: Bool = false) throws {
            guard value.isFinite, value >= (positive ? 0.001 : 0), value <= 86400 else {
                throw ScriptError.invalid("Time must be finite and within one day.")
            }
        }
        @MainActor func track(_ value: Int) throws {
            guard (0..<model.document.trackCount).contains(value) else { throw ScriptError.invalid("Track is not visible.") }
        }
        @MainActor func clip(_ reference: String) throws -> TimelineClip {
            let uid = try resolve(reference)
            guard let value = model.clip(uid) else { throw ClipEditFailure.notFound }
            target = uid
            return value
        }
        @MainActor func scene(_ id: Int64) throws -> SceneRecord {
            guard let value = library.scenes.first(where: { $0.id == id }),
                  value.videoDuration.isFinite, value.videoDuration > 0 else {
                throw ScriptError.invalid("Scene is unavailable or outside this project.")
            }
            return value
        }
        @MainActor func layout(_ name: String) throws -> CropLayoutRef {
            let ref = CropLayoutRef(name: name)
            guard ref.isFullScreen || library.layouts.contains(where: { $0.name == name && !$0.areas.isEmpty }) else {
                throw ScriptError.invalid("Layout is not in the resource snapshot.")
            }
            return ref
        }
        @MainActor func placement(_ trackIndex: Int, _ start: Double, coverAll: Bool = false) throws {
            try track(trackIndex); try time(start)
            guard coverAll || model.canPlace(track: trackIndex, at: BuilderTimelineModel.snap(start)) else {
                throw ScriptError.invalid("Track has no area at that time.")
            }
        }
        @MainActor func charge(_ count: Int) throws {
            guard affectedItems + count <= Self.maximumAffectedItems else { throw ScriptError.invalid("Affected-item limit exceeded.") }
            affectedItems += count
        }
        @MainActor func addedClip() throws -> UUID {
            let origins = Set(before.videoTrack.map(\.originKey))
            guard let new = model.document.videoTrack.first(where: { !origins.contains($0.originKey) }) else {
                throw ScriptError.invalid("Store refused the insertion.")
            }
            return new.uid
        }
        if case .query(let query) = command {
            let result = try query.execute(model: model, library: library, resolve: resolve)
            let data = try JSONEncoder().encode(result)
            guard data.count <= Self.maximumBytes else { throw ScriptError.invalid("Query result too large; request a smaller page.") }
            return .applied(actualValues: try JSONDecoder().decode(ScriptValue.self, from: data), createdIDs: [:], warnings: [])
        }
        // Packing and pause gaps can touch every lane; reserve their worst
        // case before mutation, rather than counting a bulk edit as one item.
        try charge(max(1, before.videoTrack.count + before.soundTrack.count
                       + before.textOverlays.count + before.imageOverlays.count
                       + before.overlayBlocks.count + before.cropBlocks.count))
        switch command {
        case .removeClip(let reference):
            model.removeClip(try clip(reference).uid)
        case .removeClips(let filter):
            try filter.validate()
            if let value = filter.track { try track(value) }
            let ids = model.document.videoTrack.filter { filter.matches($0, scene: model.scene(for: $0)) }.map(\.uid)
            try charge(ids.count)
            for uid in ids { model.removeClip(uid) }
            actual = .object(["removed": .array(ids.map { .string($0.uuidString) })])
        case .splitClip(let reference, let at, let policy):
            guard at.isFinite, (0...86400).contains(at) else { throw ClipEditFailure.outOfBounds }
            let value = try clip(reference)
            guard !value.bumper else { throw ClipEditFailure.bumper }
            guard let ceiling = library.sourceDuration(for: value) else { throw ClipEditFailure.outOfBounds }
            let split = try model.splitClip(value.uid, at: at, precision: policy ?? .ordinary,
                                            sourceDuration: ceiling).get()
            created = ["head": split.head.uuidString, "tail": split.tail.uuidString]
            actual = ScriptValue.stored(split)
        case .trimClip(let reference, let duration, let policy):
            guard duration.isFinite, (0...86400).contains(duration) else { throw ClipEditFailure.outOfBounds }
            let value = try clip(reference)
            let precision = policy ?? .ordinary
            if value.bumper && precision == .speech { throw ClipEditFailure.bumper }
            guard let ceiling = value.bumper ? value.sourceEnd : library.sourceDuration(for: value),
                  ceiling.isFinite, let start = value.sourceStart, start.isFinite,
                  start >= 0, start < ceiling else { throw ClipEditFailure.outOfBounds }
            try model.trimClip(value.uid, duration: duration, precision: precision, sourceDuration: ceiling).get()
        case .setSourceRange(let reference, let start, let end, let policy):
            guard start.isFinite, end.isFinite, (0...86400).contains(start), (0...86400).contains(end) else {
                throw ClipEditFailure.outOfBounds
            }
            let value = try clip(reference)
            let precision = policy ?? .ordinary
            if value.bumper && precision == .speech { throw ClipEditFailure.bumper }
            guard let ceiling = value.bumper ? value.sourceEnd : library.sourceDuration(for: value),
                  ceiling.isFinite, end > start, end <= ceiling else { throw ClipEditFailure.outOfBounds }
            try model.setClipSourceRange(value.uid, start: start, end: end,
                                         precision: precision, sourceDuration: ceiling).get()
        case .placeClip(let reference, let start, let trackIndex):
            let value = try clip(reference)
            try placement(trackIndex, start, coverAll: value.bumper || value.coverAllAreas)
            model.placeClip(value.uid, startTime: start, track: trackIndex)
        case .addScene(let id, let at, let trackIndex):
            let value = try scene(id)
            let end = model.clips(inTrack: trackIndex).map { $0.startTime + $0.duration }.max() ?? 0
            try placement(trackIndex, at ?? end)
            let screenDuration = (value.duration * 10).rounded() / 10
            guard value.startTime.isFinite, value.endTime.isFinite, value.startTime >= 0,
                  value.endTime > value.startTime, screenDuration >= 0.05,
                  value.startTime + screenDuration <= value.videoDuration + 1e-9 else {
                throw ScriptError.invalid("Scene has invalid source bounds after ordinary rounding.")
            }
            model.addScene(value, at: at, track: trackIndex)
            target = try addedClip(); created["clip"] = target?.uuidString
        case .addCutaway(let sceneID, let videoID, let at, let trackIndex, let duration, let sourceStart, let coverAll):
            try placement(trackIndex, at ?? model.playhead, coverAll: coverAll)
            if let duration { try time(duration, positive: true) }
            if let sourceStart { try time(sourceStart) }
            let source: CutawaySource
            if let sceneID, videoID == nil { source = .scene(try scene(sceneID)) }
            else if let videoID, sceneID == nil,
                    let video = library.videos.first(where: { $0.id == videoID }), video.duration.isFinite, video.duration > 0 {
                source = .file(url: video.url, duration: video.duration)
            } else { throw ScriptError.invalid("Choose exactly one available project scene or video.") }
            switch model.addCutaway(source: source, at: at, track: trackIndex, duration: duration,
                                    sourceStart: sourceStart, coverAll: coverAll) {
            case .added(let uid, let clamped):
                target = uid; created["clip"] = uid.uuidString
                if clamped != nil { warnings.append("Duration clamped to available source.") }
            case .noArea: throw ScriptError.invalid("Track has no area.")
            case .noSource: throw ScriptError.invalid("No usable source remains.")
            }
        case .setClipRole(let reference, let role):
            let value = try clip(reference)
            guard !value.bumper else { throw ScriptError.invalid("Bumpers cannot change role.") }
            model.setClipRole(value.uid, role: role)
        case .setCutawayAudio(let reference, let audio):
            let value = try clip(reference)
            guard value.isCutaway else { throw ScriptError.invalid("Audio choice requires a cutaway.") }
            model.setCutawayAudio(value.uid, audio)
        case .duplicateClip(let reference):
            model.duplicateClip(try clip(reference).uid)
            target = try addedClip(); created["clip"] = target?.uuidString
        case .setTrackSequential(let trackIndex, let sequential):
            try track(trackIndex)
            model.setTrackSequential(sequential, track: trackIndex)
            actual = .object(["track": .number(Double(trackIndex)), "sequential": .bool(sequential)])
        case .addCropBlock(let name, let at, let duration):
            try time(at ?? model.playhead)
            if let duration { try time(duration, positive: true) }
            let uid = model.addCropBlock(try layout(name), at: at, duration: duration ?? CropBlockItem.defaultDuration)
            if let block = model.cropBlock(uid) { created["block"] = uid.uuidString; actual = ScriptValue.stored(block) }
            else {
                warnings.append("Crop merged into an adjacent Full Screen block.")
                actual = ScriptValue.stored(model.document.cropBlocks)
            }
        case .setCropLayout(let reference, let name):
            let uid = try resolve(reference)
            guard model.cropBlock(uid) != nil else { throw ScriptError.invalid("Crop block is missing.") }
            model.setCropLayout(try layout(name), for: uid)
            actual = ScriptValue.stored(model.document.cropBlocks)
        case .removeCropBlock(let reference):
            let uid = try resolve(reference)
            guard model.cropBlock(uid) != nil else { throw ScriptError.invalid("Crop block is missing.") }
            model.removeCropBlock(uid)
        case .addBumper(let id, let at, let mode):
            try time(at ?? model.playhead)
            guard let bumper = library.bumpers[id], bumper.clip(at: 0) != nil else {
                throw ScriptError.invalid("Bumper resource is unavailable.")
            }
            model.addBumper(bumper, at: at, mode: mode)
            target = try addedClip(); created["clip"] = target?.uuidString
        case .addSound(let id, let at, let duration):
            try time(at ?? model.playhead); try time(duration, positive: true)
            guard let name = library.sounds[id] else { throw ScriptError.invalid("Sound resource is unavailable.") }
            model.addSound(name: name, at: at, duration: duration)
            let old = Set(before.soundTrack.map(\.uid))
            guard let item = model.document.soundTrack.first(where: { !old.contains($0.uid) }) else {
                throw ScriptError.invalid("Store refused the sound insertion.")
            }
            created["sound"] = item.uid.uuidString; actual = ScriptValue.stored(item)
        case .addText(let at, let text):
            try time(at ?? model.playhead)
            guard text.utf8.count <= 16000 else { throw ScriptError.invalid("Text exceeds 16 KiB.") }
            let uid = model.addText(at: at)
            model.updateText(uid) { $0.text = text }
            created["overlay"] = uid.uuidString; actual = ScriptValue.stored(model.textItem(uid))
        case .addImage(let id, let at, let length):
            try time(at ?? model.playhead); try time(length, positive: true)
            guard let path = library.images[id] else { throw ScriptError.invalid("Image resource is unavailable.") }
            let uid = model.addPhotoOverlay(path: path, at: at, length: length)
            created["overlay"] = uid.uuidString; actual = ScriptValue.stored(model.imageItem(uid))
        case .removeOverlay(let reference):
            let uid = try resolve(reference)
            if model.textItem(uid) != nil { model.removeText(uid) }
            else if model.imageItem(uid) != nil { model.removeImage(uid) }
            else if model.overlayBlock(uid) != nil { model.removeOverlayBlock(uid) }
            else { throw ScriptError.invalid("Overlay is missing.") }
        case .setPlayhead(let at):
            try time(at)
            if model.playhead == at { return .unchanged(reason: "Playhead already at requested time.") }
            model.playhead = at
            return .applied(actualValues: .object(["at": .number(at)]), createdIDs: [:], warnings: [])
        case .query: break
        }
        let diff = TimelineDiff(before: before, after: model.document)
        guard !diff.isEmpty else { return .unchanged(reason: "Requested state already holds.") }
        if let target, let clip = model.clip(target) {
            if let detail = actual { actual = .object(["clip": ScriptValue.stored(clip), "detail": detail]) }
            else { actual = ScriptValue.stored(clip) }
            if case .object(var values) = actual, let start = clip.sourceStart {
                values["playedSourceEnd"] = .number(start + clip.sourceSpan)
                actual = .object(values)
            }
        }
        return .applied(actualValues: actual ?? ScriptValue.stored(diff), createdIDs: created, warnings: warnings)
    }
}
