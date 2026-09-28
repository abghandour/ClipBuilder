import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Project timelines

    @discardableResult
    func createTimeline(named name: String = "Untitled Timeline",
                        document: TimelineDocument? = nil,
                        projectID requestedProjectID: Int64? = nil,
                        isWizardPlan: Bool = false, fixWithWizard: Bool = false, open: Bool = true,
                        onCreated: ((Int64) -> Void)? = nil) -> Task<Void, Never>? {
        guard let database, let projectID = requestedProjectID ?? activeProjectID else { return nil }
        let document = document ?? {
            var value = TimelineDocument()
            value.renderSettings = activeProfile.defaultRenderSettings
            return value
        }()
        guard let data = try? JSONEncoder().encode(document),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let generation = profileGeneration
        return Task {
            do {
                let id = try await database.createTimeline(projectID: projectID,
                                                           name: name,
                                                           documentJSON: json)
                onCreated?(id)
                let updatedProjects = try await database.fetchProjects()
                guard self.database === database, profileGeneration == generation else { return }
                projects = updatedProjects
                guard activeProjectID == projectID else { return }
                let updatedTimelines = try await database.fetchTimelines(projectID: projectID)
                guard self.database === database, profileGeneration == generation, activeProjectID == projectID else { return }
                timelines = updatedTimelines
                if open, let timeline = timelines.first(where: { $0.id == id }) {
                    openTimelineRecord(timeline)
                    builderPlanResult = isWizardPlan ? BuilderPlanResult(store: self, openRequested: fixWithWizard) : nil
                }
            } catch { presentError("Could not create the timeline", error) }
        }
    }

    /// "Add to Builder" from the scene grids. With a timeline open the
    /// scenes are appended to it; otherwise a new timeline is created for
    /// them first — the Builder's unsaved scratch document is not shown
    /// anywhere and would be discarded by the next open.
    func addScenesToBuilder(_ scenesToAdd: [SceneRecord]) {
        guard !scenesToAdd.isEmpty else { return }
        if openTimelineID != nil {
            scenesToAdd.forEach { builder.addScene($0) }
            selectSection(.timelines)
            return
        }
        guard let database, let projectID = activeProjectID else { return }
        var document = TimelineDocument()
        document.renderSettings = activeProfile.defaultRenderSettings
        guard let data = try? JSONEncoder().encode(document),
              let json = String(data: data, encoding: .utf8) else { return }
        let name = scenesToAdd.count == 1
            ? (scenesToAdd[0].videoFilename as NSString).deletingPathExtension
            : "\(scenesToAdd.count) scenes"
        Task {
            do {
                let id = try await database.createTimeline(projectID: projectID, name: name,
                                                           documentJSON: json)
                timelines = try await database.fetchTimelines(projectID: projectID)
                projects = try await database.fetchProjects()
                guard activeProjectID == projectID,
                      let timeline = timelines.first(where: { $0.id == id }) else { return }
                openTimelineRecord(timeline)
                scenesToAdd.forEach { builder.addScene($0) }
                selectSection(.timelines)
            } catch { presentError("Could not create a timeline for the scenes", error) }
        }
    }

    func openTimelineRecord(_ timeline: TimelineRecord, state: ProjectUIState? = nil) {
        if timeline.isWizard {
            duplicateTimeline(timeline, openCopy: true)
            return
        }
        guard let document = timeline.document else {
            presentError("This timeline could not be read.")
            return
        }
        // Leaving another timeline: remember where it was.
        if let current = openTimelineID, current != timeline.id {
            persistOpenTimelineViewState()
        }
        openTimelineID = timeline.id
        selectedSection = .timelines
        // The timeline's own viewport wins; an explicit project state (a
        // launch restore from before viewports were per timeline) is the
        // fallback, then defaults.
        let view: TimelineViewState
        if let cached = timelineViewStates[timeline.id] {
            view = cached
        } else if let own = timeline.viewState {
            view = own
        } else if let state {
            view = TimelineViewState(playhead: state.playhead, zoom: state.zoom,
                                     selection: state.timelineSelection,
                                     focusedTrack: state.timelineFocusedTrack,
                                     scrollX: state.timelineScrollX, scrollY: state.timelineScrollY)
        } else {
            view = TimelineViewState()
        }
        builder.loadTimeline(id: timeline.id, document: document, revision: timeline.documentRevision,
                             playhead: view.playhead, zoom: view.zoom,
                             selection: view.selection,
                             focusedTrack: view.focusedTrack)
        timelineScrollX = view.scrollX
        timelineScrollY = view.scrollY
        persistActiveProjectState()
    }

    /// The open timeline's viewport, encoded; nil with none open. Also
    /// records it in the session cache.
    func openTimelineViewStateJSON() -> (id: Int64, json: String)? {
        guard let openTimelineID else { return nil }
        let view = TimelineViewState(playhead: builder.playhead,
                                     zoom: Double(builder.pointsPerSecond),
                                     selection: builder.selection,
                                     focusedTrack: builder.focusedTrack,
                                     scrollX: timelineScrollX, scrollY: timelineScrollY)
        timelineViewStates[openTimelineID] = view
        guard let data = try? JSONEncoder().encode(view),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return (openTimelineID, json)
    }

    /// Write the open timeline's viewport (fire-and-forget).
    func persistOpenTimelineViewState() {
        guard let database, let (id, json) = openTimelineViewStateJSON() else { return }
        Task { try? await database.saveTimelineViewState(id: id, json: json) }
    }

    /// Builder timelines of the open project, in list order (Wizard rows
    /// open as copies, so they are not switch targets).
    var switchableTimelines: [TimelineRecord] {
        timelines.filter { !$0.isWizard }
    }

    /// Jump straight from one open timeline to another: the current one is
    /// saved first (loadTimeline flushes the autosave), the target opens
    /// fresh at its start.
    func switchTimeline(to timeline: TimelineRecord) {
        guard timeline.id != openTimelineID else { return }
        openTimelineRecord(timeline)
    }

    /// ⌥⌘[ / ⌥⌘]: previous / next timeline in the project.
    func cycleTimeline(offset: Int) {
        let candidates = switchableTimelines
        guard candidates.count > 1, let openTimelineID,
              let index = candidates.firstIndex(where: { $0.id == openTimelineID }) else { return }
        let next = (index + offset + candidates.count) % candidates.count
        switchTimeline(to: candidates[next])
    }

    func closeTimeline() {
        persistOpenTimelineViewState()
        persistActiveProjectState()
        openTimelineID = nil
        builder.closeTimeline(defaultRenderSettings: activeProfile.defaultRenderSettings)
        persistActiveProjectState()
    }

    func renameTimeline(_ timeline: TimelineRecord, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let database, let activeProjectID else { return }
        Task {
            do {
                try await database.renameTimeline(id: timeline.id, name: trimmed)
                timelines = try await database.fetchTimelines(projectID: activeProjectID)
            } catch { presentError("Could not rename the timeline", error) }
        }
    }

    func duplicateTimeline(_ timeline: TimelineRecord, openCopy: Bool = false) {
        guard let database, let activeProjectID else { return }
        Task {
            do {
                let name = timeline.name.hasSuffix(" Copy") ? "\(timeline.name) 2" : "\(timeline.name) Copy"
                let id = try await database.duplicateTimeline(id: timeline.id, name: name)
                timelines = try await database.fetchTimelines(projectID: activeProjectID)
                projects = try await database.fetchProjects()
                if openCopy, let id, let copy = timelines.first(where: { $0.id == id }) {
                    openTimelineRecord(copy)
                }
            } catch { presentError("Could not duplicate the timeline", error) }
        }
    }

    func deleteTimeline(_ timeline: TimelineRecord) {
        guard let database, let activeProjectID else { return }
        Task {
            do {
                try await database.deleteTimeline(id: timeline.id)
                if openTimelineID == timeline.id { closeTimeline() }
                timelines = try await database.fetchTimelines(projectID: activeProjectID)
                projects = try await database.fetchProjects()
            } catch { presentError("Could not delete the timeline", error) }
        }
    }

    struct TimelineSaveKey: Hashable {
        let database: ObjectIdentifier
        let id: Int64
    }
    struct TimelineSaveSnapshot {
        let version: UInt64
        let revision: Int
        let runUUID: String?
        let runStatus: BuilderRunStatus?
        let document: TimelineDocument
        let thumbnailVideoID: Int64?
    }

    @concurrent
    nonisolated private static func encodeTimeline(_ document: TimelineDocument) async throws -> String {
        String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
    }

    func saveTimeline(id: Int64, document: TimelineDocument) {
        guard let database else { return }
        // Quit and timeline switches may flush a document autosave already
        // persisted. Do not submit that revision to the database CAS again.
        guard builder.revision != builder.persistedRevision else { return }
        let key = TimelineSaveKey(database: ObjectIdentifier(database), id: id)
        timelineSaveVersion += 1
        pendingTimelineSaves[key] = TimelineSaveSnapshot(
            version: timelineSaveVersion, revision: builder.revision,
            runUUID: builder.scriptRunStatus?.uuid, runStatus: builder.scriptRunStatus?.status, document: document,
            thumbnailVideoID: document.videoTrack.first?.sceneID
                .flatMap { sceneID in scenes.first(where: { $0.id == sceneID })?.videoID })
        guard timelineSaveTasks[key] == nil else { return }
        // One drain per database/timeline serializes writes; newer snapshots
        // replace queued snapshots and invalidate an encode still in progress.
        timelineSaveTasks[key] = Task {
            defer { timelineSaveTasks[key] = nil }
            var savedRevision: Int?
            while let snapshot = pendingTimelineSaves.removeValue(forKey: key) {
                // A second flush can arrive while the first write is suspended.
                if snapshot.revision == savedRevision { continue }
                do {
                    let json = try await Self.encodeTimeline(snapshot.document)
                    if let newer = pendingTimelineSaves[key], newer.version > snapshot.version { continue }
                    try await database.saveTimelineRevision(id: id, documentJSON: json, revision: snapshot.revision,
                                                           thumbnailVideoID: snapshot.thumbnailVideoID,
                                                           runUUID: snapshot.runUUID, status: snapshot.runStatus)
                    savedRevision = snapshot.revision
                    timelineSaveFailures[key] = nil
                    if self.database === database, builder.timelineID == id {
                        builder.acknowledgePersistedRevision(snapshot.revision)
                    }
                    let row = try await database.fetchTimeline(id: id)
                    guard self.database === database, let row,
                          activeProjectID == row.projectID,
                          pendingTimelineSaves[key] == nil,
                          let index = timelines.firstIndex(where: { $0.id == id }) else { continue }
                    timelines[index] = row
                    timelines.sort {
                        if $0.editedAt != $1.editedAt { return ($0.editedAt ?? "") > ($1.editedAt ?? "") }
                        return $0.id > $1.id
                    }
                } catch {
                    timelineSaveFailures[key] = .persistence(String(describing: error))
                    presentError("Could not save the timeline", error)
                }
            }
        }
    }


    /// Drains the same queue used by autosave, then commits and installs without
    /// suspension on MainActor. The non-suspending section is the edit/switch/
    /// hydration gate; no UI or Library callback can interleave with it.
    func applyWizardRun(session: BuilderScriptSession, request: String,
                        provenance: AIProvenance) async -> Result<Int, ApplyFailure> {
        guard !wizardCommitInProgress else { return .failure(.commitInProgress) }
        guard let database, let id = session.timelineID,
              builder.timelineID == id, builder.profileName == session.profileName,
              activeProjectID == session.projectID else { return .failure(.identityChanged) }
        if session.state == .failed || session.state == .discarded {
            do {
                try await recordWizardRun(session: session, request: request, provenance: provenance,
                                          status: session.state == .failed ? .failed : .discarded)
            } catch { return .failure(.persistence(String(describing: error))) }
            return .failure(.notApplicable)
        }
        guard session.state == .completed, let candidate = session.frozenCandidate,
              !session.diff().isEmpty else { return .failure(.notApplicable) }
        wizardCommitInProgress = true
        defer { wizardCommitInProgress = false }
        let generation = profileGeneration
        do { try await drainTimelineSaves(database: database, id: id) }
        catch let failure as ApplyFailure { return .failure(failure) }
        catch { return .failure(.persistence(String(describing: error))) }
        guard self.database === database, generation == profileGeneration,
              activeProjectID == session.projectID else { return .failure(.identityChanged) }
        if let failure = builder.validateScriptSnapshot(candidate: candidate, baseline: session.baseline,
                                                        baselineRevision: session.baselineRevision) {
            return .failure(failure)
        }
        let manager = builder.undoManager
        defer { withExtendedLifetime(manager) {} }
        // No await from validation through durable commit and live installation.
        do {
            let revision = builder.revision + 1
            let before = builder.document
            let run = makeBuilderRun(session: session, request: request, provenance: provenance,
                                     status: .applied, appliedRevision: revision)
            let beforeRow = WizardBeforeRecord(timelineID: id, runUUID: session.runUUID, request: request,
                                                documentJSON: try wizardDocumentJSON(before), appliedRevision: revision)
            let json = try wizardDocumentJSON(candidate.document)
            try database.commitWizardSnapshot(timelineID: id, documentJSON: json,
                                               expectedRevision: builder.persistedRevision, revision: revision,
                                               thumbnailVideoID: wizardThumbnail(candidate.document),
                                               run: run, before: beforeRow)
            let result = builder.applyScriptSnapshot(candidate: candidate, baseline: before,
                                                     baselineRevision: session.baselineRevision, actionName: request)
            wizardBeforeSnapshots[TimelineSaveKey(database: ObjectIdentifier(database), id: id)] = (session.runUUID, before)
            builder.acknowledgePersistedRevision(revision)
            updateCommittedTimeline(id: id, json: json, revision: revision)
            return result
        } catch let failure as ApplyFailure { return .failure(failure) }
        catch { return .failure(.persistence(String(describing: error))) }
    }

    /// Restores ordinary timeline JSON (runtime clip IDs regenerate and Library
    /// metadata is hydrated once before freezing). A successful Revert deletes
    /// the before-version row; it is not repeatable. Undo does not recreate it.
    func revertLastWizardRun(timelineID: Int64, expectedRunUUID: String? = nil) async -> Result<Int, ApplyFailure> {
        guard !wizardCommitInProgress else { return .failure(.commitInProgress) }
        guard let database, builder.timelineID == timelineID else { return .failure(.identityChanged) }
        wizardCommitInProgress = true
        defer { wizardCommitInProgress = false }
        let generation = profileGeneration
        let profile = builder.profileName
        let revision = builder.revision
        let baseline = builder.document
        do {
            guard let before = try await database.fetchWizardBefore(timelineID: timelineID) else {
                return .failure(.missingBeforeVersion)
            }
            if let expectedRunUUID, before.runUUID != expectedRunUUID { return .failure(.staleRevision) }
            try await drainTimelineSaves(database: database, id: timelineID)
            guard self.database === database, generation == profileGeneration,
                  builder.timelineID == timelineID, builder.profileName == profile else {
                return .failure(.identityChanged)
            }
            // Ordinary reopening hydration, confined to a transient model.
            let working = BuilderTimelineModel(mode: .transient)
            working.seed(document: try before.document(), scenes: [])
            working.updateScenes(builder.scenes)
            let key = TimelineSaveKey(database: ObjectIdentifier(database), id: timelineID)
            let cached = wizardBeforeSnapshots[key]
            let restored = cached?.uuid == before.runUUID ? cached?.document ?? working.document : working.document
            let candidate = BuilderScriptSnapshot(document: restored, timelineID: timelineID,
                                                   profileName: profile, runUUID: before.runUUID)
            if let failure = builder.validateScriptSnapshot(candidate: candidate, baseline: baseline,
                                                            baselineRevision: revision, requiresUndo: false) {
                return .failure(failure)
            }
            let manager = builder.undoManager
            defer { withExtendedLifetime(manager) {} }
            let json = try wizardDocumentJSON(candidate.document)
            try database.commitWizardSnapshot(timelineID: timelineID, documentJSON: json,
                                               expectedRevision: builder.persistedRevision, revision: revision + 1,
                                               thumbnailVideoID: wizardThumbnail(candidate.document),
                                               run: nil, before: nil, revertingRunUUID: before.runUUID)
            let result = builder.applyRevertSnapshot(candidate: candidate, baseline: baseline,
                                                     baselineRevision: revision)
            wizardBeforeSnapshots[key] = nil
            builder.acknowledgePersistedRevision(revision + 1)
            updateCommittedTimeline(id: timelineID, json: json, revision: revision + 1)
            return result
        } catch let failure as ApplyFailure { return .failure(failure) }
        catch { return .failure(.persistence(String(describing: error))) }
    }

    /// Records terminal non-applied outcomes without changing the before-version.
    func recordWizardRun(session: BuilderScriptSession, request: String, provenance: AIProvenance,
                         status: BuilderRunStatus) async throws {
        guard [.completed, .failed, .discarded].contains(status) else { throw ApplyFailure.notApplicable }
        guard let database, session.timelineID == builder.timelineID,
              session.profileName == builder.profileName, session.projectID == activeProjectID else {
            throw ApplyFailure.identityChanged
        }
        try await database.recordBuilderRun(makeBuilderRun(session: session, request: request,
                                                           provenance: provenance, status: status))
    }

    private func makeBuilderRun(session: BuilderScriptSession, request: String, provenance: AIProvenance,
                                status: BuilderRunStatus, appliedRevision: Int? = nil) -> BuilderRunRecord {
        BuilderRunRecord(runUUID: session.runUUID, timelineID: session.timelineID ?? 0, request: request,
                         provider: provenance.provider, model: provenance.model, durationSeconds: provenance.duration,
                         status: status, baselineRevision: session.baselineRevision, appliedRevision: appliedRevision)
    }

    private func drainTimelineSaves(database: Database, id: Int64) async throws {
        let key = TimelineSaveKey(database: ObjectIdentifier(database), id: id)
        if self.database === database, builder.timelineID == id { builder.flushPendingAutosave() }
        while let task = timelineSaveTasks[key] {
            await task.value
            // Edits may have arrived during the drain; preserve them before refusing stale Apply.
            if self.database === database, builder.timelineID == id { builder.flushPendingAutosave() }
        }
        if let failure = timelineSaveFailures[key] { throw failure }
    }

    private func wizardDocumentJSON(_ document: TimelineDocument) throws -> String {
        String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
    }

    private func wizardThumbnail(_ document: TimelineDocument) -> Int64? {
        document.videoTrack.first?.sceneID.flatMap { id in scenes.first { $0.id == id }?.videoID }
    }

    private func updateCommittedTimeline(id: Int64, json: String, revision: Int) {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        timelines[index].documentJSON = json
        timelines[index].documentRevision = revision
        timelines[index].thumbnailVideoID = wizardThumbnail(builder.document)
    }

    nonisolated static func wizardTimelineKey(_ video: GeneratedVideoRecord, formatName: String) -> String {
        formatName == "podcast_highlights" ? "video-\(video.id)" : video.batchID ?? "video-\(video.id)"
    }

    func recordWizardTimelines(_ videos: [GeneratedVideoRecord], projectID: Int64,
                                       formatName: String = "Wizard Run", timelineNames: [String: String] = [:]) async {
        guard let database else { return }
        let groups = Dictionary(grouping: videos) { Self.wizardTimelineKey($0, formatName: formatName) }
        for (runID, versions) in groups {
            guard let first = versions.sorted(by: { $0.id < $1.id }).first else { continue }
            let sceneID = first.timelineJSON.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(TimelineDocument.self, from: $0) }?
                .videoTrack.first?.sceneID
            let thumbnailVideoID: Int64?
            if let sceneID {
                thumbnailVideoID = try? await database.fetchScenes(sceneID: sceneID).first?.videoID
            } else {
                thumbnailVideoID = nil
            }
            try? await database.ensureWizardTimeline(
                projectID: projectID,
                name: timelineNames[first.path] ?? (formatName == "podcast_highlights" ? first.url.deletingPathExtension().lastPathComponent : "Wizard · \(formatName)"),
                documentJSON: first.timelineJSON,
                sourceRunID: runID,
                thumbnailVideoID: thumbnailVideoID
            )
        }
        if activeProjectID == projectID {
            timelines = (try? await database.fetchTimelines(projectID: projectID)) ?? timelines
        }
        projects = (try? await database.fetchProjects()) ?? projects
    }

    // MARK: - Clip Builder

    /// Render the builder timeline through the multitrack pipeline and file
    /// the result into the Library. Mirrors the runWizard job pattern.
    func renderBuilderTimeline() {
        guard let database, !isBuilderRendering, !isBuilderPreviewRendering else { return }
        guard !builder.document.videoTrack.isEmpty else {
            presentError("Add clips to the timeline first.")
            return
        }
        isBuilderRendering = true
        builderRenderProjectID = activeProjectID
        builderRenderProjectName = activeProject?.name
        builderLog = []
        let document = builder.document
        let scenes = builder.scenes
        let profile = activeProfile
        let projectID = activeProjectID
        let renderer = multitrackRenderer
        let outputName = MultitrackRenderer.outputBaseName(project: activeProject?.name,
                                                           timeline: openTimeline?.name)
        builderRenderTask = Task {
            do {
                let result = try await renderer.render(document: document, scenes: scenes,
                                                       profile: profile, database: database,
                                                       centerStageCamera: WizardDefaults.fallbackFramingCamera,
                                                       projectID: projectID,
                                                       outputName: outputName,
                                                       emit: logSink(\.builderLog))
                appendLog(\.builderLog, ["Done: \(result.url.lastPathComponent) (\(result.duration.timecode))"])
                finishedBuilderRender = FinishedRender(url: result.url, duration: result.duration)
            } catch is CancellationError {
                appendLog(\.builderLog, ["Render stopped."])
            } catch {
                appendLog(\.builderLog, ["Failed: \(error.userMessage)"])
                presentError("Builder render failed", error)
            }
            isBuilderRendering = false
            refreshAll()
        }
    }

    func cancelBuilderRender() {
        builderRenderTask?.cancel()
    }

    /// Render Builder through the same multitrack pipeline used for the
    /// final output, but keep the resulting file temporary. This is the
    /// honest alternative to the instant AVFoundation preview, which cannot
    /// reproduce crops, captions, transitions, or overlays.
    /// Seconds of final footage the Preview sheet renders from the playhead.
    nonisolated static let exactPreviewWindow: Double = 5

    /// Renders `seconds` of the final pipeline starting at `playhead` (clamped
    /// so the window stays inside the timeline) to a temporary file. Nothing
    /// is added to the Library; the sheet deletes the file when done.
    func renderBuilderExactPreview(from playhead: Double, seconds: Double = AppStore.exactPreviewWindow,
                                   priority: MediaWorkScheduler.Priority = .interactive) async -> URL? {
        guard let database, !isBuilderRendering, !isBuilderPreviewRendering else { return nil }
        guard !builder.document.videoTrack.isEmpty else {
            presentError("Add clips to the timeline first.")
            return nil
        }

        isBuilderPreviewRendering = true
        defer { isBuilderPreviewRendering = false }
        let window = Self.exactPreviewRange(from: playhead, seconds: seconds, totalDuration: builder.totalDuration)
        let document = MultitrackRenderer.windowed(builder.document, from: window.lowerBound, to: window.upperBound)
        appendLog(\.builderLog, ["— Exact preview: rendering \(window.lowerBound.timecode)–\(window.upperBound.timecode) (\(document.videoTrack.count) clip(s)) —"], channel: "builder-preview")

        let scenes = builder.scenes
        let profile = activeProfile
        let renderer = multitrackRenderer
        do {
            let result = try await MediaWorkScheduler.$priority.withValue(priority) {
                try await renderer.render(document: document, scenes: scenes,
                                          profile: profile, database: database,
                                          centerStageCamera: WizardDefaults.fallbackFramingCamera,
                                          preview: true, emit: logSink(\.builderLog, channel: "builder-preview"))
            }
            appendLog(\.builderLog, ["Exact preview ready: \(result.duration.timecode)"], channel: "builder-preview")
            return result.url
        } catch is CancellationError {
            appendLog(\.builderLog, ["Exact preview stopped."], channel: "builder-preview")
            return nil
        } catch {
            appendLog(\.builderLog, ["Exact preview failed: \(error.userMessage)"], channel: "builder-preview")
            presentError("Exact preview failed", error)
            return nil
        }
    }

    /// Pressing Preview: play the slice of the final video that starts at
    /// the playhead. A cached slice plays at once; otherwise
    /// `exactPreviewWindow` seconds are rendered first. While a slice plays
    /// the next one is rendered ahead, so playback continues past the first
    /// slice whenever the following one is ready. Nothing enters the Library.
    func startBuilderPreview(from time: Double? = nil) {
        stopBuilderPreview()
        guard !builder.document.videoTrack.isEmpty else { presentError("Add clips to the timeline first."); return }
        guard !isBuilderRendering else { presentError("Wait for the Library render to finish."); return }
        pruneBuilderPreviewCache()
        let playhead = time ?? builder.playhead
        let window = Self.exactPreviewRange(from: playhead, seconds: Self.exactPreviewWindow, totalDuration: builder.totalDuration)
        guard window.upperBound > window.lowerBound else { return }
        builderPreviewChainStart = window.lowerBound
        builderPreviewLastPlayed = nil
        if let cached = cachedBuilderPreview(for: window) {
            play(cached)
            return
        }
        builderPreviewWindow = window
        builderPreviewTask = Task { [weak self] in
            guard let self else { return }
            let slice = await renderBuilderPreviewSlice(window: window)
            guard !Task.isCancelled else { return }
            builderPreviewWindow = nil
            guard let slice else { builderPreviewChainStart = nil; return }
            play(slice)
        }
    }

    /// Plays the last run again from where it started (cached, so instant).
    func replayBuilderPreview() {
        guard let range = builderPreviewLastPlayed else { return }
        startBuilderPreview(from: range.lowerBound)
    }

    /// Stops in-place playback and any render in flight. Cached files stay
    /// for the next press; `pruneBuilderPreviewCache` drops stale ones.
    func stopBuilderPreview() {
        builderPreviewTask?.cancel()
        builderPreviewTask = nil
        builderPrefetchTask?.cancel()
        builderPrefetchTask = nil
        builderPreviewWindow = nil
        if let preview = builderPreview {
            builderPreview = nil
            if let start = builderPreviewChainStart { builderPreviewLastPlayed = start...builder.playhead }
            _ = preview
        }
        builderPreviewChainStart = nil
    }

    /// The current slice ended: continue with the next cached slice if the
    /// prefetch got there, otherwise finish and offer Replay.
    func advanceBuilderPreview() {
        guard let current = builderPreview else { return }
        let end = current.window.upperBound
        if end < builder.totalDuration - 0.05 {
            let next = Self.exactPreviewRange(from: end, seconds: Self.exactPreviewWindow, totalDuration: builder.totalDuration)
            if next.lowerBound >= end - 0.001, let cached = cachedBuilderPreview(for: next) {
                play(cached)
                return
            }
        }
        builderPreviewLastPlayed = (builderPreviewChainStart ?? current.window.lowerBound)...end
        builderPrefetchTask?.cancel()
        builderPrefetchTask = nil
        builderPreview = nil
        builderPreviewChainStart = nil
    }

    private func play(_ slice: BuilderInPlacePreview) {
        touchBuilderPreviewCache(slice.key)
        builder.playhead = slice.window.lowerBound
        builderPreview = slice
        prefetchBuilderPreview(after: slice)
    }

    /// Renders the slice after `slice` while it plays, if it is not cached.
    private func prefetchBuilderPreview(after slice: BuilderInPlacePreview) {
        builderPrefetchTask?.cancel()
        let end = slice.window.upperBound
        guard end < builder.totalDuration - 0.05 else { return }
        let next = Self.exactPreviewRange(from: end, seconds: Self.exactPreviewWindow, totalDuration: builder.totalDuration)
        guard next.lowerBound >= end - 0.001, cachedBuilderPreview(for: next) == nil else { return }
        builderPrefetchTask = Task { [weak self] in
            guard let self else { return }
            _ = await renderBuilderPreviewSlice(window: next, priority: .background)
        }
    }

    /// Renders one window and files it in the cache under its content key.
    private func renderBuilderPreviewSlice(window: ClosedRange<Double>,
                                           priority: MediaWorkScheduler.Priority = .interactive) async -> BuilderInPlacePreview? {
        guard let key = builderPreviewKey(for: window) else { return nil }
        if let cached = builderPreviewCache[key], FileManager.default.fileExists(atPath: cached.url.path) { return cached }
        guard let rendered = await renderBuilderExactPreview(from: window.lowerBound, seconds: window.upperBound - window.lowerBound, priority: priority) else { return nil }
        guard !Task.isCancelled else { try? FileManager.default.removeItem(at: rendered); return nil }
        // The render's own key may differ if the document changed meanwhile.
        guard builderPreviewKey(for: window) == key else { try? FileManager.default.removeItem(at: rendered); return nil }
        let slice = BuilderInPlacePreview(window: window, url: rendered, key: key)
        insertBuilderPreviewCache(slice)
        return slice
    }

    private func cachedBuilderPreview(for window: ClosedRange<Double>) -> BuilderInPlacePreview? {
        guard let key = builderPreviewKey(for: window), let slice = builderPreviewCache[key] else { return nil }
        guard FileManager.default.fileExists(atPath: slice.url.path) else { removeBuilderPreviewCache(key); return nil }
        return slice
    }

    private func insertBuilderPreviewCache(_ slice: BuilderInPlacePreview) {
        if let old = builderPreviewCache[slice.key], old.url != slice.url { try? FileManager.default.removeItem(at: old.url) }
        builderPreviewCache[slice.key] = slice
        touchBuilderPreviewCache(slice.key)
        while builderPreviewCacheOrder.count > Self.builderPreviewCacheLimit, let oldest = builderPreviewCacheOrder.first {
            if oldest == builderPreview?.key { break }
            removeBuilderPreviewCache(oldest)
        }
    }

    private func touchBuilderPreviewCache(_ key: String) {
        builderPreviewCacheOrder.removeAll { $0 == key }
        builderPreviewCacheOrder.append(key)
    }

    private func removeBuilderPreviewCache(_ key: String) {
        builderPreviewCacheOrder.removeAll { $0 == key }
        if let slice = builderPreviewCache.removeValue(forKey: key) {
            let url = slice.url
            Task.detached { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Drops every cached slice whose window no longer produces the same
    /// content (the timeline changed under it). Correctness over speed: a
    /// slice that is playing is stopped too. Called on every document change
    /// and before each press.
    func pruneBuilderPreviewCache() {
        for (key, slice) in builderPreviewCache where builderPreviewKey(for: slice.window) != key {
            if builderPreview?.key == key {
                builderPreview = nil
                builderPreviewChainStart = nil
                builderPrefetchTask?.cancel()
                builderPrefetchTask = nil
            }
            removeBuilderPreviewCache(key)
        }
        // Replay must not replay a stale run.
        if let range = builderPreviewLastPlayed {
            let window = Self.exactPreviewRange(from: range.lowerBound, seconds: Self.exactPreviewWindow, totalDuration: builder.totalDuration)
            if cachedBuilderPreview(for: window) == nil { builderPreviewLastPlayed = nil }
        }
    }

    /// Deletes every cached slice (quit).
    func clearBuilderPreviewCache() {
        stopBuilderPreview()
        for key in Array(builderPreviewCache.keys) { removeBuilderPreviewCache(key) }
        builderPreviewLastPlayed = nil
    }

    /// Everything the render of `window` depends on, from the document side:
    /// the windowed document itself, the scene facts the renderer reads for
    /// its clips, the brand profile (captions, fonts) and the framing camera.
    private func builderPreviewKey(for window: ClosedRange<Double>) -> String? {
        Self.builderPreviewKey(document: builder.document, scenes: builder.scenes, profile: activeProfile,
                               camera: WizardDefaults.fallbackFramingCamera, window: window)
    }

    nonisolated static func builderPreviewKey(document: TimelineDocument, scenes: [SceneRecord], profile: BrandProfile,
                                              camera: String, window: ClosedRange<Double>) -> String? {
        struct SceneFacts: Encodable {
            var id: Int64; var videoPath: String; var startTime: Double; var endTime: Double
            var centerStagePathJSON: String?; var cropXFrac: Double?; var freeCropsJSON: String?; var wide: Bool
        }
        struct Evidence: Encodable {
            var document: TimelineDocument
            /// The renderer's own view of each clip (source path, trimmed
            /// range, speed, effects): the document encoder omits some of
            /// these fields depending on the clip's kind.
            var clips: [MultitrackRenderer.ResolvedClip]
            var scenes: [SceneFacts]
            var profile: BrandProfile
            var camera: String
            var seconds: Double
        }
        let windowed = MultitrackRenderer.windowed(document, from: window.lowerBound, to: window.upperBound)
        let used = Set(windowed.videoTrack.compactMap(\.sceneID))
        let facts = scenes.filter { used.contains($0.id) }.sorted { $0.id < $1.id }.map {
            SceneFacts(id: $0.id, videoPath: $0.videoPath, startTime: $0.startTime, endTime: $0.endTime,
                       centerStagePathJSON: $0.centerStagePathJSON, cropXFrac: $0.cropXFrac,
                       freeCropsJSON: $0.freeCropsJSON, wide: $0.wide)
        }
        let evidence = Evidence(document: windowed, clips: MultitrackRenderer.resolveClips(document: windowed, scenes: scenes),
                                scenes: facts, profile: profile, camera: camera,
                                seconds: window.upperBound - window.lowerBound)
        return try? RenderSegmentCache.key(evidence, version: "builder-preview-slice-v1")
    }

    /// The preview window: `seconds` from the playhead, pulled back so it
    /// ends at the timeline's end, never past it, never before 0.
    nonisolated static func exactPreviewRange(from playhead: Double, seconds: Double, totalDuration: Double) -> ClosedRange<Double> {
        let length = max(0, min(seconds, totalDuration))
        let start = min(max(0, playhead), max(0, totalDuration - length))
        return start...(start + length)
    }

    // MARK: - Manual build


    /// Render a manual-build document through the Builder's multitrack
    /// pipeline, logging into the wizard's Generation Log. The branded outro
    /// card (a wizard-assemble feature the multitrack renderer doesn't have)
    /// is pre-rendered here and appended as a plain video clip.
    func renderManualBuildDocument(_ document: TimelineDocument, includeOutro: Bool) {
        guard let database, !isManualBuildRendering else { return }
        isManualBuildRendering = true
        appendLog(\.wizardLog, ["— Manual build: rendering \(document.videoTrack.count) clip(s) —"])
        let profile = activeProfile
        let renderer = multitrackRenderer
        let scenes = self.scenes
        let projectID = activeProjectID
        Task {
            do {
                let document = try await manualBuildDocument(document, includeOutro: includeOutro,
                                                         profile: profile)
                let result = try await renderer.render(document: document, scenes: scenes,
                                                       profile: profile, database: database,
                                                       centerStageCamera: WizardDefaults.fallbackFramingCamera,
                                                       projectID: projectID,
                                                       emit: logSink(\.wizardLog))
                appendLog(\.wizardLog, ["VIDEO:\(result.url.lastPathComponent):\(String(format: "%.1f", result.duration))"])
            } catch is CancellationError {
                appendLog(\.wizardLog, ["Manual build render stopped."])
            } catch {
                appendLog(\.wizardLog, ["Error: \(error.userMessage)"])
                presentError("Manual build render failed", error)
            }
            isManualBuildRendering = false
            refreshAll()
        }
    }


    private func manualBuildDocument(_ document: TimelineDocument, includeOutro: Bool,
                                 profile: BrandProfile) async throws -> TimelineDocument {
        var document = document
        var options = WizardOptions()
        options.readBumperDefaults()
        let assets = (try? await database?.bumpers()) ?? []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(document)
        let preferenceKey = "\(options.includeIntroBumper)|\(options.includeOutroBumper)|\(options.includeMiddleBumper)"
        let catalogKey = assets.map { "\($0.path)|\($0.displayName)|\($0.duration ?? 0)|\($0.placements.map(\.rawValue).sorted())" }.joined(separator: ";")
        let selectionKey = original.base64EncodedString() + preferenceKey + catalogKey + "\(includeOutro)|\(profile.profileName)"
        if includeOutro,
           profile.logoURL != nil || !(profile.socials["instagram"]?.handle ?? "").isEmpty {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("ManualBuildOutro-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            if let png = BrandRenderer.outroCard(profile: profile, to: scratch) {
                let card = scratch.appendingPathComponent("outro_card.mp4")
                try await BrandRenderer.cardClip(png: png, duration: 2.5, output: card)
                var clip = TimelineClip()
                clip.videoFile = card.path
                clip.sourceStart = 0
                clip.sourceEnd = 2.5
                clip.duration = 2.5
                clip.startTime = document.videoTrack.map { $0.startTime + $0.duration }.max() ?? 0
                clip.transIn = "fadeblack"
                document.videoTrack.append(clip)
                appendLog(\.wizardLog, ["Branded outro card appended"])
            }
        }
        if let cached = manualBuildBumperSelection, cached.key == selectionKey {
            for clip in cached.clips {
                BumperPlanner.insertGap(in: &document, at: clip.startTime, duration: clip.duration)
                document.videoTrack.append(clip)
                appendLog(\.wizardLog, ["Bumper '\(clip.bumperName ?? "Bumper")' inserted at \(clip.startTime.timecode)"])
            }
        } else {
            let existing = Set(document.videoTrack.map(\.uid))
            let log = BumperPlanner.apply(to: &document, bumpers: assets, options: options)
            appendLog(\.wizardLog, log)
            manualBuildBumperSelection = (selectionKey, document.videoTrack.filter { $0.bumper && !existing.contains($0.uid) }
                .sorted { $0.startTime < $1.startTime })
        }
        return document
    }

    /// Exact preview for the manual build: the REAL render pipeline
    /// (framing, transitions, music, overlays, outro — identical output) to
    /// a temporary file the reel preview plays. Nothing lands in the
    /// Library. Returns nil on failure or cancellation.
    func renderManualBuildExactPreview(_ document: TimelineDocument,
                                   includeOutro: Bool) async -> URL? {
        guard let database, !isManualBuildPreviewRendering else { return nil }
        isManualBuildPreviewRendering = true
        defer { isManualBuildPreviewRendering = false }
        appendLog(\.wizardLog, ["— Exact preview: rendering \(document.videoTrack.count) clip(s) —"])
        let profile = activeProfile
        let renderer = multitrackRenderer
        let scenes = self.scenes
        do {
            let document = try await manualBuildDocument(document, includeOutro: includeOutro,
                                                     profile: profile)
            let result = try await renderer.render(document: document, scenes: scenes,
                                                   profile: profile, database: database,
                                                   centerStageCamera: WizardDefaults.fallbackFramingCamera,
                                                   preview: true, emit: logSink(\.wizardLog))
            return result.url
        } catch is CancellationError {
            appendLog(\.wizardLog, ["Exact preview stopped."])
            return nil
        } catch {
            appendLog(\.wizardLog, ["Exact preview failed: \(error.userMessage)"])
            presentError("Exact preview failed", error)
            return nil
        }
    }
}
